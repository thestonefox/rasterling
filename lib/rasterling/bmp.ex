defmodule Rasterling.BMP do
  @moduledoc false
  import Bitwise
  alias Rasterling.{Error, Limits}

  def decode(
        <<"BM", file_size::little-32, _::32, offset::little-32, dib::little-32, _::binary>> =
          bytes,
        limits
      ) do
    {w, signed_h, bits, compression, colors, entry_size} = header(bytes, dib)
    h = abs(signed_h)
    Limits.dimensions!(w, h, limits)
    Limits.require!(bits in [1, 4, 8, 16, 24, 32])
    if compression not in [0, 3, 6], do: Error.fail(:unsupported_feature)
    Limits.require!(compression == 0 or bits in [16, 32])
    {masks, extra} = masks(bytes, dib, bits, compression)
    start = 14 + dib + extra

    palette =
      if bits <= 8 do
        count = if colors == 0, do: 1 <<< bits, else: colors

        Limits.require!(
          count > 0 and count <= 1 <<< bits and offset >= start + count * entry_size
        )

        raw = binary_part(bytes, start, count * entry_size)

        for i <- 0..(count - 1) do
          <<b, g, r, _::binary>> = binary_part(raw, i * entry_size, entry_size)
          <<r, g, b, 255>>
        end
        |> List.to_tuple()
      end

    stride = div(w * bits + 31, 32) * 4
    ending = offset + stride * h
    Limits.require!(offset >= start and ending <= byte_size(bytes))
    Limits.require!(file_size == 0 or (file_size >= ending and file_size <= byte_size(bytes)))

    pixels =
      for y <- 0..(h - 1), x <- 0..(w - 1), into: <<>> do
        row = if signed_h > 0, do: h - 1 - y, else: y
        pos = offset + row * stride

        cond do
          bits <= 8 ->
            index =
              :binary.at(bytes, pos + div(x * bits, 8)) >>> (8 - bits - rem(x * bits, 8)) &&&
                (1 <<< bits) - 1

            Limits.require!(index < tuple_size(palette))
            elem(palette, index)

          bits == 24 ->
            <<b, g, r>> = binary_part(bytes, pos + x * 3, 3)
            <<r, g, b, 255>>

          true ->
            value =
              :binary.decode_unsigned(
                binary_part(bytes, pos + div(x * bits, 8), div(bits, 8)),
                :little
              )

            {r, g, b, a} = masks

            <<channel(value, r), channel(value, g), channel(value, b),
              if(a == 0, do: 255, else: channel(value, a))>>
        end
      end

    Limits.image!(w, h, pixels, :bmp)
  end

  def decode(_, _), do: Error.fail()

  defp header(bytes, 12) do
    <<_::binary-size(18), w::little-16, h::little-16, 1::little-16, bits::little-16, _::binary>> =
      bytes

    {w, h, bits, 0, 0, 3}
  end

  defp header(bytes, dib) when dib in [40, 52, 56, 108, 124] do
    <<_::binary-size(18), w::little-signed-32, h::little-signed-32, 1::little-16, bits::little-16,
      compression::little-32, _::binary-size(12), colors::little-32, _::binary>> = bytes

    Limits.require!(byte_size(bytes) >= 14 + dib)
    {w, h, bits, compression, colors, 4}
  end

  defp header(_, _), do: Error.fail(:unsupported_feature)

  defp masks(_, _, 16, 0), do: {{0x7C00, 0x3E0, 0x1F, 0}, 0}
  defp masks(_, _, 32, 0), do: {{0xFF0000, 0xFF00, 0xFF, 0}, 0}

  defp masks(bytes, dib, bits, compression) when compression in [3, 6] do
    count = if compression == 6 or dib >= 56, do: 4, else: 3
    Limits.require!(dib == 40 or dib >= 40 + count * 4)
    raw = binary_part(bytes, 54, count * 4)
    list = for <<mask::little-32 <- raw>>, do: mask
    [r, g, b, a] = if count == 3, do: list ++ [0], else: list
    masks = [r, g, b, a]
    Limits.require!(Enum.all?([r, g, b], &(&1 != 0)))
    Limits.require!(Enum.all?(masks, &(valid_mask?(&1) and &1 < 1 <<< bits)))
    Limits.require!(Enum.sum(masks) == Enum.reduce(masks, 0, &bor/2))
    {{r, g, b, a}, if(dib == 40, do: count * 4, else: 0)}
  end

  defp masks(_, _, _, _), do: {nil, 0}
  defp valid_mask?(0), do: true

  defp valid_mask?(n) do
    n = n >>> shift(n, 0)
    (n &&& n + 1) == 0
  end

  defp shift(n, k) when (n &&& 1) == 1, do: k
  defp shift(n, k), do: shift(n >>> 1, k + 1)

  defp channel(value, mask) do
    bits = shift(mask, 0)
    div(((value &&& mask) >>> bits) * 255 + div(mask >>> bits, 2), mask >>> bits)
  end
end
