#include <metal_stdlib>
using namespace metal;

constant uint kThreads [[function_constant(0)]];
constant uint kSimdWidth = 32;
constant uint kMaxSimdGroups = 8;
constant uint kMaxBlocks = 4096; // 64x64
constant uint kMaxLevels = 7;

struct ProxyParams {
    uint count;
    uint levelCount;
    uint weightCount;
    uint includeNeighborCorr;
    uint includeAlphaFeature;
    uint includeLogEnergyFeatures;
    uint includeEnergies;
    uint includeShapeFeatures;
    uint ratioCount;
    float bias;
    float eps;
};

inline float corr(float sumA, float sumB, float sumA2, float sumB2, float sumAB, uint n, float eps) {
    if (n <= 1u) { return 0.0f; }
    float invN = 1.0f / float(n);
    float meanA = sumA * invN;
    float meanB = sumB * invN;
    float cov = (sumAB * invN) - (meanA * meanB);
    float varA = (sumA2 * invN) - (meanA * meanA);
    float varB = (sumB2 * invN) - (meanB * meanB);
    if (varA <= 1e-18f || varB <= 1e-18f) { return 0.0f; }
    return cov / (sqrt(varA * varB) + eps);
}

inline uint mulberry(uint state, uint hiMix) {
    uint t = state ^ hiMix;
    t = (t ^ (t >> 15)) * (t | 1u);
    t ^= t + ((t ^ (t >> 7)) * (t | 61u));
    return t ^ (t >> 14);
}

inline float samplePixel(uint seedLo, uint hiMix, uint index) {
    uint offset = (index + 1u) * 0x6D2B79F5u;
    uint state = seedLo + offset;
    uint out = mulberry(state, hiMix);
    return (float(out) * (1.0f / 4294967296.0f)) - 0.5f;
}

