#ifndef BENCHLIBRE_LATENCY_H
#define BENCHLIBRE_LATENCY_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct BLLatencyContext BLLatencyContext;
typedef int (*BLLatencyCancellation)(void *context);

typedef struct {
    uint64_t loads;
    uint32_t final_index;
    int valid;
} BLLatencyResult;

/* Fixed 64-byte slots contain architecture-independent UInt32 successor
 * indices. Slot spacing is part of the workload, not a claim about the host's
 * physical cache-line size. Node count is bounded to [2, 1,048,576]. */
BLLatencyContext *bl_latency_create(uint32_t node_count, uint64_t seed);
BLLatencyContext *bl_latency_create_cancellable(uint32_t node_count, uint64_t seed,
                                              BLLatencyCancellation cancelled,
                                              void *cancellation_context);
void bl_latency_destroy(BLLatencyContext *context);
uint32_t bl_latency_node_count(const BLLatencyContext *context);
uint64_t bl_latency_working_set_bytes(const BLLatencyContext *context);

/* Accessors/reference helpers are for validation outside the timed window. */
uint32_t bl_latency_next(const BLLatencyContext *context, uint32_t index);
uint64_t bl_latency_fingerprint(const BLLatencyContext *context);
int bl_latency_validate(const BLLatencyContext *context);
int bl_latency_validate_cancellable(const BLLatencyContext *context,
                                   BLLatencyCancellation cancelled,
                                   void *cancellation_context);
uint32_t bl_latency_expected_index(const BLLatencyContext *context,
                                   uint32_t start_index, uint64_t loads);

/* The returned index consumes the result of every dependent load. Call only
 * after successful validation of this immutable context. No per-load timing,
 * bounds check, volatile stack access, or independent memory stream is added. */
BLLatencyResult bl_latency_chase(const BLLatencyContext *context,
                                uint32_t start_index, uint64_t loads);

#ifdef __cplusplus
}
#endif
#endif
