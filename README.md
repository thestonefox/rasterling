<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/rasterling-logo-dark.svg">
  <img src="docs/assets/rasterling-logo.svg" alt="Rasterling - little beast, raw pixels" width="760">
</picture>

# Rasterling

Pure Elixir decoding for PNG, JPEG, GIF and BMP. **Little beast. Raw pixels.**

- Runs on the BEAM with zero runtime dependencies.
- No third-party NIFs, external converters, platform binaries or downloads.
- Returns eight-bit RGBA pixels for your application to process or display.
- Standard OTP `:zlib` handles PNG decompression.

This is an initial decoder implementation, not a claim of complete image-format
conformance or a security certification. Supported encodings and limits are
listed below. See [security](SECURITY.md) and [performance](docs/performance.md).

## Installation

Add [Rasterling](https://hex.pm/packages/rasterling) to your dependencies in
`mix.exs`:

```elixir
{:rasterling, "~> 0.1.0"}
```

Then run `mix deps.get`. Dependency setup needs network access; decoding never
does. There is no native decoder to download or compile. Commit `mix.lock` in
your application to keep dependency versions reproducible.

ExDoc is a development-only dependency for building documentation; applications
using Rasterling do not fetch it. See the [publishing guide](docs/publishing.md)
for the maintainer release process.

## Decode bytes

```elixir
{:ok, image} = Rasterling.decode(encoded_bytes)
image.width
image.height
image.format # :png, :jpeg, :gif or :bmp
image.pixels # row-major <<r, g, b, a, ...>>, one byte per channel
Rasterling.Image.pixel(image, 0, 0) # {r, g, b, a}
```

`Rasterling.decode!/2` returns the image directly or raises `Rasterling.Error`.
Formats are recognized from bytes, not filenames or HTTP content types.

## Local files and remote URLs

```elixir
{:ok, image} = Rasterling.open("assets/photo.jpg")
{:ok, image} = Rasterling.open(Path.expand("assets/photo.jpg"))
```

Relative and absolute local paths are supported. Local file reads share the
worker time budget and read no more than `max_bytes + 1` bytes. Files must be
regular files. The decoder does not interpret URLs, run subprocesses, or fetch
anything. To decode a remote image, fetch its bytes in your application and
call `Rasterling.decode/2`. Apply download limits and URL-access policy there.

## Supported encodings

| Format | Supported |
| --- | --- |
| PNG | Grayscale 1/2/4/8/16-bit; RGB 8/16-bit; indexed 1/2/4/8-bit; grayscale-alpha/RGBA 8/16-bit; tRNS; all five filters; Adam7 |
| JPEG | 8-bit sequential and progressive Huffman DCT; grayscale, YCbCr, direct RGB, CMYK and YCCK; common chroma subsampling; restart markers |
| GIF | GIF87a/89a, global/local palettes, LZW, interlacing and transparency; first image frame composited onto its logical canvas |
| BMP | OS/2 core and Windows DIB headers 40/52/56/108/124; 1/4/8-bit palettes; 16/24/32-bit pixels; RGB and contiguous bitfields; top-down/bottom-up rows |

JPEG lossless/arithmetic/12-bit encodings, BMP RLE and embedded JPEG/PNG,
APNG, SVG, WebP, AVIF and animated playback are unsupported. Unsupported
encodings return an error; there is no native or external-tool fallback.

Sixteen-bit PNG samples use their high eight bits. JPEG inverse DCT rounding
can differ slightly from native decoders; subsampled chroma uses nearest-neighbour
upsampling, so colour at sharp boundaries can differ more noticeably. EXIF
orientation, ICC profiles, gamma correction and other colour management are not
applied. Output contains decoded sample values and no source metadata.

For legacy 32-bit BI_RGB BMPs, the unused high byte is treated as opaque.
Explicit alpha bitfields preserve transparency. GIF displays its first frame,
not subsequent animation frames; disposal timing is not implemented.

## Resource limits and errors

```elixir
Rasterling.decode(bytes,
  max_bytes: 2_000_000,
  max_pixels: 1_000_000,
  timeout: 2_000,
  max_memory_bytes: 64 * 1024 * 1024
)
```

Defaults: **10,000,000 encoded bytes**, **16,000,000 pixels**, a **10-second**
worker deadline and a **256 MiB worker heap budget**. These are rejection limits,
not a promise that an image near the limits will decode quickly or fit in the
heap budget. Use tighter values for terminal previews and untrusted uploads.
All options must be positive integers; unknown options raise `ArgumentError`.

Decoding runs in an isolated monitored process. Pixel dimensions are checked
before allocating image data; PNG inflation and GIF output are bounded. JPEG
scan count, palette indices, bitfields and container structure are validated.

The heap budget uses BEAM `max_heap_size`, checked at garbage collections.
Shared binaries are included in that accounting; shared references can be counted
more than once, and sub-binaries retain their parent allocation. Encoded-byte,
pixel and PNG scanline limits apply separately. This is **not a process RSS or
VM-wide memory ceiling**.
Applications must limit concurrent decodes. Worker timeout/heap exhaustion
returns an error without killing the calling process.

```elixir
{:error, %Rasterling.Error{reason: reason, message: message}}
```

Reasons: `:invalid_image`, `:unsupported_format`, `:unsupported_feature`,
`:too_large`, `:timeout`, `:resource_limit` and `:file_error`. Error messages
are generic and do not include image data, source metadata or local paths.

## Performance

The intended first use is small, cached image previews. A 256-pixel longest edge
means 256 by the proportional height, not 256 total pixels. CPU work still
scales with the source image; terminal display size does not reduce decoding.
Rasterling does not resize, cache, or decode only a JPEG thumbnail.

In one local run of 14 subjects per format at a 256-pixel longest edge:

| Format | Median | Slowest |
| --- | ---: | ---: |
| PNG | 72 ms | 163 ms |
| JPEG | 152 ms | 251 ms |
| GIF | 67 ms | 86 ms |
| BMP | 22 ms | 31 ms |

These Windows/Elixir 1.20/OTP 28 observations are not guarantees. Native decoders
are substantially faster. See [method and tradeoffs](docs/performance.md).

## Development

Elixir 1.16+ and OTP 26+; no C/C++ compiler, image programs or Python needed.

```sh
mix compile --warnings-as-errors
mix format --check-formatted
mix test --warnings-as-errors
mix hex.build
```

Tests use committed independent reference pixels, not encoder/decoder round
trips through Rasterling. The fixture corpus includes progressive, grayscale,
CMYK and YCCK JPEGs, restart markers, palette alpha, animation and Adam7.
Adversarial cases cover malformed/truncated files, compression expansion,
size limits, deadlines and worker heap exhaustion. This is a useful test suite,
not exhaustive fuzzing or proof of safety. [Fixture provenance](test/fixtures/README.md).

## License

[MIT](LICENSE) for Rasterling code, documentation and original mascot artwork.
Third-party test photographs retain their documented CC0/public-domain status;
they are not relicensed under MIT. No upstream decoder implementation or native
binary is bundled with Rasterling.
