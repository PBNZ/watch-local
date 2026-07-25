# Benchmarks and per-model guidance

Which Whisper model should you run? On a GPU the answer is usually
"whichever you like" -- on CPU it is the single biggest decision you
make, worth a 44x swing in run time.

Reproduce or extend any of this with
[benchmarking.md](benchmarking.md); the harness is
`plugins/watch-local/scripts/benchmark.ps1`.

> Every number here comes from **one clip on one machine**. They are
> directional, not authoritative. Speech is the workload, so a different
> video changes absolute times even on identical hardware -- the same
> `small` model measured 5.6x real-time on the contributed laptop run
> and 4.2x on a much faster workstation with a different clip. Compare
> models *within* a table; never lift a multiplier as a spec.

## Pick a model

| You are on | Use | Why |
|---|---|---|
| **NVIDIA GPU** | `large-v3` (the default) | CUDA/float16 makes the big model cheap. Nothing smaller is worth the accuracy trade. |
| **CPU, everyday use** | `small` (the CPU default) | ~6x real-time, ~1 GB RAM, and within a point of `medium` on clean English. |
| **CPU, accuracy matters** | `medium` | Best caption agreement measured, but ~3x slower than `small` and 2.7 GB RAM. |
| **CPU, long video or a draft** | `base` | 15x real-time, under 1 GB. `tiny` is faster still but starts dropping proper nouns. |
| **CPU + `large-v3`** | avoid | Slower than real-time, 6.5 GB RAM, and **no accuracy gain** over `medium` on clean English. It is a GPU-class model. |

One-time model downloads: `tiny` ~75 MB, `base` ~150 MB, `small`
~500 MB, `medium` ~1.5 GB, `large-v3` ~3 GB.

## CPU reference run

