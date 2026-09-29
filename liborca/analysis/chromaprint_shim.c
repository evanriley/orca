#include "chromaprint_shim.h"

#include <limits.h>
#include <stddef.h>

#include <chromaprint.h>

const uint32_t orca_chromaprint_sample_rate = 11025;

struct orca_chromaprint *orca_chromaprint_create(int32_t algorithm)
{
    if (algorithm < CHROMAPRINT_ALGORITHM_TEST1 || algorithm > CHROMAPRINT_ALGORITHM_TEST5) {
        return NULL;
    }
    return (struct orca_chromaprint *)chromaprint_new(algorithm);
}

void orca_chromaprint_destroy(struct orca_chromaprint *context)
{
    chromaprint_free((ChromaprintContext *)context);
}

int32_t orca_chromaprint_start(struct orca_chromaprint *context, uint32_t channels)
{
    if (channels == 0 || channels > INT_MAX) {
        return ORCA_CHROMAPRINT_FAILED;
    }
    return chromaprint_start((ChromaprintContext *)context, (int)orca_chromaprint_sample_rate,
                             (int)channels)
               ? ORCA_CHROMAPRINT_OK
               : ORCA_CHROMAPRINT_FAILED;
}

int32_t orca_chromaprint_feed(struct orca_chromaprint *context, const int16_t *samples,
                              uint32_t count)
{
    if (count > INT_MAX) {
        return ORCA_CHROMAPRINT_FAILED;
    }
    return chromaprint_feed((ChromaprintContext *)context, samples, (int)count)
               ? ORCA_CHROMAPRINT_OK
               : ORCA_CHROMAPRINT_FAILED;
}

int32_t orca_chromaprint_finish(struct orca_chromaprint *context)
{
    return chromaprint_finish((ChromaprintContext *)context) ? ORCA_CHROMAPRINT_OK
                                                             : ORCA_CHROMAPRINT_FAILED;
}

int32_t orca_chromaprint_fingerprint(struct orca_chromaprint *context, char **encoded,
                                     uint32_t *raw_size)
{
    int size = 0;

    if (!chromaprint_get_raw_fingerprint_size((ChromaprintContext *)context, &size) || size < 0) {
        return ORCA_CHROMAPRINT_FAILED;
    }
    if (!chromaprint_get_fingerprint((ChromaprintContext *)context, encoded)) {
        return ORCA_CHROMAPRINT_FAILED;
    }
    *raw_size = (uint32_t)size;
    return ORCA_CHROMAPRINT_OK;
}

int32_t orca_chromaprint_decode(const char *encoded, uint32_t encoded_length, uint32_t **raw,
                                uint32_t *raw_size, int32_t *algorithm)
{
    int size = 0;
    int decoded_algorithm = 0;

    if (encoded_length > INT_MAX) {
        return ORCA_CHROMAPRINT_FAILED;
    }
    if (!chromaprint_decode_fingerprint(encoded, (int)encoded_length, raw, &size,
                                        &decoded_algorithm, 1) ||
        size < 0) {
        return ORCA_CHROMAPRINT_FAILED;
    }
    *raw_size = (uint32_t)size;
    *algorithm = decoded_algorithm;
    return ORCA_CHROMAPRINT_OK;
}

void orca_chromaprint_release(void *pointer)
{
    chromaprint_dealloc(pointer);
}
