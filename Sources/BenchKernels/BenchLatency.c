// SPDX-License-Identifier: MIT
#include "BenchLatency.h"
#include <stdlib.h>
#include <string.h>
#include <limits.h>

typedef struct {
    uint32_t next;
    unsigned char padding[60];
} BLLatencyNode;

_Static_assert(sizeof(BLLatencyNode) == 64, "Latency slots must remain 64 bytes");

struct BLLatencyContext {
    BLLatencyNode *nodes;
    uint32_t count;
};

static int bl_latency_cancelled(BLLatencyCancellation callback, void *context) {
    return callback && callback(context);
}

static uint64_t bl_latency_random(uint64_t *state) {
    uint64_t z = (*state += UINT64_C(0x9e3779b97f4a7c15));
    z = (z ^ (z >> 30)) * UINT64_C(0xbf58476d1ce4e5b9);
    z = (z ^ (z >> 27)) * UINT64_C(0x94d049bb133111eb);
    return z ^ (z >> 31);
}

static uint32_t bl_latency_random_bounded(uint64_t *state, uint32_t bound) {
    const uint64_t threshold = (UINT64_C(0) - (uint64_t)bound) % bound;
    uint64_t value;
    do { value = bl_latency_random(state); } while (value < threshold);
    return (uint32_t)(value % bound);
}

BLLatencyContext *bl_latency_create(uint32_t node_count, uint64_t seed) {
    return bl_latency_create_cancellable(node_count, seed, NULL, NULL);
}

BLLatencyContext *bl_latency_create_cancellable(uint32_t node_count, uint64_t seed,
                                              BLLatencyCancellation cancelled,
                                              void *cancellation_context) {
    if (node_count < 2 || node_count > UINT32_C(1048576) ||
        bl_latency_cancelled(cancelled, cancellation_context)) return NULL;
    BLLatencyContext *context = calloc(1, sizeof(*context));
    if (!context) return NULL;
    context->count = node_count;
    const size_t bytes = (size_t)node_count * sizeof(BLLatencyNode);
    uint32_t *order = malloc((size_t)node_count * sizeof(*order));
    if (!order || posix_memalign((void **)&context->nodes, 64, bytes) != 0) {
        free(order); bl_latency_destroy(context); return NULL;
    }
    /* First touch is preparation, never part of the timed chase. */
    memset(context->nodes, 0, bytes);
    for (uint32_t i = 0; i < node_count; ++i) {
        if ((i & 4095U) == 0 && bl_latency_cancelled(cancelled, cancellation_context))
            goto cancelled_creation;
        order[i] = i;
    }
    for (uint32_t i = node_count - 1; i > 0; --i) {
        if ((i & 4095U) == 0 && bl_latency_cancelled(cancelled, cancellation_context))
            goto cancelled_creation;
        const uint32_t j = bl_latency_random_bounded(&seed, i + 1);
        const uint32_t temporary = order[i]; order[i] = order[j]; order[j] = temporary;
    }
    for (uint32_t i = 0; i < node_count; ++i) {
        if ((i & 4095U) == 0 && bl_latency_cancelled(cancelled, cancellation_context))
            goto cancelled_creation;
        context->nodes[order[i]].next = order[i + 1 < node_count ? i + 1 : 0];
    }
    free(order);
    return context;

cancelled_creation:
    free(order);
    bl_latency_destroy(context);
    return NULL;
}

void bl_latency_destroy(BLLatencyContext *context) {
    if (!context) return;
    free(context->nodes);
    free(context);
}

uint32_t bl_latency_node_count(const BLLatencyContext *context) {
    return context ? context->count : 0;
}

uint64_t bl_latency_working_set_bytes(const BLLatencyContext *context) {
    return context ? (uint64_t)context->count * sizeof(BLLatencyNode) : 0;
}

uint32_t bl_latency_next(const BLLatencyContext *context, uint32_t index) {
    return context && index < context->count ? context->nodes[index].next : UINT32_MAX;
}

uint64_t bl_latency_fingerprint(const BLLatencyContext *context) {
    if (!context) return 0;
    uint64_t hash = UINT64_C(14695981039346656037);
    /* Define byte order explicitly so the same seed has the same fingerprint
     * on little- and big-endian architectures. This is not a security hash. */
    for (uint32_t i = 0; i < context->count; ++i) {
        uint32_t successor = context->nodes[i].next;
        for (unsigned byte = 0; byte < 4; ++byte) {
            hash ^= (successor >> (byte * 8)) & UINT32_C(255);
            hash *= UINT64_C(1099511628211);
        }
    }
    return hash;
}

int bl_latency_validate(const BLLatencyContext *context) {
    return bl_latency_validate_cancellable(context, NULL, NULL);
}

int bl_latency_validate_cancellable(const BLLatencyContext *context,
                                   BLLatencyCancellation cancelled,
                                   void *cancellation_context) {
    if (!context || context->count < 2 || !context->nodes) return 0;
    unsigned char *visited = calloc(((size_t)context->count + 7) / 8, 1);
    if (!visited) return 0;
    uint32_t index = 0;
    for (uint32_t i = 0; i < context->count; ++i) {
        if (((i & 4095U) == 0 && bl_latency_cancelled(cancelled, cancellation_context)) ||
            index >= context->count || (visited[index >> 3] & (1U << (index & 7)))) {
            free(visited); return 0;
        }
        visited[index >> 3] |= (unsigned char)(1U << (index & 7));
        index = context->nodes[index].next;
    }
    free(visited);
    return index == 0;
}

uint32_t bl_latency_expected_index(const BLLatencyContext *context,
                                   uint32_t start_index, uint64_t loads) {
    if (!context || start_index >= context->count) return UINT32_MAX;
    /* Validated topology is a single cycle; the scalar reference only needs
     * the remainder. This bounds post-measurement validation to one sweep. */
    uint32_t index = start_index;
    for (uint64_t i = 0, remainder = loads % context->count; i < remainder; ++i)
        index = context->nodes[index].next;
    return index;
}

#if defined(__GNUC__)
__attribute__((noinline))
#endif
BLLatencyResult bl_latency_chase(const BLLatencyContext *context,
                                uint32_t start_index, uint64_t loads) {
    if (!context || start_index >= context->count)
        return (BLLatencyResult){0, UINT32_MAX, 0};
    const BLLatencyNode *nodes = context->nodes;
    uint32_t index = start_index;
    uint64_t remaining = loads;
    /* Explicit unrolling lowers loop-control overhead while keeping every
     * address dependent on the immediately preceding load. The final index
     * escapes through the result; all preceding loads therefore remain live. */
    while (remaining >= 8) {
        index = nodes[index].next;
        index = nodes[index].next;
        index = nodes[index].next;
        index = nodes[index].next;
        index = nodes[index].next;
        index = nodes[index].next;
        index = nodes[index].next;
        index = nodes[index].next;
        remaining -= 8;
    }
    while (remaining > 0) { index = nodes[index].next; --remaining; }
    return (BLLatencyResult){loads, index, index < context->count};
}
