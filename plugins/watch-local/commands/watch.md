---
description: Watch a video (URL, local path, or SMB/UNC share). Downloads with yt-dlp, extracts frames with ffmpeg, ALWAYS transcribes with faster-whisper on the local NVIDIA GPU and compares against creator captions when present. No cloud keys.
argument-hint: <video-url-or-path> [question] [-Start T -End T -SaveHere -OutDir D -Cleanup -Model name]
allowed-tools: [Bash, Read, AskUserQuestion]
---

Invoke the `watch-local` skill (defined in SKILL.md) with the user's arguments: $ARGUMENTS

Follow the skill's full pipeline: preflight check -> run scripts/watch.ps1 with the source and any opts -> Read each frame the script lists -> answer the user grounded in frames + transcript. If the user provided no arguments, ask for a video URL or path before proceeding.
