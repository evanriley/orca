#include "pipewire_shim.h"
#include <pipewire/pipewire.h>
#include <spa/param/audio/format-utils.h>
#include <spa/utils/result.h>
#include <errno.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define OUTPUT_LINK_BOUND 32
#define OUTPUT_TARGET_LINK_TIMEOUT_NS (2 * SPA_NSEC_PER_SEC)

struct output_link {
    uint32_t id;
    uint32_t input_node;
};

struct output_sink {
    struct pw_proxy *proxy;
    struct spa_hook listener;
    uint32_t global_id;
    int sequence;
    uint32_t format_flags;
    uint8_t has_format_flags;
    uint8_t is_sink;
    uint8_t is_virtual;
    uint8_t has_state;
    enum pw_node_state state;
    uint64_t format;
};

struct orca_pw_output {
    struct pw_thread_loop *loop;
    struct pw_stream *stream;
    orca_pw_render_fn render;
    void *userdata;
    uint32_t channels;
    _Atomic uint32_t quantum_frames;
    _Atomic int state;
    _Atomic uint64_t device_format;
    orca_pw_wake_fn wake;
    void *wake_context;
    struct pw_registry *registry;
    struct spa_hook registry_listener;
    struct output_sink sink;
    struct output_link links[OUTPUT_LINK_BOUND];
    uint32_t link_count;
};

#define DISCOVERY_BOUND 64

struct bound_object {
    struct pw_proxy *proxy;
    struct spa_hook listener;
    uint32_t global_id;
    uint32_t device_object;
    uint8_t kind;
};

struct bound_node {
    struct bound_object object;
    int params_sequence;
    uint8_t params_complete;
    uint8_t has_state;
    uint8_t has_rates;
    uint8_t bit_depths;
    uint8_t channels_max;
    enum pw_node_state state;
    uint32_t rate_min;
    uint32_t rate_max;
};

struct orca_pw_discovery {
    struct pw_loop *loop;
    struct pw_context *context;
    struct pw_core *core;
    struct pw_registry *registry;
    struct spa_hook core_listener;
    struct spa_hook registry_listener;
    struct orca_pw_device *devices;
    uint32_t capacity;
    uint32_t count;
    int sequence;
    int bound_synced;
    int result;
    uint8_t with_capabilities;
    enum orca_pw_discovery_phase phase;
    struct bound_node nodes[DISCOVERY_BOUND];
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
    struct bound_node *node = userdata;
    if ((info->change_mask & PW_NODE_CHANGE_MASK_PROPS) && info->props != NULL)
        node->object.kind = orca_pw_properties_kind(info->props);
    if (info->change_mask & PW_NODE_CHANGE_MASK_STATE) {
        node->state = info->state;
        node->has_state = 1;
    }
}

static uint8_t format_bit_depth(uint32_t format) {
    switch (format) {
    case SPA_AUDIO_FORMAT_S16_LE:
    case SPA_AUDIO_FORMAT_S16_BE:
    case SPA_AUDIO_FORMAT_U16_LE:
    case SPA_AUDIO_FORMAT_U16_BE:
    case SPA_AUDIO_FORMAT_S16P:
        return ORCA_PW_BIT_DEPTH_16;
    case SPA_AUDIO_FORMAT_S24_32_LE:
    case SPA_AUDIO_FORMAT_S24_32_BE:
    case SPA_AUDIO_FORMAT_U24_32_LE:
    case SPA_AUDIO_FORMAT_U24_32_BE:
    case SPA_AUDIO_FORMAT_S24_LE:
    case SPA_AUDIO_FORMAT_S24_BE:
    case SPA_AUDIO_FORMAT_U24_LE:
    case SPA_AUDIO_FORMAT_U24_BE:
    case SPA_AUDIO_FORMAT_S24_32P:
    case SPA_AUDIO_FORMAT_S24P:
        return ORCA_PW_BIT_DEPTH_24;
    case SPA_AUDIO_FORMAT_S32_LE:
    case SPA_AUDIO_FORMAT_S32_BE:
    case SPA_AUDIO_FORMAT_U32_LE:
    case SPA_AUDIO_FORMAT_U32_BE:
    case SPA_AUDIO_FORMAT_F32_LE:
    case SPA_AUDIO_FORMAT_F32_BE:
    case SPA_AUDIO_FORMAT_S32P:
    case SPA_AUDIO_FORMAT_F32P:
        return ORCA_PW_BIT_DEPTH_32;
    default:
        return 0;
    }
}

