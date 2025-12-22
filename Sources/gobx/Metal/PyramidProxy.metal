#include <metal_stdlib>
using namespace metal;

constant uint kThreads = 256;
constant uint kMaxBlocks = 4096; // 64x64
constant uint kMaxLevels = 7;

struct ProxyParams {
    uint count;
    uint levelCount;
    uint weightCount;
    uint includeNeighborCorr;
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
    uint tid [[thread_index_in_threadgroup]]
) {
    if (tgId >= params.count) { return; }

    threadgroup half bufA[kMaxBlocks];
    threadgroup half bufB[kMaxBlocks];
    threadgroup float sumShared[kThreads];
    threadgroup float sum2Shared[kThreads];
    threadgroup float maxShared[kThreads];
    threadgroup float sumAxShared[kThreads];
    threadgroup float sumBxShared[kThreads];
    threadgroup float sumAx2Shared[kThreads];
    threadgroup float sumBx2Shared[kThreads];
    threadgroup float sumABxShared[kThreads];
    threadgroup float sumAyShared[kThreads];
    threadgroup float sumByShared[kThreads];
    threadgroup float sumAy2Shared[kThreads];
    threadgroup float sumBy2Shared[kThreads];
    threadgroup float sumAByShared[kThreads];
    threadgroup float energies[kMaxLevels];
    threadgroup float maxes[kMaxLevels];
    threadgroup float e2s[kMaxLevels];
    threadgroup float neighborCorrValue;

    const uint levelCount = params.levelCount;
    if (levelCount == 0 || levelCount > kMaxLevels) {
        if (tid == 0) { scores[tgId] = params.bias; }
        return;
    }

    uint shapeCount = 0;
    uint shapeA = 0;
    uint shapeB = 0;
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

    bool includeNeighbor = params.includeNeighborCorr != 0u;
    uint expectedWeights = levelCount + (levelCount > 0 ? (levelCount - 1u) : 0u) + (shapeCount * 2u) + (includeNeighbor ? 1u : 0u);
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

    uint currentDim = 128;
    uint nextDim = 64;
    bool srcIsA = false;

    for (uint level = 0; level < levelCount; ++level) {
        uint blocks = nextDim * nextDim;
        float sumVar = 0.0f;
        float sumVar2 = 0.0f;
        float maxVar = 0.0f;
        bool trackShape = (level == shapeA) || (shapeCount == 2u && level == shapeB);

        for (uint i = tid; i < blocks; i += kThreads) {
            uint y = i / nextDim;
            uint x = i - (y * nextDim);
            uint baseRow = y * 2u;
            uint baseCol = x * 2u;

            float v00, v01, v10, v11;
            if (level == 0) {
                uint idx0 = baseRow * currentDim + baseCol;
                uint idx1 = idx0 + 1u;
                uint idx2 = idx0 + currentDim;
                uint idx3 = idx2 + 1u;
                v00 = samplePixel(seedLo, hiMix, idx0);
                v01 = samplePixel(seedLo, hiMix, idx1);
                v10 = samplePixel(seedLo, hiMix, idx2);
                v11 = samplePixel(seedLo, hiMix, idx3);
            } else {
                threadgroup half *src = srcIsA ? bufA : bufB;
                uint idx0 = baseRow * currentDim + baseCol;
                uint idx1 = idx0 + 1u;
                uint idx2 = idx0 + currentDim;
                uint idx3 = idx2 + 1u;
                v00 = float(src[idx0]);
                v01 = float(src[idx1]);
                v10 = float(src[idx2]);
                v11 = float(src[idx3]);
            }

            float m = 0.25f * (v00 + v01 + v10 + v11);
            float m2 = 0.25f * (v00 * v00 + v01 * v01 + v10 * v10 + v11 * v11);
            float varVal = m2 - m * m;
            if (varVal < 0.0f) { varVal = 0.0f; }

            sumVar += varVal;
            if (trackShape) {
                sumVar2 += varVal * varVal;
                if (varVal > maxVar) { maxVar = varVal; }
            }

            threadgroup half *dst = srcIsA ? bufB : bufA;
            dst[i] = half(m);
        }

        sumShared[tid] = sumVar;
        sum2Shared[tid] = sumVar2;
        maxShared[tid] = maxVar;
        threadgroup_barrier(mem_flags::mem_threadgroup);

        for (uint stride = kThreads / 2u; stride > 0; stride >>= 1u) {
            if (tid < stride) {
                sumShared[tid] += sumShared[tid + stride];
                sum2Shared[tid] += sum2Shared[tid + stride];
                maxShared[tid] = max(maxShared[tid], maxShared[tid + stride]);
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);
        }

        if (tid == 0) {
            float count = (float)blocks;
            energies[level] = sumShared[0] / count;
            if (trackShape) {
                maxes[level] = maxShared[0];
                e2s[level] = sum2Shared[0] / count;
            }
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);

        if (includeNeighbor && level == 0u) {
            threadgroup half *dst = srcIsA ? bufB : bufA;
            uint nX = nextDim * (nextDim - 1u);
            float sumAx = 0.0f;
            float sumBx = 0.0f;
            float sumAx2 = 0.0f;
            float sumBx2 = 0.0f;
            float sumABx = 0.0f;
            for (uint idx = tid; idx < nX; idx += kThreads) {
                uint y = idx / (nextDim - 1u);
                uint x = idx - y * (nextDim - 1u);
                uint base = y * nextDim + x;
                float a = float(dst[base]);
                float b = float(dst[base + 1u]);
                sumAx += a;
                sumBx += b;
                sumAx2 += a * a;
                sumBx2 += b * b;
                sumABx += a * b;
            }
            sumAxShared[tid] = sumAx;
            sumBxShared[tid] = sumBx;
            sumAx2Shared[tid] = sumAx2;
            sumBx2Shared[tid] = sumBx2;
            sumABxShared[tid] = sumABx;
            threadgroup_barrier(mem_flags::mem_threadgroup);

            for (uint stride = kThreads / 2u; stride > 0; stride >>= 1u) {
                if (tid < stride) {
                    sumAxShared[tid] += sumAxShared[tid + stride];
                    sumBxShared[tid] += sumBxShared[tid + stride];
                    sumAx2Shared[tid] += sumAx2Shared[tid + stride];
                    sumBx2Shared[tid] += sumBx2Shared[tid + stride];
                    sumABxShared[tid] += sumABxShared[tid + stride];
                }
                threadgroup_barrier(mem_flags::mem_threadgroup);
            }

            uint nY = (nextDim - 1u) * nextDim;
            float sumAy = 0.0f;
            float sumBy = 0.0f;
            float sumAy2 = 0.0f;
            float sumBy2 = 0.0f;
            float sumABy = 0.0f;
            for (uint idx = tid; idx < nY; idx += kThreads) {
                uint y = idx / nextDim;
                uint x = idx - y * nextDim;
                uint base = y * nextDim + x;
                float a = float(dst[base]);
                float b = float(dst[base + nextDim]);
                sumAy += a;
                sumBy += b;
                sumAy2 += a * a;
                sumBy2 += b * b;
                sumABy += a * b;
            }
            sumAyShared[tid] = sumAy;
            sumByShared[tid] = sumBy;
            sumAy2Shared[tid] = sumAy2;
            sumBy2Shared[tid] = sumBy2;
            sumAByShared[tid] = sumABy;
            threadgroup_barrier(mem_flags::mem_threadgroup);

            for (uint stride = kThreads / 2u; stride > 0; stride >>= 1u) {
                if (tid < stride) {
                    sumAyShared[tid] += sumAyShared[tid + stride];
                    sumByShared[tid] += sumByShared[tid + stride];
                    sumAy2Shared[tid] += sumAy2Shared[tid + stride];
                    sumBy2Shared[tid] += sumBy2Shared[tid + stride];
                    sumAByShared[tid] += sumAByShared[tid + stride];
                }
                threadgroup_barrier(mem_flags::mem_threadgroup);
            }

            if (tid == 0) {
                float corrX = corr(sumAxShared[0], sumBxShared[0], sumAx2Shared[0], sumBx2Shared[0], sumABxShared[0], nX, params.eps);
                float corrY = corr(sumAyShared[0], sumByShared[0], sumAy2Shared[0], sumBy2Shared[0], sumAByShared[0], nY, params.eps);
                neighborCorrValue = 0.5f * (corrX + corrY);
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);
        }

        srcIsA = !srcIsA;
        currentDim = nextDim;
        nextDim >>= 1u;
        if (nextDim == 0) { break; }
    }

    if (tid == 0) {
        float score = params.bias;
        float eps = params.eps;
        uint w = 0;
        for (uint i = 0; i < levelCount; ++i) {
            score += weights[w++] * energies[i];
        }
        if (levelCount > 1) {
            for (uint i = 0; i < levelCount - 1u; ++i) {
                float denom = energies[i + 1u] + eps;
                score += weights[w++] * (energies[i] / denom);
            }
        }
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
        if (includeNeighbor) {
            score += weights[w++] * neighborCorrValue;
        }
        scores[tgId] = score;
    }
}
