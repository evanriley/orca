#include "mp3_shim.h"

#include <stdlib.h>
#include <string.h>

#define MINIMP3_IMPLEMENTATION
#define MINIMP3_FLOAT_OUTPUT
#include "vendor/minimp3/minimp3.h"

struct orca_mp3_decoder {
    mp3dec_t native;
};

struct orca_mp3_decoder *orca_mp3_decoder_create(void)
{
    struct orca_mp3_decoder *decoder = malloc(sizeof(*decoder));
    if (!decoder) {
        return NULL;
    }
    mp3dec_init(&decoder->native);
    return decoder;
}

void orca_mp3_decoder_destroy(struct orca_mp3_decoder *decoder)
{
    free(decoder);
}

void orca_mp3_decoder_reset(struct orca_mp3_decoder *decoder)
{
    if (!decoder) {
        return;
    }
    mp3dec_init(&decoder->native);
}

int32_t orca_mp3_decode_frame(struct orca_mp3_decoder *decoder,
                              const uint8_t *input, int32_t input_len,
                              float *pcm, struct orca_mp3_frame_info *info)
{
    mp3dec_frame_info_t native_info;
    int samples;

    memset(&native_info, 0, sizeof(native_info));
    if (!decoder || !info || input_len < 0) {
        return -1;
    }
    samples = mp3dec_decode_frame(&decoder->native, input, (int)input_len, pcm,
                                  &native_info);
    info->frame_bytes = (int32_t)native_info.frame_bytes;
    info->frame_offset = (int32_t)native_info.frame_offset;
    info->channels = (int32_t)native_info.channels;
    info->sample_rate = (int32_t)native_info.hz;
    info->layer = (int32_t)native_info.layer;
    info->bitrate_kbps = (int32_t)native_info.bitrate_kbps;
    return (int32_t)samples;
}
