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
        assert sum / count < 5, "JPEG differs excessively from independent reference pixels"
        assert for(<<_::24, a <- image.pixels>>, uniq: true, do: a) == [255]
      else
        assert image.pixels == reference
      end
    end
  end

  defp error(<<>>, <<>>, sum, count), do: {sum, count}

  defp error(<<a, rest::binary>>, <<b, reference::binary>>, sum, count),
    do: error(rest, reference, sum + abs(a - b), count + 1)
end
