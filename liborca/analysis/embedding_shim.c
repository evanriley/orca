#include "embedding_shim.h"

#include <stdlib.h>
#include <string.h>

#if __has_include(<onnxruntime_c_api.h>)
#include <onnxruntime_c_api.h>
#else
#include <onnxruntime/onnxruntime_c_api.h>
#endif

/* The oldest ONNX Runtime a supported distribution ships is 1.20. Requesting
 * ORT_API_VERSION instead would make a build against newer headers refuse
 * that runtime, so every OrtApi member used here must exist in version 20. */
#define ORCA_ORT_API_VERSION 20

struct orca_embedding_model {
    const OrtApi *api;
    OrtEnv *env;
    OrtSession *session;
    OrtMemoryInfo *memory;
};

static int failed(const OrtApi *api, OrtStatus *status)
{
    if (status == NULL) {
        return 0;
    }
    api->ReleaseStatus(status);
    return 1;
}

int32_t orca_embedding_model_create(const void *bytes, size_t size,
                                    struct orca_embedding_model **model)
{
    const OrtApi *api = OrtGetApiBase()->GetApi(ORCA_ORT_API_VERSION);
    struct orca_embedding_model *self;
    OrtSessionOptions *options = NULL;
    int32_t result = ORCA_EMBEDDING_FAILED;

    *model = NULL;
    if (api == NULL) {
        return ORCA_EMBEDDING_RUNTIME_TOO_OLD;
    }
    self = calloc(1, sizeof(*self));
    if (self == NULL) {
        return ORCA_EMBEDDING_FAILED;
    }
    self->api = api;
    if (!failed(api, api->CreateEnv(ORT_LOGGING_LEVEL_ERROR, "orca", &self->env)) &&
        !failed(api, api->CreateSessionOptions(&options)) &&
        !failed(api, api->SetIntraOpNumThreads(options, 1)) &&
        !failed(api, api->SetInterOpNumThreads(options, 1)) &&
        !failed(api, api->CreateSessionFromArray(self->env, bytes, size, options,
                                                 &self->session)) &&
        !failed(api, api->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault,
                                              &self->memory))) {
        result = ORCA_EMBEDDING_OK;
    }
    if (options != NULL) {
        api->ReleaseSessionOptions(options);
    }
    if (result != ORCA_EMBEDDING_OK) {
        orca_embedding_model_destroy(self);
        return result;
    }
    *model = self;
    return ORCA_EMBEDDING_OK;
}

void orca_embedding_model_destroy(struct orca_embedding_model *model)
{
    if (model == NULL) {
        return;
    }
    if (model->memory != NULL) {
        model->api->ReleaseMemoryInfo(model->memory);
    }
    if (model->session != NULL) {
        model->api->ReleaseSession(model->session);
    }
    if (model->env != NULL) {
        model->api->ReleaseEnv(model->env);
    }
    free(model);
}

static int32_t copy_output(const OrtApi *api, OrtValue *output, float *embedding,
                           uint32_t embedding_size)
{
    OrtTensorTypeAndShapeInfo *info = NULL;
    ONNXTensorElementDataType type = ONNX_TENSOR_ELEMENT_DATA_TYPE_UNDEFINED;
    size_t count = 0;
    float *values = NULL;
    int32_t result = ORCA_EMBEDDING_FAILED;

    if (failed(api, api->GetTensorTypeAndShape(output, &info))) {
        return ORCA_EMBEDDING_FAILED;
    }
    if (!failed(api, api->GetTensorElementType(info, &type)) &&
        !failed(api, api->GetTensorShapeElementCount(info, &count)) &&
        type == ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT && count == embedding_size &&
        !failed(api, api->GetTensorMutableData(output, (void **)&values))) {
        memcpy(embedding, values, count * sizeof(float));
        result = ORCA_EMBEDDING_OK;
    }
    api->ReleaseTensorTypeAndShapeInfo(info);
    return result;
}

int32_t orca_embedding_model_run(const struct orca_embedding_model *model, const float *features,
                                 uint32_t frames, uint32_t bands, float *embedding,
                                 uint32_t embedding_size)
{
    static const char *const input_names[] = {"input_features"};
    static const char *const output_names[] = {"embedding"};
    const OrtApi *api = model->api;
    const int64_t shape[] = {1, 1, frames, bands};
    OrtValue *input = NULL;
    OrtValue *output = NULL;
    int32_t result = ORCA_EMBEDDING_FAILED;

    if (failed(api, api->CreateTensorWithDataAsOrtValue(
                        model->memory, (void *)features,
                        (size_t)frames * bands * sizeof(float), shape,
                        sizeof(shape) / sizeof(shape[0]), ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT,
                        &input))) {
        return ORCA_EMBEDDING_FAILED;
    }
    if (!failed(api, api->Run(model->session, NULL, input_names, (const OrtValue *const *)&input,
                              1, output_names, 1, &output))) {
        result = copy_output(api, output, embedding, embedding_size);
    }
    if (output != NULL) {
        api->ReleaseValue(output);
    }
    api->ReleaseValue(input);
    return result;
}
