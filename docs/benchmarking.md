# Benchmarking watch-local

`plugins/watch-local/scripts/benchmark.ps1` measures Whisper
transcription on **your** machine: per-model wall time, speed vs
real-time, mean core usage, peak memory, and transcription quality
against creator captions.

Published results live in [benchmarks.md](benchmarks.md). This page is
how to reproduce or extend them.

## The reference video

**Every published number is measured on one video, and yours should be
too** -- otherwise the tables describe different workloads and cannot be
compared:

| | |
|---|---|
| **URL** | `https://www.youtube.com/watch?v=AfOZ-MXe4uQ` |
| **Title** | "50 Insane Declassified MI6 Secrets You Didn't Know" (The Infographics Show) |
| **Length** | 32 min 53 s (1973 s) |
| **Why this one** | public; long enough that the gap between models is unmistakable; clean single-narrator English; and it carries **human-written creator captions**, which is what makes the WER column a quality measure instead of a comparison against another machine's guess |

`benchmark.ps1` uses it automatically -- `-Source` defaults to that URL,
so running the script with no arguments is the reproducible case. You
never need to type it, but if you drive the worker yourself, that is the
video to use.

Benchmark a *different* video whenever you like (`-Source`, `-Slug`,
`-AudioPath`) -- just do not compare those numbers to the published
tables, and say which clip you used if you publish them.

## Quick start

The examples below use `pwsh -File <script>`; `powershell -File` works
too on Windows. Paths are shown relative to a repo checkout. If you
installed from the marketplace, the script lives inside the installed
plugin instead -- find it with:

```powershell
Get-ChildItem "$env:USERPROFILE\.claude" -Recurse -Filter benchmark.ps1 |
  Select-Object -First 1 -ExpandProperty FullName
```

Cheapest run -- reuse a video you have already watched, so nothing is
downloaded and every model transcribes byte-identical audio:

```powershell
pwsh -File plugins/watch-local/scripts/benchmark.ps1 -Slug last -Models small,medium
```

Full sweep against the reference video -- this is the command that
produces the published tables, and it needs no arguments because
`-Source` already defaults to the fixture:

```powershell
pwsh -File plugins/watch-local/scripts/benchmark.ps1              # GPU when available
pwsh -File plugins/watch-local/scripts/benchmark.ps1 -Device cpu  # CPU numbers
```

Run those two **separately, never at the same time**, and leave the
machine otherwise idle: a sweep sharing the CPU with a build or a test
run measures the contention, not the model.

CPU numbers on a GPU machine -- the comparison most users need, because
`large-v3` behaves completely differently without CUDA:

```powershell
pwsh -File plugins/watch-local/scripts/benchmark.ps1 -Slug last -Device cpu -Models small
```

CPU thread scaling, if you want to check whether your machine behaves
differently from the ones in [benchmarks.md](benchmarks.md) (on those,
raising the count did not help and often hurt):

```powershell
pwsh -File plugins/watch-local/scripts/benchmark.ps1 -Slug last -Device cpu -Models small -CpuThreads 0,4,8,16
```

`-CpuThreads 0` is what watch-local uses by default: faster-whisper's
own setting, which is `OMP_NUM_THREADS` if you export it and otherwise
4 threads regardless of machine size. watch-local never sets
`OMP_NUM_THREADS` itself, so on a normal shell `0` means 4.

> **Time budget: roughly double what the tables say.** Every model is
> transcribed **twice** -- an untimed warm run, then the timed one -- so
> a model listed at 5 minutes costs about 10 minutes of wall clock. On
> CPU, `large-v3` can run slower than real-time (the reference video
> took ~57 minutes *per pass* on a 6-core laptop). Start with `-Models
> tiny,base,small`, and only add `medium`/`large-v3` when you can leave
> the machine alone.
>
> Once every model is downloaded and has been run once, `-SkipWarm`
> drops the warm pass and halves the wall clock. Do not use it on a
> first run: the first model's timing would swallow its own download.

