"""Unit tests for worker/frames.py pure logic (no ffmpeg required)."""
from __future__ import annotations

import pytest

from frames import (
    parse_time,
    format_time,
    auto_fps,
    auto_fps_focus,
    MAX_FPS,
)


class TestParseTime:
    def test_none_returns_none(self):
        assert parse_time(None) is None

    def test_empty_returns_none(self):
        assert parse_time("") is None

    def test_seconds_only(self):
        assert parse_time("45") == 45.0
        assert parse_time("12.5") == 12.5

    def test_minutes_seconds(self):
        assert parse_time("01:30") == 90.0
        assert parse_time("00:45") == 45.0

    def test_hours_minutes_seconds(self):
        assert parse_time("01:02:03") == 3723.0
        assert parse_time("00:00:00") == 0.0

    def test_malformed_raises(self):
        with pytest.raises(SystemExit):
            parse_time("not-a-number")

    def test_too_many_colons_raises(self):
        with pytest.raises(SystemExit):
            parse_time("1:2:3:4")


class TestFormatTime:
    def test_under_hour(self):
        assert format_time(75) == "01:15"
        assert format_time(0) == "00:00"

    def test_over_hour(self):
        assert format_time(3661) == "1:01:01"

    def test_rounding(self):
        # 30.7 rounds to 31s
        assert format_time(30.7) == "00:31"


class TestAutoFps:
    @pytest.mark.parametrize(
        "duration,max_frames",
        [(10, 100), (29, 100), (30, 100), (31, 100), (59, 100), (60, 100),
         (179, 100), (180, 100), (181, 100), (599, 100), (600, 100), (601, 100), (1800, 100)],
    )
    def test_never_exceeds_max_fps(self, duration, max_frames):
        fps, _ = auto_fps(duration, max_frames=max_frames)
        assert fps <= MAX_FPS

    @pytest.mark.parametrize(
        "duration,max_frames",
        [(10, 100), (30, 100), (60, 100), (180, 100), (600, 100), (1800, 100)],
    )
    def test_target_does_not_exceed_max_frames(self, duration, max_frames):
        _, target = auto_fps(duration, max_frames=max_frames)
        assert target <= max_frames

    def test_short_video_gets_dense_coverage(self):
        # <=30s should give ~30 frames (subject to max_frames cap).
        _, target = auto_fps(20, max_frames=100)
        assert 12 <= target <= 30

    def test_long_video_caps_at_max_frames(self):
        # >10 min uses full max_frames budget.
        _, target = auto_fps(1200, max_frames=100)
        assert target == 100

    def test_zero_duration(self):
        fps, target = auto_fps(0)
        assert fps > 0
        assert target == 1

    def test_max_frames_cap_respected(self):
        # If max_frames is tight, target should respect it.
        _, target = auto_fps(60, max_frames=10)
        assert target <= 10


class TestAutoFpsFocus:
    def test_short_focus_denser_than_full(self):
        _, full_target = auto_fps(15, max_frames=100)
        _, focus_target = auto_fps_focus(15, max_frames=100)
        # Focused mode should not undercount short ranges.
        assert focus_target >= full_target

    @pytest.mark.parametrize("duration", [5, 15, 30, 60, 180, 600])
    def test_focus_never_exceeds_caps(self, duration):
        fps, target = auto_fps_focus(duration, max_frames=100)
        assert fps <= MAX_FPS
        assert target <= 100
