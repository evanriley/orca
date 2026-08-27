#ifndef ORCA_FLAC_SHIM_H
#define ORCA_FLAC_SHIM_H

#include <stdint.h>

/* Containment boundary for libFLAC.
 *
 * libFLAC's stream decoder is push-shaped: it pulls bytes through a read
 * callback and pushes decoded blocks back through a write callback. Orca's
 * codec interface is pull-shaped over a positional `ReadableSource` that
 * exposes neither a path nor a file handle. This header is where those two
 * shapes meet, so that no `FLAC__` type, and no C type beyond the fixed-width
 * integers below, is visible to Zig. */

struct orca_flac_decoder;

/* Positional read supplied by the caller. Returns the number of bytes placed
 * in `buffer`, 0 at end of input, or a negative value on failure. */
typedef int64_t (*orca_flac_read_fn)(void *context, uint64_t offset,
                                     uint8_t *buffer, uint64_t length);

/* Outcome of a decode request. */
#define ORCA_FLAC_OK 0
#define ORCA_FLAC_END_OF_STREAM 1
#define ORCA_FLAC_FAILED (-1)

/* Creates a decoder positioned at the first audio frame, or NULL if the
 * stream's metadata cannot be read. `max_block_frames` and `channels` come
 * from the caller's own STREAMINFO parse and size the interleaving buffer;
 * both may be zero, in which case the buffer grows on the first block. */
struct orca_flac_decoder *orca_flac_decoder_create(void *context,
                                                   orca_flac_read_fn read,
                                                   uint64_t size,
                                                   uint32_t max_block_frames,
                                                   uint32_t channels);

void orca_flac_decoder_destroy(struct orca_flac_decoder *decoder);

/* Fills up to `output_frames` interleaved float frames, normalized to
 * [-1, 1) by the stream's own sample width. Writes the number of frames
 * produced to `frames_written` and returns one of the ORCA_FLAC_* codes.
 * A short fill is normal: a request is answered from at most one FLAC block. */
int32_t orca_flac_decoder_read(struct orca_flac_decoder *decoder, float *output,
                               uint32_t output_frames,
                               uint32_t *frames_written);

/* Positions the stream at an absolute frame. Returns ORCA_FLAC_OK or
 * ORCA_FLAC_FAILED; on failure the decoder is flushed and remains usable. */
int32_t orca_flac_decoder_seek(struct orca_flac_decoder *decoder,
                               uint64_t frame);

#endif /* ORCA_FLAC_SHIM_H */
