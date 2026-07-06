"""Unit tests for whisper_run.collapse_repetitions (repetition-loop guard)."""
from __future__ import annotations

from whisper_run import collapse_repetitions


def _seg(start: float, end: float, text: str) -> dict:
    return {"start": start, "end": end, "text": text}


def test_no_repeats_passthrough():
    segs = [_seg(0, 1, "a"), _seg(1, 2, "b"), _seg(2, 3, "c")]
    out, runs = collapse_repetitions(segs)
    assert out == segs
    assert runs == []


def test_short_run_below_threshold_kept():
    # "no, no" style doubles are normal speech -- must survive.
    segs = [_seg(0, 1, "no"), _seg(1, 2, "no"), _seg(2, 3, "b")]
    out, runs = collapse_repetitions(segs)
    assert out == segs
    assert runs == []


def test_loop_collapsed_spans_full_run():
    segs = [_seg(0, 1, "intro")] + [
        _seg(1 + i, 2 + i, "You put the work in") for i in range(15)
    ] + [_seg(16, 17, "outro")]
    out, runs = collapse_repetitions(segs)
    assert [s["text"] for s in out] == ["intro", "You put the work in", "outro"]
    collapsed = out[1]
    assert collapsed["start"] == 1 and collapsed["end"] == 16
    assert len(runs) == 1
    assert runs[0]["count"] == 15
    assert runs[0]["start"] == 1 and runs[0]["end"] == 16


def test_multiple_runs_and_text_truncation():
    long_text = "x" * 200
    segs = (
        [_seg(i, i + 1, "loop A") for i in range(3)]
        + [_seg(3, 4, "mid")]
        + [_seg(4 + i, 5 + i, long_text) for i in range(4)]
    )
    out, runs = collapse_repetitions(segs)
    assert [s["text"] for s in out] == ["loop A", "mid", long_text]
    assert [r["count"] for r in runs] == [3, 4]
    # run text is truncated for the report; segment text is not
    assert runs[1]["text"] == "x" * 60


def test_empty_input():
    out, runs = collapse_repetitions([])
    assert out == [] and runs == []
