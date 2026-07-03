"""Transcript comparison stage.

Inputs (env / files):
    W_CREATOR_VTT     path to creator VTT in /work (optional)
    W_WHISPER_JSON    path to whisper transcript JSON in /work (required)
    W_OUT_JSON        path to write comparison.json in /work

Reads creator VTT (if present) + whisper transcript, normalizes both into
flat text, and emits three similarity metrics:

    length_ratio    min(len_a, len_b) / max(len_a, len_b) over WORDS
    word_jaccard    |A in B| / |A or B| over WORD SETS (case-normalized)
    3gram_jaccard   |A in B| / |A or B| over WORD 3-GRAM SETS

Significance is the worst rating across the three:

    metric            match     minor       major
    length_ratio      >= 0.95   0.80-0.95   < 0.80
    word_jaccard      >= 0.85   0.70-0.85   < 0.70
    3gram_jaccard     >= 0.75   0.55-0.75   < 0.55

When the creator VTT is absent (whisper-only), comparison is skipped and
the script writes a minimal comparison.json with significance=null.
"""
from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, "/app")
from captions import parse_vtt  # noqa: E402


WORD_RE = re.compile(r"[a-z0-9']+", re.IGNORECASE)


def _normalize_words(text: str) -> list[str]:
    return [w.lower() for w in WORD_RE.findall(text or "")]


def _flatten_whisper(path: str) -> list[str]:
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    words = []
    for seg in data.get("segments") or []:
        words.extend(_normalize_words(seg.get("text") or ""))
    return words


def _flatten_vtt(path: str) -> list[str]:
    segments = parse_vtt(path)
    words = []
    for seg in segments:
        words.extend(_normalize_words(seg.get("text") or ""))
    return words


def _length_ratio(a: list[str], b: list[str]) -> float:
    if not a or not b:
        return 0.0
    lo, hi = sorted([len(a), len(b)])
    return round(lo / hi, 4)


def _jaccard(a: set, b: set) -> float:
    if not a and not b:
        return 1.0
    if not a or not b:
        return 0.0
    return round(len(a & b) / len(a | b), 4)


def _ngrams(words: list[str], n: int) -> set:
    return {tuple(words[i:i + n]) for i in range(len(words) - n + 1)} if len(words) >= n else set()


def _classify(value: float, thresholds: tuple[float, float]) -> str:
    """thresholds = (minor_floor, match_floor); higher is better."""
    minor_floor, match_floor = thresholds
    if value >= match_floor:
        return "match"
    if value >= minor_floor:
        return "minor"
    return "major"


THRESHOLDS = {
    "length_ratio":  (0.80, 0.95),
    "word_jaccard":  (0.70, 0.85),
    "trigram_jaccard": (0.55, 0.75),
}

RANK = {"match": 0, "minor": 1, "major": 2}


def main() -> int:
    creator_vtt = os.environ.get("W_CREATOR_VTT") or ""
    whisper_json = os.environ.get("W_WHISPER_JSON") or ""
    out_json = os.environ.get("W_OUT_JSON") or "/work/comparison.json"

    if not whisper_json or not Path(whisper_json).exists():
        print(f"ERROR: whisper transcript missing: {whisper_json}", file=sys.stderr)
        return 2

    whisper_words = _flatten_whisper(whisper_json)
    creator_words: list[str] = []
    have_creator = bool(creator_vtt and Path(creator_vtt).exists())
    if have_creator:
        creator_words = _flatten_vtt(creator_vtt)

    if not have_creator or not creator_words:
        out = {
            "primary_candidate": "whisper",
            "secondary_candidate": None,
            "have_creator": False,
            "have_whisper": True,
            "metrics": None,
            "significance": None,
            "whisper_word_count": len(whisper_words),
            "creator_word_count": 0,
        }
        Path(out_json).write_text(json.dumps(out, indent=2, ensure_ascii=False), encoding="utf-8")
        print(f"[compare] wrote {out_json} (whisper-only)", file=sys.stderr)
        return 0

    length_ratio = _length_ratio(creator_words, whisper_words)
    word_jaccard = _jaccard(set(creator_words), set(whisper_words))
    tri_jaccard = _jaccard(_ngrams(creator_words, 3), _ngrams(whisper_words, 3))

    ratings = {
        "length_ratio": _classify(length_ratio, THRESHOLDS["length_ratio"]),
        "word_jaccard": _classify(word_jaccard, THRESHOLDS["word_jaccard"]),
        "trigram_jaccard": _classify(tri_jaccard, THRESHOLDS["trigram_jaccard"]),
    }
    significance = max(ratings.values(), key=lambda r: RANK[r])

    out = {
        "primary_candidate": "creator",
        "secondary_candidate": "whisper",
        "have_creator": True,
        "have_whisper": True,
        "creator_word_count": len(creator_words),
        "whisper_word_count": len(whisper_words),
        "metrics": {
            "length_ratio": length_ratio,
            "word_jaccard": word_jaccard,
            "trigram_jaccard": tri_jaccard,
        },
        "ratings": ratings,
        "significance": significance,
        "thresholds": {
            "length_ratio":  {"minor_floor": THRESHOLDS["length_ratio"][0],  "match_floor": THRESHOLDS["length_ratio"][1]},
            "word_jaccard":  {"minor_floor": THRESHOLDS["word_jaccard"][0],  "match_floor": THRESHOLDS["word_jaccard"][1]},
            "trigram_jaccard": {"minor_floor": THRESHOLDS["trigram_jaccard"][0], "match_floor": THRESHOLDS["trigram_jaccard"][1]},
        },
    }
    Path(out_json).write_text(json.dumps(out, indent=2, ensure_ascii=False), encoding="utf-8")
    print(
        f"[compare] significance={significance} length_ratio={length_ratio} "
        f"word_jaccard={word_jaccard} 3gram_jaccard={tri_jaccard}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
