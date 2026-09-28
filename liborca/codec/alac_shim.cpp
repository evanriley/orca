#include "alac_shim.h"

#include <new>
#include <stdlib.h>
#include <string.h>

#include "ALACBitUtilities.h"
#include "ALACDecoder.h"

struct orca_alac_decoder {
    ALACDecoder native;
    /* One packet of interleaved integer samples at the stream's width. */
    uint8_t *scratch;
    uint32_t frame_length;
    uint32_t channels;
    uint32_t bit_depth;
};

static uint32_t bytes_per_sample(uint32_t bit_depth)
{
    return bit_depth == 16 ? 2 : bit_depth == 32 ? 4 : 3;
}

extern "C" struct orca_alac_decoder *orca_alac_decoder_create(const uint8_t *config,
                                                              uint32_t config_size,
                                                              struct orca_alac_info *info)
{
    /* Init reads the configuration through a struct pointer, which requires
     * 4-byte alignment that bytes sliced out of a container do not have. */
    uint32_t aligned[64];
    if (config_size > sizeof(aligned)) {
        return NULL;
    }
    memcpy(aligned, config, config_size);

    void *memory = calloc(1, sizeof(orca_alac_decoder));
    if (memory == NULL) {
        return NULL;
    }
    orca_alac_decoder *self = new (memory) orca_alac_decoder();
    if (self->native.Init(aligned, config_size) != 0) {
        self->~orca_alac_decoder();
        free(memory);
        return NULL;
    }
    const ALACSpecificConfig &stream = self->native.mConfig;
    self->frame_length = stream.frameLength;
    self->channels = stream.numChannels;
    self->bit_depth = stream.bitDepth;
    if (self->channels == 0 || self->frame_length == 0 ||
        (self->bit_depth != 16 && self->bit_depth != 20 && self->bit_depth != 24 &&
         self->bit_depth != 32)) {
        self->~orca_alac_decoder();
        free(memory);
        return NULL;
    }
    self->scratch = static_cast<uint8_t *>(
        calloc((size_t)self->frame_length * self->channels, bytes_per_sample(self->bit_depth)));
    if (self->scratch == NULL) {
        self->~orca_alac_decoder();
        free(memory);
        return NULL;
    }
    info->frame_length = self->frame_length;
    info->bit_depth = self->bit_depth;
    info->channels = self->channels;
    info->sample_rate = stream.sampleRate;
    return self;
}

extern "C" void orca_alac_decoder_destroy(struct orca_alac_decoder *decoder)
{
    if (decoder == NULL) {
        return;
    }
    free(decoder->scratch);
    decoder->~orca_alac_decoder();
    free(decoder);
}

static int32_t packed24(const uint8_t *bytes)
{
    uint32_t value = (uint32_t)bytes[0] | ((uint32_t)bytes[1] << 8) | ((uint32_t)bytes[2] << 16);
    return (int32_t)(value << 8) >> 8;
}

extern "C" int32_t orca_alac_decoder_decode(struct orca_alac_decoder *decoder,
                                            const uint8_t *packet, uint32_t packet_size,
                                            float *output, uint32_t *frames_written)
{
    BitBuffer bits;
    uint32_t frames = 0;
    size_t count;
    size_t index;

    *frames_written = 0;
    BitBufferInit(&bits, const_cast<uint8_t *>(packet), packet_size);
    if (decoder->native.Decode(&bits, decoder->scratch, decoder->frame_length,
                               decoder->channels, &frames) != 0 ||
        frames > decoder->frame_length) {
        return -1;
    }
    count = (size_t)frames * decoder->channels;
    switch (decoder->bit_depth) {
    case 16: {
        const int16_t *samples = reinterpret_cast<const int16_t *>(decoder->scratch);
        for (index = 0; index < count; index++) {
            output[index] = (float)samples[index] / 32768.0f;
        }
        break;
    }
    case 32: {
        const int32_t *samples = reinterpret_cast<const int32_t *>(decoder->scratch);
        for (index = 0; index < count; index++) {
            output[index] = (float)((double)samples[index] / 2147483648.0);
        }
        break;
    }
    default:
        /* 20-bit samples arrive left-aligned in 24-bit containers. */
        for (index = 0; index < count; index++) {
            output[index] = (float)packed24(decoder->scratch + index * 3) / 8388608.0f;
        }
        break;
    }
    *frames_written = frames;
    return 0;
}
