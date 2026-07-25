"""Unit tests for whisper_run: repetition-loop guard + cpu_threads policy."""
from __future__ import annotations

import os

import pytest

from whisper_run import collapse_repetitions, resolve_cpu_threads


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


# --- 2x degenerate loops (#35) ---------------------------------------------

# The reported case: large-v3 emitted a 15-word clause twice inside 0.2 s.
_LOOP_TEXT = (
    "cronies of the british secret service to the british secret service "
    "and so recruited informers"
)


def test_degenerate_two_run_collapsed_and_flagged():
    segs = [
        _seg(53.9, 59.2, "walsingham feared a catholic uprising"),
        _seg(59.2, 59.3, _LOOP_TEXT),
        _seg(59.3, 59.4, _LOOP_TEXT),
        _seg(59.4, 64.5, "cryptographers and seal breakers"),
    ]
    out, runs = collapse_repetitions(segs)
    assert [s["text"] for s in out] == [
        "walsingham feared a catholic uprising", _LOOP_TEXT, "cryptographers and seal breakers",
    ]
    assert out[1]["start"] == 59.2 and out[1]["end"] == 59.4
    assert len(runs) == 1
    assert runs[0]["count"] == 2
    assert runs[0]["start"] == 59.2 and runs[0]["end"] == 59.4


def test_plausible_two_run_left_alone():
    # Same text twice, but spoken at a human rate -- not a hallucination.
    segs = [_seg(0, 3, "i do not know what to do"), _seg(3, 6, "i do not know what to do")]
    out, runs = collapse_repetitions(segs)
    assert out == segs
    assert runs == []


def test_normal_segment_followed_by_instant_copy_is_caught():
    # The common faster-whisper loop shape: a properly-paced segment and
    # then a near-zero-duration copy. Averaging the pair would hide the
    # copy behind the original's duration, so the check is per segment.
    segs = [_seg(10.0, 20.0, _LOOP_TEXT), _seg(20.0, 20.1, _LOOP_TEXT)]
    out, runs = collapse_repetitions(segs)
    assert len(out) == 1
    assert out[0]["start"] == 10.0 and out[0]["end"] == 20.1
    assert len(runs) == 1 and runs[0]["count"] == 2


def test_rapped_repeat_at_human_speed_survives():
    # ~6.7 words/sec twice over: fast, but a real rate for sung or
    # chanted delivery, so it must not be called a hallucination.
    segs = [_seg(100.0, 100.9, "let us go let us go"), _seg(100.9, 101.8, "let us go let us go")]
    out, runs = collapse_repetitions(segs)
    assert out == segs
    assert runs == []


def test_short_double_never_degenerate_however_fast():
    # "no, no" in 0.1 s is a huge words/sec, but too few words to judge.
    segs = [_seg(0, 0.05, "no no"), _seg(0.05, 0.1, "no no")]
    out, runs = collapse_repetitions(segs)
    assert out == segs
    assert runs == []


def test_min_run_three_still_collapses_slow_repeats():
    # A 3x loop at a believable rate collapses on count alone, so the
    # rate rule never has to be loosened to catch the classic case.
    segs = [_seg(i * 4.0, i * 4.0 + 4.0, "and then it happened again") for i in range(3)]
    out, runs = collapse_repetitions(segs)
    assert len(out) == 1
    assert runs[0]["count"] == 3


def test_zero_length_duplicate_segments_collapsed():
    segs = [_seg(12.0, 12.0, _LOOP_TEXT), _seg(12.0, 12.0, _LOOP_TEXT)]
    out, runs = collapse_repetitions(segs)
    assert len(out) == 1
    assert runs[0]["count"] == 2


def test_min_run_three_still_governs_plausible_runs():
    # Three normal-paced repeats collapse on count alone, as before.
    segs = [_seg(i * 3, i * 3 + 3, "and then it happened") for i in range(3)]
    out, runs = collapse_repetitions(segs)
    assert len(out) == 1
    assert runs[0]["count"] == 3


# --- cpu_threads policy (#34) ----------------------------------------------


def test_unset_keeps_library_default():
    # Auto-sizing was withdrawn: unset means faster-whisper decides.
    assert resolve_cpu_threads("") == 0


def test_explicit_override_is_honoured():
    assert resolve_cpu_threads("6") == 6


def test_explicit_zero_is_the_library_default():
    assert resolve_cpu_threads("0") == 0


def test_whitespace_is_trimmed():
    assert resolve_cpu_threads("  8  ") == 8


@pytest.mark.parametrize("bad", ["-1", "many", "3.5", "8x"])
def test_invalid_values_fall_back_to_default(bad, capsys):
    assert resolve_cpu_threads(bad) == 0
    assert "W_CPU_THREADS" in capsys.readouterr().err


def test_unset_env_var_reads_as_default():
    # main() passes os.environ.get(...) through _env, i.e. "" when unset.
    assert resolve_cpu_threads(os.environ.get("W_CPU_THREADS_ABSENT", "")) == 0
