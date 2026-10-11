#ifndef ORCA_EMBEDDING_SHIM_H
#define ORCA_EMBEDDING_SHIM_H

#include <stddef.h>
#include <stdint.h>

struct orca_embedding_model;

#define ORCA_EMBEDDING_OK 0
#define ORCA_EMBEDDING_RUNTIME_TOO_OLD 1
#define ORCA_EMBEDDING_FAILED 2

/* The session copies `bytes`; the caller frees them on return. */
int32_t orca_embedding_model_create(const void *bytes, size_t size,
                                    struct orca_embedding_model **model);

void orca_embedding_model_destroy(struct orca_embedding_model *model);

/* Called from several threads on one model, so it keeps no per-model state. */
int32_t orca_embedding_model_run(const struct orca_embedding_model *model, const float *features,
                                 uint32_t frames, uint32_t bands, float *embedding,
                                 uint32_t embedding_size);

#endif /* ORCA_EMBEDDING_SHIM_H */
