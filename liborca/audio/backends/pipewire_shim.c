#include "pipewire_shim.h"
#include <pipewire/pipewire.h>
#include <spa/param/audio/format-utils.h>
#include <errno.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct orca_pw_output {
    struct pw_thread_loop *loop;
    struct pw_stream *stream;
    orca_pw_render_fn render;
    void *userdata;
    uint32_t channels;
    _Atomic uint32_t quantum_frames;
};

struct discovery {
    struct pw_main_loop *loop;
    struct orca_pw_device *devices;
    uint32_t capacity;
    uint32_t count;
    int sequence;
    int result;
};

static void discovery_global(void *userdata, uint32_t id,
                             uint32_t permissions, const char *type,
                             uint32_t version, const struct spa_dict *props) {
    (void)permissions;
    (void)version;
    struct discovery *discovery = userdata;
    if (strcmp(type, PW_TYPE_INTERFACE_Node) != 0 || props == NULL)
        return;
    const char *media_class = spa_dict_lookup(props, PW_KEY_MEDIA_CLASS);
    if (media_class == NULL || strcmp(media_class, "Audio/Sink") != 0)
        return;
    if (discovery->count >= discovery->capacity)
        return;

    struct orca_pw_device *device = &discovery->devices[discovery->count++];
    memset(device, 0, sizeof(*device));
    const char *serial = spa_dict_lookup(props, PW_KEY_OBJECT_SERIAL);
    device->id = serial != NULL ? strtoull(serial, NULL, 10) : id;
    const char *name = spa_dict_lookup(props, PW_KEY_NODE_DESCRIPTION);
    if (name == NULL)
        name = spa_dict_lookup(props, PW_KEY_NODE_NICK);
    if (name == NULL)
        name = spa_dict_lookup(props, PW_KEY_NODE_NAME);
    if (name == NULL)
        name = "Unknown PipeWire output";
    const size_t name_len = strnlen(name, sizeof(device->name));
    memcpy(device->name, name, name_len);
    device->name_len = name_len;
}

static const struct pw_registry_events discovery_registry_events = {
    PW_VERSION_REGISTRY_EVENTS,
    .global = discovery_global,
};

static void discovery_done(void *userdata, uint32_t id, int sequence) {
    struct discovery *discovery = userdata;
    if (id == PW_ID_CORE && sequence == discovery->sequence)
        pw_main_loop_quit(discovery->loop);
}

static void discovery_error(void *userdata, uint32_t id, int sequence,
                            int result, const char *message) {
    (void)sequence;
    (void)message;
    struct discovery *discovery = userdata;
    if (id == PW_ID_CORE) {
        discovery->result = result;
        pw_main_loop_quit(discovery->loop);
    }
}

static const struct pw_core_events discovery_core_events = {
    PW_VERSION_CORE_EVENTS,
    .done = discovery_done,
    .error = discovery_error,
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
        atomic_store_explicit(&output->quantum_frames, frames,
                              memory_order_relaxed);
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

int orca_pw_discover(struct orca_pw_device *devices, uint32_t capacity,
                     uint32_t *count) {
    if (count == NULL || (capacity > 0 && devices == NULL))
        return -EINVAL;
    *count = 0;
    struct discovery discovery = {
        .devices = devices,
        .capacity = capacity,
    };
    struct spa_hook registry_listener = {0};
    struct spa_hook core_listener = {0};
    struct pw_context *context = NULL;
    struct pw_core *core = NULL;
    struct pw_registry *registry = NULL;

    discovery.loop = pw_main_loop_new(NULL);
    if (discovery.loop == NULL)
        return -errno;
    context = pw_context_new(pw_main_loop_get_loop(discovery.loop), NULL, 0);
    if (context == NULL)
        goto fail;
    core = pw_context_connect(context, NULL, 0);
    if (core == NULL)
        goto fail;
    registry = pw_core_get_registry(core, PW_VERSION_REGISTRY, 0);
    if (registry == NULL)
        goto fail;
    pw_registry_add_listener(registry, &registry_listener,
                             &discovery_registry_events, &discovery);
    pw_core_add_listener(core, &core_listener, &discovery_core_events,
                         &discovery);
    discovery.sequence = pw_core_sync(core, PW_ID_CORE, 0);
    discovery.result = pw_main_loop_run(discovery.loop);

    spa_hook_remove(&core_listener);
    spa_hook_remove(&registry_listener);
    pw_proxy_destroy((struct pw_proxy *)registry);
    pw_core_disconnect(core);
    pw_context_destroy(context);
    pw_main_loop_destroy(discovery.loop);
    *count = discovery.count;
    return discovery.result;

fail:
    if (registry != NULL)
        pw_proxy_destroy((struct pw_proxy *)registry);
    if (core != NULL)
        pw_core_disconnect(core);
    if (context != NULL)
        pw_context_destroy(context);
    pw_main_loop_destroy(discovery.loop);
    return errno != 0 ? -errno : -EIO;
}

struct orca_pw_output *orca_pw_output_create(uint64_t device_id,
                                              uint32_t sample_rate,
                                              uint32_t channels,
                                              uint32_t requested_latency_frames,
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
    if (device_id != 0)
        pw_properties_setf(properties, PW_KEY_TARGET_OBJECT, "%llu",
                           (unsigned long long)device_id);
    if (requested_latency_frames != 0)
        pw_properties_setf(properties, PW_KEY_NODE_LATENCY, "%u/%u",
                           requested_latency_frames, sample_rate);
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

int orca_pw_output_timing(struct orca_pw_output *output,
                          struct orca_pw_timing *timing) {
    if (output == NULL || timing == NULL)
        return -EINVAL;
    struct pw_time native = {0};
    const int result = pw_stream_get_time_n(output->stream, &native,
                                             sizeof(native));
    if (result < 0)
        return result;
    *timing = (struct orca_pw_timing) {
        .sample_time = native.ticks,
        .monotonic_ns = native.now,
        .device_delay_frames = native.delay,
        .queued_frames = native.queued / (output->channels * sizeof(float)),
        .buffered_frames = native.buffered,
        .quantum_frames = atomic_load_explicit(&output->quantum_frames,
                                                memory_order_relaxed),
    };
    return 0;
}
