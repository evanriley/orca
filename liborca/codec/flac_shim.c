#include "flac_shim.h"

#include <stdlib.h>
#include <string.h>

#include <FLAC/stream_decoder.h>

/* How many times a single read request may drive libFLAC forward without
 * obtaining audio. A metadata block, a resync after damaged bytes, or a frame
 * libFLAC discards all cost an iteration; a stream that never produces audio
 * and never reports end of stream is refused rather than spun on. */
#define ORCA_FLAC_MAX_EMPTY_STEPS 4096

struct orca_flac_decoder {
    FLAC__StreamDecoder *native;
    void *context;
    orca_flac_read_fn read;
    /* Byte cursor libFLAC believes it is at, maintained by the read and seek
     * callbacks because the source is positional and holds no cursor. */
    uint64_t position;
    uint64_t size;
    /* One decoded block, interleaved, as libFLAC delivered it. Capacity is in
     * samples. */
    int32_t *pending;
    uint32_t pending_capacity;
    uint32_t pending_bits;
    uint32_t pending_frames;
    uint32_t pending_offset;
    uint32_t channels;
    /* Set when the caller's positional read reported failure. libFLAC reports
     * an aborted read the same way it reports several benign conditions, so
     * the distinction is kept here rather than inferred from decoder state. */
    int read_failed;
    uint64_t stream_errors;
    int md5_mismatch;
    /* Set once end of stream has finished the native decoder, which is the
     * only point libFLAC reports the MD5 comparison. */
    int finished;
};

static FLAC__StreamDecoderReadStatus read_callback(const FLAC__StreamDecoder *native,
                                                   FLAC__byte buffer[],
                                                   size_t *bytes,
                                                   void *client_data)
{
    struct orca_flac_decoder *self = client_data;
    int64_t obtained;

    (void)native;
    if (*bytes == 0) {
        return FLAC__STREAM_DECODER_READ_STATUS_ABORT;
    }
    obtained = self->read(self->context, self->position, buffer, (uint64_t)*bytes);
    if (obtained < 0) {
        self->read_failed = 1;
        *bytes = 0;
        return FLAC__STREAM_DECODER_READ_STATUS_ABORT;
    }
    if (obtained == 0) {
        *bytes = 0;
        return FLAC__STREAM_DECODER_READ_STATUS_END_OF_STREAM;
    }
    self->position += (uint64_t)obtained;
    *bytes = (size_t)obtained;
    return FLAC__STREAM_DECODER_READ_STATUS_CONTINUE;
}

static FLAC__StreamDecoderSeekStatus seek_callback(const FLAC__StreamDecoder *native,
                                                   FLAC__uint64 absolute_byte_offset,
                                                   void *client_data)
{
    struct orca_flac_decoder *self = client_data;

    (void)native;
    if (absolute_byte_offset > self->size) {
        return FLAC__STREAM_DECODER_SEEK_STATUS_ERROR;
    }
    self->position = absolute_byte_offset;
    return FLAC__STREAM_DECODER_SEEK_STATUS_OK;
}

static FLAC__StreamDecoderTellStatus tell_callback(const FLAC__StreamDecoder *native,
                                                   FLAC__uint64 *absolute_byte_offset,
                                                   void *client_data)
{
    struct orca_flac_decoder *self = client_data;

    (void)native;
    *absolute_byte_offset = self->position;
    return FLAC__STREAM_DECODER_TELL_STATUS_OK;
}

static FLAC__StreamDecoderLengthStatus length_callback(const FLAC__StreamDecoder *native,
                                                       FLAC__uint64 *stream_length,
                                                       void *client_data)
{
    struct orca_flac_decoder *self = client_data;

    (void)native;
    *stream_length = self->size;
    return FLAC__STREAM_DECODER_LENGTH_STATUS_OK;
}

static FLAC__bool eof_callback(const FLAC__StreamDecoder *native, void *client_data)
{
    struct orca_flac_decoder *self = client_data;

    (void)native;
    return self->position >= self->size;
}

static int reserve_pending(struct orca_flac_decoder *self, uint32_t samples)
{
    int32_t *grown;

    if (samples <= self->pending_capacity) {
        return 1;
    }
    grown = realloc(self->pending, (size_t)samples * sizeof(int32_t));
    if (!grown) {
        return 0;
    }
    self->pending = grown;
    self->pending_capacity = samples;
    return 1;
}

