# Output locations + saving artifacts

## Default

Every `/watch` call writes artifacts to:

```
%LOCALAPPDATA%\watch-local\jobs\<slug>\
  download\               # URL only: downloaded video.mp4 + info.json + .vtt
  frames\frame_NNNN.jpg
  audio.mp3
  intermediate.json
  transcript_whisper.json
  comparison.json
```

These persist indefinitely. Nothing is auto-cleaned.

Override per-call: `-OutDir <path>` -- artifacts go directly there.

Override the default for ALL future calls:

```powershell
powershell -File <plugin>\scripts\setup.ps1 -SetJobsRoot D:\watch-jobs
```

## Promoting into your project

The default location is good for transient work but bad for project
artifacts. Two ways to bring a job into your current Claude Code
working directory:

### Option 1: per-call flag

```
/watch <url> -SaveHere
```

After the run, the entire job dir is copied into
`./watch-local-output/<slug>/`. The canonical copy under `jobs_root`
stays in place (no data loss).

Extra flags:
- `-MoveOnSave` -- move instead of copy. Canonical dir is gone.
- `-IncludeSource` -- for local / UNC sources, also copy the source
  file (default behavior is link-only -- see below).

### Option 2: promote a past job

```
/watch:save-here              # promote the most recent /watch run
/watch:save-here <slug>       # promote a specific slug
/watch:save-here --include-source --move
```

`save-here.ps1` reads `last-job.json` to resolve the most recent slug.

## Local / UNC source handling

When the source is a local file or a UNC share (i.e. a file that
already lives outside watch-local's storage), the default `-SaveHere`
behaviour writes a **link-only** marker instead of copying the (often
large) source file:

```
./watch-local-output/<slug>/source-link.txt
```

Contents:

```
type: local | unc
path: <full original path>
size_bytes: 12345678
mtime_utc: 2026-05-12T14:23:01Z
sha256_first_64kb: a1b2c3d4...
note: Source file left in place. Re-run with -IncludeSource to copy.
```

The partial sha256 lets Claude (or you) detect later if the source
file has changed since the `/watch` ran.

Pass `-IncludeSource` (or `--include-source` on `/watch:save-here`)
to actually copy the source into the output dir alongside the
frames + transcripts.

## Cleanup

Default: never deletes anything.

Per-call cleanup (only for THIS call's job dir):

```
/watch <url> -Cleanup
```

This is scope-locked to `jobs_root` -- it cannot touch any
`-OutDir`, any `./watch-local-output/` promoted copy, or anything
else outside the configured jobs root.

Bulk maintenance (preview-first, token-confirmed):

```powershell
powershell -File <plugin>\scripts\setup.ps1 -ListJobs
powershell -File <plugin>\scripts\setup.ps1 -PurgeJobs -OlderThanDays 30 -DryRun
powershell -File <plugin>\scripts\setup.ps1 -PurgeJobs -OlderThanDays 30
powershell -File <plugin>\scripts\setup.ps1 -PurgeJob -Slug 1a2b3c...
```

Every purge prints exactly what will be deleted and a unique
confirmation token. Nothing happens until you type the token (or
pass `-ConfirmToken <token>` non-interactively).

## Why link-not-copy for local/UNC?

Three reasons:

1. **Space.** Source videos are often hundreds of MB to multiple GB.
   Copying them into every project dir wastes disk fast.
2. **Two-of-truths risk.** Two copies of a file diverge. If the
   source gets edited, the project copy becomes stale silently.
3. **Privacy.** Source files may live on shared drives by policy.
   Auto-copying out of those shares can break policy. A link is safe.

The sha256-of-first-64KB hash gives you a verification mechanism:
when looking at a promoted job later, you can recompute the hash
of the source-link path and confirm the source is still the file
that was processed.
