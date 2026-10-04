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

enum orca_pw_device_kind {
    ORCA_PW_DEVICE_UNKNOWN = 0,
    ORCA_PW_DEVICE_USB = 1,
    ORCA_PW_DEVICE_PCI = 2,
    ORCA_PW_DEVICE_BLUETOOTH = 3,
    ORCA_PW_DEVICE_HDMI = 4,
    ORCA_PW_DEVICE_VIRTUAL = 5,
};

enum orca_pw_device_state {
    ORCA_PW_DEVICE_ACTIVE = 0,
    ORCA_PW_DEVICE_SUSPENDED = 1,
    ORCA_PW_DEVICE_UNAVAILABLE = 2,
};

enum orca_pw_bit_depth {
    ORCA_PW_BIT_DEPTH_16 = 1,
    ORCA_PW_BIT_DEPTH_24 = 2,
    ORCA_PW_BIT_DEPTH_32 = 4,
};

struct orca_pw_device {
    uint64_t id;
    uint16_t name_len;
    char name[256];
    uint8_t kind;
    uint8_t has_capabilities;
    uint8_t state;
    uint8_t bit_depths;
    uint8_t channels_max;
    uint32_t rate_min;
    uint32_t rate_max;
};

enum orca_pw_sample_format {
    ORCA_PW_FORMAT_UNKNOWN = 0,
    ORCA_PW_FORMAT_S16 = 1,
    ORCA_PW_FORMAT_S24 = 2,
    ORCA_PW_FORMAT_S24_32 = 3,
    ORCA_PW_FORMAT_S32 = 4,
    ORCA_PW_FORMAT_F32 = 5,
};

enum orca_pw_discovery_phase {
    ORCA_PW_DISCOVERY_LISTING = 0,
    ORCA_PW_DISCOVERY_CAPABILITIES = 1,
    ORCA_PW_DISCOVERY_COMPLETE = 2,
};

struct orca_pw_discovery;

struct spa_dict;
struct spa_pod;

struct orca_pw_timing {
    uint64_t sample_time;
    int64_t monotonic_ns;
    int64_t device_delay_frames;
    uint64_t queued_frames;
    uint64_t buffered_frames;
    uint32_t quantum_frames;
    uint32_t graph_rate;
    uint32_t device_rate;
    uint16_t device_channels;
    uint8_t device_format;
    uint8_t reserved;
};

const char *orca_pw_library_version(void);
void orca_pw_initialize(void);
void orca_pw_deinitialize(void);
int orca_pw_discovery_begin(struct orca_pw_device *devices, uint32_t capacity,
                            uint8_t with_capabilities,
                            struct orca_pw_discovery **discovery);
int orca_pw_discovery_iterate(struct orca_pw_discovery *discovery,
                              int timeout_ms);
uint32_t orca_pw_discovery_finish(struct orca_pw_discovery *discovery);
uint8_t orca_pw_properties_kind(const struct spa_dict *props);
uint64_t orca_pw_format_pack(const struct spa_pod *param);
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
