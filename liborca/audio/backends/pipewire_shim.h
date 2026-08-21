#ifndef ORCA_PIPEWIRE_SHIM_H
#define ORCA_PIPEWIRE_SHIM_H

#include <stdint.h>

typedef void (*orca_pw_render_fn)(void *userdata, float *samples,
                                  uint32_t frames, uint32_t channels);

struct orca_pw_output;

const char *orca_pw_library_version(void);
void orca_pw_initialize(void);
void orca_pw_deinitialize(void);
struct orca_pw_output *orca_pw_output_create(uint32_t sample_rate,
                                              uint32_t channels,
                                              orca_pw_render_fn render,
                                              void *userdata);
void orca_pw_output_destroy(struct orca_pw_output *output);
void orca_pw_fill(orca_pw_render_fn render, void *userdata, float *samples,
                  uint32_t frames, uint32_t channels);

#endif
