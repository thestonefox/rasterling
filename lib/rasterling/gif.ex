defmodule Rasterling.GIF do
  @moduledoc false
  import Bitwise
  alias Rasterling.{Error, Limits}

  def decode(
        <<"GIF", version::binary-size(3), w::little-16, h::little-16, flags, background, _,
          rest::binary>>,
        limits
      )
      when version in ["87a", "89a"] do
    Limits.dimensions!(w, h, limits)
    {palette, rest} = table(rest, flags &&& 0x80, flags &&& 7)

    blocks(
      rest,
      %{w: w, h: h, palette: palette, background: background, transparent: nil},
      limits
    )
  end

  def decode(_, _), do: Error.fail()

  defp table(bytes, 0, _), do: {nil, bytes}

  defp table(bytes, _, n) do
    size = 1 <<< (n + 1)
    data = binary_part(bytes, 0, size * 3)
    rest = binary_part(bytes, size * 3, byte_size(bytes) - size * 3)
    {for(<<r, g, b <- data>>, do: <<r, g, b, 255>>) |> List.to_tuple(), rest}
  end

  defp blocks(<<0x21, 0xF9, 4, packed, _delay::16, index, 0, rest::binary>>, state, limits) do
    transparent = if (packed &&& 1) == 1, do: index, else: nil
    blocks(rest, %{state | transparent: transparent}, limits)
  end

  defp blocks(<<0x21, label, rest::binary>>, state, limits) when label != 0xF9 do
    {_, rest} = subblocks(rest, [])
    blocks(rest, state, limits)
  end

  defp blocks(
         <<0x2C, left::little-16, top::little-16, w::little-16, h::little-16, flags,
           rest::binary>>,
         state,
         limits
       ) do
    Limits.dimensions!(w, h, limits)
    Limits.require!(left + w <= state.w and top + h <= state.h and (flags &&& 0x18) == 0)
    {local, rest} = table(rest, flags &&& 0x80, flags &&& 7)
    palette = local || state.palette
    Limits.require!(is_tuple(palette))
    Limits.require!(state.transparent == nil or state.transparent < tuple_size(palette))
    <<minimum, rest::binary>> = rest
    Limits.require!(minimum in 2..8)
    {compressed, rest} = subblocks(rest, [])
    # First-frame display still requires a structurally valid remaining container.
    trailer!(rest)
    indices = lzw(compressed, minimum, w * h)

    rows =
      if (flags &&& 0x40) == 0 do
        for y <- 0..(h - 1), do: y
      else
        Enum.flat_map([{0, 8}, {4, 8}, {2, 4}, {1, 2}], fn {start, step} ->
          if start < h, do: Enum.take_every(Enum.to_list(start..(h - 1)), step), else: []
        end)
      end

    rows = rows |> Enum.with_index() |> Map.new()

    bg =
      if is_integer(state.transparent) or state.palette == nil,
        do: <<0, 0, 0, 0>>,
        else: color(state.palette, state.background, nil)

    pixels =
      for y <- 0..(state.h - 1), x <- 0..(state.w - 1), into: <<>> do
        if x >= left and x < left + w and y >= top and y < top + h do
          index = :binary.at(indices, Map.fetch!(rows, y - top) * w + x - left)
          color(palette, index, state.transparent)
        else
          bg
        end
      end

    Limits.image!(state.w, state.h, pixels, :gif)
  end

  defp blocks(_, _, _), do: Error.fail()

  defp color(palette, index, transparent) do
    Limits.require!(is_tuple(palette) and index < tuple_size(palette))
    <<r, g, b, _>> = elem(palette, index)
    <<r, g, b, if(index == transparent, do: 0, else: 255)>>
  end

  defp subblocks(<<0, rest::binary>>, acc), do: {IO.iodata_to_binary(Enum.reverse(acc)), rest}

  defp subblocks(<<size, data::binary-size(size), rest::binary>>, acc),
    do: subblocks(rest, [data | acc])

  defp subblocks(_, _), do: Error.fail()

  defp trailer!(<<0x3B>>), do: :ok

  defp trailer!(<<0x21, _label, rest::binary>>) do
    {_, rest} = subblocks(rest, [])
    trailer!(rest)
  end

  defp trailer!(<<0x2C, _::binary-size(8), packed, rest::binary>>) do
    {_, rest} = table(rest, packed &&& 0x80, packed &&& 7)
    <<minimum, rest::binary>> = rest
    Limits.require!(minimum in 2..8)
    {_, rest} = subblocks(rest, [])
    trailer!(rest)
  end

  defp trailer!(_), do: Error.fail()

  defp dictionary(minimum), do: Map.new(0..((1 <<< minimum) - 1), &{&1, <<&1>>})

  defp lzw(bytes, minimum, expected) do
    clear = 1 <<< minimum
    {first, reader} = code({bytes, 0, 0}, minimum + 1)
    Limits.require!(first == clear)

    decode_codes(
      reader,
      minimum + 1,
      minimum,
      dictionary(minimum),
      clear + 2,
      nil,
      [],
      0,
      expected
    )
  end

  defp decode_codes(reader, width, minimum, dict, next, previous, output, length, expected) do
    {value, reader} = code(reader, width)
    clear = 1 <<< minimum

    cond do
      value == clear ->
        decode_codes(
          reader,
          minimum + 1,
          minimum,
          dictionary(minimum),
          clear + 2,
          nil,
          output,
          length,
          expected
        )

      value == clear + 1 ->
        Limits.require!(length == expected)
        IO.iodata_to_binary(Enum.reverse(output))

      true ->
        entry =
          cond do
            Map.has_key?(dict, value) -> Map.fetch!(dict, value)
            value == next and is_binary(previous) -> previous <> binary_part(previous, 0, 1)
            true -> Error.fail()
          end

        length = length + byte_size(entry)
        if length > expected, do: Error.fail()

        {dict, next} =
          if previous != nil and next < 4096 do
            {Map.put(dict, next, previous <> binary_part(entry, 0, 1)), next + 1}
          else
            {dict, next}
          end

        width = if next == 1 <<< width and width < 12, do: width + 1, else: width

        decode_codes(
          reader,
          width,
          minimum,
          dict,
          next,
          entry,
          [entry | output],
          length,
          expected
        )
    end
  end

  defp code({bytes, buffer, available}, width) when available >= width do
    {buffer &&& (1 <<< width) - 1, {bytes, buffer >>> width, available - width}}
  end

  defp code({<<byte, rest::binary>>, buffer, available}, width),
    do: code({rest, buffer ||| byte <<< available, available + 8}, width)

  defp code(_, _), do: Error.fail()
end
