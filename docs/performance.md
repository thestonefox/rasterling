# Performance notes

Rasterling trades native decoder speed for a pure-BEAM implementation with no
third-party NIFs, platform-specific downloads or external programs.

## Preliminary local observations

Date: 2026-10-16. Windows x86-64, Elixir 1.20.1, Erlang/OTP 28. Shared development
machine; these are single-run wall-clock observations, not controlled benchmark
claims. Normal `Rasterling.decode/1` defaults were used, including worker startup.

Input: all 14 subjects from `thestonefox/media-fixtures` at commit
`9b34821d29e5bd1dc3163c5a2652aeedd4dbbc2e`, at a 256-pixel longest edge,
in each of PNG, JPEG, GIF and BMP. That is 56 decodes, all successful.

| Format | Median across 14 subjects | Maximum |
| --- | ---: | ---: |
| PNG | 72.0 ms | 162.6 ms |
| JPEG | 152.4 ms | 251.3 ms |
| GIF | 66.9 ms | 85.8 ms |
| BMP | 22.4 ms | 31.0 ms |

Three sample photographs in each of these four formats were also compared
with Pillow 12.3.0 reference pixels. PNG/GIF/BMP were exact. JPEG mean
absolute error was below 0.04 on each RGB channel for those 4:4:4 fixtures.
The committed conformance suite additionally exercises subsampling: nearest-
neighbour chroma expansion intentionally differs from smoother native upsampling.

An earlier exploratory comparison of an older `erl_img` baseline JPEG decoder
against StbImage found roughly 124 ms versus 0.6 ms at a 256-pixel longest edge,
and 2.24 seconds versus 9.2 ms at 1024. That was a different implementation,
not a Rasterling benchmark, and is included only to make the native-speed
tradeoff explicit. No code from that library is distributed here.

## Reproducible JPEG comparison

Run `mix run bench/decode.exs 9` from the repository root. Optional image paths
follow the iteration count. Files are read before timing, two warm-up decodes
precede each sample set, and the public decoder includes worker startup and
resource accounting. Each timed result must match the warm-up pixels. The script
prints input SHA-256 hashes, median and nearest-rank p95; with nine samples p95
is the maximum. Samples are sequential on a shared machine, not a throughput or
memory benchmark. Fixtures are in Git, not the published Hex package.

A same-machine comparison on 2026-10-16 (Windows x86-64, Elixir 1.20.1, OTP 28)
compared `18f0ae7` with the factorized even/odd JPEG inverse transform and shared
binary accounting. Both used two warm-ups and nine timed decodes per input:

| JPEG fixture | Before median / p95 | After median / p95 |
| --- | ---: | ---: |
| mountain-lake.jpg | 110.899 / 114.892 ms | 69.939 / 73.011 ms |
| cat-on-couch.jpg | 104.243 / 105.574 ms | 70.041 / 84.992 ms |
| grace-hopper.jpg | 180.326 / 197.222 ms | 121.344 / 142.540 ms |

These inputs have a 256-pixel longest edge. Median time fell by 33-37% in this
small sample. Every output byte matched the earlier decoder across all eighteen
committed JPEG fixtures, including progressive, subsampled, grayscale, direct
RGB, CMYK, YCCK and restart-marker inputs. Independent golden references also
pass; full-resolution channels now have tighter mean and maximum error bounds.

The transform remains separable and floating-point. Factoring its cosine matrix
removes repeated reductions and multiplications without fixed-point rounding
changes. This is not a claim that all floating-point operations allocate boxed
intermediates: OTP optimizes suitable float expressions. Tuple storage remains
useful for progressive coefficient refinement; replacing it with lists or
changing chroma expansion requires separate measurements and regression checks.

## What this means

Small, asynchronously loaded and cached terminal previews are a plausible use.
Applications must measure their own latency and throughput. A 4000 by 3000 photo
still has twelve million source pixels even if displayed in forty columns.
Rasterling currently decodes at source resolution and does not implement scaled
JPEG IDCT, progressive previews, thumbnail extraction, resizing or caching.

Do not choose it for high-throughput photo services or megapixel workloads on the
strength of these observations. Bound the input and resource usage; a timeout is
a supported failure, not a successful large-image performance result.
