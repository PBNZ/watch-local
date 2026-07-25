"""Unit tests for worker/quality.py (benchmark WER scoring)."""
from __future__ import annotations

import json

import pytest

from quality import (
    edit_distance,
    jaccard,
    order_models,
    score,
    transcript_words,
    vtt_words,
    wer,
)


def _words(text: str) -> list[str]:
    return text.split()


# ---- edit distance --------------------------------------------------------


class TestEditDistance:
    def test_identical_is_zero(self):
        assert edit_distance(_words("a b c"), _words("a b c")) == 0

    def test_substitution(self):
        assert edit_distance(_words("a b c"), _words("a x c")) == 1

    def test_insertion(self):
        assert edit_distance(_words("a b"), _words("a b c")) == 1

    def test_deletion(self):
        assert edit_distance(_words("a b c"), _words("a c")) == 1

    def test_empty_reference_is_hypothesis_length(self):
        assert edit_distance([], _words("a b")) == 2

    def test_empty_hypothesis_is_reference_length(self):
        assert edit_distance(_words("a b c"), []) == 3

    def test_both_empty(self):
        assert edit_distance([], []) == 0

    def test_prefix_suffix_trim_does_not_change_result(self):
        # The trim fast-path must agree with the untrimmed DP.
        ref = _words("the quick brown fox jumps over the lazy dog")
        hyp = _words("the quick red fox leaps over the lazy dog")
        assert edit_distance(ref, hyp) == 2

    def test_disjoint_sequences(self):
        assert edit_distance(_words("a b c"), _words("x y z")) == 3

    def test_transposition_costs_two(self):
        # Levenshtein has no swap operation: a swap is two substitutions.
        assert edit_distance(_words("a b"), _words("b a")) == 2


# ---- rates ----------------------------------------------------------------


class TestWer:
    def test_perfect_match(self):
        assert wer(_words("a b c"), _words("a b c")) == 0.0

    def test_one_error_in_four(self):
        assert wer(_words("a b c d"), _words("a b c x")) == 0.25

    def test_empty_reference_is_none(self):
        assert wer([], _words("a")) is None

    def test_can_exceed_one(self):
        # A hallucinating model can insert more words than the reference has.
        assert wer(_words("a"), _words("x y z")) == 3.0


class TestJaccard:
    def test_identical(self):
        assert jaccard(_words("a b"), _words("b a")) == 1.0

    def test_disjoint(self):
        assert jaccard(_words("a b"), _words("c d")) == 0.0

    def test_partial(self):
        # {a,b,c} vs {b,c,d} -> 2 shared / 4 union
        assert jaccard(_words("a b c"), _words("b c d")) == 0.5

    def test_both_empty_is_one(self):
        assert jaccard([], []) == 1.0

    def test_one_empty_is_zero(self):
        assert jaccard(_words("a"), []) == 0.0


# ---- file readers ---------------------------------------------------------


def test_transcript_words_flattens_segments(tmp_path):
    p = tmp_path / "transcript-tiny.json"
    p.write_text(
        json.dumps({"segments": [{"text": "Hello, world!"}, {"text": "Second LINE"}]}),
        encoding="utf-8",
    )
    assert transcript_words(p) == ["hello", "world", "second", "line"]


def test_transcript_words_tolerates_missing_segments(tmp_path):
    p = tmp_path / "transcript-tiny.json"
    p.write_text(json.dumps({"model": "tiny"}), encoding="utf-8")
    assert transcript_words(p) == []


def test_vtt_words_reads_captions(tmp_path):
    p = tmp_path / "video.en.vtt"
    p.write_text(
        "WEBVTT\n\n00:00:00.000 --> 00:00:02.000\nHello world\n\n"
        "00:00:02.000 --> 00:00:04.000\nSecond line\n",
        encoding="utf-8",
    )
    assert vtt_words(p) == ["hello", "world", "second", "line"]


# ---- scoring --------------------------------------------------------------


class TestScore:
    def _models(self):
        return {
            "tiny": _words("the cat sat on the mat"),
            "large-v3": _words("the cat sat on a mat"),
        }

    def test_scores_against_captions_and_baseline(self):
        ref = _words("the cat sat on the mat")
        out = score(self._models(), ref, "large-v3")
        assert out["reference"] == "captions"
        assert out["reference_words"] == 6
        assert out["baseline_model"] == "large-v3"
        assert out["models"]["tiny"]["wer_vs_captions"] == 0.0
        assert out["models"]["large-v3"]["wer_vs_captions"] == pytest.approx(1 / 6, abs=1e-4)
        # the baseline is not compared against itself
        assert "wer_vs_large-v3" not in out["models"]["large-v3"]
        assert out["models"]["tiny"]["wer_vs_large-v3"] == pytest.approx(1 / 6, abs=1e-4)

    def test_without_captions_only_baseline_comparison(self):
        out = score(self._models(), None, "large-v3")
        assert out["reference"] is None
        assert out["reference_words"] == 0
        assert "wer_vs_captions" not in out["models"]["tiny"]
        assert "wer_vs_large-v3" in out["models"]["tiny"]

    def test_word_counts_always_present(self):
        out = score(self._models(), None, None)
        assert out["models"]["tiny"]["words"] == 6
        assert out["models"]["large-v3"]["words"] == 6

    def test_missing_baseline_is_tolerated(self):
        out = score(self._models(), None, "medium")
        assert all("wer_vs_medium" not in m for m in out["models"].values())


class TestOrderModels:
    def test_sorts_by_size_not_alphabetically(self):
        # Alphabetical order would make "base" or "tiny" the largest and
        # invert every cross-model comparison.
        assert order_models(["small", "tiny", "large-v3", "base", "medium"]) == [
            "tiny", "base", "small", "medium", "large-v3",
        ]

    def test_largest_present_is_last(self):
        assert order_models(["tiny", "base", "large-v3"])[-1] == "large-v3"
        assert order_models(["base", "tiny"])[-1] == "base"

    def test_unknown_names_sort_last_and_stably(self):
        out = order_models(["zeta-model", "tiny", "alpha-model"])
        assert out[0] == "tiny"
        assert out[1:] == ["alpha-model", "zeta-model"]

    def test_empty(self):
        assert order_models([]) == []