kernel void pyramid_proxy(
    device const ulong *seeds [[buffer(0)]],
    device const float *weights [[buffer(1)]],
    constant ProxyParams &params [[buffer(2)]],
    device float *scores [[buffer(3)]],
    uint tgId [[threadgroup_position_in_grid]],
    uint tid [[thread_index_in_threadgroup]],
    uint simdId [[simdgroup_index_in_threadgroup]],
    uint simdTid [[thread_index_in_simdgroup]]
) {
    if (tgId >= params.count) { return; }

    threadgroup half bufA[kMaxBlocks];
    threadgroup half bufB[kMaxBlocks];
    threadgroup float sumShared[kMaxSimdGroups];
    threadgroup float sum2Shared[kMaxSimdGroups];
    threadgroup float maxShared[kMaxSimdGroups];
    threadgroup float sumAxShared[kMaxSimdGroups];
    threadgroup float sumBxShared[kMaxSimdGroups];
    threadgroup float sumAx2Shared[kMaxSimdGroups];
    threadgroup float sumBx2Shared[kMaxSimdGroups];
    threadgroup float sumABxShared[kMaxSimdGroups];
    threadgroup float sumAyShared[kMaxSimdGroups];
    threadgroup float sumByShared[kMaxSimdGroups];
    threadgroup float sumAy2Shared[kMaxSimdGroups];
    threadgroup float sumBy2Shared[kMaxSimdGroups];
    threadgroup float sumAByShared[kMaxSimdGroups];
    threadgroup float energies[kMaxLevels];
    threadgroup float maxes[kMaxLevels];
    threadgroup float e2s[kMaxLevels];
    threadgroup float neighborCorrValue;

    const uint levelCount = params.levelCount;
    const uint simdGroups = kThreads / kSimdWidth;
    if (levelCount == 0 || levelCount > kMaxLevels) {
        if (tid == 0) { scores[tgId] = params.bias; }
        return;
    }

    bool includeNeighbor = params.includeNeighborCorr != 0u;
    bool includeAlpha = params.includeAlphaFeature != 0u;
    bool includeLogEnergies = params.includeLogEnergyFeatures != 0u;
    bool includeEnergies = params.includeEnergies != 0u;
    bool includeShape = params.includeShapeFeatures != 0u;
    uint ratioCount = min(params.ratioCount, (levelCount > 0u ? (levelCount - 1u) : 0u));
    uint shapeCount = 0;
    uint shapeA = 0;
    uint shapeB = 0;
    if (includeShape) {
        if (levelCount <= 2) {
            shapeCount = levelCount;
            shapeA = 0;
            shapeB = 1;
        } else {
            uint mid = (levelCount - 1u) / 2u;
            uint first = (mid > 0) ? (mid - 1u) : 0u;
            uint second = min(levelCount - 1u, mid);
            if (first == second) {
                shapeCount = 1;
                shapeA = first;
            } else {
                shapeCount = 2;
                shapeA = first;
                shapeB = second;
            }
        }
    }
    uint expectedWeights = (includeEnergies ? levelCount : 0u)
        + ratioCount
        + (includeLogEnergies ? levelCount : 0u)
        + (shapeCount * 2u)
        + (includeAlpha ? 1u : 0u)
        + (includeNeighbor ? 1u : 0u);
    if (params.weightCount < expectedWeights) {
        if (tid == 0) { scores[tgId] = params.bias; }
        return;
    }

    if (tid == 0) {
        neighborCorrValue = 0.0f;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    ulong seed = seeds[tgId];
    uint seedLo = (uint)seed;
    uint seedHi = (uint)(seed >> 32);
    uint hiMix = seedHi * 0x9E3779B9u;

    uint nextDim = 64;
    bool srcIsA = false;

    for (uint level = 0; level < levelCount; ++level) {
        uint shift = 6u - level;
        uint currentDim = nextDim << 1u;
        uint blocks = nextDim << shift;
        uint mask = nextDim - 1u;
        float sumVar = 0.0f;
        float sumVar2 = 0.0f;
        float maxVar = 0.0f;
        bool trackShape = includeShape && ((level == shapeA) || (shapeCount == 2u && level == shapeB));

        threadgroup half *dst = srcIsA ? bufB : bufA;
        if (level == 0) {
            for (uint i = tid; i < blocks; i += kThreads) {
                uint y = i >> shift;
                uint x = i & mask;
                uint rowBase = y << (shift + 2u);
                uint idx0 = rowBase + (x << 1u);
                uint idx1 = idx0 + 1u;
                uint idx2 = idx0 + currentDim;
                uint idx3 = idx2 + 1u;
                float v00 = samplePixel(seedLo, hiMix, idx0);
                float v01 = samplePixel(seedLo, hiMix, idx1);
                float v10 = samplePixel(seedLo, hiMix, idx2);
                float v11 = samplePixel(seedLo, hiMix, idx3);

                float m = 0.25f * (v00 + v01 + v10 + v11);
                float m2 = 0.25f * (v00 * v00 + v01 * v01 + v10 * v10 + v11 * v11);
                float varVal = m2 - m * m;
                if (varVal < 0.0f) { varVal = 0.0f; }

                sumVar += varVal;
                if (trackShape) {
                    sumVar2 += varVal * varVal;
                    if (varVal > maxVar) { maxVar = varVal; }
                }

                dst[i] = half(m);
            }
        } else {
            threadgroup half *src = srcIsA ? bufA : bufB;
            for (uint i = tid; i < blocks; i += kThreads) {
                uint y = i >> shift;
                uint x = i & mask;
                uint rowBase = y << (shift + 2u);
                uint idx0 = rowBase + (x << 1u);
                uint idx1 = idx0 + 1u;
                uint idx2 = idx0 + currentDim;
                uint idx3 = idx2 + 1u;
                float v00 = float(src[idx0]);
                float v01 = float(src[idx1]);
                float v10 = float(src[idx2]);
                float v11 = float(src[idx3]);

                float m = 0.25f * (v00 + v01 + v10 + v11);
                float m2 = 0.25f * (v00 * v00 + v01 * v01 + v10 * v10 + v11 * v11);
                float varVal = m2 - m * m;
                if (varVal < 0.0f) { varVal = 0.0f; }

                sumVar += varVal;
                if (trackShape) {
                    sumVar2 += varVal * varVal;
                    if (varVal > maxVar) { maxVar = varVal; }
                }

                dst[i] = half(m);
            }
        }

        float sumVarSimd = simd_sum(sumVar);
        float sumVar2Simd = simd_sum(sumVar2);
        float maxVarSimd = simd_max(maxVar);
        if (simdTid == 0u) {
            sumShared[simdId] = sumVarSimd;
            sum2Shared[simdId] = sumVar2Simd;
            maxShared[simdId] = maxVarSimd;
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);

        if (simdId == 0u) {
            float sumTotal = simd_sum(simdTid < simdGroups ? sumShared[simdTid] : 0.0f);
            float sum2Total = simd_sum(simdTid < simdGroups ? sum2Shared[simdTid] : 0.0f);
            float maxTotal = simd_max(simdTid < simdGroups ? maxShared[simdTid] : 0.0f);
            if (simdTid == 0u) {
                float count = (float)blocks;
                energies[level] = sumTotal / count;
                if (trackShape) {
                    maxes[level] = maxTotal;
                    e2s[level] = sum2Total / count;
                }
            }
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);

        if (includeNeighbor && level == 0u) {
            threadgroup half *dst = srcIsA ? bufB : bufA;
            uint rowStride = nextDim - 1u;
            uint nX = nextDim * rowStride;
            float sumAx = 0.0f;
            float sumBx = 0.0f;
            float sumAx2 = 0.0f;
            float sumBx2 = 0.0f;
            float sumABx = 0.0f;
            uint idx = tid;
            uint y = (rowStride > 0u) ? (idx / rowStride) : 0u;
            uint x = (rowStride > 0u) ? (idx - y * rowStride) : 0u;
            while (idx < nX) {
                uint base = y * nextDim + x;
                float a = float(dst[base]);
                float b = float(dst[base + 1u]);
                sumAx += a;
                sumBx += b;
                sumAx2 += a * a;
                sumBx2 += b * b;
                sumABx += a * b;

                idx += kThreads;
                x += kThreads;
                while (x >= rowStride && rowStride > 0u) {
                    x -= rowStride;
                    y += 1u;
                }
            }
            float sumAxSimd = simd_sum(sumAx);
            float sumBxSimd = simd_sum(sumBx);
            float sumAx2Simd = simd_sum(sumAx2);
            float sumBx2Simd = simd_sum(sumBx2);
            float sumABxSimd = simd_sum(sumABx);
            if (simdTid == 0u) {
                sumAxShared[simdId] = sumAxSimd;
                sumBxShared[simdId] = sumBxSimd;
                sumAx2Shared[simdId] = sumAx2Simd;
                sumBx2Shared[simdId] = sumBx2Simd;
                sumABxShared[simdId] = sumABxSimd;
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);

            uint nY = rowStride * nextDim;
            float sumAy = 0.0f;
            float sumBy = 0.0f;
            float sumAy2 = 0.0f;
            float sumBy2 = 0.0f;
            float sumABy = 0.0f;
            for (uint idx = tid; idx < nY; idx += kThreads) {
                uint y = idx >> shift;
                uint x = idx & mask;
                uint base = (y << shift) + x;
                float a = float(dst[base]);
                float b = float(dst[base + nextDim]);
                sumAy += a;
                sumBy += b;
                sumAy2 += a * a;
                sumBy2 += b * b;
                sumABy += a * b;
            }
            float sumAySimd = simd_sum(sumAy);
            float sumBySimd = simd_sum(sumBy);
            float sumAy2Simd = simd_sum(sumAy2);
            float sumBy2Simd = simd_sum(sumBy2);
            float sumABySimd = simd_sum(sumABy);
            if (simdTid == 0u) {
                sumAyShared[simdId] = sumAySimd;
                sumByShared[simdId] = sumBySimd;
                sumAy2Shared[simdId] = sumAy2Simd;
                sumBy2Shared[simdId] = sumBy2Simd;
                sumAByShared[simdId] = sumABySimd;
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);

            if (simdId == 0u) {
                float sumAxTotal = simd_sum(simdTid < simdGroups ? sumAxShared[simdTid] : 0.0f);
                float sumBxTotal = simd_sum(simdTid < simdGroups ? sumBxShared[simdTid] : 0.0f);
                float sumAx2Total = simd_sum(simdTid < simdGroups ? sumAx2Shared[simdTid] : 0.0f);
                float sumBx2Total = simd_sum(simdTid < simdGroups ? sumBx2Shared[simdTid] : 0.0f);
                float sumABxTotal = simd_sum(simdTid < simdGroups ? sumABxShared[simdTid] : 0.0f);
                float sumAyTotal = simd_sum(simdTid < simdGroups ? sumAyShared[simdTid] : 0.0f);
                float sumByTotal = simd_sum(simdTid < simdGroups ? sumByShared[simdTid] : 0.0f);
                float sumAy2Total = simd_sum(simdTid < simdGroups ? sumAy2Shared[simdTid] : 0.0f);
                float sumBy2Total = simd_sum(simdTid < simdGroups ? sumBy2Shared[simdTid] : 0.0f);
                float sumAByTotal = simd_sum(simdTid < simdGroups ? sumAByShared[simdTid] : 0.0f);
                if (simdTid == 0u) {
                    float corrX = corr(sumAxTotal, sumBxTotal, sumAx2Total, sumBx2Total, sumABxTotal, nX, params.eps);
                    float corrY = corr(sumAyTotal, sumByTotal, sumAy2Total, sumBy2Total, sumAByTotal, nY, params.eps);
                    neighborCorrValue = 0.5f * (corrX + corrY);
                }
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);
        }

        srcIsA = !srcIsA;
        nextDim >>= 1u;
        if (nextDim == 0) { break; }
    }

    if (tid == 0) {
        float score = params.bias;
        float eps = params.eps;
        uint w = 0;
        if (includeEnergies) {
            for (uint i = 0; i < levelCount; ++i) {
                score += weights[w++] * energies[i];
            }
        }
        if (ratioCount > 0u) {
            for (uint i = 0; i < ratioCount; ++i) {
                float denom = energies[i + 1u] + eps;
                score += weights[w++] * (energies[i] / denom);
            }
        }
        if (includeLogEnergies) {
            for (uint i = 0; i < levelCount; ++i) {
                float logE = log(energies[i] + eps);
                score += weights[w++] * logE;
            }
        }
        if (includeShape) {
            if (shapeCount >= 1u) {
                score += weights[w++] * (maxes[shapeA] / (energies[shapeA] + eps));
            }
            if (shapeCount == 2u) {
                score += weights[w++] * (maxes[shapeB] / (energies[shapeB] + eps));
            }
            if (shapeCount >= 1u) {
                float denom = energies[shapeA] * energies[shapeA] + eps;
                score += weights[w++] * ((e2s[shapeA] / denom) - 1.0f);
            }
            if (shapeCount == 2u) {
                float denom = energies[shapeB] * energies[shapeB] + eps;
                score += weights[w++] * ((e2s[shapeB] / denom) - 1.0f);
            }
        }
        if (includeAlpha) {
            float sumX = 0.0f;
            float sumX2 = 0.0f;
            float sumY = 0.0f;
            float sumXY = 0.0f;
            for (uint i = 0; i < levelCount; ++i) {
                float x = float(i);
                float y = log(energies[i] + eps);
                sumX += x;
                sumX2 += x * x;
                sumY += y;
                sumXY += x * y;
            }
            float n = float(levelCount);
            float denom = n * sumX2 - sumX * sumX;
            float slope = (denom != 0.0f) ? ((n * sumXY - sumX * sumY) / denom) : 0.0f;
            float alphaProxy = -slope;
            score += weights[w++] * alphaProxy;
        }
        if (includeNeighbor) {
            score += weights[w++] * neighborCorrValue;
        }
        scores[tgId] = score;
    }
}