static FLAC__StreamDecoderWriteStatus write_callback(const FLAC__StreamDecoder *native,
                                                     const FLAC__Frame *frame,
                                                     const FLAC__int32 *const buffer[],
                                                     void *client_data)
{
    struct orca_flac_decoder *self = client_data;
    uint32_t channels = frame->header.channels;
    uint32_t blocksize = frame->header.blocksize;
    uint32_t bits = frame->header.bits_per_sample;
    uint32_t frame_index;
    uint32_t channel;

    (void)native;
    /* A stream that changes shape mid-file would silently reinterpret already
     * reported format facts, so it is refused rather than accommodated. */
    if (self->channels != 0 && channels != self->channels) {
        return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT;
    }
    if (channels == 0 || bits == 0 || bits > 32) {
        return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT;
    }
    if (!reserve_pending(self, channels * blocksize)) {
        return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT;
    }
    self->channels = channels;
    self->pending_bits = bits;
    for (frame_index = 0; frame_index < blocksize; frame_index++) {
        for (channel = 0; channel < channels; channel++) {
            self->pending[frame_index * channels + channel] = buffer[channel][frame_index];
        }
    }
    self->pending_frames = blocksize;
    self->pending_offset = 0;
    return FLAC__STREAM_DECODER_WRITE_STATUS_CONTINUE;
}

static void metadata_callback(const FLAC__StreamDecoder *native,
                              const FLAC__StreamMetadata *metadata,
                              void *client_data)
{
    (void)native;
    (void)metadata;
    (void)client_data;
}

static void error_callback(const FLAC__StreamDecoder *native,
                           FLAC__StreamDecoderErrorStatus status,
                           void *client_data)
{
    struct orca_flac_decoder *self = client_data;

    (void)native;
    (void)status;
    /* Counted, never fatal: libFLAC resyncs on its own, and a trailing tag
     * looks like a lost sync. Whether an error is damage is decided by the
     * caller against STREAMINFO's declared total. */
    self->stream_errors++;
}

static int start_native(struct orca_flac_decoder *self)
{
    self->position = 0;
    self->finished = 0;
    /* The caller parses STREAMINFO itself, so no metadata block needs to reach
     * a callback; ignoring them keeps a large picture block from being
     * assembled on every open. MD5 is compared only when the whole stream was
     * decoded without a seek, and only reported, never fatal. */
    FLAC__stream_decoder_set_md5_checking(self->native, true);
    FLAC__stream_decoder_set_metadata_ignore_all(self->native);
    if (FLAC__stream_decoder_init_stream(self->native, read_callback, seek_callback,
                                         tell_callback, length_callback, eof_callback,
                                         write_callback, metadata_callback,
                                         error_callback,
                                         self) != FLAC__STREAM_DECODER_INIT_STATUS_OK) {
        return 0;
    }
    return FLAC__stream_decoder_process_until_end_of_metadata(self->native);
}

struct orca_flac_decoder *orca_flac_decoder_create(void *context,
                                                   orca_flac_read_fn read,
                                                   uint64_t size,
                                                   uint32_t max_block_frames,
                                                   uint32_t channels)
{
    struct orca_flac_decoder *self;

    if (!read) {
        return NULL;
    }
    self = calloc(1, sizeof(*self));
    if (!self) {
        return NULL;
    }
    self->context = context;
    self->read = read;
    self->size = size;
    if (max_block_frames != 0 && channels != 0 &&
        !reserve_pending(self, max_block_frames * channels)) {
        orca_flac_decoder_destroy(self);
        return NULL;
    }
    self->native = FLAC__stream_decoder_new();
    if (!self->native || !start_native(self)) {
        orca_flac_decoder_destroy(self);
        return NULL;
    }
    return self;
}

void orca_flac_decoder_destroy(struct orca_flac_decoder *decoder)
{
    if (!decoder) {
        return;
    }
    if (decoder->native) {
        FLAC__stream_decoder_finish(decoder->native);
        FLAC__stream_decoder_delete(decoder->native);
    }
    free(decoder->pending);
    free(decoder);
}

