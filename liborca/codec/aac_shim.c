#include "aac_shim.h"

#include <stdlib.h>
#include <string.h>

#include "ixheaac_type_def.h"
#include "ixheaac_error_standards.h"
#include "ixheaacd_apicmd_standards.h"
#include "ixheaacd_memory_standards.h"
#include "ixheaacd_aac_config.h"

IA_ERRORCODE ixheaacd_dec_api(pVOID p_ia_module_obj, WORD32 i_cmd, WORD32 i_idx,
                              pVOID pv_value);

/* Every allocation libxaac asks for: the API object, the memory-table array
 * and each memory region. Bounded by the library's own
 * table counts, which are small constants. */
#define ORCA_AAC_MAX_ALLOCATIONS 64
/* Init consumes the AudioSpecificConfig; a stream that never completes init
 * within this many calls is refused rather than spun on. */
#define ORCA_AAC_MAX_INIT_CALLS 8

struct orca_aac_decoder {
    void *api;
    void *allocations[ORCA_AAC_MAX_ALLOCATIONS];
    uint32_t allocation_count;
    uint8_t *input;
    uint32_t input_capacity;
    uint8_t *output;
    uint32_t output_capacity;
    uint8_t *config;
    uint32_t config_size;
    uint32_t channels;
    uint32_t sample_rate;
    /* Output word size in bytes, read back after init: libxaac may revert a
     * requested 24-bit width to 16. */
    uint32_t sample_bytes;
    /* Init still needs an access unit, which the next decode supplies. */
    int pending_init;
    int init_done;
    WORD32 init_consumed;
    /* Bytes of the next access unit that init already consumed. */
    WORD32 skip_next;
};

static int initialize(struct orca_aac_decoder *self, const uint8_t *bytes, uint32_t size);

static void *aligned_alloc_tracked(struct orca_aac_decoder *self, size_t size,
                                   size_t alignment)
{
    uint8_t *memory;
    size_t remainder;

    if (self->allocation_count == ORCA_AAC_MAX_ALLOCATIONS || alignment == 0) {
        return NULL;
    }
    memory = calloc(1, size + alignment);
    if (memory == NULL) {
        return NULL;
    }
    self->allocations[self->allocation_count++] = memory;
    remainder = (size_t)memory % alignment;
    return memory + (remainder == 0 ? 0 : alignment - remainder);
}

static void release(struct orca_aac_decoder *self)
{
    uint32_t index;

    for (index = 0; index < self->allocation_count; index++) {
        free(self->allocations[index]);
    }
    self->allocation_count = 0;
    self->api = NULL;
    self->input = NULL;
    self->output = NULL;
}

static int failed(IA_ERRORCODE code)
{
    return (code & IA_FATAL_ERROR) != 0;
}

static int set_param(struct orca_aac_decoder *self, WORD32 index, WORD32 value)
{
    return failed(ixheaacd_dec_api(self->api, IA_API_CMD_SET_CONFIG_PARAM, index, &value));
}

static int get_param(struct orca_aac_decoder *self, WORD32 index, WORD32 *value)
{
    return failed(ixheaacd_dec_api(self->api, IA_API_CMD_GET_CONFIG_PARAM, index, value));
}

/* The full libxaac bring-up: API object, memory tables, then init from the
 * AudioSpecificConfig. Tables stay where the library built them; relocating
 * them is optional and addresses state that does not exist until the memory
 * tables are set. */
