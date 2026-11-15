// SPDX-License-Identifier: MIT
// FP32-FMA-v1: four independent float4 FMAs per loop iteration.
// That is 16 scalar FMAs, or exactly 32 counted FLOPs, per thread/iteration.
// Seed setup and the final reduction are deliberately excluded from the count.
#include <metal_stdlib>
using namespace metal;

kernel void fp32_fma_v1(
    device const float4 *seeds [[buffer(0)]],
    device float4 *output [[buffer(1)]],
    constant uint &iterations [[buffer(2)]],
    uint index [[thread_position_in_grid]])
{
    float4 a = seeds[index];
    float4 b = a + float4(0.25f, 0.5f, 0.75f, 1.0f);
    float4 c = a + float4(1.0f, 0.75f, 0.5f, 0.25f);
    float4 d = a + float4(0.125f, 0.375f, 0.625f, 0.875f);
    for (uint i = 0; i < iterations; ++i) {
        a = fma(a, float4(0.99991f, 0.99983f, 0.99979f, 0.99971f), float4(0.00011f, 0.00017f, 0.00023f, 0.00029f));
        b = fma(b, float4(0.99967f, 0.99961f, 0.99953f, 0.99947f), float4(0.00031f, 0.00037f, 0.00041f, 0.00043f));
        c = fma(c, float4(0.99943f, 0.99937f, 0.99929f, 0.99923f), float4(0.00047f, 0.00053f, 0.00059f, 0.00061f));
        d = fma(d, float4(0.99919f, 0.99913f, 0.99907f, 0.99901f), float4(0.00067f, 0.00071f, 0.00073f, 0.00079f));
    }
    output[index] = ((a + b) + c) + d;
}
