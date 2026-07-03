"""Unit tests for worker/captions.py."""
from __future__ import annotations

import json
import tempfile
from pathlib import Path

import pytest

from captions import (
    parse_vtt,
    filter_range,
    format_transcript,
    classify_subtitle_source,
    _dedupe,
    _suffix_merge,
)


# ---- VTT parsing ----------------------------------------------------------

VTT_SIMPLE = """WEBVTT

00:00:00.000 --> 00:00:02.000
Hello world

00:00:02.000 --> 00:00:04.000
Second line
"""

VTT_YOUTUBE_ROLLING = """WEBVTT
Kind: captions
Language: en

00:00:00.000 --> 00:00:01.590 align:start position:0%

When<00:00:00.080><c> you</c><00:00:00.360><c> give</c><00:00:00.680><c> Claude</c>

00:00:01.590 --> 00:00:01.600 align:start position:0%
When you give Claude


00:00:01.600 --> 00:00:03.950 align:start position:0%
When you give Claude
code the ability to

00:00:03.950 --> 00:00:03.960 align:start position:0%
code the ability to

"""


def _write_tmp_vtt(content: str, bom: bool = False) -> Path:
    tmp = Path(tempfile.mkstemp(suffix=".vtt")[1])
    raw = content.encode("utf-8")
    if bom:
        raw = b"\xef\xbb\xbf" + raw
    tmp.write_bytes(raw)
    return tmp


class TestParseVTT:
    def test_simple(self):
        p = _write_tmp_vtt(VTT_SIMPLE)
        segs = parse_vtt(str(p))
        assert len(segs) == 2
        assert segs[0]["text"] == "Hello world"
        assert segs[0]["start"] == 0.0
        assert segs[1]["text"] == "Second line"

    def test_bom_safe(self):
        p = _write_tmp_vtt(VTT_SIMPLE, bom=True)
        segs = parse_vtt(str(p))
        # BOM must not leak into the first cue's text.
        assert segs[0]["text"] == "Hello world"

    def test_rolling_dedupe_collapses(self):
        p = _write_tmp_vtt(VTT_YOUTUBE_ROLLING)
        segs = parse_vtt(str(p))
        # Should NOT have 4 segments; rolling cues collapse via prefix-extend
        # or suffix-merge. Final cohesive text contains both halves.
        joined = " ".join(s["text"] for s in segs)
        assert "When you give Claude" in joined
        assert "code the ability to" in joined
        assert len(segs) <= 2


# ---- dedupe ---------------------------------------------------------------

class TestDedupe:
    def test_exact_dup_collapses(self):
        segs = [
            {"start": 0.0, "end": 1.0, "text": "foo"},
            {"start": 1.0, "end": 2.0, "text": "foo"},
        ]
        out = _dedupe(segs)
        assert len(out) == 1
        assert out[0]["end"] == 2.0

    def test_prefix_extend(self):
        segs = [
            {"start": 0.0, "end": 1.0, "text": "foo bar"},
            {"start": 1.0, "end": 2.0, "text": "foo bar baz"},
        ]
        out = _dedupe(segs)
        assert len(out) == 1
        assert out[0]["text"] == "foo bar baz"
        assert out[0]["end"] == 2.0

    def test_suffix_merge(self):
        # Last 3 words of prev == first 3 of curr -- merge.
        segs = [
            {"start": 0.0, "end": 1.0, "text": "alpha beta gamma delta epsilon"},
            {"start": 1.0, "end": 2.0, "text": "gamma delta epsilon zeta eta"},
        ]
        out = _dedupe(segs)
        assert len(out) == 1
        assert out[0]["text"] == "alpha beta gamma delta epsilon zeta eta"

    def test_distinct_cues_kept(self):
        segs = [
            {"start": 0.0, "end": 1.0, "text": "one two"},
            {"start": 1.0, "end": 2.0, "text": "three four"},
        ]
        out = _dedupe(segs)
        assert len(out) == 2

    def test_short_overlap_does_not_merge(self):
        # Only 2-word tail/head match -- below min_overlap_words=3 default.
        out = _suffix_merge("a b c d", "c d e f")
        # 2-word match -> below threshold, returns None.
        assert out is None


# ---- filter_range ---------------------------------------------------------

class TestFilterRange:
    def _segs(self):
        return [
            {"start": 0.0, "end": 5.0, "text": "early"},
            {"start": 5.0, "end": 10.0, "text": "middle"},
            {"start": 10.0, "end": 15.0, "text": "late"},
        ]

    def test_no_range_passes_through(self):
        assert filter_range(self._segs(), None, None) == self._segs()

    def test_start_only(self):
        # Inclusive overlap: 'early' ends at 5.0 which equals lo=5.0 -> kept.
        out = filter_range(self._segs(), 5.0, None)
        assert [s["text"] for s in out] == ["early", "middle", "late"]

    def test_start_only_strict_after(self):
        out = filter_range(self._segs(), 5.01, None)
        assert [s["text"] for s in out] == ["middle", "late"]

    def test_end_only(self):
        # 'late' starts at 10.0 which equals hi=5.0? No -- 10.0 > 5.0, dropped.
        out = filter_range(self._segs(), None, 5.0)
        assert [s["text"] for s in out] == ["early", "middle"]

    def test_overlap_inclusive(self):
        # A cue that overlaps the [4, 6] window should be kept.
        out = filter_range(self._segs(), 4.0, 6.0)
        labels = [s["text"] for s in out]
        assert "early" in labels and "middle" in labels


# ---- format_transcript ----------------------------------------------------

class TestFormatTranscript:
    def test_stamps_use_mm_ss(self):
        segs = [{"start": 75.0, "end": 80.0, "text": "ok"}]
        out = format_transcript(segs)
        assert out.startswith("[01:15] ")


# ---- provenance classifier -----------------------------------------------

def _write_info(tmpdir, payload):
    p = tmpdir / "info.json"
    p.write_text(json.dumps(payload), encoding="utf-8")
    return p


class TestClassify:
    def test_creator_when_manual_subs_match(self, tmp_path):
        p = _write_info(tmp_path, {"subtitles": {"en": [{"ext": "vtt"}]}, "automatic_captions": {}})
        assert classify_subtitle_source(str(p)) == "creator"

    def test_auto_when_only_auto(self, tmp_path):
        p = _write_info(tmp_path, {"subtitles": {}, "automatic_captions": {"en": [{}]}})
        assert classify_subtitle_source(str(p)) == "auto"

    def test_creator_wins_when_both_present(self, tmp_path):
        p = _write_info(tmp_path, {"subtitles": {"en": [{}]}, "automatic_captions": {"en": [{}]}})
        assert classify_subtitle_source(str(p)) == "creator"

    def test_none_when_no_match(self, tmp_path):
        p = _write_info(tmp_path, {"subtitles": {"fr": [{}]}, "automatic_captions": {"de": [{}]}})
        assert classify_subtitle_source(str(p)) is None

    def test_none_when_path_missing(self, tmp_path):
        assert classify_subtitle_source(str(tmp_path / "no.json")) is None

    def test_none_when_path_is_none(self):
        assert classify_subtitle_source(None) is None

    def test_prefix_matching(self, tmp_path):
        # "en-orig" key matches prefix "en".
        p = _write_info(tmp_path, {"subtitles": {}, "automatic_captions": {"en-orig": [{}]}})
        assert classify_subtitle_source(str(p)) == "auto"
