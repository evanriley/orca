#ifndef ORCA_PIPEWIRE_SHIM_H
#define ORCA_PIPEWIRE_SHIM_H

#include <stdint.h>

typedef void (*orca_pw_render_fn)(void *userdata, float *samples,
                                  uint32_t frames, uint32_t channels);
typedef void (*orca_pw_wake_fn)(void *context);

struct orca_pw_output;

enum orca_pw_output_state {
    ORCA_PW_OUTPUT_CONNECTING = 0,
    ORCA_PW_OUTPUT_ACTIVE = 1,
    ORCA_PW_OUTPUT_LOST = 2,
};

struct orca_pw_device {
    uint64_t id;
    uint16_t name_len;
    char name[256];
};

struct orca_pw_timing {
    uint64_t sample_time;
    int64_t monotonic_ns;
    int64_t device_delay_frames;
    uint64_t queued_frames;
    uint64_t buffered_frames;
    uint32_t quantum_frames;
    uint32_t graph_rate;
};

const char *orca_pw_library_version(void);
void orca_pw_initialize(void);
void orca_pw_deinitialize(void);
int orca_pw_discover(struct orca_pw_device *devices, uint32_t capacity,
                     uint32_t *count);
struct orca_pw_output *orca_pw_output_create(uint64_t device_id,
                                              uint32_t sample_rate,
                                              uint32_t channels,
                                              uint32_t requested_latency_frames,
                                              orca_pw_render_fn render,
                                              void *userdata);
void orca_pw_output_destroy(struct orca_pw_output *output);
int orca_pw_output_timing(struct orca_pw_output *output,
                          struct orca_pw_timing *timing);
enum orca_pw_output_state orca_pw_output_status(struct orca_pw_output *output);
void orca_pw_output_set_waker(struct orca_pw_output *output,
                              orca_pw_wake_fn wake, void *context);
void orca_pw_fill(orca_pw_render_fn render, void *userdata, float *samples,
                  uint32_t frames, uint32_t channels);

#endif
