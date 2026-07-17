"""Unit tests for worker/tools_run.py pure logic (no yt-dlp/ffmpeg required).

Covers the file-pick helpers (merge-target preference, fragment
rejection, subtitle ordering) and the batch timestamp handling in
stills.py -- issues #10, #13, and the tools_run coverage gap from #24.
"""
from __future__ import annotations

from pathlib import Path

import pytest

import tools_run


def _touch(p: Path) -> Path:
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes(b"x")
    return p


class TestPickVideo:
    def test_prefers_merge_target_over_fragment(self, tmp_path):
        _touch(tmp_path / "video.f399.mp4")
        merged = _touch(tmp_path / "video.mp4")
        assert tools_run._pick_video(tmp_path) == merged

    def test_fragment_only_is_not_a_result(self, tmp_path):
        # Failed merge: video-only stream + audio-only stream, no merged
        # output. Picking the fragment silently loses the audio track and
        # gets misreported downstream as 'no audio track in source'.
        _touch(tmp_path / "video.f399.mp4")
        _touch(tmp_path / "video.f140.m4a")
        assert tools_run._pick_video(tmp_path) is None

    def test_single_format_download(self, tmp_path):
        vid = _touch(tmp_path / "video.webm")
        assert tools_run._pick_video(tmp_path) == vid

    def test_unusual_extension_fallback(self, tmp_path):
        vid = _touch(tmp_path / "video.avi")
        assert tools_run._pick_video(tmp_path) == vid

    def test_empty_dir(self, tmp_path):
        assert tools_run._pick_video(tmp_path) is None


class TestIsStreamFragment:
    def test_fragment_names(self):
        assert tools_run._is_stream_fragment(Path("video.f399.mp4"))
        assert tools_run._is_stream_fragment(Path("video.f299-drc.m4a"))

    def test_regular_names(self):
        assert not tools_run._is_stream_fragment(Path("video.mp4"))
        assert not tools_run._is_stream_fragment(Path("video.webm"))


class TestPickSubtitle:
    def test_prefers_plain_en_over_en_orig(self, tmp_path):
        _touch(tmp_path / "video.en-orig.vtt")
        plain = _touch(tmp_path / "video.en.vtt")
        assert tools_run._pick_subtitle(tmp_path) == plain

    def test_falls_back_to_first_candidate(self, tmp_path):
        auto = _touch(tmp_path / "video.en-orig.vtt")
        assert tools_run._pick_subtitle(tmp_path) == auto

    def test_none_when_no_vtt(self, tmp_path):
        assert tools_run._pick_subtitle(tmp_path) is None


class TestFpsOverride:
    """-Fps override must mirror the auto path's guards (#14)."""

    def _run_main(self, tmp_path, monkeypatch, fps, duration=600.0, max_frames=80):
        work = tmp_path / "work"
        monkeypatch.setattr(tools_run, "WORK", work)
        monkeypatch.setattr(tools_run, "FRAMES_DIR", work / "frames")
        monkeypatch.setattr(tools_run, "AUDIO_PATH", work / "audio.mp3")
        monkeypatch.setattr(tools_run, "OUT_JSON", work / "intermediate.json")
        monkeypatch.setattr(tools_run, "resolve_local", lambda p: {
            "video_path": p, "subtitle_path": None, "info_path": None,
            "subtitle_source": None, "info": {"title": "t", "url": p},
        })
        monkeypatch.setattr(tools_run, "get_metadata", lambda p: {
            "duration_seconds": duration, "width": 100, "height": 100,
            "codec": "h264", "size_bytes": 1, "has_audio": False,
        })
        extracted = {}

        def fake_extract(video, frames_dir, fps, resolution, max_frames, **kw):
            extracted["fps"] = fps
            return []

        monkeypatch.setattr(tools_run, "extract", fake_extract)
        monkeypatch.setenv("W_SOURCE", "fake.mp4")
        monkeypatch.setenv("W_IS_URL", "0")
        monkeypatch.setenv("W_MAX_FRAMES", str(max_frames))
        monkeypatch.setenv("W_FPS", str(fps))
        monkeypatch.delenv("W_START", raising=False)
        monkeypatch.delenv("W_END", raising=False)
        rc = tools_run.main()
        out = tools_run.OUT_JSON
        import json as _json
        return rc, (_json.loads(out.read_text(encoding="utf-8")) if out.exists() else None)

    def test_zero_fps_rejected_with_clear_message(self, tmp_path, monkeypatch):
        with pytest.raises(SystemExit, match="must be positive"):
            self._run_main(tmp_path, monkeypatch, fps=0)

    def test_negative_fps_rejected(self, tmp_path, monkeypatch):
        with pytest.raises(SystemExit, match="must be positive"):
            self._run_main(tmp_path, monkeypatch, fps=-1)

    def test_target_clamped_to_max_frames_with_warning(self, tmp_path, monkeypatch, capsys):
        # 2 fps x 600 s wants 1200 frames; the cap is 80 and the report
        # must say 80, not 1200.
        rc, out = self._run_main(tmp_path, monkeypatch, fps=2, duration=600.0, max_frames=80)
        assert rc == 0
        assert out["target_frames"] == 80
        assert "coverage stops" in capsys.readouterr().err

    def test_valid_override_passes_through(self, tmp_path, monkeypatch):
        rc, out = self._run_main(tmp_path, monkeypatch, fps=0.5, duration=60.0, max_frames=80)
        assert rc == 0
        assert out["fps"] == 0.5
        assert out["target_frames"] == 30


class TestStillsBatchTimestamps:
    """One malformed W_SHOTS token must not abort the whole batch (#13)."""

    def test_bad_token_skipped_valid_ones_survive(self, tmp_path, monkeypatch, capsys):
        import stills

        video = _touch(tmp_path / "video.mp4")
        captured = {}

        def fake_extract_stills(video_path, out_dir, timestamps, resolution=None, prefix="shot"):
            captured["timestamps"] = timestamps
            return [{"timestamp_seconds": t, "path": "x.jpg"} for t in timestamps]

        monkeypatch.setattr(stills, "extract_stills", fake_extract_stills)
        monkeypatch.setenv("W_VIDEO", str(video))
        monkeypatch.setenv("W_SHOTS", "10:00,intro,22:40")
        monkeypatch.setenv("W_OUT_DIR", str(tmp_path / "shots"))

        assert stills.main() == 0
        assert captured["timestamps"] == [600.0, 1360.0]
        assert "could not parse timestamp 'intro'" in capsys.readouterr().err

    def test_all_bad_tokens_error_cleanly(self, tmp_path, monkeypatch):
        import stills

        video = _touch(tmp_path / "video.mp4")
        monkeypatch.setenv("W_VIDEO", str(video))
        monkeypatch.setenv("W_SHOTS", "intro,outro")
        monkeypatch.setenv("W_OUT_DIR", str(tmp_path / "shots"))
        assert stills.main() == 2
