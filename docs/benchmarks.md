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
| **CPU + `large-v3`** | avoid | Slower than real-time on every machine measured, 5-6.5 GB RAM, and it scores *worse* against captions than `medium` (see below). |

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
- **Run-to-run spread is real.** A second identical run of `large-v3`
  took 349 s rather than 414 s (-16%) and emitted a different segment
  count, so treat single-digit-percent gaps here as noise.

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

On identical audio the laptop is roughly **2x faster** than the i9 at
every model size. That is not a typo, and it is the most useful thing in
this document.

The one thing measurement establishes firmly:

- **Whisper on CPU barely parallelises.** Mean core usage sat at
  **2.4-3.9 on both machines regardless of the thread setting** --
  4, 8, 12 or 16 requested made almost no difference to cores actually
  used -- with brief peaks to 11 during encoder passes. The
  autoregressive decoder dominates and runs essentially single-threaded.
  Cores you add mostly idle.

Candidate explanations for the rest of the gap, none of them confirmed:

- **The install differs.** The laptop ran a CPU-only stack; the
  workstation runs the CUDA build forced onto CPU with `-Device cpu`.
- **Background load.** The workstation carried ~3 of 24 cores of
  unrelated work; the laptop was idle.
- **Sustained-load behaviour.** The workstation's numbers drifted over a
  long session in a way a 15-minute idle period did not undo, and the
  cause was not identified.

Practical reading: **do not size a CPU transcription box by core
count**, and do not expect `-Device cpu` on a GPU machine to predict a
CPU-only machine's numbers.

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
| `large-v3` | **4,479.5 s** | 5,739.1 s | +28% |

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
actually transcribe in, and treat differences under ~10% as noise --
`large-v3` on GPU varied 16% between two identical runs here.

**If you want CPU transcription to finish sooner, pick a smaller
model.** That lever is worth 44x; the thread count is worth nothing
reliable.

## Quality: what the WER column does and does not mean

Lower WER = closer to the creator captions. Across all three tables the
shape is identical and worth trusting: **accuracy improves to `medium`,
and `large-v3` scores worst.**

That is not a `large-v3` failure. It transcribes more literally -- ~5%
more words than the captions contain -- so it agrees least with
human-*edited* text while being no less correct. The captions are an
editor's rendering, not ground truth, which is exactly why the column is
labelled "vs captions" and not "accuracy".

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

More hardware makes these tables worth trusting -- especially CPU-only
machines and non-Windows hosts, and any machine that can say whether the
CUDA-build-on-CPU theory above holds. See
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
