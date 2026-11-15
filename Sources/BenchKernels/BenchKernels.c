#include "BenchKernels.h"
#include <math.h>
#include <stdlib.h>
#include <stdint.h>
#include <limits.h>

#if defined(__FAST_MATH__) || (defined(__FINITE_MATH_ONLY__) && __FINITE_MATH_ONLY__ > 0)
#error "BenchLibre requires strict floating-point semantics; disable fast math."
#endif

#ifndef __has_builtin
#define __has_builtin(x) 0
#endif

#if defined(__clang__)
#pragma clang fp reassociate(off)
#pragma clang fp contract(off)
#endif

typedef float BLFloat4 __attribute__((ext_vector_type(4)));

static inline BLFloat4 bl_fma4(BLFloat4 x, BLFloat4 y, BLFloat4 z) {
#if __has_builtin(__builtin_elementwise_fma)
    return __builtin_elementwise_fma(x, y, z);
#else
    BLFloat4 out;
    for (unsigned lane = 0; lane < 4; ++lane)
        out[lane] = fmaf(x[lane], y[lane], z[lane]);
    return out;
#endif
}

static inline float bl_cpu_initial(uint32_t seed, unsigned lane) {
    return 0.25f + (float)(seed & 1023U) * (1.0f / 1024.0f)
        + (float)lane * (1.0f / 32.0f);
}

__attribute__((noinline)) static void bl_cpu_compute(uint64_t iterations, uint32_t seed, float out[32]) {
    BLFloat4 v[8];
    for (unsigned chain = 0; chain < 8; ++chain)
        for (unsigned lane = 0; lane < 4; ++lane)
            v[chain][lane] = bl_cpu_initial(seed, chain * 4 + lane);
    const BLFloat4 multiplier = (BLFloat4){0x1.000002p0f, 0x1.000002p0f,
                                         0x1.000002p0f, 0x1.000002p0f};
    /* The bounded inputs and small multiplier keep results finite through the
     * calibrated chunks. Strict FP semantics prohibit collapsing the loop. */
    for (uint64_t i = 0; i < iterations; ++i) {
        v[0] = bl_fma4(v[0], multiplier, (BLFloat4){0x1p-20f, 0x1p-20f, 0x1p-20f, 0x1p-20f});
        v[1] = bl_fma4(v[1], multiplier, (BLFloat4){0x2p-20f, 0x2p-20f, 0x2p-20f, 0x2p-20f});
        v[2] = bl_fma4(v[2], multiplier, (BLFloat4){0x3p-20f, 0x3p-20f, 0x3p-20f, 0x3p-20f});
        v[3] = bl_fma4(v[3], multiplier, (BLFloat4){0x4p-20f, 0x4p-20f, 0x4p-20f, 0x4p-20f});
        v[4] = bl_fma4(v[4], multiplier, (BLFloat4){0x5p-20f, 0x5p-20f, 0x5p-20f, 0x5p-20f});
        v[5] = bl_fma4(v[5], multiplier, (BLFloat4){0x6p-20f, 0x6p-20f, 0x6p-20f, 0x6p-20f});
        v[6] = bl_fma4(v[6], multiplier, (BLFloat4){0x7p-20f, 0x7p-20f, 0x7p-20f, 0x7p-20f});
        v[7] = bl_fma4(v[7], multiplier, (BLFloat4){0x8p-20f, 0x8p-20f, 0x8p-20f, 0x8p-20f});
    }
    for (unsigned chain = 0; chain < 8; ++chain)
        for (unsigned lane = 0; lane < 4; ++lane)
            out[chain * 4 + lane] = v[chain][lane];
}

__attribute__((noinline)) BLCPUResult bl_cpu_fp32(uint64_t iterations, uint32_t seed) {
    if (iterations > UINT64_C(4194304)) return (BLCPUResult){NAN, 0};
    float values[32];
    bl_cpu_compute(iterations, seed, values);
    double checksum = 0;
    for (unsigned i = 0; i < 32; ++i) checksum += values[i];
    return (BLCPUResult){checksum, iterations * 64U};
}

