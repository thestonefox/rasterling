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

All twelve Breeze Images sample photographs in these four formats were also
compared with Pillow 12.3.0 reference pixels. PNG/GIF/BMP were exact. JPEG mean
absolute error was below 0.04 on each RGB channel for those 4:4:4 fixtures.
The committed conformance suite additionally exercises subsampling: nearest-
neighbour chroma expansion intentionally differs from smoother native upsampling.

An earlier exploratory comparison of an older `erl_img` baseline JPEG decoder
against StbImage found roughly 124 ms versus 0.6 ms at a 256-pixel longest edge,
and 2.24 seconds versus 9.2 ms at 1024. That was a different implementation,
not a Rasterling benchmark, and is included only to make the native-speed
tradeoff explicit. No code from that library is distributed here.

## What this means

Small, asynchronously loaded and cached terminal previews are a plausible use.
Applications must measure their own latency and throughput. A 4000 by 3000 photo
still has twelve million source pixels even if displayed in forty columns.
Rasterling currently decodes at source resolution and does not implement scaled
JPEG IDCT, progressive previews, thumbnail extraction, resizing or caching.

Do not choose it for high-throughput photo services or megapixel workloads on the
strength of these observations. Bound the input and resource usage; a timeout is
a supported failure, not a successful large-image performance result.
