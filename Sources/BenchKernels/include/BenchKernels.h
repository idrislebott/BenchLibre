#ifndef BENCHLIBRE_KERNELS_H
#define BENCHLIBRE_KERNELS_H

#include <stddef.h>
#include <stdint.h>
#include "BenchLatency.h"

#ifdef __cplusplus
extern "C" {
#endif

/* 8 independent four-lane FP32 FMA chains: 64 floating-point operations
 * per iteration (a multiply and an add are counted separately).
 * At most 4194304 iterations per call; an oversized call returns NaN/0. */
typedef struct {
    double checksum;
    uint64_t operations;
} BLCPUResult;

BLCPUResult bl_cpu_fp32(uint64_t iterations, uint32_t seed);
int bl_cpu_validate(void);

typedef struct BLMemoryContext BLMemoryContext;
/* Three separately allocated, 64-byte-aligned arrays. Creation includes first
 * touch. At most 16777216 floats per array (192 MiB total).
 * Callers must release the context with bl_memory_destroy. */
BLMemoryContext *bl_memory_create(size_t float_count);
void bl_memory_destroy(BLMemoryContext *context);
void bl_memory_triad(BLMemoryContext *context);
uint64_t bl_memory_logical_bytes_per_pass(const BLMemoryContext *context);
double bl_memory_checksum(const BLMemoryContext *context);
double bl_memory_expected_checksum(const BLMemoryContext *context);
int bl_memory_validate(const BLMemoryContext *context);
size_t bl_memory_float_count(const BLMemoryContext *context);

#ifdef __cplusplus
}
#endif
#endif
