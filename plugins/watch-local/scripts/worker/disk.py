"""yt-dlp dry-run probe for download size estimation.

Used by the host launcher's disk-space pre-flight. Returns the approximate
filesize in bytes for the format we will actually download (matching the
real download command's -f selector). Falls back to None on any error so
the launcher can apply a pessimistic default.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys

from formats import build_format_selector


def main() -> int:
    url = os.environ.get("W_URL")
    if not url:
        print("ERROR: W_URL required", file=sys.stderr)
        return 2

    # Selector mirrors tools_run.download_url exactly (shared builder) so the
    # size estimate matches the real download. W_MAX_HEIGHT optionally caps it.
    selector = build_format_selector(os.environ.get("W_MAX_HEIGHT"))

    # `-J` gives full info JSON without downloading. `--no-playlist` matches
    # our real downloader. `--simulate` is implied by -J.
    cmd = ["yt-dlp", "-J", "-f", selector, "--no-playlist", url]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    except subprocess.TimeoutExpired:
        print('{"bytes": null, "error": "yt-dlp probe timed out"}')
        return 0
    if result.returncode != 0:
        print(json.dumps({"bytes": None, "error": result.stderr.strip()[:300]}))
        return 0

    try:
        info = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        print(json.dumps({"bytes": None, "error": f"JSON parse: {exc}"}))
        return 0

    # yt-dlp populates filesize_approx (or filesize) on the resolved format.
    size = info.get("filesize") or info.get("filesize_approx")
    # When merging audio+video, `requested_formats` is a list; sum sizes.
    if not size and isinstance(info.get("requested_formats"), list):
        total = 0
        for fmt in info["requested_formats"]:
            s = fmt.get("filesize") or fmt.get("filesize_approx")
            if s:
                total += int(s)
        if total:
            size = total

    print(json.dumps({
        "bytes": int(size) if size else None,
        "duration_seconds": info.get("duration"),
        "title": info.get("title"),
    }))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
