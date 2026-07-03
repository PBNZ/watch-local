"""watch-whisper entry point -- runs inside watch-local/whisper:cu128.

Reads /work/audio.mp3, runs faster-whisper on GPU, writes
/work/transcript_whisper.json with the same {start, end, text} segment
shape used by captions.parse_vtt -- so downstream report + compare code
doesn't care which source it came from.

Inputs (env):
    W_MODEL     faster-whisper model name (default: large-v3)
    W_LANGUAGE  language code or "" for auto-detect
    W_DEVICE    device (default: cuda)
    W_COMPUTE   compute type (default: float16)

Outputs:
    /work/transcript_whisper.json
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path


WORK = Path("/work")
AUDIO = WORK / "audio.mp3"
OUT = WORK / "transcript_whisper.json"


def _env(name: str, default: str = "") -> str:
    v = os.environ.get(name, "")
    return v if v != "" else default


def main() -> int:
    if not AUDIO.exists():
        print(f"ERROR: audio not found at {AUDIO}", file=sys.stderr)
        return 2

    model_name = _env("W_MODEL", "large-v3")
    language = _env("W_LANGUAGE", "") or None
    device = _env("W_DEVICE", "cuda")
    compute_type = _env("W_COMPUTE", "float16")

    from faster_whisper import WhisperModel  # type: ignore

    print(f"[whisper] loading {model_name} on {device}/{compute_type}", file=sys.stderr, flush=True)
    model = WhisperModel(model_name, device=device, compute_type=compute_type)

    print(f"[whisper] transcribing {AUDIO}", file=sys.stderr, flush=True)
    segments_iter, info = model.transcribe(
        str(AUDIO),
        language=language,
        word_timestamps=False,
        vad_filter=True,
    )

    segments_list = []
    for seg in segments_iter:
        text = (seg.text or "").strip()
        if not text:
            continue
        segments_list.append({
            "start": round(float(seg.start), 2),
            "end": round(float(seg.end), 2),
            "text": text,
        })
        if seg.id % 10 == 0:
            print(
                f"[whisper]   [{seg.start:7.2f}-{seg.end:7.2f}] {text[:80]}",
                file=sys.stderr, flush=True,
            )

    out = {
        "model": model_name,
        "language": info.language,
        "language_probability": float(info.language_probability),
        "duration": float(info.duration),
        "segments": segments_list,
    }

    OUT.write_text(json.dumps(out, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"[whisper] wrote {OUT} ({len(segments_list)} segments)", file=sys.stderr, flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