static int setup(struct orca_aac_decoder *self)
{
    UWORD32 size = 0;
    WORD32 count = 0;
    WORD32 index;
    UWORD32 done = 0;
    WORD32 init_calls = 0;
    WORD32 value;

    if (failed(ixheaacd_dec_api(NULL, IA_API_CMD_GET_API_SIZE, 0, &size))) {
        return -1;
    }
    self->api = aligned_alloc_tracked(self, size, 4);
    if (self->api == NULL ||
        failed(ixheaacd_dec_api(self->api, IA_API_CMD_INIT,
                                IA_CMD_TYPE_INIT_API_PRE_CONFIG_PARAMS, NULL))) {
        return -1;
    }
    if (set_param(self, IA_XHEAAC_DEC_CONFIG_PARAM_MP4FLAG, 1) ||
        set_param(self, IA_XHEAAC_DEC_CONFIG_PARAM_PCM_WDSZ, 16) ||
        set_param(self, IA_XHEAAC_DEC_CONFIG_PARAM_TOSTEREO, 0) ||
        set_param(self, IA_XHEAAC_DEC_CONFIG_PARAM_DOWNMIX, 0) ||
        set_param(self, IA_XHEAAC_DEC_CONFIG_PARAM_PEAK_LIMITER, 1)) {
        return -1;
    }

    if (failed(ixheaacd_dec_api(self->api, IA_API_CMD_GET_MEMTABS_SIZE, 0, &size))) {
        return -1;
    }
    {
        void *tables = aligned_alloc_tracked(self, size, 4);
        if (tables == NULL ||
            failed(ixheaacd_dec_api(self->api, IA_API_CMD_SET_MEMTABS_PTR, 0, tables)) ||
            failed(ixheaacd_dec_api(self->api, IA_API_CMD_INIT,
                                    IA_CMD_TYPE_INIT_API_POST_CONFIG_PARAMS, NULL))) {
            return -1;
        }
    }

    if (failed(ixheaacd_dec_api(self->api, IA_API_CMD_GET_N_MEMTABS, 0, &count))) {
        return -1;
    }
    for (index = 0; index < count; index++) {
        UWORD32 region_size = 0;
        UWORD32 alignment = 0;
        UWORD32 type = 0;
        void *region;

        if (failed(ixheaacd_dec_api(self->api, IA_API_CMD_GET_MEM_INFO_SIZE, index,
                                    &region_size)) ||
            failed(ixheaacd_dec_api(self->api, IA_API_CMD_GET_MEM_INFO_ALIGNMENT, index,
                                    &alignment)) ||
            failed(ixheaacd_dec_api(self->api, IA_API_CMD_GET_MEM_INFO_TYPE, index, &type))) {
            return -1;
        }
        region = aligned_alloc_tracked(self, region_size, alignment);
        if (region == NULL ||
            failed(ixheaacd_dec_api(self->api, IA_API_CMD_SET_MEM_PTR, index, region))) {
            return -1;
        }
        if (type == IA_MEMTYPE_INPUT) {
            self->input = region;
            self->input_capacity = region_size;
        } else if (type == IA_MEMTYPE_OUTPUT) {
            self->output = region;
            self->output_capacity = region_size;
        }
    }
    if (self->input == NULL || self->output == NULL || self->config_size > self->input_capacity) {
        return -1;
    }

    if (initialize(self, self->config, self->config_size) != 0) {
        return -1;
    }
    self->pending_init = !self->init_done;
    return 0;
}

/* Runs init over `bytes`. Plain AAC completes init only once it has seen the
 * first access unit, which it parses for channel layout, SBR and PS; the
 * AudioSpecificConfig alone is not enough. */
static int initialize(struct orca_aac_decoder *self, const uint8_t *bytes, uint32_t size)
{
    WORD32 value = (WORD32)size;
    WORD32 consumed = 0;
    UWORD32 done = 0;

    if (size > self->input_capacity) {
        return -1;
    }
    memcpy(self->input, bytes, size);
    if (failed(ixheaacd_dec_api(self->api, IA_API_CMD_SET_INPUT_BYTES, 0, &value)) ||
        failed(ixheaacd_dec_api(self->api, IA_API_CMD_INIT, IA_CMD_TYPE_INIT_PROCESS, NULL)) ||
        failed(ixheaacd_dec_api(self->api, IA_API_CMD_INIT, IA_CMD_TYPE_INIT_DONE_QUERY, &done)) ||
        failed(ixheaacd_dec_api(self->api, IA_API_CMD_GET_CURIDX_INPUT_BUF, 0, &consumed))) {
        return -1;
    }
    self->init_done = done != 0;
    self->init_consumed = consumed;
    if (!self->init_done) {
        return 0;
    }
    {
        WORD32 channels = 0;
        WORD32 rate = 0;
        if (get_param(self, IA_XHEAAC_DEC_CONFIG_PARAM_NUM_CHANNELS, &channels) ||
            get_param(self, IA_XHEAAC_DEC_CONFIG_PARAM_SAMP_FREQ, &rate) || channels <= 0 ||
            rate <= 0) {
            return -1;
        }
        self->channels = (uint32_t)channels;
        self->sample_rate = (uint32_t)rate;
    }
    {
        WORD32 width = 0;
        if (get_param(self, IA_XHEAAC_DEC_CONFIG_PARAM_PCM_WDSZ, &width) ||
            (width != 16 && width != 24)) {
            return -1;
        }
        self->sample_bytes = (uint32_t)width / 8;
    }
    return 0;
}

