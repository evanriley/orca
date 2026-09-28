#ifndef ORCA_VORBIS_SHIM_H
#define ORCA_VORBIS_SHIM_H

#include <stdint.h>

/* Containment boundary for libvorbisfile. No `ov_` or `vorbis_` type is
 * visible past this header: callers see an opaque handle driven by a
 * positional read callback, fixed-width integers and interleaved float32
 * frames. */

struct orca_vorbis_decoder;

/* Positional read supplied by the caller. Returns the number of bytes placed
 * in `buffer`, 0 at end of input, or a negative value on failure. */
typedef int64_t (*orca_vorbis_read_fn)(void *context, uint64_t offset,
                                       uint8_t *buffer, uint64_t length);

#define ORCA_VORBIS_OK 0
#define ORCA_VORBIS_END_OF_STREAM 1
#define ORCA_VORBIS_FAILED (-1)

struct orca_vorbis_info {
    uint32_t channels;
    uint32_t sample_rate;
    /* Decoded frames, or -1 when the stream does not say. */
    int64_t total_frames;
};

/* Opens the stream and reads its headers. NULL when the bytes are not a
 * decodable Ogg Vorbis stream. */
struct orca_vorbis_decoder *orca_vorbis_decoder_create(void *context,
                                                       orca_vorbis_read_fn read,
                                                       uint64_t size,
                                                       struct orca_vorbis_info *info);

void orca_vorbis_decoder_destroy(struct orca_vorbis_decoder *decoder);

/* Fills up to `output_frames` interleaved float frames. A chained stream whose
 * channel count or sample rate changes between links fails rather than
 * reinterpreting samples. */
int32_t orca_vorbis_decoder_read(struct orca_vorbis_decoder *decoder, float *output,
                                 uint32_t output_frames,
                                 uint32_t *frames_written);

int32_t orca_vorbis_decoder_seek(struct orca_vorbis_decoder *decoder,
                                 uint64_t frame);

#endif /* ORCA_VORBIS_SHIM_H */
