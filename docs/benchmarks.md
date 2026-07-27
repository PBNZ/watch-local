# Benchmarks and per-model guidance

Which Whisper model should you run, and what will it cost you? Every
table below is measured on **the same video** so the rows can be
compared at all -- see [the reference video](benchmarking.md#the-reference-video).
Reproduce any of it with [benchmarking.md](benchmarking.md).

**The fixture:** `https://www.youtube.com/watch?v=AfOZ-MXe4uQ` -- The
Infographics Show, 32 min 53 s (1973 s), clean single-narrator English
with **human-written creator captions** (5,778 normalised reference
words). `benchmark.ps1` uses it by default; run it with no arguments and
you are running exactly what produced these numbers.

> **Read within a table, not across one.** Absolute speed depends on the
> machine and the audio, and not in the way you would guess: the two CPU
> tables below disagree by ~1.5x on identical audio, with the machine
> that has *more* cores coming last. That is worth understanding rather
> than averaging away.

## Pick a model

| You are on | Use | Why |
|---|---|---|
| **NVIDIA GPU** | `large-v3` (the shipped default) | Still 4.8x real-time here, and the model choice barely changes the wall clock. |
| **CPU, everyday use** | `small` (what the wizard recommends) | The accuracy knee: `medium` buys 0.7 points of WER for ~2.8x the time. |
| **CPU, accuracy matters** | `medium` | Best measured agreement with human captions, but ~26 min for a 33-min video. |
| **CPU, long video or a draft** | `base` | ~2.7x faster than `small` for ~1.4 points of WER. |
| **CPU + `large-v3`** | avoid | Slower than real-time on every machine measured, 5-6.5 GB RAM, and it got stuck in repetition loops in 10 of 11 runs on this fixture -- scoring *worse* against captions than `medium` (see below). |

One-time model downloads: `tiny` ~75 MB, `base` ~150 MB, `small`
~500 MB, `medium` ~1.5 GB, `large-v3` ~3 GB.

## GPU -- RTX PRO 5000 Blackwell

Intel Core i9-12900K, Windows 11, `cuda`/`float16`, `benchmark.ps1` with
no arguments.

| Model | Time | Speed vs real-time | Mean cores | Peak RSS | WER vs captions |
|---|---:|---:|---:|---:|---:|
| `tiny` | 55.3 s | 35.7x | 1.4 | 1,757 MB | 8.3% |
| `base` | 55.7 s | 35.4x | 1.5 | 2,101 MB | 7.1% |
| `small` | 89.5 s | 22.1x | 1.3 | 1,548 MB | 6.1% |
| `medium` | 147.0 s | 13.4x | 1.2 | 1,685 MB | **5.5%** |
| `large-v3` | 413.6 s | 4.8x | 1.4 | 2,998 MB | 16.0% |

- **`tiny` and `base` are indistinguishable** (55.3 vs 55.7 s). At this
  speed the fixed costs -- model load, audio decode, VAD -- dominate, so
  there is no reason to run `tiny` on a GPU.
- **`large-v3` is affordable**: 7.5x `tiny`'s time, still 4.8x
  real-time, and it leaves the CPU almost free (~1.4 cores).
- **The `large-v3` row is a single sample from a wide spread, and its
  WER is not a quality measurement.** Seven comparable runs on this
  fixture produced seven different transcripts: 255-414 s and
  11.6-17.7% WER, every one degenerating into repetition loops. Read
  [large-v3 does not reproduce](#large-v3-does-not-reproduce-on-this-fixture)
  before quoting that row.

## CPU -- same machine, forced to CPU

Same i9-12900K with `-Device cpu` (`int8`), same audio and same creator
captions as the GPU run above, at the shipped default thread count.
Warm pass skipped; models were already cached.

| Model | Time | Speed vs real-time | Mean cores | Peak RSS | WER vs captions |
|---|---:|---:|---:|---:|---:|
| `tiny` | 121.2 s | 16.3x | 3.0 | 1,487 MB | 8.6% |
| `base` | 203.8 s | 9.7x | 3.3 | 1,695 MB | 7.4% |
| `small` | 558.7 s | 3.5x | 3.3 | 1,348 MB | 6.0% |
| `medium` | 1,544.2 s | 1.3x | 3.4 | 1,959 MB | **5.3%** |
| `large-v3` | 4,479.5 s | **0.44x** | 3.4 | 4,909 MB | 13.3% |

`large-v3` took **1 h 15 m** to transcribe a 33-minute video, and scored
worse against the captions than `medium` did in a third of the time.
Note the mean-cores column: ~3.0-3.4 on a 16-core machine, at every
model size. That is not a configuration mistake -- see below.

That `large-v3` row is again one sample, and the model does not repeat
itself: two CPU runs at this thread count span **2,964-4,479 s**
(0.67x-0.44x). The one run in eleven that decoded cleanly finished in
2,964 s and scored 5.9% -- so on CPU the honest statement is "somewhere
between 49 and 75 minutes, most likely with degraded output", not
0.44x. Every other model in this table reproduces to within contention
noise.

## CPU -- contributed, 6-core laptop

Contributed with [#36](https://github.com/PBNZ/watch-local/issues/36)
from watch-local 0.6.1: Intel Core i7-10810U (6 cores / 12 threads),
16 GB RAM, Fedora Linux 43, CPU-only install, `int8`, 4 threads (the
pre-0.7.0 default).

| Model | Time | Speed vs real-time | Mean cores (of 12) | Peak RSS | WER vs captions |
|---|---:|---:|---:|---:|---:|
| `tiny` | 78 s | 25.3x | 3.2 | 0.75 GB | 6.3% |
| `base` | 130 s | 15.1x | 3.5 | 0.80 GB | 4.9% |
| `small` | 354 s | 5.6x | 3.7 | 1.04 GB | 4.4% |
| `medium` | 1,008 s | 2.0x | 3.9 | 2.68 GB | **3.5%** |
| `large-v3` | 3,449 s | 0.57x | 3.9 | 6.48 GB | 10.1% |

### Why the 6-core laptop beats the 16-core workstation

On identical audio the laptop is **1.3-1.6x faster** than the i9 --
1.55x on `tiny`, 1.53x on `medium`, 1.30x on the non-reproducible
`large-v3` row. That is not a typo, and it is the most useful thing in
this document. (Earlier revisions said "roughly 2x": that ratio came
from the 16-thread sweep 0.7.1 withdrew, not from the default-thread
table above.)

The one thing measurement establishes firmly:

- **Whisper on CPU barely parallelises.** Mean core usage sat at
  **2.4-3.9 on both machines regardless of the thread setting** --
  4, 8, 12 or 16 requested made almost no difference to cores actually
  used -- with brief peaks to 11 during encoder passes. The
  autoregressive decoder dominates and runs essentially single-threaded.
  Cores you add mostly idle.

Candidate explanations for the rest of the gap:

- ~~**The install differs.** The laptop ran a CPU-only stack; the
  workstation runs the CUDA build forced onto CPU.~~ **Tested and
  ruled out** -- see [the next section](#the-cuda-build-theory-tested-and-wrong).
  It was the leading theory here and it was wrong.
- **Background load.** The workstation carried ~3 of 24 cores of
  unrelated work; the laptop was idle.
- **Sustained-load behaviour.** The workstation's numbers drifted over a
  long session in a way a 15-minute idle period did not undo, and the
  cause was not identified.
- **Plain hardware difference.** Memory bandwidth, cache, and
  single-thread throughput are what a ~3-thread decoder actually spends
  its time on, and neither machine was chosen for those.

The last three remain unconfirmed. Practical reading: **do not size a
CPU transcription box by core count** -- and note that the one theory
specific enough to test did not survive.

### The CUDA-build theory, tested and wrong

The claim above used to be that `-Device cpu` on a GPU machine is not
representative of a real CPU-only install. It is. Three checks, in
increasing cost:

1. **There is no separate CPU build to install.** watch-local pins
   `faster-whisper==1.2.1` + `ctranslate2==4.8.1` for every machine
   (`runtime-manifest.json`); a GPU machine additionally gets
   `nvidia-cublas-cu12`, `nvidia-cudnn-cu12` and `nvidia-cuda-nvrtc-cu12`.
   PyPI ships one ctranslate2 wheel with CUDA compiled in. Provisioning
   a second, genuinely CPU-only runtime produced **byte-identical**
   `ctranslate2.dll`, `_ext.cp312-win_amd64.pyd`, `cudnn64_9.dll` and
   `libiomp5md.dll` (sha256).
2. **A CPU run never loads the CUDA libraries.** `cuda_paths` does put
   the three NVIDIA DLL directories on the search path even for
   `-Device cpu`, but after a real int8 decode `GetModuleHandleW`
   reports `cublas64_12`, `cublasLt64_12`, `cudnn_ops64_9`,
   `cudnn_graph64_9` and `nvrtc64_120_0` all **unloaded**. The only
   cuDNN in the process is the 266 KB stub inside the ctranslate2 wheel,
   which is present in both installs.
3. **The two stacks measure the same.** Both runtimes were pinned to
   identical package versions (six transitive deps had floated,
   including `onnxruntime`, which runs the VAD) so that they differed by
   exactly the three NVIDIA wheels. On a full sweep, four of five models
   produced **identical segment counts and identical WER to the
   decimal** -- 380/500/515/773 segments, 8.6/7.4/6.0/5.3% -- and only
   `large-v3`, which is non-deterministic anyway, differed.

| Model | Published (CUDA stack, `-Device cpu`) | CPU-only stack | Segments | WER |
|---|---:|---:|:---:|:---:|
| `tiny` | 121.2 s | 136.6 s | 380 = 380 | 8.6% = 8.6% |
| `base` | 203.8 s | 251.2 s | 500 = 500 | 7.4% = 7.4% |
| `small` | 558.7 s | 627.2 s | 515 = 515 | 6.0% = 6.0% |
| `medium` | 1,544.2 s | 1,745.0 s | 773 = 773 | 5.3% = 5.3% |
| `large-v3` | 4,479.5 s | 2,964.0 s | 511 / 659 | 13.3% / 5.9% |

The CPU-only column ran with more background load (`tiny` and `base`
sampled 2.5-2.7 mean cores against 3.0-3.3 elsewhere), which is what its
slower times record -- not the stack. Quote the published table, not
this one; it is here to show the transcripts match, not to add a second
set of timings.

Timing is noisier than the transcripts, and supports less. A first pass
ran the CPU-only build first in every pair and found it 2-7% slower;
but whichever stack runs second reads the model weights from a warm
page cache, so order and stack were confounded. Reversing the order
flipped `base` to **-3.6%** and collapsed `tiny` to **+0.9%** -- and
blew `small` out to **+27.8%**, the largest gap anywhere in the
experiment. That third pair is contaminated rather than informative: it
sampled 2.16 and 2.81 mean cores against 3.0-3.3 everywhere else, and
both of its runs were slower than the same runs in the first pass.

All three pairs are reported here because omitting the inconvenient one
is the exact failure this release is retracting. What the timings
support is narrow: on this box the channel is too noisy to settle a few
percent either way. **The identical transcripts are what carry this
section**; the timings only rule out a difference big enough to matter.

**Consequence for contributors:** you do not need a GPU-free machine to
contribute CPU numbers. `-Device cpu` on a GPU box is the same
measurement.

### `large-v3` does not reproduce on this fixture

`large-v3` is the only model here that fails to produce the same
transcript twice, and the cause is in the library rather than in
watch-local. `faster_whisper` defaults to a temperature ladder
(`[0.0, 0.2, 0.4, 0.6, 0.8, 1.0]`); when a segment trips
`compression_ratio_threshold = 2.4` ("too repetitive") it retries at a
higher temperature, and at any temperature above zero decoding switches
from beam search to **stochastic sampling**. Once that happens the run
is random, so identical audio yields different output.

Six back-to-back GPU runs, same audio, same everything:

| Run | Time | Segments | Repetition runs | Words | WER |
|---|---:|---:|---:|---:|---:|
| 1 | 309.2 s | 438 | 4 | 6,016 | 12.6% |
| 2 | 341.5 s | 547 | 2 | 6,132 | 15.4% |
| 3 | 325.8 s | 530 | 5 | 6,290 | 16.4% |
| 4 | 319.2 s | 553 | 2 | 6,393 | 17.7% |
| 5 | 265.2 s | 533 | 1 | 6,033 | 11.6% |
| 6 | 255.3 s | 431 | 2 | 6,126 | 12.9% |

Across every measurement taken on this fixture, `large-v3` degenerated
in **8 of 8 GPU runs and 2 of 3 CPU runs**. No other model has tripped
the detector once. The "repetition runs" column is watch-local's own
hallucination detector firing on real output -- the same one that
annotates `/watch` transcripts.

Two things follow:

- **`large-v3`'s WER here measures how often it gets stuck, not how well
  it hears.** The single clean run in eleven scored **5.9%** -- better
  than `tiny` or `base`, and close to `medium`'s 5.3%.
- **Its timings inherit the same spread.** A stuck decode re-runs
  segments at up to six temperatures and emits far more tokens: 2,964 s
  clean versus 4,479 s degenerate on CPU.

This is one fixture, and a clip that provokes the failure. Do not read
it as "large-v3 is a bad model" -- read it as a reason to prefer
`medium` when you cannot check the output, and as the reason the numbers
above carry a spread instead of a decimal.

## CPU thread count: why watch-local no longer touches it

[#34](https://github.com/PBNZ/watch-local/issues/34) reported ~3-4
threads busy on a 12-thread machine whatever the model, and read the
idle cores as recoverable headroom. faster-whisper's `cpu_threads=0`
does resolve inside ctranslate2 to `OMP_NUM_THREADS` or **4**, a
constant rather than a function of the host -- so the diagnosis was
right.

The inference was not. **Those cores are idle because Whisper cannot use
them**, and demanding more threads makes things worse. Full sweep on the
reference video, same machine and audio, only the thread count changed:

| Model | 4 threads (default) | 16 threads (physical cores) | Cost of more threads |
|---|---:|---:|---:|
| `tiny` | **121.2 s** | 178.5 s | +47% |
| `base` | **203.8 s** | 280.5 s | +38% |
| `small` | **558.7 s** | 719.1 s | +29% |
| `medium` | **1,544.2 s** | 1,781.7 s | +15% |
| `large-v3` | 4,479.5 s | 5,739.1 s | +28%* |

\* Do not lean on the `large-v3` row. Both endpoints are single
degenerate draws (2 repetition runs each), and two runs at a *fixed*
thread count already span 2,964-4,479 s -- a 51% spread that swallows
the +28% whole. The four rows above it are deterministic models where
the delta means something.

Every model, slower. Mean cores actually used was ~3.0-3.4 in **both**
columns -- asking for 16 did not deliver 16, it delivered the same ~3
plus the overhead of coordinating threads that had nothing to do. `tiny`
degrades monotonically (117 s / 137 s / 171 s at 4 / 8 / 16 threads),
its matrices being far too small to pay for the threads.

0.7.0 briefly shipped a default that sized CPU threads to the physical
core count, published as "~24% faster" from a single sweep on a
different clip. **That result has never reproduced** -- not on the
reference video, not on the original clip, not after a 15-minute idle
period -- and the sweep above is what repeated measurement shows. The
default is withdrawn: an unpinned CPU run again uses faster-whisper's
own setting.

The knob remains, because hardware varies and yours may genuinely
differ:

```powershell
benchmark.ps1 -Slug last -Device cpu -Models small -CpuThreads 4,8,16
```

Pin a winner with `setup.ps1 -SetCpuThreads N` (`0` = the library
default), or `-UnsetCpuThreads` to go back. Measure in the state you
actually transcribe in, and treat differences under ~10% as noise -- on
`large-v3` far more than that, since the eight GPU runs on record here
span 255-414 s, the slowest **62% slower** than the fastest.

**If you want CPU transcription to finish sooner, pick a smaller
model.** That lever is worth 44x; the thread count is worth nothing
reliable.

## Quality: what the WER column does and does not mean

Lower WER = closer to the creator captions. Across all three tables the
shape is identical and worth trusting: **accuracy improves to `medium`,
and `large-v3` scores worst.**

For `tiny` through `medium` that shape reproduces exactly, on both
machines and on both stacks. The `large-v3` half of it has a different
cause than this page used to give.

**Correction.** Earlier versions of this document explained large-v3's
poor score as the model "transcribing more literally -- ~5% more words
than the captions contain -- so it agrees least with human-*edited*
text while being no less correct." The surplus words are real, but they
are not literalness: they are **repeated text from decodes that got
stuck**, and the runs that produced them tripped watch-local's own
repetition detector 1-5 times each. The one run in eleven that decoded
cleanly emitted 5,713 words against a 5,778-word reference -- *fewer*
than the captions, not 5% more -- and scored 5.9% instead of 13-17%.

The rest of the original point still stands: captions are an editor's
rendering rather than ground truth, which is why the column is labelled
"vs captions" and not "accuracy". That just is not what produced the
`large-v3` number.

Two comparability warnings:

- **Across tables the quality numbers are only roughly comparable.** The
  contributed run scored with the reporter's own script (which splits
  `don't` into two tokens); `quality.py` keeps contractions intact. Its
  reference came to 5,845 words against our 5,778.
- **Caption provenance matters more than either.** WER against a
  platform's *auto* captions measures drift between two speech
  recognisers, not accuracy. `benchmark.ps1` states which kind it used
  in every report; only `creator` captions support the readings above.

## Contributing numbers

More hardware makes these tables worth trusting -- especially
non-Windows hosts and machines with different memory bandwidth, which is
the leading remaining suspect for the laptop/workstation gap. You do
**not** need a GPU-free machine: `-Device cpu` on a GPU box is now a
measured equivalent (see above). See
[benchmarking.md](benchmarking.md#contributing-numbers).

## Caveats

- **One clip, easy audio.** Clean studio narration. On noisy audio,
  accents, overlapping speakers, or non-English, larger models pull
  ahead in ways this fixture cannot show.
- **Captions are human-edited, not ground truth.**
- **The workstation figures carry background load.** Its measurements
  ran with ~2-4 of 24 cores busy (MCP servers, file sync). The laptop
  figures were taken on an otherwise-idle machine.
- **Timings include model load-from-disk, exclude the download.**
- **Thermal state is part of the measurement**, as the table above
  shows. Numbers from a cold machine flatter it.
- **`large-v3` is not a repeatable measurement on this fixture.** Every
  row for it is one draw from a wide distribution; `tiny` through
  `medium` reproduce to within contention noise.
