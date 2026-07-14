"""Make pip-installed NVIDIA DLLs loadable by ctranslate2 on Windows.

The nvidia-cublas-cu12 / nvidia-cudnn-cu12 / nvidia-cuda-nvrtc-cu12 wheels
drop their DLLs into site-packages/nvidia/<lib>/bin, which is not on the
default DLL search path. ctranslate2 loads them with LoadLibrary at
runtime, so both os.add_dll_directory() and a PATH prepend are applied
(PATH covers transitive loads). No-op on non-Windows and in containers,
where the CUDA base image already provides the libraries.

Call add_cuda_dll_dirs() BEFORE importing ctranslate2 / faster_whisper.
"""
from __future__ import annotations

import glob
import os
import sys


def add_cuda_dll_dirs() -> list[str]:
    if sys.platform != "win32":
        return []
    added: list[str] = []
    for sp in [p for p in sys.path if p.endswith("site-packages")]:
        for d in glob.glob(os.path.join(sp, "nvidia", "*", "bin")):
            os.add_dll_directory(d)
            os.environ["PATH"] = d + os.pathsep + os.environ.get("PATH", "")
            added.append(d)
    return added
