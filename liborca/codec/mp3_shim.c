#include "mp3_shim.h"

#include <mpg123.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define ORCA_MP3_CHANNELS_MONO 1
#define ORCA_MP3_CHANNELS_STEREO 2
#define ORCA_MP3_ENCODING_FLOAT_32 MPG123_ENC_FLOAT_32
#define ORCA_MP3_RESYNC_LIMIT_BYTES (128 * 1024)
#define ORCA_MP3_FRAME_INDEX_ENTRIES 1000
#define ORCA_MP3_RESERVOIR_PREFRAMES 18
#define ORCA_MP3_SEEK_CEILING (1LL << 40)
#define ORCA_MP3_MAX_CHANNELS 2

struct orca_mp3_decoder {
    mpg123_handle* native;
    void* context;
    orca_mp3_read_fn read;
    uint64_t position;
    uint64_t size;
    int read_failed;
    int32_t channels;
    int64_t sample_rate;
};

static int read_callback(void* io, void* buffer, size_t count, size_t* done) {
    struct orca_mp3_decoder* self = io;
    int64_t obtained;

    *done = 0;
    if (count == 0) {
        return 0;
    }
    obtained = self->read(self->context, self->position, buffer, (uint64_t)count);
    if (obtained < 0) {
        self->read_failed = 1;
        return -1;
    }
    self->position += (uint64_t)obtained;
    *done = (size_t)obtained;
    return 0;
}

static int64_t seek_callback(void* io, int64_t offset, int whence) {
    struct orca_mp3_decoder* self = io;
    int64_t base;
    int64_t target;

    switch (whence) {
    case SEEK_SET:
        base = 0;
        break;
    case SEEK_CUR:
        base = (int64_t)self->position;
        break;
    case SEEK_END:
        base = (int64_t)self->size;
        break;
    default:
        return -1;
    }
    target = base + offset;
    if (target < 0) {
        return -1;
    }
    self->position = (uint64_t)target;
    return target;
}

static int configure(struct orca_mp3_decoder* self) {
    long flags = MPG123_QUIET | MPG123_GAPLESS | MPG123_SKIP_ID3V2;

    if (mpg123_param2(self->native, MPG123_FLAGS, flags, 0.0) != MPG123_OK) {
        return 0;
    }
    if (mpg123_param2(self->native, MPG123_RESYNC_LIMIT, ORCA_MP3_RESYNC_LIMIT_BYTES, 0.0) !=
        MPG123_OK) {
        return 0;
    }
    if (mpg123_param2(self->native, MPG123_INDEX_SIZE, ORCA_MP3_FRAME_INDEX_ENTRIES, 0.0) !=
        MPG123_OK) {
        return 0;
    }
    if (mpg123_param2(self->native, MPG123_PREFRAMES, ORCA_MP3_RESERVOIR_PREFRAMES, 0.0) !=
        MPG123_OK) {
        return 0;
    }
    if (mpg123_format_none(self->native) != MPG123_OK) {
        return 0;
    }
    if (mpg123_format2(self->native, 0, ORCA_MP3_CHANNELS_MONO | ORCA_MP3_CHANNELS_STEREO,
                       ORCA_MP3_ENCODING_FLOAT_32) != MPG123_OK) {
        return 0;
    }
    if (mpg123_reader64(self->native, read_callback, seek_callback, NULL) != MPG123_OK) {
        return 0;
    }
    return 1;
}

