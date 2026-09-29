#include "samplerate_shim.h"

#include <limits.h>
#include <stdlib.h>

#include <samplerate.h>

struct orca_samplerate {
    SRC_STATE *native;
};

static int native_converter(int32_t converter)
{
    switch (converter) {
    case ORCA_SAMPLERATE_SINC_BEST:
        return SRC_SINC_BEST_QUALITY;
    case ORCA_SAMPLERATE_SINC_MEDIUM:
        return SRC_SINC_MEDIUM_QUALITY;
    case ORCA_SAMPLERATE_SINC_FASTEST:
        return SRC_SINC_FASTEST;
    case ORCA_SAMPLERATE_ZERO_ORDER_HOLD:
        return SRC_ZERO_ORDER_HOLD;
    case ORCA_SAMPLERATE_LINEAR:
        return SRC_LINEAR;
    default:
        return -1;
    }
}

struct orca_samplerate *orca_samplerate_create(int32_t converter, uint32_t channels)
{
    struct orca_samplerate *state;
    int native_type = native_converter(converter);
    int error = 0;

    if (native_type < 0 || channels == 0 || channels > INT_MAX) {
        return NULL;
    }
    state = malloc(sizeof(*state));
    if (!state) {
        return NULL;
    }
    state->native = src_new(native_type, (int)channels, &error);
    if (!state->native) {
        free(state);
        return NULL;
    }
    return state;
}

void orca_samplerate_destroy(struct orca_samplerate *state)
{
    if (!state) {
        return;
    }
    src_delete(state->native);
    free(state);
}

int32_t orca_samplerate_process(struct orca_samplerate *state, const float *input,
                                uint64_t input_frames, float *output,
                                uint64_t output_frames, double ratio,
                                int32_t end_of_input, uint64_t *input_used,
                                uint64_t *output_generated)
{
    static const float no_input = 0.0f;
    SRC_DATA data;

    if (input_frames > LONG_MAX || output_frames > LONG_MAX) {
        return ORCA_SAMPLERATE_FAILED;
    }
    /* An empty input slice may point one past its array, at the output
     * buffer, which libsamplerate refuses as overlapping. */
    data.data_in = input_frames == 0 ? &no_input : input;
    data.data_out = output;
    data.input_frames = (long)input_frames;
    data.output_frames = (long)output_frames;
    data.input_frames_used = 0;
    data.output_frames_gen = 0;
    data.end_of_input = end_of_input ? 1 : 0;
    data.src_ratio = ratio;
    if (src_process(state->native, &data) != 0) {
        return ORCA_SAMPLERATE_FAILED;
    }
    *input_used = (uint64_t)data.input_frames_used;
    *output_generated = (uint64_t)data.output_frames_gen;
    return ORCA_SAMPLERATE_OK;
}

int32_t orca_samplerate_reset(struct orca_samplerate *state)
{
    return src_reset(state->native) == 0 ? ORCA_SAMPLERATE_OK : ORCA_SAMPLERATE_FAILED;
}
