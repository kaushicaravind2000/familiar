#include "Int8Kernels.h"

#if defined(__ARM_FEATURE_DOTPROD)
#include <arm_neon.h>

/// One row, two accumulators (so consecutive SDOTs don't wait on each other).
static inline int32_t row_dot(const int8_t *row, const int8_t *query, size_t dimension) {
    int32x4_t s0 = vdupq_n_s32(0), s1 = vdupq_n_s32(0);
    size_t k = 0;
    for (; k + 32 <= dimension; k += 32) {
        s0 = vdotq_s32(s0, vld1q_s8(row + k), vld1q_s8(query + k));
        s1 = vdotq_s32(s1, vld1q_s8(row + k + 16), vld1q_s8(query + k + 16));
    }
    if (k + 16 <= dimension) { s0 = vdotq_s32(s0, vld1q_s8(row + k), vld1q_s8(query + k)); k += 16; }
    int32_t sum = vaddvq_s32(vaddq_s32(s0, s1));
    for (; k < dimension; k++) sum += (int32_t)row[k] * (int32_t)query[k];
    return sum;
}
#endif

void int8_scores(const int8_t *matrix, const float *scales, size_t first, size_t last, size_t dimension,
                 const int8_t *query, float query_scale, float *out) {
    size_t r = first;
#if defined(__ARM_FEATURE_DOTPROD)
    // Four rows at a time, each 32 bytes of the query loaded once for all four: eight independent SDOT chains, enough
    // to keep the vector units busy, and the rows read straight through.
    if (dimension % 32 == 0) {
        for (; r + 4 <= last; r += 4) {
            const int8_t *a = matrix + r * dimension, *b = a + dimension, *c = b + dimension, *d = c + dimension;
            int32x4_t a0 = vdupq_n_s32(0), a1 = a0, b0 = a0, b1 = a0, c0 = a0, c1 = a0, d0 = a0, d1 = a0;
            for (size_t k = 0; k < dimension; k += 32) {
                int8x16_t q0 = vld1q_s8(query + k), q1 = vld1q_s8(query + k + 16);
                a0 = vdotq_s32(a0, vld1q_s8(a + k), q0); a1 = vdotq_s32(a1, vld1q_s8(a + k + 16), q1);
                b0 = vdotq_s32(b0, vld1q_s8(b + k), q0); b1 = vdotq_s32(b1, vld1q_s8(b + k + 16), q1);
                c0 = vdotq_s32(c0, vld1q_s8(c + k), q0); c1 = vdotq_s32(c1, vld1q_s8(c + k + 16), q1);
                d0 = vdotq_s32(d0, vld1q_s8(d + k), q0); d1 = vdotq_s32(d1, vld1q_s8(d + k + 16), q1);
            }
            out[r]     = (float)vaddvq_s32(vaddq_s32(a0, a1)) * scales[r]     * query_scale;
            out[r + 1] = (float)vaddvq_s32(vaddq_s32(b0, b1)) * scales[r + 1] * query_scale;
            out[r + 2] = (float)vaddvq_s32(vaddq_s32(c0, c1)) * scales[r + 2] * query_scale;
            out[r + 3] = (float)vaddvq_s32(vaddq_s32(d0, d1)) * scales[r + 3] * query_scale;
        }
    }
    for (; r < last; r++) out[r] = (float)row_dot(matrix + r * dimension, query, dimension) * scales[r] * query_scale;
#else
    for (; r < last; r++) {
        const int8_t *row = matrix + r * dimension;
        int32_t sum = 0;
        for (size_t k = 0; k < dimension; k++) sum += (int32_t)row[k] * (int32_t)query[k];
        out[r] = (float)sum * scales[r] * query_scale;
    }
#endif
}