struct orca_aac_decoder *orca_aac_decoder_create(const uint8_t *config,
                                                 uint32_t config_size,
                                                 const uint8_t *first_unit,
                                                 uint32_t first_unit_size,
                                                 struct orca_aac_info *info)
{
    struct orca_aac_decoder *self = calloc(1, sizeof(*self));

    if (self == NULL) {
        return NULL;
    }
    self->config = malloc(config_size == 0 ? 1 : config_size);
    if (self->config == NULL) {
        free(self);
        return NULL;
    }
    memcpy(self->config, config, config_size);
    self->config_size = config_size;
    if (setup(self) != 0 ||
        (self->pending_init && initialize(self, first_unit, first_unit_size) != 0) ||
        !self->init_done) {
        orca_aac_decoder_destroy(self);
        return NULL;
    }
    self->skip_next = self->pending_init ? self->init_consumed : 0;
    self->pending_init = 0;
    info->channels = self->channels;
    info->sample_rate = self->sample_rate;
    info->max_frames = self->output_capacity / 2 / self->channels;
    return self;
}

void orca_aac_decoder_destroy(struct orca_aac_decoder *decoder)
{
    if (decoder == NULL) {
        return;
    }
    release(decoder);
    free(decoder->config);
    free(decoder);
}

int32_t orca_aac_decoder_reset(struct orca_aac_decoder *decoder)
{
    release(decoder);
    decoder->skip_next = 0;
    return setup(decoder) == 0 ? 0 : -1;
}

int32_t orca_aac_decoder_decode(struct orca_aac_decoder *decoder,
                                const uint8_t *unit, uint32_t unit_size,
                                float *output, uint32_t *frames_written)
{
    WORD32 bytes = (WORD32)unit_size;
    WORD32 produced = 0;
    WORD32 channels = 0;
    uint32_t count;
    uint32_t index;

    *frames_written = 0;
    if (decoder->api == NULL || unit_size > decoder->input_capacity) {
        return -1;
    }
    if (decoder->pending_init) {
        uint32_t channels = decoder->channels;
        uint32_t rate = decoder->sample_rate;
        if (initialize(decoder, unit, unit_size) != 0 || !decoder->init_done ||
            decoder->channels != channels || decoder->sample_rate != rate) {
            return -1;
        }
        decoder->pending_init = 0;
        decoder->skip_next = decoder->init_consumed;
    }
    if (decoder->skip_next > 0) {
        if ((uint32_t)decoder->skip_next >= unit_size) {
            decoder->skip_next = 0;
            return 0;
        }
        unit += decoder->skip_next;
        unit_size -= (uint32_t)decoder->skip_next;
        bytes = (WORD32)unit_size;
        decoder->skip_next = 0;
    }
    memcpy(decoder->input, unit, unit_size);
    if (failed(ixheaacd_dec_api(decoder->api, IA_API_CMD_SET_INPUT_BYTES, 0, &bytes)) ||
        failed(ixheaacd_dec_api(decoder->api, IA_API_CMD_EXECUTE, IA_CMD_TYPE_DO_EXECUTE,
                                NULL)) ||
        failed(ixheaacd_dec_api(decoder->api, IA_API_CMD_GET_OUTPUT_BYTES, 0, &produced)) ||
        get_param(decoder, IA_XHEAAC_DEC_CONFIG_PARAM_NUM_CHANNELS, &channels)) {
        return -1;
    }
    if ((uint32_t)channels != decoder->channels || produced < 0 ||
        (uint32_t)produced > decoder->output_capacity) {
        return -1;
    }
    count = (uint32_t)produced / decoder->sample_bytes;
    for (index = 0; index < count; index++) {
        const uint8_t *sample_bytes = decoder->output + (size_t)index * decoder->sample_bytes;
        if (decoder->sample_bytes == 2) {
            int16_t sample = (int16_t)((uint16_t)sample_bytes[0] | ((uint16_t)sample_bytes[1] << 8));
            output[index] = (float)sample / 32768.0f;
        } else {
            uint32_t raw = (uint32_t)sample_bytes[0] | ((uint32_t)sample_bytes[1] << 8) |
                           ((uint32_t)sample_bytes[2] << 16);
            int32_t sample = (int32_t)(raw << 8) >> 8;
            output[index] = (float)sample / 8388608.0f;
        }
    }
    *frames_written = count / decoder->channels;
    return 0;
}
