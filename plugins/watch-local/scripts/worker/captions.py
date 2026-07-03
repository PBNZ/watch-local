"""WebVTT parsing + provenance classification + smarter dedupe.

Handles:
- UTF-8 with or without BOM (YouTube VTTs are sometimes BOM'd).
- Trailing position/align attributes after the timestamp line.
- Inline cue timing tags like <00:00:00.080><c> word</c>.
- Rolling auto-caption duplicates that overlap by suffix, not just prefix.

Provenance is read from yt-dlp's info.json: keys `subtitles` (creator-uploaded
manual subs) vs `automatic_captions` (platform auto-generated). When the
language filter matches the manual list, source = "creator"; if only
automatic_captions has it, source = "auto". Anything else = None.
"""
from __future__ import annotations

import json
import re
from pathlib import Path


TS_RE = re.compile(
    r"(\d{2}):(\d{2}):(\d{2})[.,](\d{3})\s+-->\s+(\d{2}):(\d{2}):(\d{2})[.,](\d{3})"
)
TAG_RE = re.compile(r"<[^>]+>")


def _to_seconds(h: str, m: str, s: str, ms: str) -> float:
    return int(h) * 3600 + int(m) * 60 + int(s) + int(ms) / 1000.0


def _read_text_bom_safe(path: str) -> str:
    """Read UTF-8 with or without BOM. utf-8-sig handles both transparently."""
    raw = Path(path).read_bytes()
    return raw.decode("utf-8-sig", errors="replace")


def parse_vtt(path: str) -> list[dict]:
    text = _read_text_bom_safe(path)
    lines = text.splitlines()

    segments: list[dict] = []
    i = 0
    while i < len(lines):
        match = TS_RE.match(lines[i])
        if not match:
            i += 1
            continue
        start = _to_seconds(*match.groups()[:4])
        end = _to_seconds(*match.groups()[4:])
        # The timestamp line may have trailing position/align attributes;
        # they are not part of the cue body. Move to the next line.
        i += 1

        cue_lines: list[str] = []
        while i < len(lines) and lines[i].strip():
            cleaned = TAG_RE.sub("", lines[i]).strip()
            if cleaned:
                cue_lines.append(cleaned)
            i += 1

        cue_text = " ".join(cue_lines).strip()
        if cue_text:
            segments.append({
                "start": round(start, 2),
                "end": round(end, 2),
                "text": cue_text,
            })
        i += 1

    return _dedupe(segments)


def _dedupe(segments: list[dict]) -> list[dict]:
    """Collapse rolling / overlapping caption cues.

    Three cases caught:
    1. Exact duplicate -> extend prev's end, drop this one.
    2. New cue starts with prev's text + ' ' -> new is a strict extension,
       replace prev's text and end.
    3. Suffix overlap -- new cue's first N words equal prev's last N words.
       Merge into a single longer cue (this is the YouTube "rolling" case
       upstream's startswith-only logic misses).
    """
    out: list[dict] = []
    for seg in segments:
        if not out:
            out.append(seg)
            continue
        prev = out[-1]
        if seg["text"] == prev["text"]:
            prev["end"] = seg["end"]
            continue
        if seg["text"].startswith(prev["text"] + " "):
            prev["text"] = seg["text"]
            prev["end"] = seg["end"]
            continue
        merged = _suffix_merge(prev["text"], seg["text"])
        if merged is not None:
            prev["text"] = merged
            prev["end"] = seg["end"]
            continue
        out.append(seg)
    return out


def _suffix_merge(prev: str, curr: str, min_overlap_words: int = 3) -> str | None:
    """Return a merged string if curr's first words overlap prev's last words.

    Requires at least `min_overlap_words` matching words so we don't merge
    legitimately adjacent short cues.
    """
    p = prev.split()
    c = curr.split()
    max_overlap = min(len(p), len(c))
    for k in range(max_overlap, min_overlap_words - 1, -1):
        if p[-k:] == c[:k]:
            return " ".join(p + c[k:])
    return None


def filter_range(segments, start_seconds, end_seconds):
    if start_seconds is None and end_seconds is None:
        return segments
    lo = start_seconds if start_seconds is not None else float("-inf")
    hi = end_seconds if end_seconds is not None else float("inf")
    return [seg for seg in segments if seg["end"] >= lo and seg["start"] <= hi]


def format_transcript(segments) -> str:
    lines = []
    for seg in segments:
        start = int(seg["start"])
        stamp = f"[{start // 60:02d}:{start % 60:02d}]"
        lines.append(f"{stamp} {seg['text']}")
    return "\n".join(lines)


# --- provenance classification ----------------------------------------------

def classify_subtitle_source(info_path, lang_prefixes=("en",)) -> str | None:
    """Return 'creator' | 'auto' | None based on yt-dlp info.json.

    info.json has:
      - `subtitles`         dict of lang -> [variants]  (creator-uploaded)
      - `automatic_captions` dict of lang -> [variants] (platform auto-gen)

    A language matches if any key in the dict starts with any prefix in
    `lang_prefixes` (so 'en', 'en-US', 'en-GB', 'en-orig' all count for
    prefix 'en').
    """
    if not info_path:
        return None
    p = Path(info_path)
    if not p.exists():
        return None
    try:
        info = json.loads(p.read_text(encoding="utf-8"))
    except Exception:
        return None

    def _match(d):
        if not isinstance(d, dict):
            return False
        for k in d.keys():
            for pre in lang_prefixes:
                if k.startswith(pre):
                    return True
        return False

    has_creator = _match(info.get("subtitles") or {})
    has_auto = _match(info.get("automatic_captions") or {})

    if has_creator:
        return "creator"
    if has_auto:
        return "auto"
    return None
