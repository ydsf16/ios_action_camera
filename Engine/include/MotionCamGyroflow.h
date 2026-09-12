// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct Engine MCGyroflowEngine;
MCGyroflowEngine *mc_engine_create(const char *json, char *error, size_t capacity);
int32_t mc_engine_process(MCGyroflowEngine *engine, int64_t timestamp_us,
    uint8_t *input, size_t input_len, size_t input_stride,
    uint8_t *output, size_t output_len, size_t output_stride,
    char *error, size_t capacity);
int32_t mc_engine_transform(MCGyroflowEngine *engine, int64_t timestamp_us, float *rows, size_t capacity);
void mc_engine_destroy(MCGyroflowEngine *engine);
#ifdef __cplusplus
}
#endif