struct orca_mp3_decoder* orca_mp3_decoder_create(void* context, orca_mp3_read_fn read,
                                                 uint64_t size, struct orca_mp3_info* info,
                                                 int32_t* error_code) {
    struct orca_mp3_decoder* self;
    int new_status = MPG123_OK;
    long rate = 0;
    int channels = 0;
    int encoding = 0;
    struct mpg123_frameinfo2 frame_info;
    int64_t length;

    if (error_code) {
        *error_code = ORCA_MP3_ERROR_OTHER;
    }
    if (read == NULL || info == NULL) {
        return NULL;
    }
    self = calloc(1, sizeof(*self));
    if (self == NULL) {
        if (error_code) {
            *error_code = ORCA_MP3_ERROR_OUT_OF_MEMORY;
        }
        return NULL;
    }
    self->context = context;
    self->read = read;
    self->size = size;
    self->native = mpg123_new(NULL, &new_status);
    if (self->native == NULL) {
        if (error_code) {
            (void)new_status;
            *error_code = ORCA_MP3_ERROR_OUT_OF_MEMORY;
        }
        free(self);
        return NULL;
    }
    if (!configure(self)) {
        mpg123_delete(self->native);
        free(self);
        return NULL;
    }
    if (mpg123_open_handle(self->native, self) != MPG123_OK) {
        if (error_code) {
            *error_code = ORCA_MP3_ERROR_OTHER;
        }
        mpg123_delete(self->native);
        free(self);
        return NULL;
    }

    switch (mpg123_getformat(self->native, &rate, &channels, &encoding)) {
    case MPG123_OK:
        break;
    case MPG123_DONE:
        if (error_code) {
            *error_code = ORCA_MP3_ERROR_NO_SYNC;
        }
        mpg123_close(self->native);
        mpg123_delete(self->native);
        free(self);
        return NULL;
    default:
        if (error_code) {
            *error_code = ORCA_MP3_ERROR_NO_SYNC;
        }
        mpg123_close(self->native);
        mpg123_delete(self->native);
        free(self);
        return NULL;
    }
    if (encoding != ORCA_MP3_ENCODING_FLOAT_32 || channels <= 0 ||
        channels > ORCA_MP3_MAX_CHANNELS || rate <= 0) {
        mpg123_close(self->native);
        mpg123_delete(self->native);
        free(self);
        return NULL;
    }
    if (mpg123_info2(self->native, &frame_info) != MPG123_OK) {
        mpg123_close(self->native);
        mpg123_delete(self->native);
        free(self);
        return NULL;
    }
    self->channels = channels;
    self->sample_rate = rate;
    length = mpg123_length64(self->native);

    info->layer = frame_info.layer;
    info->channels = channels;
    info->sample_rate = rate;
    info->frame_count = length < 0 ? -1 : length;
    if (error_code) {
        *error_code = ORCA_MP3_ERROR_NONE;
    }
    return self;
}

void orca_mp3_decoder_destroy(struct orca_mp3_decoder* decoder) {
    if (decoder == NULL) {
        return;
    }
    mpg123_close(decoder->native);
    mpg123_delete(decoder->native);
    free(decoder);
}

int32_t orca_mp3_decoder_read(struct orca_mp3_decoder* decoder, float* output,
                              uint32_t output_frames, uint32_t* frames_written) {
    const size_t frame_bytes = (size_t)decoder->channels * sizeof(float);
    const size_t capacity_bytes = (size_t)output_frames * frame_bytes;
    unsigned char* bytes = (unsigned char*)output;
    size_t produced_bytes = 0;

    *frames_written = 0;
    while (produced_bytes < capacity_bytes) {
        size_t done = 0;
        const int status = mpg123_read(decoder->native, bytes + produced_bytes,
                                       capacity_bytes - produced_bytes, &done);
        produced_bytes += done;
        if (status == MPG123_OK) {
            if (done == 0) {
                break;
            }
        } else if (status == MPG123_DONE) {
            break;
        } else if (status == MPG123_NEW_FORMAT) {
            long rate = 0;
            int channels = 0;
            int encoding = 0;
            if (mpg123_getformat(decoder->native, &rate, &channels, &encoding) != MPG123_OK) {
                return ORCA_MP3_FAILED;
            }
            if (encoding != ORCA_MP3_ENCODING_FLOAT_32 || channels != decoder->channels ||
                rate != decoder->sample_rate) {
                return ORCA_MP3_FAILED;
            }
        } else {
            return ORCA_MP3_FAILED;
        }
    }
    if (produced_bytes % frame_bytes != 0) {
        return ORCA_MP3_FAILED;
    }
    *frames_written = (uint32_t)(produced_bytes / frame_bytes);
    return *frames_written == 0 ? ORCA_MP3_END_OF_STREAM : ORCA_MP3_OK;
}

int32_t orca_mp3_decoder_seek(struct orca_mp3_decoder* decoder, uint64_t frame) {
    int64_t target =
        frame > (uint64_t)ORCA_MP3_SEEK_CEILING ? ORCA_MP3_SEEK_CEILING : (int64_t)frame;
    if (mpg123_seek64(decoder->native, target, SEEK_SET) < 0) {
        return ORCA_MP3_FAILED;
    }
    return ORCA_MP3_OK;
}
