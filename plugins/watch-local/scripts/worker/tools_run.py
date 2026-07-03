"""watch-tools entry point -- runs inside watch-local/tools image.

Always:
- For URLs: downloads via yt-dlp with both manual and auto-generated subs.
- Classifies subtitle source as "creator" / "auto" / null.
- Probes video metadata.
- Extracts frames at auto-scaled fps.
- Extracts mono 16 kHz audio.mp3 (always -- whisper runs every time per
  v0.2 spec).
- Writes intermediate.json with everything the launcher + later stages
  need.

Inputs (env):
    W_SOURCE        URL or container path /input/<filename>
    W_IS_URL        "1" if URL, else "0"
    W_MAX_FRAMES    int, default 80, hard cap 100
    W_RESOLUTION    int px, default 768
    W_MAX_HEIGHT    int px cap on downloaded video, or 0/unset for best
    W_FPS           float override or "" (auto)
    W_START         seconds str or ""
    W_END           seconds str or ""

Outputs (in /work/):
    download/                video file (URL only) and video.*.vtt subs
    frames/frame_NNNN.jpg
    audio.mp3                always (unless video has no audio track)
    intermediate.json
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, "/app")
from frames import (  # noqa: E402
    auto_fps, auto_fps_focus, extract, extract_audio_for_whisper,
    format_time, get_metadata, MAX_FPS, parse_time,
)
from captions import classify_subtitle_source  # noqa: E402
from formats import build_format_selector  # noqa: E402


WORK = Path("/work")
DL_DIR = WORK / "download"
FRAMES_DIR = WORK / "frames"
AUDIO_PATH = WORK / "audio.mp3"
OUT_JSON = WORK / "intermediate.json"

VIDEO_EXTS = {".mp4", ".mkv", ".webm", ".mov", ".m4v", ".avi", ".flv", ".wmv"}


def _env(name: str, default: str = "") -> str:
    v = os.environ.get(name, "")
    return v if v != "" else default


def _env_int(name: str, default: int) -> int:
    v = _env(name, "")
    return int(v) if v else default


def _env_float_opt(name: str):
    v = _env(name, "")
    return float(v) if v else None


def _pick_subtitle(out_dir: Path):
    candidates = sorted(out_dir.glob("video*.vtt"))
    if not candidates:
        return None
    # Prefer plain `.en` (creator-style filename) over `.en-orig` (auto-gen
    # filename) when both present. The info.json-based classifier is the
    # authoritative provenance signal; this is just file-pick order.
    plain = [c for c in candidates if ".en." in c.name and ".en-orig." not in c.name]
    if plain:
        return plain[0]
    return candidates[0]


def _pick_video(out_dir: Path):
    for ext in (".mp4", ".mkv", ".webm", ".mov"):
        for c in out_dir.glob(f"video*{ext}"):
            return c
    for c in out_dir.glob("video.*"):
        if c.suffix.lower() in VIDEO_EXTS:
            return c
    return None


def download_url(url: str) -> dict:
    if shutil.which("yt-dlp") is None:
        raise SystemExit("yt-dlp is not installed in this container")
    DL_DIR.mkdir(parents=True, exist_ok=True)
    output_template = str(DL_DIR / "video.%(ext)s")
    # Best quality by default; W_MAX_HEIGHT (watch.ps1 -MaxHeight) optionally
    # caps it. Shared with disk.py via formats.build_format_selector so the
    # pre-flight size estimate matches what we actually pull.
    selector = build_format_selector(os.environ.get("W_MAX_HEIGHT"))
    cmd = [
        "yt-dlp",
        "-N", "8",
        "-f", selector,
        "--merge-output-format", "mp4",
        "--write-info-json",
        "--write-subs",
        "--write-auto-subs",
        "--sub-langs", "en,en-US,en-GB,en-orig",
        "--sub-format", "vtt",
        "--convert-subs", "vtt",
        "--no-playlist",
        "--ignore-errors",
        "-o", output_template,
        url,
    ]
    print(f"[tools] yt-dlp downloading {url}", file=sys.stderr, flush=True)
    result = subprocess.run(cmd, stdout=sys.stderr, stderr=sys.stderr)
    video = _pick_video(DL_DIR)
    if video is None:
        raise SystemExit(f"yt-dlp did not produce a video file (exit {result.returncode})")

    info_path = DL_DIR / "video.info.json"
    info = {}
    if info_path.exists():
        try:
            raw = json.loads(info_path.read_text(encoding="utf-8"))
            info = {
                "title": raw.get("title"),
                "uploader": raw.get("uploader") or raw.get("channel"),
                "duration": raw.get("duration"),
                "url": raw.get("webpage_url") or url,
            }
        except Exception:
            info = {"url": url}

    subtitle = _pick_subtitle(DL_DIR)
    source = classify_subtitle_source(str(info_path) if info_path.exists() else None)
    return {
        "video_path": str(video),
        "subtitle_path": str(subtitle) if subtitle else None,
        "info_path": str(info_path) if info_path.exists() else None,
        "subtitle_source": source,
        "info": info or {"url": url},
    }


def resolve_local(path: str) -> dict:
    p = Path(path)
    if not p.exists():
        raise SystemExit(f"file not found inside container: {p}")
    if p.suffix.lower() not in VIDEO_EXTS:
        print(
            f"[tools] warning: {p.suffix} not a known video extension, proceeding anyway",
            file=sys.stderr, flush=True,
        )
    return {
        "video_path": str(p),
        "subtitle_path": None,
        "info_path": None,
        "subtitle_source": None,
        "info": {"title": p.name, "url": str(p)},
    }


def main() -> int:
    source = _env("W_SOURCE")
    is_url = _env("W_IS_URL") == "1"
    if not source:
        print("ERROR: W_SOURCE env var required", file=sys.stderr)
        return 2

    max_frames = min(_env_int("W_MAX_FRAMES", 80), 100)
    resolution = _env_int("W_RESOLUTION", 768)
    fps_override = _env_float_opt("W_FPS")
    start_sec = parse_time(_env("W_START") or None)
    end_sec = parse_time(_env("W_END") or None)

    WORK.mkdir(parents=True, exist_ok=True)

    if is_url:
        dl = download_url(source)
    else:
        dl = resolve_local(source)

    video_path = dl["video_path"]
    meta = get_metadata(video_path)
    full_duration = meta["duration_seconds"]

    if start_sec is not None and start_sec < 0:
        raise SystemExit("--start must be non-negative")
    if end_sec is not None and start_sec is not None and end_sec <= start_sec:
        raise SystemExit("--end must be greater than --start")
    if full_duration > 0 and start_sec is not None and start_sec >= full_duration:
        raise SystemExit(f"--start {start_sec:.1f}s past end of video ({full_duration:.1f}s)")

    effective_start = start_sec if start_sec is not None else 0.0
    effective_end = end_sec if end_sec is not None else full_duration
    effective_duration = max(0.0, effective_end - effective_start)
    focused = start_sec is not None or end_sec is not None

    if focused:
        fps, target = auto_fps_focus(effective_duration, max_frames=max_frames)
    else:
        fps, target = auto_fps(effective_duration, max_frames=max_frames)
    if fps_override is not None:
        fps = min(fps_override, MAX_FPS)
        target = max(1, int(round(fps * effective_duration)))

    scope = (
        f"{format_time(effective_start)}-{format_time(effective_end)} ({effective_duration:.1f}s)"
        if focused else f"full {effective_duration:.1f}s"
    )
    print(
        f"[tools] extracting ~{target} frames at {fps:.3f} fps over {scope}",
        file=sys.stderr, flush=True,
    )

    frames = extract(
        video_path, FRAMES_DIR,
        fps=fps, resolution=resolution, max_frames=max_frames,
        start_seconds=start_sec, end_seconds=end_sec,
    )

    # ALWAYS extract audio if the video has any. Whisper runs every time.
    audio_extracted = False
    if meta.get("has_audio"):
        print("[tools] extracting audio for whisper", file=sys.stderr, flush=True)
        extract_audio_for_whisper(video_path, AUDIO_PATH)
        audio_extracted = True
    else:
        print("[tools] no audio track -- skipping audio extraction", file=sys.stderr, flush=True)

    out = {
        "source": source,
        "is_url": is_url,
        "video_path": video_path,
        "subtitle_path": dl.get("subtitle_path"),
        "info_path": dl.get("info_path"),
        "subtitle_source": dl.get("subtitle_source"),
        "info": dl.get("info") or {},
        "metadata": meta,
        "duration_seconds": full_duration,
        "focused": focused,
        "effective_start": effective_start,
        "effective_end": effective_end,
        "effective_duration": effective_duration,
        "fps": fps,
        "target_frames": target,
        "max_frames": max_frames,
        "resolution": resolution,
        "frames": frames,
        "audio_extracted": audio_extracted,
        "audio_path": str(AUDIO_PATH) if audio_extracted else None,
    }

    OUT_JSON.write_text(json.dumps(out, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"[tools] wrote {OUT_JSON} ({len(frames)} frames, subtitle_source={dl.get('subtitle_source')})", file=sys.stderr, flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
