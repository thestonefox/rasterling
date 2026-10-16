defmodule Rasterling.PNG do
  @moduledoc false
  import Bitwise
  alias Rasterling.{Error, Limits}
  @signature <<137, "PNG", 13, 10, 26, 10>>
  @passes [
    {0, 0, 8, 8},
    {4, 0, 8, 8},
    {0, 4, 4, 8},
    {2, 0, 4, 4},
    {0, 2, 2, 4},
    {1, 0, 2, 2},
    {0, 1, 1, 2}
  ]

  def decode(<<@signature, rest::binary>>, limits) do
    {header, rest} = chunk(rest)
    {"IHDR", <<w::32, h::32, depth, color, 0, 0, interlace>>} = header
    Limits.dimensions!(w, h, limits)
    Limits.require!(interlace in [0, 1])

    valid =
      case color do
        0 -> depth in [1, 2, 4, 8, 16]
        2 -> depth in [8, 16]
        3 -> depth in [1, 2, 4, 8]
        4 -> depth in [8, 16]
        6 -> depth in [8, 16]
        _ -> false
      end

    Limits.require!(valid)
    channels = %{0 => 1, 2 => 3, 3 => 1, 4 => 2, 6 => 4}[color]

    state = %{
      w: w,
      h: h,
      depth: depth,
      color: color,
      channels: channels,
      palette: nil,
      transparent: nil,
      idat: [],
      phase: :before,
      seen_trns: false
    }

    state = chunks(rest, state)
    if color == 3, do: Limits.require!(is_tuple(state.palette))
    passes = if interlace == 0, do: [{0, 0, 1, 1}], else: @passes

    passes =
      Enum.map(passes, fn {x, y, dx, dy} ->
        pw = if x < w, do: Limits.ceil_div(w - x, dx), else: 0
        ph = if y < h, do: Limits.ceil_div(h - y, dy), else: 0
        {x, y, dx, dy, pw, ph}
      end)
      |> Enum.filter(fn {_, _, _, _, pw, ph} -> pw > 0 and ph > 0 end)

    expected =
      Enum.reduce(passes, 0, fn {_, _, _, _, pw, ph}, n ->
        n + (1 + Limits.ceil_div(pw * channels * depth, 8)) * ph
      end)

    inflated = inflate(IO.iodata_to_binary(Enum.reverse(state.idat)), expected)

    {<<>>, rows} =
      Enum.reduce(passes, {inflated, %{}}, fn pass, {bytes, rows} ->
        pass(bytes, pass, state, rows)
      end)

    pixels =
      if interlace == 0 do
        for y <- 0..(h - 1), into: <<>>, do: Map.fetch!(rows, y)
      else
        for y <- 0..(h - 1), x <- 0..(w - 1), into: <<>>, do: Map.fetch!(rows, {x, y})
      end

    Limits.image!(w, h, pixels, :png)
  end

  def decode(_, _), do: Error.fail()

  defp chunk(
         <<length::32, type::binary-size(4), data::binary-size(length), crc::32, rest::binary>>
       ) do
    Limits.require!(:erlang.crc32([type, data]) == crc)
    Limits.require!(Enum.all?(:binary.bin_to_list(type), &(&1 in ?A..?Z or &1 in ?a..?z)))
    Limits.require!((:binary.at(type, 2) &&& 32) == 0)
    {{type, data}, rest}
  end

  defp chunk(_), do: Error.fail()

  defp chunks(bytes, state) do
    {{type, data}, rest} = chunk(bytes)

    case type do
      "IEND" ->
        Limits.require!(data == <<>> and rest == <<>> and state.idat != [])
        state

      "IDAT" ->
        Limits.require!(state.phase != :after)
        if state.color == 3, do: Limits.require!(state.palette != nil)
        chunks(rest, %{state | idat: [data | state.idat], phase: :during})

      "IHDR" ->
        Error.fail()

      "PLTE" ->
        Limits.require!(
          state.palette == nil and state.phase == :before and state.color not in [0, 4]
        )

        count = div(byte_size(data), 3)
        Limits.require!(byte_size(data) == count * 3 and count in 1..256)
        if state.color == 3, do: Limits.require!(count <= 1 <<< state.depth)
        palette = for(<<r, g, b <- data>>, do: {r, g, b}) |> List.to_tuple()
        chunks(rest, %{state | palette: palette})

      "tRNS" ->
        Limits.require!(not state.seen_trns and state.phase == :before)

        transparent =
          case {state.color, data} do
            {0, <<gray::16>>} ->
              Limits.require!(gray < 1 <<< state.depth)
              {:gray, gray}

            {2, <<r::16, g::16, b::16>>} ->
              Limits.require!(Enum.all?([r, g, b], &(&1 < 1 <<< state.depth)))
              {:rgb, r, g, b}

            {3, alpha} ->
              Limits.require!(
                state.palette != nil and byte_size(alpha) > 0 and
                  byte_size(alpha) <= tuple_size(state.palette)
              )

              {:palette, alpha}

            _ ->
              Error.fail()
          end

        chunks(rest, %{state | transparent: transparent, seen_trns: true})

      "acTL" ->
        Error.fail(:unsupported_feature)

      _ ->
        if (:binary.at(type, 0) &&& 32) == 0, do: Error.fail(:unsupported_feature)
        phase = if state.phase == :during, do: :after, else: state.phase
        chunks(rest, %{state | phase: phase})
    end
  end

  defp inflate(compressed, expected) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z)
      output = inflate_parts(z, compressed, expected, 0, [])
      :ok = :zlib.inflateEnd(z)
      Limits.require!(byte_size(output) == expected)
      output
    after
      :zlib.close(z)
    end
  end

  defp inflate_parts(z, input, limit, size, acc) do
    {status, output} = :zlib.safeInflate(z, input)
    size = size + IO.iodata_length(output)
    if size > limit, do: Error.fail(:too_large)

    case status do
      :continue -> inflate_parts(z, <<>>, limit, size, [output | acc])
      :finished -> IO.iodata_to_binary(Enum.reverse([output | acc]))
    end
  end

  defp pass(bytes, {sx, sy, dx, dy, w, h}, state, output) do
    length = Limits.ceil_div(w * state.channels * state.depth, 8)
    bpp = max(1, Limits.ceil_div(state.channels * state.depth, 8))

    {_previous, bytes, output} =
      Enum.reduce(0..(h - 1), {:binary.copy(<<0>>, length), bytes, output}, fn y,
                                                                               {previous, bytes,
                                                                                output} ->
        <<filter, bytes::binary>> = bytes
        row = binary_part(bytes, 0, length)
        rest = binary_part(bytes, length, byte_size(bytes) - length)
        row = unfilter(row, previous, bpp, filter)
        rgba = pixels(row, w, state)

        output =
          if dx == 1 and dy == 1 do
            Map.put(output, y, rgba)
          else
            Enum.reduce(0..(w - 1), output, fn x, acc ->
              Map.put(acc, {sx + x * dx, sy + y * dy}, binary_part(rgba, x * 4, 4))
            end)
          end

        {row, rest, output}
      end)

    {bytes, output}
  end

  defp unfilter(bytes, _previous, _bpp, 0), do: bytes

  defp unfilter(bytes, previous, bpp, filter) when filter in 1..4 do
    {_, output} =
      Enum.reduce(0..(byte_size(bytes) - 1), {:array.new(byte_size(bytes), default: 0), []}, fn i,
                                                                                                {row,
                                                                                                 acc} ->
        left = if i >= bpp, do: :array.get(i - bpp, row), else: 0
        up = :binary.at(previous, i)
        corner = if i >= bpp, do: :binary.at(previous, i - bpp), else: 0

        prediction =
          case filter do
            1 -> left
            2 -> up
            3 -> div(left + up, 2)
            4 -> paeth(left, up, corner)
          end

        value = :binary.at(bytes, i) + prediction &&& 255
        {:array.set(i, value, row), [value | acc]}
      end)

    output |> Enum.reverse() |> :binary.list_to_bin()
  end

  defp unfilter(_, _, _, _), do: Error.fail()

  defp paeth(a, b, c) do
    p = a + b - c
    pa = abs(p - a)
    pb = abs(p - b)
    pc = abs(p - c)

    cond do
      pa <= pb and pa <= pc -> a
      pb <= pc -> b
      true -> c
    end
  end

  defp pixels(row, width, state) do
    for x <- 0..(width - 1), into: <<>> do
      samples =
        for c <- 0..(state.channels - 1) do
          index = x * state.channels + c

          case state.depth do
            16 ->
              :binary.decode_unsigned(binary_part(row, index * 2, 2))

            8 ->
              :binary.at(row, index)

            depth ->
              :binary.at(row, div(index * depth, 8)) >>> (8 - depth - rem(index * depth, 8)) &&&
                (1 <<< depth) - 1
          end
        end

      rgba(samples, state)
    end
  end

  defp scale(n, 16), do: n >>> 8
  defp scale(n, depth), do: div(n * 255, (1 <<< depth) - 1)

  defp rgba([gray], %{color: 0, depth: depth, transparent: transparent}) do
    value = scale(gray, depth)
    <<value, value, value, if(transparent == {:gray, gray}, do: 0, else: 255)>>
  end

  defp rgba([r, g, b], %{color: 2, depth: depth, transparent: transparent}),
    do:
      <<scale(r, depth), scale(g, depth), scale(b, depth),
        if(transparent == {:rgb, r, g, b}, do: 0, else: 255)>>

  defp rgba([index], %{color: 3, palette: palette, transparent: transparent}) do
    Limits.require!(index < tuple_size(palette))
    {r, g, b} = elem(palette, index)

    alpha =
      case transparent do
        {:palette, bytes} when index < byte_size(bytes) -> :binary.at(bytes, index)
        _ -> 255
      end

    <<r, g, b, alpha>>
  end

  defp rgba([gray, a], %{color: 4, depth: depth}) do
    value = scale(gray, depth)
    <<value, value, value, scale(a, depth)>>
  end

  defp rgba([r, g, b, a], %{color: 6, depth: depth}),
    do: <<scale(r, depth), scale(g, depth), scale(b, depth), scale(a, depth)>>
end
