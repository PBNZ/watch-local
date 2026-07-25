"""Transcription quality scoring for the benchmark harness.

Inputs (env):
    W_QUALITY_DIR    dir holding transcript-<model>.json files (required)
    W_MODELS         comma-separated model names, smallest-to-largest
    W_REFERENCE_VTT  creator captions to score against (optional)
    W_OUT_JSON       output path (default: <W_QUALITY_DIR>/quality.json)

Emits per-model word counts plus WER and word-set Jaccard against the
creator captions when they exist, and against the largest model listed
either way -- so a fixture without captions still ranks models against
each other.

Word normalization matches compare.py exactly, so the numbers here and
the ones in a /watch report describe the same tokens.

Caveat worth repeating wherever these numbers are published: creator
captions are human-EDITED text, not ground truth. WER measures agreement
with the captions, so a more literal transcriber scores worse while
being no less correct.
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

from captions import parse_vtt
from compare import _normalize_words


# Smallest to largest. Used to pick the baseline when the caller does not
# list models itself -- alphabetical order would crown "base" or "tiny"
# the largest and silently invert every cross-model comparison.
MODEL_ORDER = ["tiny", "base", "small", "medium", "large-v3"]


def order_models(names: list[str]) -> list[str]:
    """Sort discovered model names smallest-first; unknown names last."""
    return sorted(names, key=lambda n: (MODEL_ORDER.index(n) if n in MODEL_ORDER else len(MODEL_ORDER), n))


def transcript_words(path: Path) -> list[str]:
    data = json.loads(path.read_text(encoding="utf-8"))
    words: list[str] = []
    for seg in data.get("segments") or []:
        words.extend(_normalize_words(seg.get("text") or ""))
    return words


def vtt_words(path: Path) -> list[str]:
    words: list[str] = []
    for seg in parse_vtt(str(path)):
        words.extend(_normalize_words(seg.get("text") or ""))
    return words


def edit_distance(ref: list[str], hyp: list[str]) -> int:
    """Word-level Levenshtein distance.

    Plain two-row DP: O(len(ref) * len(hyp)) and a few seconds on the
    ~6k-word transcripts this harness produces -- irrelevant next to the
    transcription runs it scores, and it keeps the metric exact and
    dependency-free. Trim the shared prefix/suffix first, which is most
    of the work when two transcripts largely agree.
    """
    start = 0
    while start < len(ref) and start < len(hyp) and ref[start] == hyp[start]:
        start += 1
    ref_end, hyp_end = len(ref), len(hyp)
    while ref_end > start and hyp_end > start and ref[ref_end - 1] == hyp[hyp_end - 1]:
        ref_end -= 1
        hyp_end -= 1
    a, b = ref[start:ref_end], hyp[start:hyp_end]
    if not a:
        return len(b)
    if not b:
        return len(a)

    prev = list(range(len(b) + 1))
    for i, ref_word in enumerate(a, start=1):
        cur = [i] + [0] * len(b)
        for j, hyp_word in enumerate(b, start=1):
            cur[j] = min(
                prev[j] + 1,
                cur[j - 1] + 1,
                prev[j - 1] + (0 if ref_word == hyp_word else 1),
            )
        prev = cur
    return prev[len(b)]


def wer(ref: list[str], hyp: list[str]) -> float | None:
    """Word error rate against ref. None when there is nothing to score."""
    if not ref:
        return None
    return round(edit_distance(ref, hyp) / len(ref), 4)


def jaccard(a: list[str], b: list[str]) -> float:
    sa, sb = set(a), set(b)
    if not sa and not sb:
        return 1.0
    if not sa or not sb:
        return 0.0
    return round(len(sa & sb) / len(sa | sb), 4)


def score(
    per_model: dict[str, list[str]],
    reference: list[str] | None,
    baseline_model: str | None,
) -> dict:
    """Score every model against the captions and against the baseline."""
    out: dict = {
        "reference": "captions" if reference else None,
        "reference_words": len(reference) if reference else 0,
        "baseline_model": baseline_model,
        "models": {},
    }
    baseline = per_model.get(baseline_model or "", [])
    for model, words in per_model.items():
        entry: dict = {"words": len(words)}
        if reference:
            entry["wer_vs_captions"] = wer(reference, words)
            entry["word_jaccard_vs_captions"] = jaccard(reference, words)
        if baseline_model and model != baseline_model and baseline:
            entry[f"wer_vs_{baseline_model}"] = wer(baseline, words)
        out["models"][model] = entry
    return out


def main() -> int:
    qdir = os.environ.get("W_QUALITY_DIR") or ""
    if not qdir or not Path(qdir).is_dir():
        print(f"ERROR: W_QUALITY_DIR not a directory: {qdir!r}", file=sys.stderr)
        return 2
    root = Path(qdir)

    models = [m.strip() for m in (os.environ.get("W_MODELS") or "").split(",") if m.strip()]
    if not models:
        models = order_models([p.stem[len("transcript-"):] for p in root.glob("transcript-*.json")])

    per_model: dict[str, list[str]] = {}
    for model in models:
        path = root / f"transcript-{model}.json"
        if path.exists():
            per_model[model] = transcript_words(path)
        else:
            print(f"[quality] no transcript for {model} -- skipping", file=sys.stderr)
    if not per_model:
        print(f"ERROR: no transcript-*.json under {root}", file=sys.stderr)
        return 2

    reference: list[str] | None = None
    ref_vtt = os.environ.get("W_REFERENCE_VTT") or ""
    if ref_vtt and Path(ref_vtt).exists():
        reference = vtt_words(Path(ref_vtt)) or None
        if reference is None:
            print(f"[quality] {ref_vtt} parsed to zero words -- scoring models against each other only", file=sys.stderr)

    # Largest model present wins the tie-break for "compare everything
    # else to this", following the order the caller listed.
    baseline = next((m for m in reversed(models) if m in per_model), None)

    out = score(per_model, reference, baseline)
    out_path = Path(os.environ.get("W_OUT_JSON") or (root / "quality.json"))
    out_path.write_text(json.dumps(out, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"[quality] wrote {out_path} ({len(per_model)} models)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
