"""Frame extraction + auto-fps logic.

Ported from bradautomates/claude-video — same caps and budgets so behavior
matches the original /watch skill. Token cost is dominated by frames; auto-fps
targets a frame budget by duration, hard-capped at 2 fps and 100 frames.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path


MAX_FPS = 2.0


def hwaccel_args() -> list[str]:
    """ffmpeg input options for hardware-accelerated DECODE, from env.

    The launcher sets W_HWACCEL=cuda only when it detected a GPU with
    working NVDEC and ran this container with --gpus. Decode-only offload:
    frames come back to system memory, so the fps/scale filter chain is
    unchanged. If hwaccel init still fails at runtime (driver hiccup),
    ffmpeg logs a warning and falls back to software decode on its own --
    verified behavior, so no retry logic here.
    """
    v = os.environ.get("W_HWACCEL", "")
    return ["-hwaccel", v] if v else []


def parse_time(value):
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return float(value)
    s = str(value).strip()
    if not s:
        return None
    parts = s.split(":")
    try:
        if len(parts) == 1:
            return float(parts[0])
        if len(parts) == 2:
            return int(parts[0]) * 60 + float(parts[1])
        if len(parts) == 3:
            return int(parts[0]) * 3600 + int(parts[1]) * 60 + float(parts[2])
    except ValueError:
        pass
    raise SystemExit(f"Cannot parse time value: {value!r} (expected SS, MM:SS, or HH:MM:SS)")


def format_time(seconds: float) -> str:
    total = int(round(seconds))
    hours, rem = divmod(total, 3600)
    minutes, sec = divmod(rem, 60)
    if hours:
        return f"{hours}:{minutes:02d}:{sec:02d}"
    return f"{minutes:02d}:{sec:02d}"


def get_metadata(video_path: str) -> dict:
    if shutil.which("ffprobe") is None:
        raise SystemExit("ffprobe is not installed in this container")

    result = subprocess.run(
        [
            "ffprobe", "-v", "quiet",
            "-print_format", "json",
            "-show_format", "-show_streams",
            video_path,
        ],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        raise SystemExit(f"ffprobe failed: {result.stderr.strip()}")

    data = json.loads(result.stdout or "{}")
    streams = data.get("streams", [])
    fmt = data.get("format", {})
    video_stream = next((s for s in streams if s.get("codec_type") == "video"), {})
    audio_stream = next((s for s in streams if s.get("codec_type") == "audio"), None)

    duration = float(fmt.get("duration") or video_stream.get("duration") or 0)
    return {
        "duration_seconds": duration,
        "width": video_stream.get("width"),
        "height": video_stream.get("height"),
        "codec": video_stream.get("codec_name"),
        "size_bytes": int(fmt.get("size") or 0),
        "has_audio": audio_stream is not None,
    }


def _clamp_fps(fps: float, duration_seconds: float, max_frames: int):
    fps = min(fps, MAX_FPS)
    target = min(max_frames, max(1, int(round(fps * duration_seconds))))
    return fps, target


def auto_fps(duration_seconds: float, max_frames: int = 100):
    if duration_seconds <= 0:
        return 1.0, 1
    if duration_seconds <= 30:
        target = min(max_frames, max(12, int(round(duration_seconds))))
    elif duration_seconds <= 60:
        target = min(max_frames, 40)
    elif duration_seconds <= 180:
        target = min(max_frames, 60)
    elif duration_seconds <= 600:
        target = min(max_frames, 80)
    else:
        target = max_frames
    return _clamp_fps(target / duration_seconds, duration_seconds, max_frames)


def auto_fps_focus(duration_seconds: float, max_frames: int = 100):
    if duration_seconds <= 0:
        return min(MAX_FPS, 2.0), 2
    if duration_seconds <= 5:
        target = min(max_frames, max(10, int(round(duration_seconds * 6))))
    elif duration_seconds <= 15:
        target = min(max_frames, max(30, int(round(duration_seconds * 4))))
    elif duration_seconds <= 30:
        target = min(max_frames, 60)
    elif duration_seconds <= 60:
        target = min(max_frames, 80)
    else:
        target = max_frames
    return _clamp_fps(target / duration_seconds, duration_seconds, max_frames)


def extract(
    video_path: str,
    out_dir: Path,
    fps: float,
    resolution: int = 768,
    max_frames: int = 100,
    start_seconds=None,
    end_seconds=None,
):
    if shutil.which("ffmpeg") is None:
        raise SystemExit("ffmpeg is not installed in this container")

    out_dir.mkdir(parents=True, exist_ok=True)
    for existing in out_dir.glob("frame_*.jpg"):
        existing.unlink()

    output_pattern = str(out_dir / "frame_%04d.jpg")
    cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y"] + hwaccel_args()
    if start_seconds is not None:
        cmd += ["-ss", f"{start_seconds:.3f}"]
    if end_seconds is not None:
        cmd += ["-to", f"{end_seconds:.3f}"]
    cmd += [
        "-i", video_path,
        "-vf", f"fps={fps},scale={resolution}:-2",
        "-frames:v", str(max_frames),
        "-q:v", "4",
        output_pattern,
    ]

    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit(f"ffmpeg frame extraction failed: {result.stderr.strip()}")

    offset = start_seconds or 0.0
    frames = sorted(out_dir.glob("frame_*.jpg"))
    return [
        {
            "index": i,
            "timestamp_seconds": round(offset + (i / fps if fps > 0 else 0.0), 2),
            "path": str(p),
        }
        for i, p in enumerate(frames)
    ]


def extract_stills(video_path, out_dir, timestamps, resolution=None, prefix="shot"):
    """Extract one high-quality still per timestamp at NATIVE resolution.

    Used for on-demand screenshots / follow-up content: the survey frames
    are downscaled to -Resolution, but the full-quality source is kept on
    disk, so we can pull any exact moment at native (or a chosen) width.

    timestamps : iterable of seconds (float). Use frames.parse_time on
                 "MM:SS" strings before calling.
    resolution : target width in px, or None / 0 for native (no scaling).
    Returns a list of {"timestamp_seconds", "path"} dicts (in input order),
    skipping any timestamp ffmpeg failed to render.
    """
    if shutil.which("ffmpeg") is None:
        raise SystemExit("ffmpeg is not installed in this container")
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    results = []
    for t in timestamps:
        t = float(t)
        if t < 0:
            continue
        stamp = format_time(t).replace(":", "-")
        out_path = out_dir / f"{prefix}_{stamp}.jpg"
        # Accurate seek: input seek (-ss before -i) is fast; combined with a
        # single output frame it lands on the keyframe-nearest decoded frame,
        # which is what we want for a UI screenshot. -q:v 2 = high-quality JPEG.
        cmd = (["ffmpeg", "-hide_banner", "-loglevel", "error", "-y"]
               + hwaccel_args()
               + ["-ss", f"{t:.3f}", "-i", video_path, "-frames:v", "1"])
        if resolution:
            cmd += ["-vf", f"scale={int(resolution)}:-2"]
        cmd += ["-q:v", "2", str(out_path)]
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0 or not out_path.exists():
            print(f"[stills] WARNING: failed to render t={t:.3f}s: "
                  f"{result.stderr.strip()[:200]}", flush=True)
            continue
        results.append({"timestamp_seconds": round(t, 2), "path": str(out_path)})
    return results


def extract_audio_for_whisper(video_path: str, out_path: Path) -> Path:
    """mono 16 kHz 64 kbps mp3 — small and Whisper-friendly."""
    out_path.parent.mkdir(parents=True, exist_ok=True)
    cmd = [
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
        "-i", video_path,
        "-vn", "-acodec", "libmp3lame",
        "-ar", "16000", "-ac", "1", "-b:a", "64k",
        str(out_path),
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        raise SystemExit(f"ffmpeg audio extraction failed: {result.stderr.strip()}")
    if not out_path.exists() or out_path.stat().st_size == 0:
        raise SystemExit("ffmpeg produced no audio — video may have no audio track")
    return out_path
