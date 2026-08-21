#include "pipewire_shim.h"
#include <pipewire/pipewire.h>
#include <spa/param/audio/format-utils.h>
#include <stdlib.h>
#include <string.h>

struct orca_pw_output {
    struct pw_thread_loop *loop;
    struct pw_stream *stream;
    orca_pw_render_fn render;
    void *userdata;
    uint32_t channels;
};

void orca_pw_fill(orca_pw_render_fn render, void *userdata, float *samples,
                  uint32_t frames, uint32_t channels) {
    const size_t sample_count = (size_t)frames * channels;
    if (render != NULL) {
        render(userdata, samples, frames, channels);
    } else {
        memset(samples, 0, sample_count * sizeof(float));
    }
}

static void output_process(void *userdata) {
    struct orca_pw_output *output = userdata;
    struct pw_buffer *pw_buffer = pw_stream_dequeue_buffer(output->stream);
    if (pw_buffer == NULL)
        return;

    struct spa_buffer *buffer = pw_buffer->buffer;
    if (buffer->n_datas == 0) {
        pw_stream_queue_buffer(output->stream, pw_buffer);
        return;
    }
    struct spa_data *data = &buffer->datas[0];
    if (data->data != NULL && data->chunk != NULL) {
        const uint32_t stride = output->channels * sizeof(float);
        const uint32_t capacity = data->maxsize / stride;
        const uint32_t frames = pw_buffer->requested > 0
                                    ? SPA_MIN(pw_buffer->requested, capacity)
                                    : capacity;
        orca_pw_fill(output->render, output->userdata, data->data, frames,
                     output->channels);
        data->chunk->offset = 0;
        data->chunk->stride = stride;
        data->chunk->size = frames * stride;
    }
    pw_stream_queue_buffer(output->stream, pw_buffer);
}

static const struct pw_stream_events output_events = {
    PW_VERSION_STREAM_EVENTS,
    .process = output_process,
};

const char *orca_pw_library_version(void) {
    return pw_get_library_version();
}

void orca_pw_initialize(void) {
    pw_init(NULL, NULL);
}

void orca_pw_deinitialize(void) {
    pw_deinit();
}

struct orca_pw_output *orca_pw_output_create(uint32_t sample_rate,
                                              uint32_t channels,
                                              orca_pw_render_fn render,
                                              void *userdata) {
    if (sample_rate == 0 || channels == 0 || channels > SPA_AUDIO_MAX_CHANNELS)
        return NULL;

    struct orca_pw_output *output = calloc(1, sizeof(*output));
    if (output == NULL)
        return NULL;
    output->render = render;
    output->userdata = userdata;
    output->channels = channels;

    output->loop = pw_thread_loop_new("orca-output", NULL);
    if (output->loop == NULL)
        goto fail;

    struct pw_properties *properties = pw_properties_new(
        PW_KEY_MEDIA_TYPE, "Audio",
        PW_KEY_MEDIA_CATEGORY, "Playback",
        PW_KEY_MEDIA_ROLE, "Music",
        NULL);
    output->stream = pw_stream_new_simple(
        pw_thread_loop_get_loop(output->loop), "Orca", properties,
        &output_events, output);
    if (output->stream == NULL)
        goto fail;

    uint8_t pod_buffer[1024];
    struct spa_pod_builder builder = SPA_POD_BUILDER_INIT(pod_buffer,
                                                           sizeof(pod_buffer));
    struct spa_audio_info_raw info = {
        .format = SPA_AUDIO_FORMAT_F32,
        .rate = sample_rate,
        .channels = channels,
    };
    const struct spa_pod *params[] = {
        spa_format_audio_raw_build(&builder, SPA_PARAM_EnumFormat, &info),
    };
    int result = pw_stream_connect(
        output->stream, PW_DIRECTION_OUTPUT, PW_ID_ANY,
        PW_STREAM_FLAG_AUTOCONNECT | PW_STREAM_FLAG_MAP_BUFFERS |
            PW_STREAM_FLAG_RT_PROCESS,
        params, 1);
    if (result < 0 || pw_thread_loop_start(output->loop) < 0)
        goto fail;
    return output;

fail:
    if (output->stream != NULL)
        pw_stream_destroy(output->stream);
    if (output->loop != NULL)
        pw_thread_loop_destroy(output->loop);
    free(output);
    return NULL;
}

void orca_pw_output_destroy(struct orca_pw_output *output) {
    if (output == NULL)
        return;
    pw_thread_loop_stop(output->loop);
    pw_stream_destroy(output->stream);
    pw_thread_loop_destroy(output->loop);
    free(output);
}
