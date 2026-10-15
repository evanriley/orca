#ifndef ORCA_OPUS_SHIM_H
#define ORCA_OPUS_SHIM_H

#include <stdint.h>

/* Containment boundary for libopusfile. No `op_` or `Opus` type is visible
 * past this header: callers see an opaque handle driven by a positional read
 * callback, fixed-width integers and interleaved float32 frames. Output is
 * always 48 kHz, the only rate Opus decodes to. */

struct orca_opus_decoder;

/* Positional read supplied by the caller. Returns the number of bytes placed
 * in `buffer`, 0 at end of input, or a negative value on failure. */
typedef int64_t (*orca_opus_read_fn)(void *context, uint64_t offset,
                                     uint8_t *buffer, uint64_t length);

#define ORCA_OPUS_OK 0
#define ORCA_OPUS_END_OF_STREAM 1
#define ORCA_OPUS_FAILED (-1)

struct orca_opus_info {
    uint32_t channels;
    /* Decoded frames after pre-skip and end trimming, or -1 when the stream
     * does not say. */
    int64_t total_frames;
};

/* Opens the stream and reads its headers. NULL when the bytes are not a
 * decodable Ogg Opus stream. */
struct orca_opus_decoder *orca_opus_decoder_create(void *context,
                                                   orca_opus_read_fn read,
                                                   uint64_t size,
                                                   struct orca_opus_info *info);

void orca_opus_decoder_destroy(struct orca_opus_decoder *decoder);

/* Fills up to `output_frames` interleaved float frames. A chained stream whose
 * channel count changes between links fails rather than reinterpreting
 * samples. */
int32_t orca_opus_decoder_read(struct orca_opus_decoder *decoder, float *output,
                               uint32_t output_frames,
                               uint32_t *frames_written);

int32_t orca_opus_decoder_seek(struct orca_opus_decoder *decoder,
                               uint64_t frame);

#endif /* ORCA_OPUS_SHIM_H */
