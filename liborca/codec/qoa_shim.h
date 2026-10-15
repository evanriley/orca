#ifndef ORCA_QOA_SHIM_H
#define ORCA_QOA_SHIM_H

#include <stdint.h>

/* Containment boundary around the vendored reference QOA decoder. Nothing
 * from qoa.h is visible past this header: callers see one opaque handle,
 * plain integers and interleaved float32 frames. */

/* Samples per channel in every QOA frame except the last. */
#define ORCA_QOA_FRAME_FRAMES 5120

struct orca_qoa_decoder;

struct orca_qoa_info {
    uint32_t channels;
    uint32_t sample_rate;
    /* Frames the file header declares. */
    uint32_t frames;
    /* Bytes of a full frame, and so the upper bound on any frame. */
    uint32_t max_frame_bytes;
};

/* Reads the file header and the first frame header. NULL when they are not a
 * QOA stream the decoder accepts. */
struct orca_qoa_decoder *orca_qoa_decoder_create(const uint8_t *header, uint32_t header_size,
                                                 struct orca_qoa_info *info);

void orca_qoa_decoder_destroy(struct orca_qoa_decoder *decoder);

/* Decodes the frame at the start of `bytes` into interleaved float frames.
 * `output` must hold ORCA_QOA_FRAME_FRAMES * channels floats. Returns the
 * frame's size in bytes, or 0 when it is invalid. */
uint32_t orca_qoa_decoder_decode_frame(struct orca_qoa_decoder *decoder, const uint8_t *bytes,
                                       uint32_t size, float *output, uint32_t *frames_written);

#endif /* ORCA_QOA_SHIM_H */
