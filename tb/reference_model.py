#!/usr/bin/env python3
"""
reference_model.py
Bit-exact integer-based software reference model for INT8 matrix multiplication.
Applies modular two's-complement 32-bit accumulator wraparound semantics.
"""
from typing import List

def int8_clamp(val: int) -> int:
    """Clamps integer into signed 8-bit range [-128, 127]."""
    val = val & 0xFF
    return val - 256 if val >= 128 else val

def int32_clamp(val: int) -> int:
    """Clamps integer into signed 32-bit range [-2^31, 2^31 - 1] (two's complement wrap)."""
    val = val & 0xFFFFFFFF
    return val - 0x100000000 if val >= 0x80000000 else val

def matmul_int8(A: List[List[int]], B: List[List[int]]) -> List[List[int]]:
    """
    Computes C = A x B for arbitrary dimensions (default 4x4).
    A: M x K matrix of signed 8-bit integers.
    B: K x N matrix of signed 8-bit integers.
    Returns: C (M x N matrix of signed 32-bit integers).
    """
    M = len(A)
    K = len(A[0])
    N = len(B[0])
    assert len(B) == K, f"Inner dimension mismatch: A is {M}x{K}, B is {len(B)}x{N}"

    C = [[0 for _ in range(N)] for _ in range(M)]

    for i in range(M):
        for j in range(N):
            running_sum = 0
            for k in range(K):
                a_val = int8_clamp(A[i][k])
                b_val = int8_clamp(B[k][j])
                prod = a_val * b_val  # 16-bit signed
                running_sum = int32_clamp(running_sum + prod)
            C[i][j] = running_sum

    return C

if __name__ == "__main__":
    # Self-validation
    W = [
        [ 1,  2,  3,  4],
        [ 2,  1,  0, -1],
        [-1, -2,  1,  2],
        [ 0,  3, -2,  1]
    ]
    A = [
        [ 2,  1,  3,  0],
        [ 1, -2,  0,  4],
        [ 3,  0, -1,  2],
        [-1,  1,  2, -3]
    ]
    expected_C = [
        [ 1, -1,  9, 13],
        [-3, 12, -5, 10],
        [ 4, 14,  4, 12],
        [-1,-14,  5, -4]
    ]

    result = matmul_int8(A, W)
    assert result == expected_C, f"Reference model mismatch: {result} != {expected_C}"
    print("Golden Model Self-Check: 100% PASSED!")
