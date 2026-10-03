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
    _Atomic int state;
    orca_pw_wake_fn wake;
    void *wake_context;
};

#define DISCOVERY_BOUND 64

struct bound_object {
    struct pw_proxy *proxy;
    struct spa_hook listener;
    uint32_t global_id;
    uint32_t device_object;
    uint8_t kind;
};

struct discovery {
    struct pw_main_loop *loop;
    struct pw_core *core;
    struct pw_registry *registry;
    struct orca_pw_device *devices;
    uint32_t capacity;
    uint32_t count;
    int sequence;
    int bound_synced;
    int result;
    struct bound_object nodes[DISCOVERY_BOUND];
    struct bound_object audio_devices[DISCOVERY_BOUND];
    uint32_t audio_device_count;
};

static int has_prefix(const char *value, const char *prefix) {
    return value != NULL && strncmp(value, prefix, strlen(prefix)) == 0;
}

static int equals(const char *value, const char *expected) {
    return value != NULL && strcmp(value, expected) == 0;
}

static int has_bluez5_property(const struct spa_dict *props) {
    const struct spa_dict_item *item;
    spa_dict_for_each(item, props) {
        if (has_prefix(item->key, "api.bluez5."))
            return 1;
    }
    return 0;
}

uint8_t orca_pw_properties_kind(const struct spa_dict *props) {
    if (props == NULL)
        return ORCA_PW_DEVICE_UNKNOWN;
    const char *factory = spa_dict_lookup(props, PW_KEY_FACTORY_NAME);
    if (equals(factory, "support.null-audio-sink"))
        return ORCA_PW_DEVICE_VIRTUAL;
    const char *api = spa_dict_lookup(props, PW_KEY_DEVICE_API);
    const char *bus = spa_dict_lookup(props, PW_KEY_DEVICE_BUS);
    if (equals(api, "bluez5") || equals(bus, "bluetooth") ||
        has_prefix(factory, "api.bluez5.") || has_bluez5_property(props))
        return ORCA_PW_DEVICE_BLUETOOTH;
    const char *profile = spa_dict_lookup(props, "device.profile.name");
    if (has_prefix(spa_dict_lookup(props, "api.alsa.path"), "hdmi:") ||
        (profile != NULL && strstr(profile, "hdmi") != NULL))
        return ORCA_PW_DEVICE_HDMI;
    if (equals(bus, "usb"))
        return ORCA_PW_DEVICE_USB;
    if (equals(bus, "pci"))
        return ORCA_PW_DEVICE_PCI;
    return ORCA_PW_DEVICE_UNKNOWN;
}

static void discovery_node_info(void *userdata, const struct pw_node_info *info) {
    struct bound_object *node = userdata;
    if ((info->change_mask & PW_NODE_CHANGE_MASK_PROPS) && info->props != NULL)
        node->kind = orca_pw_properties_kind(info->props);
}

static const struct pw_node_events discovery_node_events = {
    PW_VERSION_NODE_EVENTS,
    .info = discovery_node_info,
};

static void discovery_device_info(void *userdata,
                                  const struct pw_device_info *info) {
    struct bound_object *device = userdata;
    if ((info->change_mask & PW_DEVICE_CHANGE_MASK_PROPS) && info->props != NULL)
        device->kind = orca_pw_properties_kind(info->props);
}

static const struct pw_device_events discovery_device_events = {
    PW_VERSION_DEVICE_EVENTS,
    .info = discovery_device_info,
};

/* Registry globals carry only a filtered set of properties; the bus, the
 * ALSA path and the factory name arrive in the info of a bound proxy. */
static void discovery_bind_node(struct discovery *discovery,
                                struct bound_object *entry, uint32_t id,
                                const struct spa_dict *props) {
    const char *device_object = spa_dict_lookup(props, PW_KEY_DEVICE_ID);
    entry->global_id = id;
    entry->device_object = device_object != NULL
                               ? (uint32_t)strtoul(device_object, NULL, 10)
                               : SPA_ID_INVALID;
    struct pw_node *node = pw_registry_bind(
        discovery->registry, id, PW_TYPE_INTERFACE_Node, PW_VERSION_NODE, 0);
    if (node == NULL)
        return;
    entry->proxy = (struct pw_proxy *)node;
    pw_node_add_listener(node, &entry->listener, &discovery_node_events, entry);
}

static void discovery_bind_device(struct discovery *discovery, uint32_t id,
                                  const struct spa_dict *props) {
    if (!equals(spa_dict_lookup(props, PW_KEY_MEDIA_CLASS), "Audio/Device") ||
        discovery->audio_device_count >= DISCOVERY_BOUND)
        return;
    struct pw_device *device = pw_registry_bind(
        discovery->registry, id, PW_TYPE_INTERFACE_Device, PW_VERSION_DEVICE, 0);
    if (device == NULL)
        return;
    struct bound_object *entry =
        &discovery->audio_devices[discovery->audio_device_count++];
    entry->global_id = id;
    entry->proxy = (struct pw_proxy *)device;
    pw_device_add_listener(device, &entry->listener, &discovery_device_events,
                           entry);
}

static void discovery_unbind(struct bound_object *entry) {
    if (entry->proxy == NULL)
        return;
    spa_hook_remove(&entry->listener);
    pw_proxy_destroy(entry->proxy);
    entry->proxy = NULL;
}