static int32_t fill_pending(struct orca_flac_decoder *self)
{
    uint32_t steps;

    self->pending_frames = 0;
    self->pending_offset = 0;
    if (self->finished) {
        return ORCA_FLAC_END_OF_STREAM;
    }
    for (steps = 0; steps < ORCA_FLAC_MAX_EMPTY_STEPS; steps++) {
        FLAC__StreamDecoderState state = FLAC__stream_decoder_get_state(self->native);

        if (state == FLAC__STREAM_DECODER_END_OF_STREAM) {
            self->md5_mismatch = !FLAC__stream_decoder_finish(self->native);
            self->finished = 1;
            return ORCA_FLAC_END_OF_STREAM;
        }
        if (state == FLAC__STREAM_DECODER_ABORTED ||
            state == FLAC__STREAM_DECODER_MEMORY_ALLOCATION_ERROR ||
            state == FLAC__STREAM_DECODER_OGG_ERROR ||
            state == FLAC__STREAM_DECODER_SEEK_ERROR ||
            state == FLAC__STREAM_DECODER_UNINITIALIZED) {
            return ORCA_FLAC_FAILED;
        }
        if (!FLAC__stream_decoder_process_single(self->native)) {
            return ORCA_FLAC_FAILED;
        }
        if (self->read_failed) {
            return ORCA_FLAC_FAILED;
        }
        if (self->pending_frames > 0) {
            return ORCA_FLAC_OK;
        }
    }
    return ORCA_FLAC_FAILED;
}

static int32_t take_pending(struct orca_flac_decoder *self, uint32_t output_frames,
                            uint32_t *taken)
{
    uint32_t available;

    *taken = 0;
    if (output_frames == 0) {
        return ORCA_FLAC_OK;
    }
    if (self->pending_offset >= self->pending_frames) {
        int32_t status = fill_pending(self);

        if (status != ORCA_FLAC_OK) {
            return status;
        }
    }
    available = self->pending_frames - self->pending_offset;
    *taken = available < output_frames ? available : output_frames;
    return ORCA_FLAC_OK;
}

int32_t orca_flac_decoder_read(struct orca_flac_decoder *decoder, float *output,
                               uint32_t output_frames, uint32_t *frames_written)
{
    const int32_t *source;
    double scale;
    uint32_t taken;
    uint32_t index;
    int32_t status;

    if (!decoder || !output || !frames_written) {
        return ORCA_FLAC_FAILED;
    }
    status = take_pending(decoder, output_frames, &taken);
    if (status != ORCA_FLAC_OK || taken == 0) {
        *frames_written = 0;
        return status;
    }
    source = decoder->pending + (size_t)decoder->pending_offset * decoder->channels;
    /* Full-scale for the stream's own sample width, so a 24-bit file and a
     * 16-bit file of the same music land on the same float amplitudes. */
    scale = 1.0 / (double)((int64_t)1 << (decoder->pending_bits - 1));
    for (index = 0; index < taken * decoder->channels; index++) {
        output[index] = (float)((double)source[index] * scale);
    }
    decoder->pending_offset += taken;
    *frames_written = taken;
    return ORCA_FLAC_OK;
}

int32_t orca_flac_decoder_read_i32(struct orca_flac_decoder *decoder, int32_t *output,
                                   uint32_t output_frames, uint32_t *frames_written)
{
    const int32_t *source;
    uint32_t shift;
    uint32_t taken;
    uint32_t index;
    int32_t status;

    if (!decoder || !output || !frames_written) {
        return ORCA_FLAC_FAILED;
    }
    status = take_pending(decoder, output_frames, &taken);
    if (status != ORCA_FLAC_OK || taken == 0) {
        *frames_written = 0;
        return status;
    }
    source = decoder->pending + (size_t)decoder->pending_offset * decoder->channels;
    shift = 32 - decoder->pending_bits;
    for (index = 0; index < taken * decoder->channels; index++) {
        output[index] = (int32_t)((uint32_t)source[index] << shift);
    }
    decoder->pending_offset += taken;
    *frames_written = taken;
    return ORCA_FLAC_OK;
}

int32_t orca_flac_decoder_seek(struct orca_flac_decoder *decoder, uint64_t frame)
{
    if (!decoder) {
        return ORCA_FLAC_FAILED;
    }
    /* Cleared first: a successful seek decodes the frame holding the target
     * and delivers it, already trimmed to start at the target sample, through
     * the write callback before returning. */
    decoder->pending_frames = 0;
    decoder->pending_offset = 0;
    if (decoder->finished && !start_native(decoder)) {
        return ORCA_FLAC_FAILED;
    }
    if (!FLAC__stream_decoder_seek_absolute(decoder->native, frame)) {
        /* A failed seek leaves the decoder unusable until it is flushed. */
        FLAC__stream_decoder_flush(decoder->native);
        decoder->pending_frames = 0;
        decoder->pending_offset = 0;
        return ORCA_FLAC_FAILED;
    }
    return ORCA_FLAC_OK;
}

uint64_t orca_flac_decoder_stream_errors(const struct orca_flac_decoder *decoder)
{
    return decoder ? decoder->stream_errors : 0;
}

int32_t orca_flac_decoder_md5_mismatch(const struct orca_flac_decoder *decoder)
{
    return decoder ? decoder->md5_mismatch : 0;
}