Contributed by an agent session benchmarking watch-local **0.6.1** and
filed as [#36](https://github.com/PBNZ/watch-local/issues/36). All five
models, same 32 min 53 s audio (clean single-narrator studio English
with human captions), measured in isolation.

**Hardware:** Intel Core i7-10810U (6 cores / 12 threads), 16 GB RAM, no
NVIDIA GPU, Fedora Linux 43. CPU-only, Whisper `int8`, VAD on, language
auto-detected.

| Model | Time | Speed vs real-time | Segments | Mean cores (of 12) | Peak process RSS |
|---|---:|---:|---:|---:|---:|
| `tiny` | 1m18 | **25.3x** | 237 | 3.2 | 0.75 GB |
| `base` | 2m10 | **15.1x** | 355 | 3.5 | 0.80 GB |
| `small` | 5m54 | **5.6x** | 539 | 3.7 | 1.04 GB |
| `medium` | 16m48 | **2.0x** | 845 | 3.9 | 2.68 GB |
| `large-v3` | **57m29** | **0.57x** (slower than the video) | 392 | 3.9 | 6.48 GB |

Each step up costs 1.7-3.4x more time; `large-v3` is ~44x slower than
`tiny`. Memory only becomes a consideration at `large-v3` (peak system
usage 9.6 GB of 16 GB).

### Quality on the same run

Scored against the creator captions (5,845 normalised words). **Lower
WER = closer to the captions.**

| Model | Words | WER vs captions | Word Jaccard | WER vs `large-v3` |
|---|---:|---:|---:|---:|
| `tiny` | 5,840 | 6.3% | 0.865 | 10.4% |
| `base` | 5,823 | 4.9% | 0.897 | 9.1% |
| `small` | 5,822 | 4.4% | 0.913 | 8.6% |
| `medium` | 5,818 | **3.5%** | 0.915 | 8.0% |
| `large-v3` | 6,035 | 10.1% | 0.895 | -- |

Reading these honestly:

- **Accuracy climbs to `small`, then flattens.** `tiny` mangles or drops
  proper nouns (Goldeneye, Faraday, Wormwood Scrubs, Roald Dahl);
  `small` and `medium` land most of them.
- **`large-v3`'s worst-looking score is not a quality failure.** It
  transcribes more literally (+3% words) and hit one repetition loop, so
  it agrees *least* with lightly-edited human captions while tying
  `medium` for best on proper nouns. Captions reward editing, not
  fidelity. (That loop is what [#35](https://github.com/PBNZ/watch-local/issues/35)
  fixed -- 2x loops are now caught and flagged.)
- **Rare names defeat everyone, humans included.** No source spelled
  *Sidney Reilly*, *Gordievsky*, or *Fort Monckton* correctly -- the
  captions themselves wrote "Riley", "Goryevski", "Monkton".

### Full pipeline, same machine

One end-to-end `/watch` with `small`, 100 frames at 768 px:

| Phase | Wall time | Notes |
|---|---:|---|
| Download (video + audio + captions) | ~15 s | network-bound |
| Frame + audio extraction (ffmpeg) | ~100 s | ~980% CPU -- CPU decode, no NVDEC |
| Transcription (`small`) | ~362 s | ~73% of total run time |
| Compare | ~2 s | |
| **Total** | **~8.3 min** | peak system memory ~5.1 GB |

Without an NVIDIA GPU, frame extraction is the CPU-heaviest phase but
transcription is the *longest* one -- which is why model choice, not
frame count, decides how long `/watch` takes.

## CPU thread scaling

The "mean cores" column above is the bug
[#34](https://github.com/PBNZ/watch-local/issues/34) reported: ~3-4
threads busy on a 12-thread machine, whatever the model. The cause is
faster-whisper's default `cpu_threads=0`, which ctranslate2 resolves to
`OMP_NUM_THREADS` or **4** -- a constant, not a function of the machine.

Since 0.7.0, unpinned CPU runs size themselves to the machine's
**physical core count**. That number is not arbitrary -- it is where
scaling stops paying.

**Measured:** Intel Core i9-12900K (16 physical cores / 24 threads,
8 P-cores + 8 E-cores), Windows 11, `small` on `cpu`/`int8`, the same
8m36 English talk each time.

```powershell
pwsh -File plugins/watch-local/scripts/benchmark.ps1 `
     -Slug last -Device cpu -Models small -CpuThreads 0,4,8,12,16,24
```

| `cpu_threads` | Time | Speed vs real-time | vs the old default |
|---|---:|---:|---:|
| 0 (= faster-whisper's default, 4) | 169.2 s | 3.05x | -- |
| 4 | 159.7 s | 3.23x | +6% |
| 8 | 127.0 s | 4.06x | **+25%** |
| 12 | **122.7 s** | **4.20x** | **+27%** |
| 16 (physical cores -- the new default) | 128.8 s | 4.01x | **+24%** |
| 24 (every logical CPU) | 151.7 s | 3.40x | +10% |

Three things this shows:

1. **The old default left ~25% on the table** on a machine this size,
   and the gap widens with core count.
2. **Scaling saturates well before the thread count.** 8, 12, and 16 are
   within 5% of each other -- a plateau, not a peak.
3. **Using every logical CPU is nearly as bad as using four.** Piling
   onto SMT siblings (and, here, E-cores) gives most of the win back,
   which is why the default is physical cores rather than
   `ProcessorCount`. Physical cores also lands correctly on non-SMT
   machines like Apple Silicon, where the two counts are equal.

Rows 0 and 4 request the same four threads and still differ by 6%, so
treat differences under ~10% as noise; the 4-vs-12 gap is far outside
it. Measured on an otherwise-idle workstation with light background
load.

Pin a different value with `setup.ps1 -SetCpuThreads N` (0 restores
faster-whisper's own default), or `-UnsetCpuThreads` to go back to auto.
Useful on a shared box, or when transcription competing for every core
makes the rest of the machine unusable.

## GPU reference run

Why `large-v3` is the default when CUDA works, and why the CPU table
above should not be read as "big models are bad".

**Hardware:** NVIDIA RTX PRO 5000 Blackwell (48 GB VRAM) on an Intel
Core i9-12900K, Windows 11. `cuda`/`float16`, 8m36 English talk.
Produced by `benchmark.ps1 -Slug last`.

| Model | Time | Speed vs real-time | Mean cores | Peak RSS | Drift vs auto-captions |
|---|---:|---:|---:|---:|---:|
| `tiny` | 17.0 s | 30.3x | 2.3 | 761 MB | 5.7% |
| `base` | 20.0 s | 25.9x | 2.2 | 761 MB | 3.1% |
| `small` | 29.3 s | 17.6x | 2.1 | 762 MB | 3.1% |
| `medium` | 43.5 s | 11.9x | 1.9 | 1,119 MB | 2.4% |
| `large-v3` | 62.4 s | **8.3x** | 2.0 | 2,690 MB | 2.7% |

> **The last column is not accuracy.** This clip carries only YouTube
> **auto-generated** captions, so that WER measures how far each model
> drifts from *another speech recogniser* -- both sides can be wrong,
> and a better model can score worse. Read the timing columns here and
> take quality signal from the CPU table above, whose reference is
> human-edited. (`benchmark.ps1` now labels caption provenance in every
> report so this distinction cannot be lost again.)

**On a GPU the model-size decision nearly disappears.** `large-v3` costs
3.7x `tiny`'s time and still transcribes at 8x real-time -- where on CPU
the same step-up is a ~44x penalty that pushes past real-time. It also
barely touches the CPU (about 2 cores, mostly audio decode and feature
extraction), so the machine stays usable.

The same clip on the same machine forced to CPU (`benchmark.ps1 -Slug
last -Device cpu -Models tiny,base`, 16 threads): `tiny` 30.3 s and
`base` 48.5 s, versus 17.0 s and 20.0 s on the GPU -- and the gap widens
sharply with model size.

One caveat to carry over: this is a **different, shorter clip** than the
CPU reference run above, so do not compare the two tables directly. Only
the timing column is comparable within this table.

## Contributing numbers

More hardware makes these tables worth trusting -- especially CPU-only
machines and non-Windows hosts. See
[benchmarking.md](benchmarking.md#contributing-numbers); results are
published with attribution and the hardware behind them.

## Caveats

- **Captions are not ground truth.** They are human-*edited*, so WER
  measures agreement with an editor, not correctness.
- **One clip, easy audio.** Clean studio narration. On noisy audio,
  accents, overlapping speakers, or non-English, larger models pull
  ahead in ways this fixture cannot show.
- **Timings exclude one-time model downloads** but include
  load-from-disk.
- **Laptops throttle.** Sustained `large-v3` runs on thin hardware vary
  run to run.
