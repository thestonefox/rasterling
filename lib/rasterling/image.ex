defmodule Rasterling.Image do
  @moduledoc "Decoded row-major, eight-bit RGBA pixels, without source metadata."
  @enforce_keys [:width, :height, :pixels, :format]
  defstruct [:width, :height, :pixels, :format]

  @type t :: %__MODULE__{
          width: pos_integer(),
          height: pos_integer(),
          pixels: binary(),
          format: :png | :jpeg | :gif | :bmp
        }

  @doc "Returns the RGBA tuple at a zero-based coordinate."
  def pixel(%__MODULE__{width: width, height: height, pixels: pixels}, x, y)
      when is_integer(x) and is_integer(y) and x >= 0 and y >= 0 and x < width and y < height do
    offset = (y * width + x) * 4
    <<r, g, b, a>> = binary_part(pixels, offset, 4)
    {r, g, b, a}
  end
end
