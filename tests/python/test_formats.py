"""Unit tests for worker/formats.py -- yt-dlp format selector builder.

Locks the contract that disk.py (size probe) and tools_run.py (real
download) share so they can never drift.
"""
from __future__ import annotations

from formats import build_format_selector


class TestUncapped:
    def test_none_is_uncapped_best(self):
        assert build_format_selector(None) == "bv*+ba/b/bv+ba/b"

    def test_zero_is_uncapped(self):
        assert build_format_selector(0) == "bv*+ba/b/bv+ba/b"

    def test_empty_string_is_uncapped(self):
        assert build_format_selector("") == "bv*+ba/b/bv+ba/b"

    def test_nonnumeric_is_uncapped(self):
        assert build_format_selector("best") == "bv*+ba/b/bv+ba/b"


class TestCapped:
    def test_1080_caps_height(self):
        sel = build_format_selector(1080)
        assert sel == "bv*[height<=1080]+ba/b[height<=1080]/bv*+ba/b"

    def test_string_int_caps(self):
        # env vars arrive as strings
        assert build_format_selector("720") == (
            "bv*[height<=720]+ba/b[height<=720]/bv*+ba/b"
        )

    def test_negative_treated_as_uncapped(self):
        assert build_format_selector(-1) == "bv*+ba/b/bv+ba/b"

    def test_cap_has_uncapped_fallback(self):
        # A capped selector must still fall back to *some* format if no
        # rendition satisfies the cap, so we never hard-fail a download.
        assert build_format_selector(1080).endswith("/bv*+ba/b")
