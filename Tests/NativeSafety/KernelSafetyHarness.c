// SPDX-License-Identifier: MIT
#include "BenchKernels.h"
#include <assert.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>

int main(void) {
    assert(bl_cpu_validate());
    assert(isnan(bl_cpu_fp32(UINT64_MAX, 0).checksum));
    bl_memory_destroy(NULL); bl_latency_destroy(NULL);
    assert(!bl_memory_create(SIZE_MAX));
    assert(!bl_latency_create(UINT32_MAX, 0));
    for (unsigned run = 0; run < 64; ++run) {
        BLMemoryContext *m = bl_memory_create(4097 + run);
        assert(m);
        for (unsigned i = 0; i < 16; ++i) bl_memory_triad(m);
        assert(bl_memory_validate(m));
        assert(bl_memory_checksum(m) == bl_memory_expected_checksum(m));
        bl_memory_destroy(m);
        BLLatencyContext *l = bl_latency_create(1024 + run, run);
        assert(l && bl_latency_validate(l));
        BLLatencyResult r = bl_latency_chase(l, 0, 100000);
        assert(r.valid && r.loads == 100000);
        assert(r.final_index == bl_latency_expected_index(l, 0, r.loads));
        assert(!bl_latency_chase(l, UINT32_MAX, 1).valid);
        assert(!bl_latency_chase(l, 0, UINT64_MAX).valid);
        bl_latency_destroy(l);
    }
    puts("ASan/UBSan kernel lifecycle and boundary checks passed (64 cycles).");
    return 0;
}
