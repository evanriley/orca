/* Decodes one ALAC packet under AddressSanitizer and UndefinedBehaviorSanitizer.
 *
 * Input file: a 24-byte ALACSpecificConfig cookie followed by one packet. The
 * packet is copied into an exact-size allocation and decoded through the shim
 * under the sanitizers. The shim pads each packet before decoding, so a read
 * past the packet is caught only once it passes that padding.
 * scripts/alac-sanitize.sh runs this over the seeds in fixtures/fuzz/alac/. */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "alac_shim.h"

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
    if (size < 24 || fseek(f, 0, SEEK_SET) != 0) {
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

    uint8_t cookie[24];
    memcpy(cookie, file, 24);
    size_t packet_size = (size_t)size - 24;
    uint8_t *packet = (uint8_t *)malloc(packet_size == 0 ? 1 : packet_size);
    if (packet == NULL) {
        free(file);
        return 2;
    }
    memcpy(packet, file + 24, packet_size);
    free(file);

    struct orca_alac_info info;
    struct orca_alac_decoder *decoder =
        orca_alac_decoder_create(cookie, 24, &info);
    if (decoder == NULL) {
        printf("create-failed\n");
        free(packet);
        return 0;
    }

    size_t capacity = (size_t)info.frame_length * (size_t)info.channels;
    float *output = (float *)malloc((capacity == 0 ? 1 : capacity) * sizeof(float));
    if (output == NULL) {
        orca_alac_decoder_destroy(decoder);
        free(packet);
        return 2;
    }

    uint32_t frames = 0;
    int32_t rc = orca_alac_decoder_decode(
        decoder, packet, (uint32_t)packet_size, output, &frames);
    if (rc != 0) {
        printf("decode-failed\n");
    } else {
        uint64_t hash = 1469598103934665603ULL;
        size_t bytes = (size_t)frames * (size_t)info.channels * sizeof(float);
        const uint8_t *p = (const uint8_t *)output;
        for (size_t i = 0; i < bytes; i++) {
            hash ^= p[i];
            hash *= 1099511628211ULL;
        }
        printf("frames=%u hash=%016llx\n", frames, (unsigned long long)hash);
    }

    free(output);
    orca_alac_decoder_destroy(decoder);
    free(packet);
    return 0;
}
