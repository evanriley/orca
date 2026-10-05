#ifndef ORCA_ALAC_SHIM_H
#define ORCA_ALAC_SHIM_H

#include <stdint.h>

/* Containment boundary for Apple's reference ALAC decoder, which is C++. No
 * C++ type is visible past this header: callers see an opaque handle, plain
 * integers and interleaved float32 frames. */

#ifdef __cplusplus
extern "C" {
#endif

struct orca_alac_decoder;

struct orca_alac_info {
    uint32_t frame_length;
    uint32_t bit_depth;
    uint32_t channels;
    uint32_t sample_rate;
};

/* Creates a decoder from an ALACSpecificConfig. NULL when the configuration is
 * invalid or declares a layout the decoder cannot produce. */
struct orca_alac_decoder *orca_alac_decoder_create(const uint8_t *config,
                                                   uint32_t config_size,
                                                   struct orca_alac_info *info);

void orca_alac_decoder_destroy(struct orca_alac_decoder *decoder);

/* Decodes one packet into interleaved float frames normalized to [-1, 1).
 * `output` must hold `frame_length * channels` floats. Returns 0 and the
 * frame count in `frames_written`, or -1 when the packet is corrupt. */
int32_t orca_alac_decoder_decode(struct orca_alac_decoder *decoder,
                                 const uint8_t *packet, uint32_t packet_size,
                                 float *output, uint32_t *frames_written);

/* The same packet as integers left-justified in 32 bits: a 16-bit sample s is
 * written as s << 16. `output` must hold `frame_length * channels` integers. */
int32_t orca_alac_decoder_decode_i32(struct orca_alac_decoder *decoder,
                                     const uint8_t *packet, uint32_t packet_size,
                                     int32_t *output, uint32_t *frames_written);

#ifdef __cplusplus
}
#endif

#endif /* ORCA_ALAC_SHIM_H */
