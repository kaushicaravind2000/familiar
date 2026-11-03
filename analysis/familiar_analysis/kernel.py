"""The C kernel (Sources/Int8Kernels/Int8Kernels.c), compiled as a shared library and called through ctypes, so it's
tested on its own, against NumPy, without Swift in between."""

from __future__ import annotations

import ctypes
import hashlib
import platform
import subprocess
from pathlib import Path

import numpy as np

from . import REPO

SOURCE = REPO / "Sources" / "Int8Kernels" / "Int8Kernels.c"
INCLUDE = REPO / "Sources" / "Int8Kernels" / "include"
BUILD = Path(__file__).resolve().parents[1] / ".build"

#: Compiler flags for each path through the kernel: SDOT (what ships on Apple silicon) and the plain C loop.
FLAGS = {"sdot": ["-mcpu=apple-m1"], "plain": ["-march=armv8-a+nodotprod"]}


def apple_silicon() -> bool:
    return platform.system() == "Darwin" and platform.machine() == "arm64"


def defines_dotprod(flags: list[str]) -> bool:
    """Whether the compiler, with these flags, takes the kernel's `#if defined(__ARM_FEATURE_DOTPROD)` branch."""
    out = subprocess.run(["clang", *flags, "-dM", "-E", "-x", "c", "-"], input="", text=True,
                         capture_output=True, check=True).stdout
    return "__ARM_FEATURE_DOTPROD" in out


def build(path: str = "sdot") -> Path:
    """Compiles the kernel for one path (cached by source and flags) and checks the flags select that path."""
    flags = ["-O2", "-shared", "-fPIC", f"-I{INCLUDE}", *FLAGS[path]]
    if defines_dotprod(FLAGS[path]) != (path == "sdot"):
        raise RuntimeError(f"clang {' '.join(FLAGS[path])} doesn't select the {path} path")
    tag = hashlib.sha256(SOURCE.read_bytes() + " ".join(flags).encode()).hexdigest()[:12]
    BUILD.mkdir(exist_ok=True)
    lib = BUILD / f"int8kernels-{path}-{tag}.dylib"
    if not lib.exists():
        subprocess.run(["clang", *flags, "-o", str(lib), str(SOURCE)], check=True)
    return lib


class Kernel:
    """`int8_scores(matrix, scales, first, last, dimension, query, query_scale, out)` from Python."""

    def __init__(self, path: str = "sdot"):
        self.path = path
        f = ctypes.CDLL(str(build(path))).int8_scores
        f.restype = None
        f.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_size_t, ctypes.c_size_t,
                      ctypes.c_void_p, ctypes.c_float, ctypes.c_void_p]
        self._f = f

    def scores(self, matrix: np.ndarray, scales: np.ndarray, query: np.ndarray, query_scale: float,
               first: int = 0, last: int | None = None, out: np.ndarray | None = None) -> np.ndarray:
        """Fills out[first:last]; the rest of `out` is left as it was."""
        matrix = np.ascontiguousarray(matrix, dtype=np.int8)
        scales = np.ascontiguousarray(scales, dtype=np.float32)
        query = np.ascontiguousarray(query, dtype=np.int8)
        rows, dimension = matrix.shape
        last = rows if last is None else last
        if not (0 <= first <= last <= rows) or query.shape != (dimension,) or scales.shape != (rows,):
            raise ValueError("shapes or range don't fit")
        if out is None:
            out = np.zeros(rows, dtype=np.float32)
        if out.dtype != np.float32 or not out.flags.c_contiguous or out.shape != (rows,):
            raise ValueError("out must be a contiguous float32 array with one value per row")
        self._f(matrix.ctypes.data, scales.ctypes.data, first, last, dimension, query.ctypes.data,
                ctypes.c_float(query_scale), out.ctypes.data)
        return out