static const void *format_values(const struct spa_pod_object *format,
                                 uint32_t key, uint32_t type, uint32_t *count,
                                 uint32_t *choice) {
    const struct spa_pod_prop *prop =
        spa_pod_object_find_prop(format, NULL, key);
    if (prop == NULL)
        return NULL;
    const struct spa_pod *values = spa_pod_get_values(&prop->value, count, choice);
    if (values->type != type || *count == 0)
        return NULL;
    return SPA_POD_BODY_CONST(values);
}

static int choice_is_range(uint32_t choice, uint32_t count) {
    return (choice == SPA_CHOICE_Range || choice == SPA_CHOICE_Step) && count >= 3;
}

static int choice_is_list(uint32_t choice) {
    return choice == SPA_CHOICE_None || choice == SPA_CHOICE_Enum;
}

static void fold_rates(struct bound_node *node, int32_t low, int32_t high) {
    if (low <= 0 || high < low)
        return;
    if (!node->has_rates || (uint32_t)low < node->rate_min)
        node->rate_min = (uint32_t)low;
    if (!node->has_rates || (uint32_t)high > node->rate_max)
        node->rate_max = (uint32_t)high;
    node->has_rates = 1;
}

static void fold_channels(struct bound_node *node, int32_t channels) {
    if (channels <= 0)
        return;
    const uint8_t clamped = channels > UINT8_MAX ? UINT8_MAX : (uint8_t)channels;
    if (clamped > node->channels_max)
        node->channels_max = clamped;
}

static void discovery_fold_format(struct bound_node *node,
                                  const struct spa_pod *param) {
    uint32_t media_type = 0;
    uint32_t media_subtype = 0;
    if (!spa_pod_is_object_type(param, SPA_TYPE_OBJECT_Format) ||
        spa_format_parse(param, &media_type, &media_subtype) < 0 ||
        media_type != SPA_MEDIA_TYPE_audio || media_subtype != SPA_MEDIA_SUBTYPE_raw)
        return;
    const struct spa_pod_object *format = (const struct spa_pod_object *)param;
    uint32_t count = 0;
    uint32_t choice = 0;

    const int32_t *rates = format_values(format, SPA_FORMAT_AUDIO_rate,
                                         SPA_TYPE_Int, &count, &choice);
    if (rates != NULL && choice_is_range(choice, count))
        fold_rates(node, rates[1], rates[2]);
    else if (rates != NULL && choice_is_list(choice))
        for (uint32_t index = 0; index < count; index++)
            fold_rates(node, rates[index], rates[index]);

    const uint32_t *formats = format_values(format, SPA_FORMAT_AUDIO_format,
                                            SPA_TYPE_Id, &count, &choice);
    if (formats != NULL && choice_is_list(choice))
        for (uint32_t index = 0; index < count; index++)
            node->bit_depths |= format_bit_depth(formats[index]);

    const int32_t *channels = format_values(format, SPA_FORMAT_AUDIO_channels,
                                            SPA_TYPE_Int, &count, &choice);
    if (channels != NULL && choice_is_range(choice, count))
        fold_channels(node, channels[2]);
    else if (channels != NULL && choice_is_list(choice))
        for (uint32_t index = 0; index < count; index++)
            fold_channels(node, channels[index]);
}

static void discovery_node_param(void *userdata, int sequence, uint32_t id,
                                 uint32_t index, uint32_t next,
                                 const struct spa_pod *param) {
    (void)sequence;
    (void)index;
    (void)next;
    if (id == SPA_PARAM_EnumFormat && param != NULL)
        discovery_fold_format(userdata, param);
}

