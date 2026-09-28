#include "qoa_shim.h"

#include <stdlib.h>

#define QOA_IMPLEMENTATION
#define QOA_NO_STDIO
#include "vendor/qoa/qoa.h"

struct orca_qoa_decoder {
    qoa_desc native;
    short samples[QOA_FRAME_LEN * QOA_MAX_CHANNELS];
};

struct orca_qoa_decoder *orca_qoa_decoder_create(const uint8_t *header, uint32_t header_size,
                                                 struct orca_qoa_info *info)
{
    struct orca_qoa_decoder *decoder = calloc(1, sizeof(*decoder));
    if (decoder == NULL) {
        return NULL;
    }
    if (header_size > INT32_MAX ||
        qoa_decode_header(header, (int)header_size, &decoder->native) == 0) {
        free(decoder);
        return NULL;
    }
    info->channels = decoder->native.channels;
    info->sample_rate = decoder->native.samplerate;
    info->frames = decoder->native.samples;
    info->max_frame_bytes = qoa_max_frame_size(&decoder->native);
    return decoder;
}

void orca_qoa_decoder_destroy(struct orca_qoa_decoder *decoder)
{
    free(decoder);
}

uint32_t orca_qoa_decoder_decode_frame(struct orca_qoa_decoder *decoder, const uint8_t *bytes,
                                       uint32_t size, float *output, uint32_t *frames_written)
{
    unsigned int frames = 0;
    unsigned int consumed;
    unsigned int count;
    unsigned int index;

    *frames_written = 0;
    consumed = qoa_decode_frame(bytes, size, &decoder->native, decoder->samples, &frames);
    if (consumed == 0 || frames > QOA_FRAME_LEN) {
        return 0;
    }
    count = frames * decoder->native.channels;
    for (index = 0; index < count; index++) {
        output[index] = (float)decoder->samples[index] / 32768.0f;
    }
    *frames_written = frames;
    return consumed;
}
