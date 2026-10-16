defmodule Rasterling.Limits do
  @moduledoc false
  alias Rasterling.Error

  def dimensions!(width, height, limits) do
    if width <= 0 or height <= 0, do: Error.fail()
    if width * height > limits.max_pixels, do: Error.fail(:too_large)
    :ok
  end

  def image!(width, height, pixels, format) do
    if byte_size(pixels) != width * height * 4, do: Error.fail()
    %Rasterling.Image{width: width, height: height, pixels: pixels, format: format}
  end

  def ceil_div(a, b), do: div(a + b - 1, b)
  def clamp(n), do: max(0, min(255, round(n)))
  def require!(true), do: :ok
  def require!(_), do: Error.fail()
end
