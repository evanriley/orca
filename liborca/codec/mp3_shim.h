#ifndef ORCA_MP3_SHIM_H
#define ORCA_MP3_SHIM_H

#include <stdint.h>

/* Narrow containment boundary around the vendored minimp3 decoder. Nothing
   from minimp3.h is visible past this header: callers see one opaque handle,
   plain integers, and an interleaved float32 buffer. */

/* Interleaved float32 samples produced by a single MPEG audio frame:
   1152 samples per channel at up to two channels. */
#define ORCA_MP3_MAX_SAMPLES_PER_FRAME (1152 * 2)

struct orca_mp3_decoder;

struct orca_mp3_frame_info {
    int32_t frame_bytes;
    int32_t frame_offset;
    int32_t channels;
    int32_t sample_rate;
    int32_t layer;
    int32_t bitrate_kbps;
};

/* Allocates and initializes one decoder. NULL on allocation failure. */
struct orca_mp3_decoder *orca_mp3_decoder_create(void);
void orca_mp3_decoder_destroy(struct orca_mp3_decoder *decoder);

/* Drops the bit reservoir and overlap state. Required after a seek. */
void orca_mp3_decoder_reset(struct orca_mp3_decoder *decoder);

/* Decodes at most one frame from `input`. Returns the number of PCM frames
   (samples per channel) written to `pcm`, which must have room for
   ORCA_MP3_MAX_SAMPLES_PER_FRAME floats.

   A return of 0 with `info->frame_bytes == 0` means the input held no
   complete frame and the caller must supply more bytes. A return of 0 with
   `info->frame_bytes > 0` means those bytes were skipped as non-audio and
   the caller should advance and retry. */
int32_t orca_mp3_decode_frame(struct orca_mp3_decoder *decoder,
                              const uint8_t *input, int32_t input_len,
                              float *pcm, struct orca_mp3_frame_info *info);

#endif /* ORCA_MP3_SHIM_H */
