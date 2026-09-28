#include "vorbis_shim.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>

#include <vorbis/vorbisfile.h>

/* How many consecutive holes a single read may skip. A hole is a gap in the
 * page sequence that vorbisfile reports and then continues past; a stream made
 * of nothing but holes is refused rather than spun on. */
#define ORCA_VORBIS_MAX_HOLES 64

struct orca_vorbis_decoder {
    OggVorbis_File native;
    void *context;
    orca_vorbis_read_fn read;
    /* vorbisfile's callbacks are cursor-shaped and the source is positional,
     * so the cursor lives here. */
    uint64_t position;
    uint64_t size;
    uint32_t channels;
    uint32_t sample_rate;
};

static size_t read_callback(void *buffer, size_t size, size_t count, void *stream)
{
    struct orca_vorbis_decoder *self = stream;
    uint64_t wanted;
    int64_t obtained;

    if (size == 0 || count == 0) {
        return 0;
    }
    wanted = (uint64_t)size * (uint64_t)count;
    obtained = self->read(self->context, self->position, buffer, wanted);
    if (obtained < 0) {
        errno = EIO;
        return 0;
    }
    self->position += (uint64_t)obtained;
    return (size_t)obtained / size;
}

static int seek_callback(void *stream, ogg_int64_t offset, int whence)
{
    struct orca_vorbis_decoder *self = stream;
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

static long tell_callback(void *stream)
{
    struct orca_vorbis_decoder *self = stream;

    return (long)self->position;
}

struct orca_vorbis_decoder *orca_vorbis_decoder_create(void *context,
                                                       orca_vorbis_read_fn read,
                                                       uint64_t size,
                                                       struct orca_vorbis_info *info)
{
    ov_callbacks callbacks = {
        read_callback,
        seek_callback,
        NULL,
        tell_callback,
    };
    struct orca_vorbis_decoder *self;
    vorbis_info *stream_info;
    ogg_int64_t total;

    self = calloc(1, sizeof(*self));
    if (self == NULL) {
        return NULL;
    }
    self->context = context;
    self->read = read;
    self->size = size;
    if (ov_open_callbacks(self, &self->native, NULL, 0, callbacks) != 0) {
        free(self);
        return NULL;
    }
    stream_info = ov_info(&self->native, -1);
    if (stream_info == NULL || stream_info->channels <= 0 || stream_info->rate <= 0) {
        ov_clear(&self->native);
        free(self);
        return NULL;
    }
    self->channels = (uint32_t)stream_info->channels;
    self->sample_rate = (uint32_t)stream_info->rate;
    total = ov_pcm_total(&self->native, -1);
    info->channels = self->channels;
    info->sample_rate = self->sample_rate;
    info->total_frames = total < 0 ? -1 : (int64_t)total;
    return self;
}

void orca_vorbis_decoder_destroy(struct orca_vorbis_decoder *decoder)
{
    if (decoder == NULL) {
        return;
    }
    ov_clear(&decoder->native);
    free(decoder);
}

int32_t orca_vorbis_decoder_read(struct orca_vorbis_decoder *decoder, float *output,
                                 uint32_t output_frames,
                                 uint32_t *frames_written)
{
    float **planes = NULL;
    vorbis_info *link_info;
    int holes = 0;
    int link = 0;
    long produced;
    long frame;
    uint32_t channel;

    *frames_written = 0;
    if (output_frames > (uint32_t)INT32_MAX) {
        output_frames = (uint32_t)INT32_MAX;
    }
    for (;;) {
        produced = ov_read_float(&decoder->native, &planes, (int)output_frames, &link);
        if (produced != OV_HOLE) {
            break;
        }
        if (++holes > ORCA_VORBIS_MAX_HOLES) {
            return ORCA_VORBIS_FAILED;
        }
    }
    if (produced < 0) {
        return ORCA_VORBIS_FAILED;
    }
    if (produced == 0) {
        return ORCA_VORBIS_END_OF_STREAM;
    }
    link_info = ov_info(&decoder->native, link);
    if (link_info == NULL || (uint32_t)link_info->channels != decoder->channels ||
        (uint32_t)link_info->rate != decoder->sample_rate) {
        return ORCA_VORBIS_FAILED;
    }
    for (frame = 0; frame < produced; frame++) {
        for (channel = 0; channel < decoder->channels; channel++) {
            output[(size_t)frame * decoder->channels + channel] = planes[channel][frame];
        }
    }
    *frames_written = (uint32_t)produced;
    return ORCA_VORBIS_OK;
}

int32_t orca_vorbis_decoder_seek(struct orca_vorbis_decoder *decoder,
                                 uint64_t frame)
{
    if (frame > (uint64_t)INT64_MAX) {
        return ORCA_VORBIS_FAILED;
    }
    return ov_pcm_seek(&decoder->native, (ogg_int64_t)frame) == 0 ? ORCA_VORBIS_OK
                                                                   : ORCA_VORBIS_FAILED;
}
