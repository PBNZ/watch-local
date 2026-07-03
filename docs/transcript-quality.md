# Transcript quality + provenance

## Why we always run Whisper

Three transcript sources exist for any given video:

1. **Creator-uploaded subtitles** (manual SRT/VTT the creator wrote or
   commissioned). Highest quality on average -- accurate proper nouns,
   technical terms, capitalization, occasional editorial polish.
2. **Local Whisper (large-v3)** running on your GPU. Strong second
   place. Faster-whisper large-v3 handles most English content well,
   including technical jargon, with reasonable speaker-change handling.
3. **Platform auto-captions** (YouTube auto-subs, etc.). Lowest quality
   of the three. Visibly broken on proper nouns ("Grok" -> "GROC"),
   homophones, and any unusual vocabulary.

Per the spec, watch-local **always runs Whisper** so the comparison
data is always available. The launcher picks a "primary" transcript
per these rules:

- Creator subs exist for the filter language -> primary = creator,
  secondary = whisper.
- Only auto-captions exist (or none) -> primary = whisper, secondary
  = captions (if any).

The secondary appears in the report inside a `<details>` fold.

## The comparison stage

`compare.py` (in the `tools` container -- no GPU needed) computes:

- **length_ratio** = `min(words_a, words_b) / max(words_a, words_b)`
- **word_jaccard** = set intersection over union, over lowercased
  word lists.
- **trigram_jaccard** = same, over 3-gram tuples. Catches order /
  phrasing differences that word-bag misses.

Each is classified independently:

| Metric | match | minor | major |
|---|---|---|---|
| length_ratio | >= 0.95 | 0.80-0.95 | < 0.80 |
| word_jaccard | >= 0.85 | 0.70-0.85 | < 0.70 |
| trigram_jaccard | >= 0.75 | 0.55-0.75 | < 0.55 |

Final `significance` = worst-of-three.

If `significance == "major"`, the report includes a `> **Note:**`
callout telling the user the two transcripts disagree noticeably.
Spot-check proper nouns / technical terms in that case.

## Override flags

| Flag | Effect |
|---|---|
| `-NoCompare` | Skip `compare.py`. Saves a few seconds. |
| `-PrimaryOverride creator` | Force creator subs as primary (only valid if they exist). |
| `-PrimaryOverride whisper` | Force whisper as primary (only valid if it ran). |

## When the primary auto-pick goes wrong

Two known edge cases:

1. **Creator subs are translated, not original-language.** yt-dlp
   doesn't distinguish translations from native uploads; both land
   under `subtitles`. If the source is a non-English video with
   creator-uploaded English subs, those subs may be lower quality
   than Whisper's automatic transcription. Compare scores will show
   the divergence; user can pass `-PrimaryOverride whisper`.

2. **Creator subs are time-misaligned.** Some uploaders post subs that
   drift over a long video. The transcripts will still match
   word-for-word, so length_ratio + jaccard stay high -- but
   timestamp filtering with `-Start`/`-End` will pick the wrong text.
   No automated detection yet. Suggest comparing the report's frame
   timestamps to the transcript stamps; if they drift, fall back to
   Whisper.
