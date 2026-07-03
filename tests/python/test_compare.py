"""Unit tests for worker/compare.py."""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

import pytest

from compare import (
    _length_ratio,
    _jaccard,
    _ngrams,
    _classify,
    _normalize_words,
    THRESHOLDS,
)


class TestNormalize:
    def test_lowercases(self):
        assert _normalize_words("Hello WORLD") == ["hello", "world"]

    def test_strips_punctuation(self):
        out = _normalize_words("Hello, world!")
        assert out == ["hello", "world"]

    def test_keeps_apostrophes(self):
        out = _normalize_words("don't won't")
        assert out == ["don't", "won't"]


class TestLengthRatio:
    def test_equal_lengths(self):
        assert _length_ratio(["a", "b"], ["c", "d"]) == 1.0

    def test_ratio_below_one(self):
        # 5 / 10 = 0.5
        a = ["x"] * 5
        b = ["y"] * 10
        assert _length_ratio(a, b) == 0.5

    def test_empty(self):
        assert _length_ratio([], ["x"]) == 0.0


class TestJaccard:
    def test_identical(self):
        s = {"a", "b", "c"}
        assert _jaccard(s, s) == 1.0

    def test_disjoint(self):
        assert _jaccard({"a"}, {"b"}) == 0.0

    def test_partial(self):
        # |{a}|/|{a,b,c}| = 1/3
        assert _jaccard({"a", "b"}, {"a", "c"}) == pytest.approx(1/3, abs=0.001)

    def test_both_empty(self):
        assert _jaccard(set(), set()) == 1.0


class TestNgrams:
    def test_3grams(self):
        out = _ngrams(["a", "b", "c", "d"], 3)
        assert ("a", "b", "c") in out
        assert ("b", "c", "d") in out
        assert len(out) == 2

    def test_short_input(self):
        assert _ngrams(["a", "b"], 3) == set()


class TestClassify:
    def test_match(self):
        # length_ratio thresholds = (0.80, 0.95)
        assert _classify(0.96, THRESHOLDS["length_ratio"]) == "match"

    def test_minor(self):
        assert _classify(0.85, THRESHOLDS["length_ratio"]) == "minor"

    def test_major(self):
        assert _classify(0.50, THRESHOLDS["length_ratio"]) == "major"


# ---- end-to-end main() with synthesized inputs ----------------------------

WORKER_DIR = Path(__file__).resolve().parents[2] / "plugins" / "watch-local" / "scripts" / "worker"


def _run_compare(env):
    env_full = dict(os.environ)
    env_full.update(env)
    # Force PYTHONPATH so /app-style import works outside the container.
    env_full["PYTHONPATH"] = str(WORKER_DIR)
    return subprocess.run(
        [sys.executable, str(WORKER_DIR / "compare.py")],
        env=env_full, capture_output=True, text=True,
    )


def test_whisper_only_produces_minimal_output(tmp_path):
    whisper = tmp_path / "whisper.json"
    out = tmp_path / "comparison.json"
    whisper.write_text(json.dumps({
        "segments": [{"start": 0, "end": 1, "text": "hello world"}]
    }), encoding="utf-8")
    r = _run_compare({"W_WHISPER_JSON": str(whisper), "W_OUT_JSON": str(out)})
    assert r.returncode == 0, r.stderr
    obj = json.loads(out.read_text(encoding="utf-8"))
    assert obj["have_whisper"] is True
    assert obj["have_creator"] is False
    assert obj["significance"] is None


def test_full_comparison_match(tmp_path):
    whisper = tmp_path / "whisper.json"
    creator = tmp_path / "creator.vtt"
    out = tmp_path / "comparison.json"
    text = "hello world this is a test of the watch local pipeline"
    whisper.write_text(json.dumps({
        "segments": [{"start": 0, "end": 5, "text": text}]
    }), encoding="utf-8")
    creator.write_text(f"""WEBVTT

00:00:00.000 --> 00:00:05.000
{text}
""", encoding="utf-8")
    r = _run_compare({
        "W_WHISPER_JSON": str(whisper),
        "W_CREATOR_VTT": str(creator),
        "W_OUT_JSON": str(out),
    })
    assert r.returncode == 0, r.stderr
    obj = json.loads(out.read_text(encoding="utf-8"))
    assert obj["significance"] == "match"
    assert obj["metrics"]["length_ratio"] == 1.0
    assert obj["metrics"]["word_jaccard"] == 1.0


def test_full_comparison_major_divergence(tmp_path):
    whisper = tmp_path / "whisper.json"
    creator = tmp_path / "creator.vtt"
    out = tmp_path / "comparison.json"
    whisper.write_text(json.dumps({
        "segments": [{"start": 0, "end": 5, "text": "completely unrelated content goes here"}]
    }), encoding="utf-8")
    creator.write_text("""WEBVTT

00:00:00.000 --> 00:00:05.000
something totally different in the captions stream
""", encoding="utf-8")
    r = _run_compare({
        "W_WHISPER_JSON": str(whisper),
        "W_CREATOR_VTT": str(creator),
        "W_OUT_JSON": str(out),
    })
    assert r.returncode == 0, r.stderr
    obj = json.loads(out.read_text(encoding="utf-8"))
    assert obj["significance"] == "major"
