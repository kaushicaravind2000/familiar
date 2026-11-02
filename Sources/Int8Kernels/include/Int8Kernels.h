#ifndef INT8_KERNELS_H
#define INT8_KERNELS_H

#include <stddef.h>
#include <stdint.h>

/// Scores rows `first` up to `last` of an 8-bit matrix (`dimension` values per row, row after row) against an 8-bit
/// query: out[r] = (row r · query) × scales[r] × query_scale, the dot product summed exactly in 32-bit integers.
/// On Apple silicon it uses the int8 dot-product instruction (SDOT: 16 multiply-adds per instruction).
void int8_scores(const int8_t *matrix, const float *scales, size_t first, size_t last, size_t dimension,
                 const int8_t *query, float query_scale, float *out);

#endif
