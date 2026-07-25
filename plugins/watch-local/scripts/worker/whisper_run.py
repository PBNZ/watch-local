"""watch-whisper entry point -- runs inside watch-local/whisper:cu128.

Reads /work/audio.mp3, runs faster-whisper on GPU, writes
/work/transcript_whisper.json with the same {start, end, text} segment
shape used by captions.parse_vtt -- so downstream report + compare code
doesn't care which source it came from.

Inputs (env):
    W_MODEL        faster-whisper model name (default: large-v3)
    W_LANGUAGE     language code or "" for auto-detect
    W_DEVICE       device (default: cuda)
    W_COMPUTE      compute type (default: float16)
    W_CPU_THREADS  CPU worker threads; "" = auto, "0" = library default

Outputs:
    /work/transcript_whisper.json
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path


# A repeated line is only a hallucination when it could not physically
# have been spoken in the time its segments claim to cover.
#
# The ceiling is deliberately far above conversational speech (2-3
# words/sec) and above rapped or chanted delivery (6-7), which watch-local
# does encounter on YouTube: the fastest documented human speech is around
# 11 words/sec, so 12 cannot be reached by a real speaker while a stuck
# decode overshoots it by an order of magnitude (observed: 150). Requiring
# a few words as well keeps genuine short doubles ("no, no" / "yeah yeah")
# out of it entirely.
MAX_PLAUSIBLE_WORDS_PER_SEC = 12.0
MIN_DEGENERATE_REPEAT_WORDS = 4


# Host job dir when run natively (W_WORK_DIR); /work inside a container.
WORK = Path(os.environ.get("W_WORK_DIR", "/work"))
AUDIO = WORK / "audio.mp3"
OUT = WORK / "transcript_whisper.json"


def _env(name: str, default: str = "") -> str:
    v = os.environ.get(name, "")
    return v if v != "" else default


def available_cpus() -> int:
    """CPUs this process may actually use (affinity / cgroup aware)."""
    get_affinity = getattr(os, "sched_getaffinity", None)
    if get_affinity is not None:
        try:
            return len(get_affinity(0))
        except OSError:
            pass
    return os.cpu_count() or 0


def resolve_cpu_threads(raw: str, device: str) -> int:
    """Pick ctranslate2's intra_threads count for this run.

    faster-whisper's cpu_threads=0 default becomes "OMP_NUM_THREADS if
    set, else 4" inside ctranslate2, so CPU transcription ran on ~4
    threads no matter how many cores the machine had (#34).

    W_CPU_THREADS decides: a positive int pins the count, 0 restores the
    library default. The launcher normally sets it to the physical core
    count, which is where CPU scaling plateaus -- see
    Get-WLPhysicalCoreCount. The auto path below is the fallback for a
    direct worker run (tests, benchmarks, a platform that would not
    report its core layout): every CPU this process may use, which beats
    a flat 4 without needing to know the machine's SMT topology. On GPU
    the value only affects feature extraction, so keep the library
    default rather than pinning host threads a CUDA run does not need.

    Garbage falls back to auto with a warning -- a transcription is too
    expensive to abort over a tuning knob.
    """
    text = (raw or "").strip()
    if text:
        try:
            n = int(text)
        except ValueError:
            n = -1
        if n >= 0:
            return n
        print(
            f"[whisper] WARNING: ignoring W_CPU_THREADS={text!r} (want a non-negative integer)",
            file=sys.stderr, flush=True,
        )
    if device.startswith("cuda"):
        return 0
    return available_cpus()


def is_degenerate_repeat(segments: list[dict], i: int, j: int) -> bool:
    """True when segments[i..j] repeat text faster than speech allows.

    Guards the 2x case that a raw count threshold cannot judge: a real
    "no, no" double and a stuck decode both have count == 2, but only
    the hallucination claims to fit many words into a fraction of a
    second (observed: a 15-word clause twice across 0.2 s, #35).

    Judged per segment, on the FASTEST occurrence -- not on the run as a
    whole. The usual faster-whisper loop is a normally-paced segment
    followed by a near-instant copy of it, and averaging the two hides
    the copy behind the original's respectable duration.
    """
    words = len((segments[i]["text"] or "").split())
    if words < MIN_DEGENERATE_REPEAT_WORDS:
        return False
    for k in range(i, j + 1):
        duration = float(segments[k]["end"]) - float(segments[k]["start"])
        if duration <= 0:
            return True
        if words / duration > MAX_PLAUSIBLE_WORDS_PER_SEC:
            return True
    return False


def collapse_repetitions(segments: list[dict], min_run: int = 3) -> tuple[list[dict], list[dict]]:
    """Collapse runs of consecutive identical segment texts.

    Whisper's classic repetition-loop hallucination emits the same line
    over and over ("You put the work in" x15). Keep one segment spanning
    the whole run and report the run so the host can flag the span as
    suspect.

    A run qualifies when it is at least min_run long, OR when it repeats
    at a physically impossible speech rate (is_degenerate_repeat) -- the
    latter catches 2x loops that min_run=3 used to pass through silently.
    Anything else is left alone: deliberate repetition ("no, no, no") is
    normal speech.
    # ponytail: exact-match only; near-duplicate loops pass through.
    # Upgrade path: condition_on_previous_text=False if loops keep landing.
    """
    out: list[dict] = []
    runs: list[dict] = []
    i = 0
    while i < len(segments):
        j = i
        while j + 1 < len(segments) and segments[j + 1]["text"] == segments[i]["text"]:
            j += 1
        count = j - i + 1
        if count >= min_run or (count > 1 and is_degenerate_repeat(segments, i, j)):
            seg = dict(segments[i])
            seg["end"] = segments[j]["end"]
            out.append(seg)
            runs.append({
                "start": segments[i]["start"],
                "end": segments[j]["end"],
                "text": segments[i]["text"][:60],
                "count": count,
            })
        else:
            out.extend(segments[i:j + 1])
        i = j + 1
    return out, runs


def main() -> int:
    if not AUDIO.exists():
        print(f"ERROR: audio not found at {AUDIO}", file=sys.stderr)
        return 2

    model_name = _env("W_MODEL", "large-v3")
    language = _env("W_LANGUAGE", "") or None
    device = _env("W_DEVICE", "cuda")
    compute_type = _env("W_COMPUTE", "float16")
    cpu_threads = resolve_cpu_threads(_env("W_CPU_THREADS"), device)

    import cuda_paths
    cuda_paths.add_cuda_dll_dirs()
    from faster_whisper import WhisperModel  # type: ignore

    threads_label = str(cpu_threads) if cpu_threads else "library default"
    print(
        f"[whisper] loading {model_name} on {device}/{compute_type} (cpu_threads: {threads_label})",
        file=sys.stderr, flush=True,
    )
    model = WhisperModel(
        model_name, device=device, compute_type=compute_type, cpu_threads=cpu_threads
    )

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

    segments_list, repetition_runs = collapse_repetitions(segments_list)
    if repetition_runs:
        for r in repetition_runs:
            print(
                f"[whisper] WARNING: repetition loop collapsed at "
                f"{r['start']:.0f}-{r['end']:.0f}s ({r['count']}x '{r['text']}')",
                file=sys.stderr, flush=True,
            )

    out = {
        "model": model_name,
        "device": device,
        "compute_type": compute_type,
        "cpu_threads": cpu_threads,
        "language": info.language,
        "language_probability": float(info.language_probability),
        "duration": float(info.duration),
        "segments": segments_list,
        "repetition_runs": repetition_runs,
    }

    OUT.write_text(json.dumps(out, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"[whisper] wrote {OUT} ({len(segments_list)} segments)", file=sys.stderr, flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
