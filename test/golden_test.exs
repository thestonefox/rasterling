defmodule Rasterling.GoldenTest do
  use ExUnit.Case, async: true
  alias Rasterling.Image
  @directory Path.expand("fixtures", __DIR__)
  {fixtures, _} = Code.eval_file(Path.join(@directory, "catalogue.data"))

  for {name, width, height, lossy, checksum} <- fixtures do
    @tag fixture: name
    test "independent decoded pixels: #{name}" do
      bytes = File.read!(Path.join(@directory, unquote(name)))
      assert Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == unquote(checksum)

      assert {:ok, %Image{width: unquote(width), height: unquote(height)} = image} =
               Rasterling.decode(bytes)

      reference =
        File.read!(Path.join(@directory, unquote(name) <> ".rgba.zlib")) |> :zlib.uncompress()

      assert byte_size(image.pixels) == byte_size(reference)

      if unquote(lossy) do
        {sum, count} = error(image.pixels, reference, 0, 0)
        # Native chroma interpolation differs from our nearest-neighbour expansion.
        # Full-resolution colour, grayscale and CMYK need much tighter bounds.
        subsampled = unquote(name) in ~w(jpeg-rgb-1-baseline.jpg jpeg-rgb-1-progressive.jpg
          jpeg-rgb-2-baseline.jpg jpeg-rgb-2-progressive.jpg jpeg-progressive-restart.jpg
          jpeg-restart-blocks.jpg jpeg-restart-rows.jpg)
        tolerance = if subsampled, do: 5, else: 0.1

        assert sum / count < tolerance,
               "JPEG differs excessively from independent reference pixels"

        unless subsampled do
          assert max_error(image.pixels, reference, 0) <= 3
        end

        assert for(<<_::24, a <- image.pixels>>, uniq: true, do: a) == [255]
      else
        assert image.pixels == reference
      end
    end
  end

  defp max_error(<<>>, <<>>, maximum), do: maximum

  defp max_error(<<a, rest::binary>>, <<b, reference::binary>>, maximum),
    do: max_error(rest, reference, max(maximum, abs(a - b)))

  defp error(<<>>, <<>>, sum, count), do: {sum, count}

  defp error(<<a, rest::binary>>, <<b, reference::binary>>, sum, count),
    do: error(rest, reference, sum + abs(a - b), count + 1)
end
