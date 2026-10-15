#include "opus_shim.h"

#include <stdio.h>
#include <stdlib.h>

#include <opusfile.h>

/* How many consecutive holes a single read may skip. A hole is a gap in the
 * page sequence that opusfile reports and then continues past; a stream made
 * of nothing but holes is refused rather than spun on. */
#define ORCA_OPUS_MAX_HOLES 64

struct orca_opus_decoder {
    OggOpusFile *native;
    void *context;
    orca_opus_read_fn read;
    /* opusfile's callbacks are cursor-shaped and the source is positional, so
     * the cursor lives here. */
    uint64_t position;
    uint64_t size;
    uint32_t channels;
};

static int read_callback(void *stream, unsigned char *buffer, int length)
{
    struct orca_opus_decoder *self = stream;
    int64_t obtained;

    if (length <= 0) {
        return 0;
    }
    obtained = self->read(self->context, self->position, buffer, (uint64_t)length);
    if (obtained < 0) {
        return -1;
    }
    self->position += (uint64_t)obtained;
    return (int)obtained;
}

static int seek_callback(void *stream, opus_int64 offset, int whence)
{
    struct orca_opus_decoder *self = stream;
    int64_t base;
    int64_t target;

    switch (whence) {
    case SEEK_SET:
        base = 0;
        break;
    case SEEK_CUR:
        base = (int64_t)self->position;
        break;
    case SEEK_END:
        base = (int64_t)self->size;
        break;
    default:
        return -1;
    }
    target = base + offset;
    if (target < 0 || (uint64_t)target > self->size) {
        return -1;
    }
    self->position = (uint64_t)target;
    return 0;
}

static opus_int64 tell_callback(void *stream)
{
    struct orca_opus_decoder *self = stream;

    return (opus_int64)self->position;
}

struct orca_opus_decoder *orca_opus_decoder_create(void *context,
                                                   orca_opus_read_fn read,
                                                   uint64_t size,
                                                   struct orca_opus_info *info)
{
    static const OpusFileCallbacks callbacks = {
        read_callback,
        seek_callback,
        tell_callback,
        NULL,
    };
    struct orca_opus_decoder *self;
    int error = 0;
    ogg_int64_t total;

    self = calloc(1, sizeof(*self));
    if (self == NULL) {
        return NULL;
    }
    self->context = context;
    self->read = read;
    self->size = size;
    self->native = op_open_callbacks(self, &callbacks, NULL, 0, &error);
    if (self->native == NULL) {
        free(self);
        return NULL;
    }
    self->channels = (uint32_t)op_channel_count(self->native, -1);
    total = op_pcm_total(self->native, -1);
    info->channels = self->channels;
    info->total_frames = total < 0 ? -1 : (int64_t)total;
    return self;
}

void orca_opus_decoder_destroy(struct orca_opus_decoder *decoder)
{
    if (decoder == NULL) {
        return;
    }
    op_free(decoder->native);
    free(decoder);
}

int32_t orca_opus_decoder_read(struct orca_opus_decoder *decoder, float *output,
                               uint32_t output_frames,
                               uint32_t *frames_written)
{
    uint64_t capacity = (uint64_t)output_frames * decoder->channels;
    int holes = 0;
    int link = 0;
    int produced;

    *frames_written = 0;
    if (capacity > (uint64_t)INT32_MAX) {
        capacity = (uint64_t)INT32_MAX - ((uint64_t)INT32_MAX % decoder->channels);
    }
    for (;;) {
        produced = op_read_float(decoder->native, output, (int)capacity, &link);
        if (produced != OP_HOLE) {
            break;
        }
        if (++holes > ORCA_OPUS_MAX_HOLES) {
            return ORCA_OPUS_FAILED;
        }
    }
    if (produced < 0) {
        return ORCA_OPUS_FAILED;
    }
    if (produced == 0) {
        return ORCA_OPUS_END_OF_STREAM;
    }
    if ((uint32_t)op_channel_count(decoder->native, link) != decoder->channels) {
        return ORCA_OPUS_FAILED;
    }
    *frames_written = (uint32_t)produced;
    return ORCA_OPUS_OK;
}

int32_t orca_opus_decoder_seek(struct orca_opus_decoder *decoder,
                               uint64_t frame)
{
    if (frame > (uint64_t)INT64_MAX) {
        return ORCA_OPUS_FAILED;
    }
    return op_pcm_seek(decoder->native, (ogg_int64_t)frame) == 0 ? ORCA_OPUS_OK
                                                                  : ORCA_OPUS_FAILED;
}