## Output

Everything lands in `<state root>/benchmarks/<timestamp>/` (override with
`-OutDir`), never inside the plugin directory:

| File | Contents |
|---|---|
| `report.md` | Ready-to-paste markdown table + machine description |
| `results.json` | Machine-readable runs, machine info, quality scores (`schema: watch-local/benchmark@1`) |
| `results.csv` | One row per run, for spreadsheets |
| `quality.json` | WER / Jaccard per model |
| `transcripts/` | Every transcript produced, for your own scoring |
| `run-*.err.log` | Per-run worker stderr, kept for failures |

## Method

Four decisions matter for numbers that mean anything:

1. **Audio is acquired once.** Every model transcribes the same file, so
   differences are the model, not the download or the extraction.
2. **Each model gets an untimed warm run first.** That absorbs the
   one-time model download and the first load. The timed run therefore
   covers load-from-disk plus transcription -- what you actually wait
   for on a second run, and comparable across models.
3. **Resource use is sampled per process, not system-wide.** Peak RSS
   and total processor-seconds come from the worker process itself
   (`Get-Process`), which reports identically on Windows, Linux, and
   macOS. **Mean cores** = processor-seconds / wall-seconds, so 3.9 on a
   12-thread box means Whisper used about 4 threads and left the rest
   idle. System-wide CPU is deliberately not collected: it is the one
   metric with no portable implementation, and it measures the machine
   rather than the model.
4. **Quality is scored against the source's captions** by
   `worker/quality.py`: word-level WER (Levenshtein / reference words)
   and word-set Jaccard, on the same normalised tokens `compare.py` uses.
   Each model is also scored against the largest model, so a fixture
   without captions still ranks models against each other.

   **Check which kind of captions you got.** The report names the
   provenance: `creator` captions are human-edited and make WER a
   quality signal; `auto` captions are the platform's own ASR output,
   and scoring one recogniser against another measures *drift*, not
   accuracy -- both can be wrong, and the better model can score worse.
   Most YouTube videos carry auto-captions only, so pick your fixture
   deliberately if quality is what you are after.

### Caveats that belong next to any number you publish

- **Captions are not ground truth.** Even creator captions are
  human-*edited* text, so WER measures agreement with an editor: a more
  literal transcriber scores worse while being no less correct. Against
  auto-captions the number is weaker still (see above). Relative, not
  absolute.
- **One clip is one clip.** The reference fixture is clean,
  single-speaker studio English. On noisy audio, strong accents,
  overlapping speakers, or non-English, larger models pull ahead in ways
  this fixture cannot show.
- **Thermals and background load.** Laptops throttle on sustained runs;
  `large-v3` is where that shows up first. Re-run if the machine was
  busy.
- **The fixture is a third-party video.** It can be taken down or break
  with a yt-dlp change. `-Slug` / `-AudioPath` exist so a benchmark is
  never blocked on that.

## Contributing numbers

Reference tables are only useful with a spread of hardware behind them.
To contribute:

1. Run the full sweep, ideally against the default `-Source` so the clip
   matches. `-Device cpu` results are especially valuable -- most
   published data is GPU-shaped, and CPU is where model choice hurts.
2. Open an issue with `report.md` pasted in, plus your CPU model, RAM,
   OS, and GPU (if any). `results.json` already carries the machine
   block; attach it if you can.
3. Say if anything was unusual: thermal throttling, a busy machine, a
   non-default `models_root` on a slow disk.

Numbers are published with attribution and the hardware they came from,
never as universal truth.

## Related

- [benchmarks.md](benchmarks.md) -- the published results.
- [transcript-quality.md](transcript-quality.md) -- how `/watch` picks a
  primary transcript and what the comparison metrics mean.
- [architecture.md](architecture.md) -- where the worker stages sit.
