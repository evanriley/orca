/* Decodes AAC access units under AddressSanitizer and UndefinedBehaviorSanitizer.
 *
 * Input file: a u32-le config size, the AudioSpecificConfig bytes, then one or
 * more access units each prefixed by a u32-le size. The config and first unit
 * configure the decoder; every unit is then decoded through the shim under the
 * sanitizers. Each buffer is an exact-size allocation so a read past it is
 * caught. scripts/aac-sanitize.sh runs this over the seeds in fixtures/fuzz/aac/. */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "aac_shim.h"

static int read_u32(const uint8_t *p, size_t avail, uint32_t *out) {
    if (avail < 4) return -1;
    *out = (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) |
           ((uint32_t)p[3] << 24);
    return 0;
}

static uint8_t *dup_exact(const uint8_t *src, size_t n) {
    uint8_t *copy = (uint8_t *)malloc(n == 0 ? 1 : n);
    if (copy != NULL && n != 0) memcpy(copy, src, n);
    return copy;
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s FILE\n", argv[0]);
        return 2;
    }

    FILE *f = fopen(argv[1], "rb");
    if (f == NULL) {
        perror("fopen");
        return 2;
    }
    if (fseek(f, 0, SEEK_END) != 0) {
        fclose(f);
        return 2;
    }
    long size = ftell(f);
    if (size < 4 || fseek(f, 0, SEEK_SET) != 0) {
        fprintf(stderr, "%s: short file\n", argv[1]);
        fclose(f);
        return 2;
    }
    uint8_t *file = (uint8_t *)malloc((size_t)size);
    if (file == NULL || fread(file, 1, (size_t)size, f) != (size_t)size) {
        fclose(f);
        free(file);
        return 2;
    }
    fclose(f);

    size_t pos = 0;
    uint32_t config_size = 0;
    if (read_u32(file, (size_t)size - pos, &config_size) != 0) {
        free(file);
        return 2;
    }
    pos += 4;
    if (config_size > (size_t)size - pos) {
        fprintf(stderr, "%s: config overruns file\n", argv[1]);
        free(file);
        return 2;
    }
    uint8_t *config = dup_exact(file + pos, config_size);
    pos += config_size;
    if (config == NULL) {
        free(file);
        return 2;
    }

    /* The first access unit, needed to finish init. */
    uint32_t first_size = 0;
    uint8_t *first = NULL;
    if (read_u32(file + pos, (size_t)size - pos, &first_size) == 0) {
        pos += 4;
        if (first_size <= (size_t)size - pos) {
            first = dup_exact(file + pos, first_size);
        }
    }

    struct orca_aac_info info;
    struct orca_aac_decoder *decoder = orca_aac_decoder_create(
        config, config_size, first == NULL ? NULL : first,
        first == NULL ? 0 : first_size, &info);
    free(config);
    if (decoder == NULL) {
        printf("create-failed\n");
        free(first);
        free(file);
        return 0;
    }

    size_t capacity = (size_t)info.max_frames * (size_t)info.channels;
    float *output = (float *)malloc((capacity == 0 ? 1 : capacity) * sizeof(float));
    if (output == NULL) {
        orca_aac_decoder_destroy(decoder);
        free(first);
        free(file);
        return 2;
    }

    uint64_t hash = 1469598103934665603ULL;
    unsigned decoded = 0;

    /* Rewind to the first unit and decode every unit in the file. */
    size_t cursor = 4 + config_size;
    while (cursor + 4 <= (size_t)size) {
        uint32_t unit_size = 0;
        read_u32(file + cursor, (size_t)size - cursor, &unit_size);
        cursor += 4;
        if (unit_size > (size_t)size - cursor) break;
        uint8_t *unit = dup_exact(file + cursor, unit_size);
        cursor += unit_size;
        if (unit == NULL) break;

        uint32_t frames = 0;
        int32_t rc = orca_aac_decoder_decode(decoder, unit, unit_size, output, &frames);
        free(unit);
        if (rc != 0) continue;
        decoded++;
        size_t bytes = (size_t)frames * (size_t)info.channels * sizeof(float);
        const uint8_t *p = (const uint8_t *)output;
        for (size_t i = 0; i < bytes; i++) {
            hash ^= p[i];
            hash *= 1099511628211ULL;
        }
    }

    printf("units=%u hash=%016llx\n", decoded, (unsigned long long)hash);

    free(output);
    orca_aac_decoder_destroy(decoder);
    free(first);
    free(file);
    return 0;
}
