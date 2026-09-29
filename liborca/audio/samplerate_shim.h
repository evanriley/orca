#ifndef ORCA_SAMPLERATE_SHIM_H
#define ORCA_SAMPLERATE_SHIM_H

#include <stdint.h>

/* Containment boundary for libsamplerate: no SRC_ type reaches Zig. */

struct orca_samplerate;

#define ORCA_SAMPLERATE_SINC_BEST 0
#define ORCA_SAMPLERATE_SINC_MEDIUM 1
#define ORCA_SAMPLERATE_SINC_FASTEST 2
#define ORCA_SAMPLERATE_ZERO_ORDER_HOLD 3
#define ORCA_SAMPLERATE_LINEAR 4

#define ORCA_SAMPLERATE_OK 0
#define ORCA_SAMPLERATE_FAILED (-1)

/* NULL when the converter or channel count is refused. */
struct orca_samplerate *orca_samplerate_create(int32_t converter, uint32_t channels);

void orca_samplerate_destroy(struct orca_samplerate *state);

/* Converts interleaved float frames at `ratio` (output rate / input rate),
 * reporting how many input frames were consumed and output frames produced. */
int32_t orca_samplerate_process(struct orca_samplerate *state, const float *input,
                                uint64_t input_frames, float *output,
                                uint64_t output_frames, double ratio,
                                int32_t end_of_input, uint64_t *input_used,
                                uint64_t *output_generated);

int32_t orca_samplerate_reset(struct orca_samplerate *state);

#endif /* ORCA_SAMPLERATE_SHIM_H */
