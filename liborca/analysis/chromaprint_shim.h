#ifndef ORCA_CHROMAPRINT_SHIM_H
#define ORCA_CHROMAPRINT_SHIM_H

#include <stdint.h>

/* Containment boundary for Chromaprint: no Chromaprint type reaches Zig.
 * Built without its internal resampler, Chromaprint accepts only
 * `orca_chromaprint_sample_rate` Hz, so callers resample first. */

struct orca_chromaprint;

#define ORCA_CHROMAPRINT_OK 0
#define ORCA_CHROMAPRINT_FAILED (-1)

extern const uint32_t orca_chromaprint_sample_rate;

/* NULL when `algorithm` is not one Chromaprint knows. */
struct orca_chromaprint *orca_chromaprint_create(int32_t algorithm);

void orca_chromaprint_destroy(struct orca_chromaprint *context);

int32_t orca_chromaprint_start(struct orca_chromaprint *context, uint32_t channels);

/* `samples` is interleaved, `count` counts samples, not frames. */
int32_t orca_chromaprint_feed(struct orca_chromaprint *context, const int16_t *samples,
                              uint32_t count);

int32_t orca_chromaprint_finish(struct orca_chromaprint *context);

/* The compressed, base64 fingerprint AcoustID accepts, NUL-terminated and
 * released with `orca_chromaprint_release`. `raw_size` is how many 32-bit
 * sub-fingerprints it holds. */
int32_t orca_chromaprint_fingerprint(struct orca_chromaprint *context, char **encoded,
                                     uint32_t *raw_size);

/* Decodes a compressed, base64 fingerprint into its sub-fingerprints,
 * released with `orca_chromaprint_release`. */
int32_t orca_chromaprint_decode(const char *encoded, uint32_t encoded_length, uint32_t **raw,
                                uint32_t *raw_size, int32_t *algorithm);

void orca_chromaprint_release(void *pointer);

#endif /* ORCA_CHROMAPRINT_SHIM_H */
