"""Shared yt-dlp format selector builder.

Imported by BOTH tools_run.py (the real downloader) and disk.py (the
pre-flight size probe) so the two can never drift -- the disk estimate
must reflect exactly the format we will actually download.

Default policy (v0.2.2): grab the best available video + best audio,
merged to mp4, with NO height cap. Honors the user directive "always
download the best quality video to work off." A height cap is opt-in
via the W_MAX_HEIGHT env var (watch.ps1 -MaxHeight flag) for users who
want to bound bandwidth on 4K/8K sources.
"""
from __future__ import annotations


def build_format_selector(max_height=None) -> str:
    """Return a yt-dlp -f selector string.

    max_height: int cap in pixels (e.g. 1080) or None / 0 / "" for
    uncapped best. Non-numeric input is treated as uncapped.
    """
    try:
        h = int(max_height) if max_height not in (None, "") else 0
    except (TypeError, ValueError):
        h = 0
    if h > 0:
        # Best video <= cap + best audio; fall back to best combined <= cap;
        # then best video+audio uncapped; then best combined.
        return (
            f"bv*[height<={h}]+ba/b[height<={h}]/bv*+ba/b"
        )
    # Uncapped: best video + best audio, merged; fall back to best combined.
    return "bv*+ba/b/bv+ba/b"