int bl_cpu_validate(void) {
    const uint64_t iterations = 31;
    const uint32_t seed = 17;
    float actual[32];
    bl_cpu_compute(iterations, seed, actual);
    for (unsigned lane = 0; lane < 32; ++lane) {
        volatile float reference = bl_cpu_initial(seed, lane);
        const float add = (float)(lane / 4 + 1) * 0x1p-20f;
        for (uint64_t i = 0; i < iterations; ++i)
            reference = fmaf(reference, 0x1.000002p0f, add);
        if (!isfinite(actual[lane]) || fabsf(actual[lane] - reference) > 1e-6f)
            return 0;
    }
    BLCPUResult r = bl_cpu_fp32(iterations, seed);
    return r.operations == iterations * 64U && isfinite(r.checksum);
}

struct BLMemoryContext {
    float *a;
    float *b;
    float *c;
    size_t count;
};

static inline float bl_memory_b(size_t i) {
    return 0.25f + (float)(i & 1023U) * (1.0f / 1024.0f);
}
static inline float bl_memory_c(size_t i) {
    return 0.5f + (float)(i & 4095U) * (1.0f / 4096.0f);
}

BLMemoryContext *bl_memory_create(size_t float_count) {
    if (float_count == 0 || float_count > (size_t)16 * 1024 * 1024) return NULL;
    BLMemoryContext *ctx = calloc(1, sizeof(*ctx));
    if (!ctx) return NULL;
    ctx->count = float_count;
    size_t bytes = float_count * sizeof(float);
    void *a = NULL, *b = NULL, *c = NULL;
    if (posix_memalign(&a, 64, bytes) != 0 ||
        posix_memalign(&b, 64, bytes) != 0 ||
        posix_memalign(&c, 64, bytes) != 0) {
        free(a); free(b); free(c); free(ctx);
        return NULL;
    }
    ctx->a = a; ctx->b = b; ctx->c = c;
    for (size_t i = 0; i < float_count; ++i) {
        ctx->a[i] = 0;
        ctx->b[i] = bl_memory_b(i);
        ctx->c[i] = bl_memory_c(i);
    }
    return ctx;
}

void bl_memory_destroy(BLMemoryContext *context) {
    if (!context) return;
    free(context->a); free(context->b); free(context->c); free(context);
}

__attribute__((noinline)) void bl_memory_triad(BLMemoryContext *context) {
    if (!context) return;
    float *restrict a = context->a;
    const float *restrict b = context->b;
    const float *restrict c = context->c;
    for (size_t i = 0; i < context->count; ++i) a[i] = b[i] + 3.0f * c[i];
}

uint64_t bl_memory_logical_bytes_per_pass(const BLMemoryContext *context) {
    return context ? (uint64_t)context->count * sizeof(float) * 3U : 0;
}
size_t bl_memory_float_count(const BLMemoryContext *context) { return context ? context->count : 0; }

double bl_memory_checksum(const BLMemoryContext *context) {
    if (!context) return NAN;
    double sum = 0;
    for (size_t i = 0; i < context->count; ++i) sum += context->a[i];
    return sum;
}

double bl_memory_expected_checksum(const BLMemoryContext *context) {
    if (!context) return NAN;
    double period = 0, tail = 0;
    size_t remainder = context->count % 4096U;
    for (size_t i = 0; i < 4096U; ++i) {
        double value = (double)bl_memory_b(i) + 3.0 * (double)bl_memory_c(i);
        period += value;
        if (i < remainder) tail += value;
    }
    return period * (double)(context->count / 4096U) + tail;
}

int bl_memory_validate(const BLMemoryContext *context) {
    if (!context || !context->count) return 0;
    for (size_t i = 0; i < context->count; ++i) {
        float expected = bl_memory_b(i) + 3.0f * bl_memory_c(i);
        if (context->a[i] != expected) return 0;
    }
    return bl_memory_checksum(context) == bl_memory_expected_checksum(context);
}
