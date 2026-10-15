#ifndef ORCA_MP3_SHIM_H
#define ORCA_MP3_SHIM_H

#include <stdint.h>

/* Containment boundary for libmpg123.
 *
 * mpg123 is pull-shaped with cursor callbacks and a native frame-info struct;
 * Orca's codec interface is positional `ReadableSource` -> interleaved float
 * frames. This header is where the two shapes meet, so no `mpg123_` type is
 * visible past it. */

struct orca_mp3_decoder;

/* Positional read supplied by the caller. Returns the number of bytes placed
 * in `buffer`, 0 at end of input, or a negative value on failure. */
typedef int64_t (*orca_mp3_read_fn)(void* context, uint64_t offset, uint8_t* buffer,
                                    uint64_t length);

#define ORCA_MP3_OK 0
#define ORCA_MP3_END_OF_STREAM 1
#define ORCA_MP3_FAILED (-1)

#define ORCA_MP3_ERROR_NONE 0
#define ORCA_MP3_ERROR_NO_SYNC 1
#define ORCA_MP3_ERROR_OUT_OF_MEMORY 2
#define ORCA_MP3_ERROR_OTHER 3

struct orca_mp3_info {
    /* MPEG layer: 1, 2 or 3. */
    int32_t layer;
    int32_t channels;
    int64_t sample_rate;
    /* Decoded frames after gapless trimming, or -1 when the stream does not
     * say. */
    int64_t frame_count;
};

/* Creates a decoder over `read`. NULL on failure, with `error_code` set to one
 * of the ORCA_MP3_ERROR_* values. */
struct orca_mp3_decoder* orca_mp3_decoder_create(void* context, orca_mp3_read_fn read,
                                                 uint64_t size, struct orca_mp3_info* info,
                                                 int32_t* error_code);

void orca_mp3_decoder_destroy(struct orca_mp3_decoder* decoder);

/* Fills up to `output_frames` interleaved float frames. Returns ORCA_MP3_OK,
 * ORCA_MP3_END_OF_STREAM or ORCA_MP3_FAILED and writes the frame count to
 * `frames_written`. */
int32_t orca_mp3_decoder_read(struct orca_mp3_decoder* decoder, float* output,
                              uint32_t output_frames, uint32_t* frames_written);

/* Seeks to an absolute frame. Returns ORCA_MP3_OK or ORCA_MP3_FAILED. */
int32_t orca_mp3_decoder_seek(struct orca_mp3_decoder* decoder, uint64_t frame);

#endif /* ORCA_MP3_SHIM_H */
