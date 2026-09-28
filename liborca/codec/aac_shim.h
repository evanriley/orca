#ifndef ORCA_AAC_SHIM_H
#define ORCA_AAC_SHIM_H

#include <stdint.h>

/* Containment boundary for libxaac. No `ia_` or `ixheaacd_` type is visible
 * past this header: callers see an opaque handle, plain integers and
 * interleaved float32 frames. The decoder runs in MP4 mode: it is configured
 * from an AudioSpecificConfig and fed one access unit at a time. */

struct orca_aac_decoder;

struct orca_aac_info {
    uint32_t channels;
    /* Output rate, which SBR makes twice the core coder's. */
    uint32_t sample_rate;
    /* Most frames one access unit can decode to. */
    uint32_t max_frames;
};

/* `first_unit` is the stream's first access unit: plain AAC finishes init
 * only after parsing one. It is not consumed as audio; decode it normally. */
struct orca_aac_decoder *orca_aac_decoder_create(const uint8_t *config,
                                                 uint32_t config_size,
                                                 const uint8_t *first_unit,
                                                 uint32_t first_unit_size,
                                                 struct orca_aac_info *info);

void orca_aac_decoder_destroy(struct orca_aac_decoder *decoder);

/* Decodes one access unit into interleaved float frames. `output` must hold
 * `max_frames * channels` floats. Returns 0, or -1 when the unit cannot be
 * decoded. */
int32_t orca_aac_decoder_decode(struct orca_aac_decoder *decoder,
                                const uint8_t *unit, uint32_t unit_size,
                                float *output, uint32_t *frames_written);

/* Discards all decoder state, as after a seek. The next decoded access unit
 * completes init. Returns 0, or -1 when the decoder could not be set up. */
int32_t orca_aac_decoder_reset(struct orca_aac_decoder *decoder);

#endif /* ORCA_AAC_SHIM_H */