static void discovery_global(void *userdata, uint32_t id,
                             uint32_t permissions, const char *type,
                             uint32_t version, const struct spa_dict *props) {
    (void)permissions;
    (void)version;
    struct discovery *discovery = userdata;
    if (props == NULL)
        return;
    if (strcmp(type, PW_TYPE_INTERFACE_Device) == 0) {
        discovery_bind_device(discovery, id, props);
        return;
    }
    if (strcmp(type, PW_TYPE_INTERFACE_Node) != 0)
        return;
    const char *media_class = spa_dict_lookup(props, PW_KEY_MEDIA_CLASS);
    if (media_class == NULL || strcmp(media_class, "Audio/Sink") != 0)
        return;
    if (discovery->count >= discovery->capacity)
        return;

    const uint32_t index = discovery->count++;
    struct orca_pw_device *device = &discovery->devices[index];
    memset(device, 0, sizeof(*device));
    if (index < DISCOVERY_BOUND)
        discovery_bind_node(discovery, &discovery->nodes[index], id, props);
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

static void discovery_resolve_kinds(struct discovery *discovery) {
    for (uint32_t index = 0; index < discovery->count && index < DISCOVERY_BOUND;
         index++) {
        const struct bound_object *node = &discovery->nodes[index];
        uint8_t kind = node->kind;
        for (uint32_t entry = 0;
             kind == ORCA_PW_DEVICE_UNKNOWN && entry < discovery->audio_device_count;
             entry++) {
            if (discovery->audio_devices[entry].global_id == node->device_object)
                kind = discovery->audio_devices[entry].kind;
        }
        discovery->devices[index].kind = kind;
    }
}

static const struct pw_registry_events discovery_registry_events = {
    PW_VERSION_REGISTRY_EVENTS,
    .global = discovery_global,
};

/* The first round trip delivers the globals, which bind proxies; the second
 * delivers those proxies' info. */
static void discovery_done(void *userdata, uint32_t id, int sequence) {
    struct discovery *discovery = userdata;
    if (id != PW_ID_CORE || sequence != discovery->sequence)
        return;
    if (!discovery->bound_synced) {
        discovery->bound_synced = 1;
        discovery->sequence = pw_core_sync(discovery->core, PW_ID_CORE, 0);
        return;
    }
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

static void output_state_changed(void *userdata, enum pw_stream_state old,
                                 enum pw_stream_state state,
                                 const char *error) {
    (void)old;
    (void)error;
    struct orca_pw_output *output = userdata;
    switch (state) {
    case PW_STREAM_STATE_PAUSED:
    case PW_STREAM_STATE_STREAMING:
        atomic_store_explicit(&output->state, ORCA_PW_OUTPUT_ACTIVE,
                              memory_order_release);
        break;
    case PW_STREAM_STATE_ERROR:
    case PW_STREAM_STATE_UNCONNECTED:
        atomic_store_explicit(&output->state, ORCA_PW_OUTPUT_LOST,
                              memory_order_release);
        break;
    default:
        return;
    }
    if (output->wake != NULL)
        output->wake(output->wake_context);
}

static const struct pw_stream_events output_events = {
    PW_VERSION_STREAM_EVENTS,
    .state_changed = output_state_changed,
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
    discovery.core = core;
    discovery.registry = registry;
    pw_registry_add_listener(registry, &registry_listener,
                             &discovery_registry_events, &discovery);
    pw_core_add_listener(core, &core_listener, &discovery_core_events,
                         &discovery);
    discovery.sequence = pw_core_sync(core, PW_ID_CORE, 0);
    discovery.result = pw_main_loop_run(discovery.loop);

    for (uint32_t index = 0; index < DISCOVERY_BOUND; index++) {
        discovery_unbind(&discovery.nodes[index]);
        discovery_unbind(&discovery.audio_devices[index]);
    }
    spa_hook_remove(&core_listener);
    spa_hook_remove(&registry_listener);
    pw_proxy_destroy((struct pw_proxy *)registry);
    pw_core_disconnect(core);
    pw_context_destroy(context);
    pw_main_loop_destroy(discovery.loop);
    discovery_resolve_kinds(&discovery);
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
    atomic_init(&output->state, ORCA_PW_OUTPUT_CONNECTING);

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
    pw_properties_setf(properties, PW_KEY_NODE_RATE, "1/%u", sample_rate);
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
        .graph_rate = native.rate.num == 1 ? native.rate.denom : 0,
    };
    return 0;
}

enum orca_pw_output_state orca_pw_output_status(struct orca_pw_output *output) {
    if (output == NULL)
        return ORCA_PW_OUTPUT_LOST;
    return atomic_load_explicit(&output->state, memory_order_acquire);
}

void orca_pw_output_set_waker(struct orca_pw_output *output,
                              orca_pw_wake_fn wake, void *context) {
    if (output == NULL)
        return;
    // state_changed runs on the loop thread with this lock held, so once it is
    // released the previous waker can no longer be running or be called.
    pw_thread_loop_lock(output->loop);
    output->wake = wake;
    output->wake_context = context;
    pw_thread_loop_unlock(output->loop);
}
