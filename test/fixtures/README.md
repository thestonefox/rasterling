# Fixture provenance

The three photographic subjects are copied unchanged at a 256-pixel longest edge
from [media-fixtures](https://github.com/thestonefox/media-fixtures/tree/9b34821d29e5bd1dc3163c5a2652aeedd4dbbc2e).
Each is included as PNG, JPEG, GIF and BMP. See that revision's
[image rights](https://github.com/thestonefox/media-fixtures/blob/9b34821d29e5bd1dc3163c5a2652aeedd4dbbc2e/images/RIGHTS.md)
for original URLs, hashes and evidence.

- Mountain lake: kraigseder, CC0; historically reviewed Pixabay CC0 source.
- Cat on a couch: Christoffer G. Thomsen, CC0.
- Grace Hopper: James S. Davis / US Navy, official portrait NH 96919-KN;
  public domain in the United States. Other jurisdictions can differ.

The other fixtures are original procedural colour samples by The Stonefox /
Rasterling contributors, covered by the repository MIT license. No Pillow test
images, unrelated repository assets, camera metadata or upstream source files
are included.

Independent preparation used Pillow 12.3.0 and Python's standard PNG/zlib/CRC
primitives. Tests do not require those tools. PNG16, Adam7 and a constant-colour
YCCK JPEG were independently constructed; expected PNG16 samples explicitly
use their high eight bits. Pillow independently decoded the YCCK fixture.
The RGB/L/CMYK JPEG variants exercise baseline/progressive scans, 4:4:4/4:2:2/
4:2:0 sampling and restart intervals. The GIF corpus includes animation and
interlacing. BMP palette/truecolour fixtures include unused high bytes.

`catalogue.data` lists encoded file SHA-256 values, dimensions and whether
comparison allows JPEG rounding/chroma differences. Each `.rgba.zlib` is the
corresponding reference row-major RGBA byte string, compressed with zlib for
storage. Lossless outputs must match exactly; JPEG mean absolute byte error
must stay below five, with fully opaque alpha. This checks actual pixel layout
and colour, rather than just file recognition or dimensions.
