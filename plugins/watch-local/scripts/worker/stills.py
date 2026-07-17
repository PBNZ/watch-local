"""On-demand native-resolution still extraction (runs in the tools image).

Pulls one high-quality screenshot per requested timestamp from an already
downloaded source video, at native resolution by default. Powers both
`watch.ps1 -Screenshots` and the `/watch:grab-frames` command, so the host
side never has to shell ffmpeg directly.

Inputs (env):
    W_VIDEO       container path to the source video (e.g. /work/download/video.mp4)
    W_SHOTS       comma-separated timestamps: seconds or SS / MM:SS / HH:MM:SS
    W_OUT_DIR     container dir to write stills into (e.g. /work/screenshots)
    W_STILL_RES   width in px, or "" / "0" for native resolution (default native)
    W_PREFIX      filename prefix (default "shot")

Output:
    JSON to stdout: {"stills": [{"timestamp_seconds": .., "path": ".."}, ...]}
    Stills written to W_OUT_DIR as <prefix>_<MM-SS>.jpg
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

from frames import extract_stills, parse_time


def _env(name: str, default: str = "") -> str:
    v = os.environ.get(name, "")
    return v if v != "" else default


def main() -> int:
    video = _env("W_VIDEO")
    shots = _env("W_SHOTS")
    work = _env("W_WORK_DIR", "/work")
    out_dir = _env("W_OUT_DIR", os.path.join(work, "screenshots"))
    prefix = _env("W_PREFIX", "shot")
    res_raw = _env("W_STILL_RES", "")
    try:
        resolution = int(res_raw) if res_raw else 0
    except ValueError:
        resolution = 0

    if not video:
        print("ERROR: W_VIDEO env var required", file=sys.stderr)
        return 2
    if not shots:
        print("ERROR: W_SHOTS env var required", file=sys.stderr)
        return 2
    if not Path(video).exists():
        print(f"ERROR: source video not found: {video}", file=sys.stderr)
        return 2

    timestamps = []
    for tok in shots.split(","):
        tok = tok.strip()
        if not tok:
            continue
        # parse_time raises (SystemExit) on malformed input -- right for
        # single-value fail-fast sites, but one bad token in a batch must
        # not abort the valid ones.
        try:
            secs = parse_time(tok)
        except (SystemExit, ValueError):
            print(f"[stills] WARNING: could not parse timestamp '{tok}' -- skipping",
                  file=sys.stderr)
            continue
        if secs is None:
            continue
        timestamps.append(secs)

    if not timestamps:
        print("ERROR: no valid timestamps in W_SHOTS", file=sys.stderr)
        return 2

    stills = extract_stills(
        video, out_dir, timestamps,
        resolution=(resolution or None), prefix=prefix,
    )
    print(json.dumps({"stills": stills}))
    print(f"[stills] wrote {len(stills)}/{len(timestamps)} stills to {out_dir}",
          file=sys.stderr, flush=True)
    return 0 if stills else 1


if __name__ == "__main__":
    raise SystemExit(main())
