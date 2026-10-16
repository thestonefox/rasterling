# Security

Rasterling parses untrusted binary data in Elixir on the BEAM. It does not load
third-party NIFs, invoke executables, interpret image metadata as code, make
network requests or create atoms from image data. PNG uses OTP's bundled zlib.

## Boundaries

- Keep encoded-byte, pixel, deadline and heap limits enabled and appropriately
  small for your application. Worker processes isolate decoding failures.
- The worker heap limit includes shared binaries and is checked during GC.
  Shared references may be counted repeatedly; sub-binaries count their parent
  allocation. It is not a hard RSS or VM-wide ceiling. Encoded-byte, pixel and
  PNG scanline limits apply separately.
- Limit concurrent operations. A thousand individually bounded workers can
  still exhaust a machine. Apply rate limits to public upload endpoints.
- Bound remote downloads before decoding and implement URL/SSRF restrictions in
  your HTTP layer. Rasterling deliberately has no URL fetcher.
- Keep Erlang/OTP up to date; standard runtime components remain part of the
  trust boundary, including file I/O, zlib and the BEAM VM itself.
- Do not treat acceptance as image authentication, proof of provenance or full
  specification conformance. Metadata/colour management and uncommon encodings
  have explicit limitations in the README.

The default maximum dimensions do not guarantee a decode will complete before
its deadline or fit its heap budget. Large photos are not the initial performance
target. Local filesystem calls ultimately depend on the OS/filesystem; worker
deadlines are not a guarantee of kernel I/O cancellation.

## Reporting

Please use GitHub's private vulnerability reporting for this repository if
available. Otherwise open a minimal issue requesting a private reporting channel,
without attaching an exploit or sensitive image. Include the Rasterling revision,
Elixir/OTP versions and a minimal reproduction once a private channel is agreed.
There is no independent security audit or support response-time guarantee yet.
