// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct Engine RoamShotGyroflowEngine;
typedef struct {
    double requested_smoothing_seconds;
    double effective_smoothing_seconds;
    double minimum_crop;
    double maximum_crop;
    double requested_horizon_percent;
    double effective_horizon_percent;
    double locally_adjusted;
} RoamShotStabilizationReport;
RoamShotGyroflowEngine *roamshot_engine_create(const char *json, char *error, size_t capacity);
int32_t roamshot_engine_report(const RoamShotGyroflowEngine *engine, RoamShotStabilizationReport *report);
int32_t roamshot_engine_process(RoamShotGyroflowEngine *engine, int64_t timestamp_us,
    uint8_t *input, size_t input_len, size_t input_stride,
    uint8_t *output, size_t output_len, size_t output_stride,
    char *error, size_t capacity);
int32_t roamshot_engine_transform(RoamShotGyroflowEngine *engine, int64_t timestamp_us, float *rows, size_t capacity);
void roamshot_engine_destroy(RoamShotGyroflowEngine *engine);
#ifdef __cplusplus
}
#endif