static const struct pw_node_events discovery_node_events = {
    PW_VERSION_NODE_EVENTS,
    .info = discovery_node_info,
    .param = discovery_node_param,
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
static void discovery_bind_node(struct orca_pw_discovery *discovery,
                                struct bound_node *entry, uint32_t id,
                                const struct spa_dict *props) {
    const char *device_object = spa_dict_lookup(props, PW_KEY_DEVICE_ID);
    entry->object.global_id = id;
    entry->object.device_object = device_object != NULL
                                      ? (uint32_t)strtoul(device_object, NULL, 10)
                                      : SPA_ID_INVALID;
    struct pw_node *node = pw_registry_bind(
        discovery->registry, id, PW_TYPE_INTERFACE_Node, PW_VERSION_NODE, 0);
    if (node == NULL)
        return;
    entry->object.proxy = (struct pw_proxy *)node;
    pw_node_add_listener(node, &entry->object.listener, &discovery_node_events,
                         entry);
}

static void discovery_bind_device(struct orca_pw_discovery *discovery, uint32_t id,
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
    struct orca_pw_discovery *discovery = userdata;
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

static void discovery_resolve_kinds(struct orca_pw_discovery *discovery) {
    for (uint32_t index = 0; index < discovery->count && index < DISCOVERY_BOUND;
         index++) {
        const struct bound_object *node = &discovery->nodes[index].object;
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

static uint8_t node_device_state(const struct bound_node *node) {
    if (!node->has_state)
        return ORCA_PW_DEVICE_UNAVAILABLE;
    switch (node->state) {
    case PW_NODE_STATE_RUNNING:
    case PW_NODE_STATE_IDLE:
        return ORCA_PW_DEVICE_ACTIVE;
    case PW_NODE_STATE_SUSPENDED:
        return ORCA_PW_DEVICE_SUSPENDED;
    default:
        return ORCA_PW_DEVICE_UNAVAILABLE;
    }
}

static void discovery_resolve_capabilities(struct orca_pw_discovery *discovery) {
    for (uint32_t index = 0; index < discovery->count && index < DISCOVERY_BOUND;
         index++) {
        const struct bound_node *node = &discovery->nodes[index];
        if (!node->params_complete || !node->has_rates)
            continue;
        struct orca_pw_device *device = &discovery->devices[index];
        device->has_capabilities = 1;
        device->state = node_device_state(node);
        device->bit_depths = node->bit_depths;
        device->channels_max = node->channels_max;
        device->rate_min = node->rate_min;
        device->rate_max = node->rate_max;
    }
}

static void discovery_request_formats(struct orca_pw_discovery *discovery) {
    for (uint32_t index = 0; index < discovery->count && index < DISCOVERY_BOUND;
         index++) {
        struct bound_node *node = &discovery->nodes[index];
        if (node->object.proxy == NULL)
            continue;
        pw_node_enum_params((struct pw_node *)node->object.proxy, 0,
                            SPA_PARAM_EnumFormat, 0, UINT32_MAX, NULL);
        node->params_sequence = pw_proxy_sync(node->object.proxy, 0);
    }
}

static void discovery_formats_done(struct orca_pw_discovery *discovery,
                                   uint32_t proxy_id, int sequence) {
    for (uint32_t index = 0; index < discovery->count && index < DISCOVERY_BOUND;
         index++) {
        struct bound_node *node = &discovery->nodes[index];
        if (node->object.proxy != NULL &&
            pw_proxy_get_id(node->object.proxy) == proxy_id &&
            node->params_sequence == sequence)
            node->params_complete = 1;
    }
}

static const struct pw_registry_events discovery_registry_events = {
    PW_VERSION_REGISTRY_EVENTS,
    .global = discovery_global,
};

/* The first round trip delivers the globals, which bind proxies; the second
 * delivers those proxies' info; the third, when asked for, each sink's
 * EnumFormat params. A node's own sync is answered only after its params,
 * because the server holds back this client's later requests while an
 * asynchronous enumeration is pending. */
static void discovery_done(void *userdata, uint32_t id, int sequence) {
    struct orca_pw_discovery *discovery = userdata;
    if (id != PW_ID_CORE) {
        discovery_formats_done(discovery, id, sequence);
        return;
    }
    if (sequence != discovery->sequence)
        return;
    if (!discovery->bound_synced) {
        discovery->bound_synced = 1;
        discovery->sequence = pw_core_sync(discovery->core, PW_ID_CORE, 0);
        return;
    }
    if (discovery->phase == ORCA_PW_DISCOVERY_LISTING &&
        discovery->with_capabilities) {
        discovery_request_formats(discovery);
        discovery->sequence = pw_core_sync(discovery->core, PW_ID_CORE, 0);
        discovery->phase = ORCA_PW_DISCOVERY_CAPABILITIES;
        return;
    }
    discovery->phase = ORCA_PW_DISCOVERY_COMPLETE;
}

static void discovery_error(void *userdata, uint32_t id, int sequence,
                            int result, const char *message) {
    (void)sequence;
    (void)message;
    struct orca_pw_discovery *discovery = userdata;
    if (id == PW_ID_CORE) {
        discovery->result = result < 0 ? result : -EIO;
        discovery->phase = ORCA_PW_DISCOVERY_COMPLETE;
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

static uint8_t device_sample_format(uint32_t format) {
    switch (format) {
    case SPA_AUDIO_FORMAT_S16_LE:
    case SPA_AUDIO_FORMAT_S16P:
        return ORCA_PW_FORMAT_S16;
    case SPA_AUDIO_FORMAT_S24_LE:
    case SPA_AUDIO_FORMAT_S24P:
        return ORCA_PW_FORMAT_S24;
    case SPA_AUDIO_FORMAT_S24_32_LE:
    case SPA_AUDIO_FORMAT_S24_32P:
        return ORCA_PW_FORMAT_S24_32;
    case SPA_AUDIO_FORMAT_S32_LE:
    case SPA_AUDIO_FORMAT_S32P:
        return ORCA_PW_FORMAT_S32;
    case SPA_AUDIO_FORMAT_F32_LE:
    case SPA_AUDIO_FORMAT_F32P:
        return ORCA_PW_FORMAT_F32;
    default:
        return ORCA_PW_FORMAT_UNKNOWN;
    }
}

uint64_t orca_pw_format_pack(const struct spa_pod *param) {
    uint32_t media_type = 0;
    uint32_t media_subtype = 0;
    struct spa_audio_info_raw raw;
    spa_zero(raw);
    if (spa_format_parse(param, &media_type, &media_subtype) < 0 ||
        media_type != SPA_MEDIA_TYPE_audio ||
        media_subtype != SPA_MEDIA_SUBTYPE_raw ||
        spa_format_audio_raw_parse(param, &raw) < 0)
        return 0;
    const uint8_t format = device_sample_format(raw.format);
    if (format == ORCA_PW_FORMAT_UNKNOWN || raw.rate == 0 || raw.channels == 0 ||
        raw.channels > UINT16_MAX)
        return 0;
    return (uint64_t)raw.rate << 32 | (uint64_t)raw.channels << 8 | format;
}

static void sink_publish(struct orca_pw_output *output) {
    const struct output_sink *sink = &output->sink;
    const int running = sink->has_state && (sink->state == PW_NODE_STATE_RUNNING ||
                                             sink->state == PW_NODE_STATE_IDLE);
    const uint64_t format = sink->proxy != NULL && sink->is_sink &&
                                    !sink->is_virtual && running
                                ? sink->format
                                : 0;
    atomic_store_explicit(&output->device_format, format, memory_order_release);
}

static void sink_info(void *userdata, const struct pw_node_info *info) {
    struct orca_pw_output *output = userdata;
    struct output_sink *sink = &output->sink;
    if ((info->change_mask & PW_NODE_CHANGE_MASK_PROPS) && info->props != NULL) {
        sink->is_sink =
            equals(spa_dict_lookup(info->props, PW_KEY_MEDIA_CLASS), "Audio/Sink");
        sink->is_virtual =
            orca_pw_properties_kind(info->props) == ORCA_PW_DEVICE_VIRTUAL;
    }
    if (info->change_mask & PW_NODE_CHANGE_MASK_STATE) {
        sink->state = info->state;
        sink->has_state = 1;
    }
    if (info->change_mask & PW_NODE_CHANGE_MASK_PARAMS) {
        for (uint32_t index = 0; index < info->n_params; index++) {
            const struct spa_param_info *param = &info->params[index];
            if (param->id != SPA_PARAM_Format)
                continue;
            if (sink->has_format_flags && sink->format_flags == param->flags)
                break;
            sink->has_format_flags = 1;
            sink->format_flags = param->flags;
            sink->format = 0;
            sink->sequence = -1;
            if (param->flags & SPA_PARAM_INFO_READ) {
                const int result = pw_node_enum_params(
                    (struct pw_node *)sink->proxy, 0, SPA_PARAM_Format, 0,
                    UINT32_MAX, NULL);
                if (SPA_RESULT_IS_ASYNC(result))
                    sink->sequence = result;
            }
            break;
        }
    }
    sink_publish(output);
}

static void sink_param(void *userdata, int sequence, uint32_t id,
                       uint32_t index, uint32_t next,
                       const struct spa_pod *param) {
    (void)index;
    (void)next;
    struct orca_pw_output *output = userdata;
    if (id != SPA_PARAM_Format || param == NULL ||
        sequence != output->sink.sequence)
        return;
    output->sink.format = orca_pw_format_pack(param);
    sink_publish(output);
}

static const struct pw_node_events sink_events = {
    PW_VERSION_NODE_EVENTS,
    .info = sink_info,
    .param = sink_param,
};

static void sink_unbind(struct orca_pw_output *output) {
    if (output->sink.proxy != NULL) {
        spa_hook_remove(&output->sink.listener);
        pw_proxy_destroy(output->sink.proxy);
    }
    memset(&output->sink, 0, sizeof(output->sink));
    sink_publish(output);
}

static void sink_bind(struct orca_pw_output *output, uint32_t id) {
    sink_unbind(output);
    struct pw_node *node = pw_registry_bind(output->registry, id,
                                            PW_TYPE_INTERFACE_Node,
                                            PW_VERSION_NODE, 0);
    if (node == NULL)
        return;
    output->sink.proxy = (struct pw_proxy *)node;
    output->sink.global_id = id;
    pw_node_add_listener(node, &output->sink.listener, &sink_events, output);
}

static void sink_follow_links(struct orca_pw_output *output) {
    for (uint32_t index = 0; index < output->link_count; index++) {
        if (output->sink.proxy != NULL &&
            output->links[index].input_node == output->sink.global_id)
            return;
    }
    if (output->link_count == 0)
        sink_unbind(output);
    else
        sink_bind(output, output->links[output->link_count - 1].input_node);
}

static void output_global(void *userdata, uint32_t id, uint32_t permissions,
                          const char *type, uint32_t version,
                          const struct spa_dict *props) {
    (void)permissions;
    (void)version;
    struct orca_pw_output *output = userdata;
    if (props == NULL || strcmp(type, PW_TYPE_INTERFACE_Link) != 0 ||
        output->link_count >= OUTPUT_LINK_BOUND)
        return;
    const uint32_t node = pw_stream_get_node_id(output->stream);
    const char *from = spa_dict_lookup(props, PW_KEY_LINK_OUTPUT_NODE);
    const char *to = spa_dict_lookup(props, PW_KEY_LINK_INPUT_NODE);
    if (node == SPA_ID_INVALID || from == NULL || to == NULL ||
        strtoul(from, NULL, 10) != node)
        return;
    output->links[output->link_count++] = (struct output_link){
        .id = id,
        .input_node = (uint32_t)strtoul(to, NULL, 10),
    };
    sink_follow_links(output);
    pw_thread_loop_signal(output->loop, false);
}

static void output_global_remove(void *userdata, uint32_t id) {
    struct orca_pw_output *output = userdata;
    uint32_t kept = 0;
    for (uint32_t index = 0; index < output->link_count; index++) {
        const struct output_link link = output->links[index];
        if (link.id != id && link.input_node != id)
            output->links[kept++] = link;
    }
    output->link_count = kept;
    if (output->sink.proxy != NULL && output->sink.global_id == id)
        sink_unbind(output);
    sink_follow_links(output);
}

static const struct pw_registry_events output_registry_events = {
    PW_VERSION_REGISTRY_EVENTS,
    .global = output_global,
    .global_remove = output_global_remove,
};

static void output_watch_sink(struct orca_pw_output *output) {
    if (output->registry != NULL)
        return;
    struct pw_core *core = pw_stream_get_core(output->stream);
    if (core == NULL)
        return;
    output->registry = pw_core_get_registry(core, PW_VERSION_REGISTRY, 0);
    if (output->registry == NULL)
        return;
    pw_registry_add_listener(output->registry, &output->registry_listener,
                             &output_registry_events, output);
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
        output_watch_sink(output);
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
    pw_thread_loop_signal(output->loop, false);
    if (output->wake != NULL)
        output->wake(output->wake_context);
}

static int output_await_target_link(struct orca_pw_output *output) {
    struct timespec deadline;
    pw_thread_loop_lock(output->loop);
    pw_thread_loop_get_time(output->loop, &deadline,
                            OUTPUT_TARGET_LINK_TIMEOUT_NS);
    while (output->link_count == 0 &&
           atomic_load_explicit(&output->state, memory_order_acquire) !=
               ORCA_PW_OUTPUT_LOST) {
        if (pw_thread_loop_timed_wait_full(output->loop, &deadline) < 0)
            break;
    }
    const int result = output->link_count > 0 ? 0 : -ENOLINK;
    pw_thread_loop_unlock(output->loop);
    return result;
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

static void discovery_destroy(struct orca_pw_discovery *discovery) {
    if (discovery->registry != NULL)
        pw_proxy_destroy((struct pw_proxy *)discovery->registry);
    if (discovery->core != NULL)
        pw_core_disconnect(discovery->core);
    if (discovery->context != NULL)
        pw_context_destroy(discovery->context);
    if (discovery->loop != NULL)
        pw_loop_destroy(discovery->loop);
    free(discovery);
}

int orca_pw_discovery_begin(struct orca_pw_device *devices, uint32_t capacity,
                            uint8_t with_capabilities,
                            struct orca_pw_discovery **out) {
    if (out == NULL || (capacity > 0 && devices == NULL))
        return -EINVAL;
    *out = NULL;
    struct orca_pw_discovery *discovery = calloc(1, sizeof(*discovery));
    if (discovery == NULL)
        return -ENOMEM;
    discovery->devices = devices;
    discovery->capacity = capacity;
    discovery->with_capabilities = with_capabilities != 0;

    discovery->loop = pw_loop_new(NULL);
    if (discovery->loop == NULL)
        goto fail;
    discovery->context = pw_context_new(discovery->loop, NULL, 0);
    if (discovery->context == NULL)
        goto fail;
    discovery->core = pw_context_connect(discovery->context, NULL, 0);
    if (discovery->core == NULL)
        goto fail;
    discovery->registry =
        pw_core_get_registry(discovery->core, PW_VERSION_REGISTRY, 0);
    if (discovery->registry == NULL)
        goto fail;
    pw_registry_add_listener(discovery->registry, &discovery->registry_listener,
                             &discovery_registry_events, discovery);
    pw_core_add_listener(discovery->core, &discovery->core_listener,
                         &discovery_core_events, discovery);
    discovery->sequence = pw_core_sync(discovery->core, PW_ID_CORE, 0);
    pw_loop_enter(discovery->loop);
    *out = discovery;
    return 0;

fail:;
    const int result = errno != 0 ? -errno : -EIO;
    discovery_destroy(discovery);
    return result;
}

int orca_pw_discovery_iterate(struct orca_pw_discovery *discovery,
                              int timeout_ms) {
    if (discovery == NULL)
        return -EINVAL;
    if (discovery->phase != ORCA_PW_DISCOVERY_COMPLETE) {
        const int result = pw_loop_iterate(discovery->loop, timeout_ms);
        if (result < 0 && result != -EINTR)
            return result;
    }
    if (discovery->result < 0)
        return discovery->result;
    return discovery->phase;
}

uint32_t orca_pw_discovery_finish(struct orca_pw_discovery *discovery) {
    if (discovery == NULL)
        return 0;
    pw_loop_leave(discovery->loop);
    for (uint32_t index = 0; index < DISCOVERY_BOUND; index++) {
        discovery_unbind(&discovery->nodes[index].object);
        discovery_unbind(&discovery->audio_devices[index]);
    }
    spa_hook_remove(&discovery->core_listener);
    spa_hook_remove(&discovery->registry_listener);
    discovery_resolve_kinds(discovery);
    discovery_resolve_capabilities(discovery);
    const uint32_t count = discovery->count;
    discovery_destroy(discovery);
    return count;
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
    if (device_id != 0) {
        pw_properties_setf(properties, PW_KEY_TARGET_OBJECT, "%llu",
                           (unsigned long long)device_id);
        // An explicitly chosen device fails closed: without these the session
        // manager plays to the default sink when the target is missing or
        // removed, which can be speakers the user did not choose.
        pw_properties_set(properties, PW_KEY_NODE_DONT_RECONNECT, "true");
        pw_properties_set(properties, "node.dont-fallback", "true");
    }
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
    if (device_id != 0 && output_await_target_link(output) < 0) {
        orca_pw_output_destroy(output);
        return NULL;
    }
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
    sink_unbind(output);
    if (output->registry != NULL) {
        spa_hook_remove(&output->registry_listener);
        pw_proxy_destroy((struct pw_proxy *)output->registry);
    }
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
    const uint64_t device_format =
        atomic_load_explicit(&output->device_format, memory_order_acquire);
    *timing = (struct orca_pw_timing) {
        .sample_time = native.ticks,
        .monotonic_ns = native.now,
        .device_delay_frames = native.delay,
        .queued_frames = native.queued / (output->channels * sizeof(float)),
        .buffered_frames = native.buffered,
        .quantum_frames = atomic_load_explicit(&output->quantum_frames,
                                                memory_order_relaxed),
        .graph_rate = native.rate.num == 1 ? native.rate.denom : 0,
        .device_rate = (uint32_t)(device_format >> 32),
        .device_channels = (uint16_t)(device_format >> 8),
        .device_format = (uint8_t)device_format,
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
