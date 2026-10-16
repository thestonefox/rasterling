defmodule Rasterling.JPEG do
  @moduledoc false
  import Bitwise
  alias Rasterling.{Error, Limits}

  @eoi 0xD9
  @soi 0xD8
  @dqt 0xDB
  @dht 0xC4
  @sof_baseline 0xC0
  @sof_extended 0xC1
  @sof_progressive 0xC2
  @dri 0xDD
  @app14 0xEE
  @sos 0xDA

  @zigzag {0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34,
           27, 20, 13, 6, 7, 14, 21, 28, 35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37,
           44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63}
  @zero List.to_tuple(List.duplicate(0, 64))
  @c1 :math.cos(1 * :math.pi() / 16)
  @c2 :math.cos(2 * :math.pi() / 16)
  @c3 :math.cos(3 * :math.pi() / 16)
  @c4 :math.cos(4 * :math.pi() / 16)
  @c5 :math.cos(5 * :math.pi() / 16)
  @c6 :math.cos(6 * :math.pi() / 16)
  @c7 :math.cos(7 * :math.pi() / 16)

  def decode(<<255, 216, rest::binary>>, limits) do
    state = %{
      frame: nil,
      quant: %{},
      huffman: %{},
      interval: 0,
      adobe: nil,
      scans: 0,
      progression: %{},
      limits: limits
    }

    state = segments(rest, state)
    frame = state.frame
    Limits.require!(frame != nil and state.scans > 0)
    for id <- frame.order, do: Limits.require!(Map.has_key?(state.progression, {id, 0}))

    planes =
      Map.new(frame.order, fn id ->
        c = frame.components[id]
        quant = Map.fetch!(state.quant, c.q)
        {id, plane(c, quant)}
      end)

    pixels =
      for y <- 0..(frame.h - 1), x <- 0..(frame.w - 1), into: <<>> do
        values =
          Enum.map(frame.order, fn id ->
            c = frame.components[id]
            sx = div(x * c.h, frame.max_h)
            sy = div(y * c.v, frame.max_v)
            row = elem(planes[id], sy)
            :binary.at(row, sx)
          end)

        rgb(values, state.adobe, frame.order)
      end

    Limits.image!(frame.w, frame.h, pixels, :jpeg)
  end

  def decode(_, _), do: Error.fail()

  defp marker(<<255, 255, rest::binary>>), do: marker(<<255, rest::binary>>)
  defp marker(<<255, value, rest::binary>>) when value != 0, do: {value, rest}
  defp marker(_), do: Error.fail()

  defp segments(bytes, state) do
    {marker, rest} = marker(bytes)

    case marker do
      @eoi ->
        Limits.require!(rest == <<>>)
        state

      @soi ->
        Error.fail()

      value when value in 0xD0..0xD7 ->
        Error.fail()

      _ ->
        <<length::16, payload::binary-size(length - 2), rest::binary>> = rest
        Limits.require!(length >= 2)

        state =
          case marker do
            @dqt ->
              quant(payload, state)

            @dht ->
              huffman(payload, state)

            value when value in [@sof_baseline, @sof_extended, @sof_progressive] ->
              frame(payload, state, value == @sof_progressive)

            @dri ->
              <<interval::16>> = payload
              %{state | interval: interval}

            @app14 ->
              adobe(payload, state)

            @sos ->
              state

            value
            when value in [0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF, 0xCC, 0xDC] ->
              Error.fail(:unsupported_feature)

            value when value in 0xE0..0xEF or value == 0xFE ->
              state

            _ ->
              Error.fail(:unsupported_feature)
          end

        if marker == @sos do
          {rest, state} = scan(payload, rest, state)
          segments(rest, state)
        else
          segments(rest, state)
        end
    end
  end

  defp adobe(<<"Adobe", _version::16, _flags::32, transform, _::binary>>, state)
       when transform in 0..2,
       do: %{state | adobe: transform}

  defp adobe(_, state), do: state

  defp quant(<<>>, state), do: state

  defp quant(<<precision::4, id::4, rest::binary>>, state) when precision in [0, 1] and id <= 3 do
    count = 64 * (precision + 1)
    raw = binary_part(rest, 0, count)
    values = if precision == 0, do: :binary.bin_to_list(raw), else: for(<<n::16 <- raw>>, do: n)
    Limits.require!(Enum.all?(values, &(&1 > 0)))

    table =
      values
      |> Enum.with_index()
      |> Enum.reduce(@zero, fn {value, i}, table -> put_elem(table, elem(@zigzag, i), value) end)

    quant(binary_part(rest, count, byte_size(rest) - count), %{
      state
      | quant: Map.put(state.quant, id, table)
    })
  end

  defp quant(_, _), do: Error.fail()

  defp huffman(<<>>, state), do: state

  defp huffman(<<class::4, id::4, counts::binary-size(16), rest::binary>>, state)
       when class in [0, 1] and id <= 3 do
    counts = :binary.bin_to_list(counts)
    count = Enum.sum(counts)
    Limits.require!(count > 0 and count <= 256)
    symbols = binary_part(rest, 0, count) |> :binary.bin_to_list()

    {table, _, []} =
      Enum.reduce(Enum.with_index(counts, 1), {%{}, 0, symbols}, fn {count, length},
                                                                    {table, code, symbols} ->
        Limits.require!(code + count < 1 <<< length)
        {values, symbols} = Enum.split(symbols, count)

        table =
          values
          |> Enum.with_index(code)
          |> Enum.reduce(table, fn {symbol, code}, table ->
            Map.put(table, {length, code}, symbol)
          end)

        {table, (code + count) <<< 1, symbols}
      end)

    huffman(binary_part(rest, count, byte_size(rest) - count), %{
      state
      | huffman: Map.put(state.huffman, {class, id}, table)
    })
  end

  defp huffman(_, _), do: Error.fail()

  defp frame(<<8, h::16, w::16, n, raw::binary>>, %{frame: nil} = state, progressive)
       when n in [1, 3, 4] do
    Limits.dimensions!(w, h, state.limits)
    Limits.require!(byte_size(raw) == n * 3)
    specs = for <<id, hor::4, ver::4, q <- raw>>, do: {id, hor, ver, q}
    Limits.require!(length(Enum.uniq_by(specs, &elem(&1, 0))) == n)

    Limits.require!(
      Enum.all?(specs, fn {_, hor, ver, q} -> hor in 1..4 and ver in 1..4 and q in 0..3 end)
    )

    Limits.require!(Enum.reduce(specs, 0, fn {_, hor, ver, _}, sum -> sum + hor * ver end) <= 10)
    max_h = specs |> Enum.map(&elem(&1, 1)) |> Enum.max()
    max_v = specs |> Enum.map(&elem(&1, 2)) |> Enum.max()
    cols = Limits.ceil_div(w, 8 * max_h)
    rows = Limits.ceil_div(h, 8 * max_v)

    components =
      Map.new(specs, fn {id, hor, ver, q} ->
        bw = Limits.ceil_div(w * hor, 8 * max_h)
        bh = Limits.ceil_div(h * ver, 8 * max_v)

        {id,
         %{
           id: id,
           h: hor,
           v: ver,
           q: q,
           bw: bw,
           bh: bh,
           stride: cols * hor,
           blocks: :array.new(cols * rows * hor * ver, default: @zero)
         }}
      end)

    frame = %{
      w: w,
      h: h,
      max_h: max_h,
      max_v: max_v,
      cols: cols,
      rows: rows,
      progressive: progressive,
      order: Enum.map(specs, &elem(&1, 0)),
      components: components
    }

    %{state | frame: frame}
  end

  defp frame(_, _, _), do: Error.fail(:unsupported_feature)

  defp scan(<<n, raw::binary-size(n * 2), ss, se, ah::4, al::4>>, bytes, state) when n in 1..4 do
    Limits.require!(state.frame != nil and state.scans < 256)
    ids = for <<id, dc::4, ac::4 <- raw>>, do: {id, dc, ac}
    Limits.require!(Enum.uniq_by(ids, &elem(&1, 0)) == ids)

    Limits.require!(
      Enum.all?(ids, fn {id, dc, ac} ->
        Map.has_key?(state.frame.components, id) and dc <= 3 and ac <= 3
      end)
    )

    progressive = state.frame.progressive
    Limits.require!(al <= 13 and ah <= 13)

    if progressive do
      Limits.require!((ss == 0 and se == 0) or (n == 1 and ss > 0 and ss <= se and se <= 63))
      Limits.require!(ah == 0 or ah == al + 1)
    else
      Limits.require!(ss == 0 and se == 63 and ah == 0 and al == 0)
    end

    progression =
      Enum.reduce(ids, state.progression, fn {id, _, _}, progression ->
        Enum.reduce(ss..se, progression, fn coefficient, progression ->
          previous = Map.get(progression, {id, coefficient})
          Limits.require!(if ah == 0, do: previous == nil, else: previous == ah)
          Map.put(progression, {id, coefficient}, al)
        end)
      end)

    components =
      Enum.map(ids, fn {id, dc, ac} ->
        if ss == 0 and ah == 0, do: Limits.require!(Map.has_key?(state.huffman, {0, dc}))
        if se > 0, do: Limits.require!(Map.has_key?(state.huffman, {1, ac}))
        Limits.require!(Map.has_key?(state.quant, state.frame.components[id].q))
        {id, Map.get(state.huffman, {0, dc}), Map.get(state.huffman, {1, ac})}
      end)

    [first | _] = components
    component = state.frame.components[elem(first, 0)]
    total = if n == 1, do: component.bw * component.bh, else: state.frame.cols * state.frame.rows

    context = %{
      reader: {bytes, 0, 0},
      pred: Map.new(ids, fn {id, _, _} -> {id, 0} end),
      eob: 0,
      components: state.frame.components,
      ss: ss,
      se: se,
      ah: ah,
      al: al,
      progressive: progressive
    }

    context =
      Enum.reduce(0..(total - 1), context, fn mcu, ctx ->
        ctx =
          if state.interval > 0 and mcu > 0 and rem(mcu, state.interval) == 0 do
            {bytes, _, _} = ctx.reader
            {restart, rest} = marker(bytes)

            Limits.require!(
              restart == 0xD0 + rem(div(mcu, state.interval) - 1, 8) and ctx.eob == 0
            )

            %{
              ctx
              | reader: {rest, 0, 0},
                pred: Map.new(ids, fn {id, _, _} -> {id, 0} end),
                eob: 0
            }
          else
            ctx
          end

        Enum.reduce(components, ctx, fn {id, dc, ac}, ctx ->
          c = ctx.components[id]

          locations =
            if n == 1 do
              [div(mcu, c.bw) * c.stride + rem(mcu, c.bw)]
            else
              for v <- 0..(c.v - 1),
                  h <- 0..(c.h - 1),
                  do:
                    (div(mcu, state.frame.cols) * c.v + v) * c.stride +
                      rem(mcu, state.frame.cols) * c.h + h
            end

          Enum.reduce(locations, ctx, fn index, ctx ->
            c = ctx.components[id]
            block = :array.get(index, c.blocks)
            {block, ctx} = block(block, id, dc, ac, ctx)
            c = %{c | blocks: :array.set(index, block, c.blocks)}
            %{ctx | components: Map.put(ctx.components, id, c)}
          end)
        end)
      end)

    Limits.require!(context.eob == 0)
    {rest, _, _} = context.reader

    {rest,
     %{
       state
       | frame: %{state.frame | components: context.components},
         scans: state.scans + 1,
         progression: progression
     }}
  end

  defp scan(_, _, _), do: Error.fail()

  defp bits(reader, 0), do: {0, reader}

  defp bits({bytes, buffer, available}, count) when available >= count do
    {buffer >>> (available - count) &&& (1 <<< count) - 1,
     {bytes, buffer &&& (1 <<< (available - count)) - 1, available - count}}
  end

  defp bits({<<255, 0, rest::binary>>, buffer, available}, count),
    do: bits({rest, buffer <<< 8 ||| 255, available + 8}, count)

  defp bits({<<byte, rest::binary>>, buffer, available}, count) when byte != 255,
    do: bits({rest, buffer <<< 8 ||| byte, available + 8}, count)

  defp bits(_, _), do: Error.fail()
  defp symbol(reader, table), do: symbol(reader, table, 0, 1)

  defp symbol(reader, table, code, length) when length <= 16 do
    {bit, reader} = bits(reader, 1)
    code = code <<< 1 ||| bit

    case Map.fetch(table, {length, code}) do
      {:ok, value} -> {value, reader}
      :error -> symbol(reader, table, code, length + 1)
    end
  end

  defp symbol(_, _, _, _), do: Error.fail()
  defp signed(reader, 0), do: {0, reader}

  defp signed(reader, count) when count in 1..11 do
    {value, reader} = bits(reader, count)
    {if(value < 1 <<< (count - 1), do: value - (1 <<< count) + 1, else: value), reader}
  end

  defp signed(_, _), do: Error.fail()

  defp block(block, id, dc, ac, %{progressive: false} = ctx) do
    {count, reader} = symbol(ctx.reader, dc)
    {diff, reader} = signed(reader, count)
    pred = ctx.pred[id] + diff
    Limits.require!(abs(pred) <= 2048)
    ctx = %{ctx | reader: reader, pred: Map.put(ctx.pred, id, pred)}
    ac_first(put_elem(block, 0, pred), 1, 63, ac, ctx)
  end

  defp block(block, id, dc, _ac, %{ss: 0, ah: 0} = ctx) do
    {count, reader} = symbol(ctx.reader, dc)
    {diff, reader} = signed(reader, count)
    pred = ctx.pred[id] + diff
    Limits.require!(abs(pred) <= 2048)

    {put_elem(block, 0, pred <<< ctx.al),
     %{ctx | reader: reader, pred: Map.put(ctx.pred, id, pred)}}
  end

  defp block(block, _id, _dc, _ac, %{ss: 0} = ctx) do
    {bit, reader} = bits(ctx.reader, 1)
    {put_elem(block, 0, elem(block, 0) ||| bit <<< ctx.al), %{ctx | reader: reader}}
  end

  defp block(block, _id, _dc, ac, %{ah: 0} = ctx) do
    if ctx.eob > 0,
      do: {block, %{ctx | eob: ctx.eob - 1}},
      else: ac_first(block, ctx.ss, ctx.se, ac, ctx)
  end

  defp block(block, _id, _dc, ac, ctx) do
    if ctx.eob > 0 do
      {block, ctx} = refine_existing(block, ctx.ss, ctx.se, ctx)
      {block, %{ctx | eob: ctx.eob - 1}}
    else
      ac_refine(block, ctx.ss, ctx.se, ac, ctx)
    end
  end

  defp ac_first(block, k, last, _table, ctx) when k > last, do: {block, ctx}

  defp ac_first(block, k, last, table, ctx) do
    {rs, reader} = symbol(ctx.reader, table)
    run = rs >>> 4
    size = rs &&& 15

    cond do
      size == 0 and run < 15 ->
        if ctx.progressive do
          {extra, reader} = bits(reader, run)
          {block, %{ctx | reader: reader, eob: (1 <<< run) + extra - 1}}
        else
          Limits.require!(run == 0)
          {block, %{ctx | reader: reader}}
        end

      size == 0 ->
        Limits.require!(k + 16 <= last + 1)
        ac_first(block, k + 16, last, table, %{ctx | reader: reader})

      true ->
        Limits.require!(k + run <= last and size <= 10)
        {value, reader} = signed(reader, size)
        block = put_elem(block, elem(@zigzag, k + run), value <<< ctx.al)
        ac_first(block, k + run + 1, last, table, %{ctx | reader: reader})
    end
  end

  defp refine_existing(block, k, last, ctx) when k > last, do: {block, ctx}

  defp refine_existing(block, k, last, ctx) do
    {block, ctx} = refine_at(block, elem(@zigzag, k), ctx)
    refine_existing(block, k + 1, last, ctx)
  end

  defp refine_at(block, index, ctx) do
    value = elem(block, index)

    if value == 0 do
      {block, ctx}
    else
      {bit, reader} = bits(ctx.reader, 1)
      delta = if value < 0, do: -(bit <<< ctx.al), else: bit <<< ctx.al
      {put_elem(block, index, value + delta), %{ctx | reader: reader}}
    end
  end

  defp ac_refine(block, k, last, _table, ctx) when k > last, do: {block, ctx}

  defp ac_refine(block, k, last, table, ctx) do
    {rs, reader} = symbol(ctx.reader, table)
    run = rs >>> 4
    size = rs &&& 15
    ctx = %{ctx | reader: reader}

    cond do
      size == 0 and run < 15 ->
        {extra, reader} = bits(ctx.reader, run)
        {block, ctx} = refine_existing(block, k, last, %{ctx | reader: reader})
        {block, %{ctx | eob: (1 <<< run) + extra - 1}}

      size == 0 ->
        {block, k, ctx} = skip_zeros(block, k, last, 16, ctx)
        ac_refine(block, k, last, table, ctx)

      size == 1 ->
        {sign, reader} = bits(ctx.reader, 1)
        {block, k, ctx} = skip_zeros(block, k, last, run, %{ctx | reader: reader})

        {block, k, ctx} =
          insert_ac(block, k, last, if(sign == 0, do: -1, else: 1) <<< ctx.al, ctx)

        ac_refine(block, k, last, table, ctx)

      true ->
        Error.fail()
    end
  end

  defp skip_zeros(block, k, _last, 0, ctx), do: {block, k, ctx}

  defp skip_zeros(block, k, last, n, ctx) when k <= last do
    index = elem(@zigzag, k)
    {block, ctx} = refine_at(block, index, ctx)
    skip_zeros(block, k + 1, last, if(elem(block, index) == 0, do: n - 1, else: n), ctx)
  end

  defp skip_zeros(_, _, _, _, _), do: Error.fail()

  defp insert_ac(block, k, last, value, ctx) when k <= last do
    index = elem(@zigzag, k)

    if elem(block, index) == 0 do
      {put_elem(block, index, value), k + 1, ctx}
    else
      {block, ctx} = refine_at(block, index, ctx)
      insert_ac(block, k + 1, last, value, ctx)
    end
  end

  defp insert_ac(_, _, _, _, _), do: Error.fail()

  defp plane(c, quant) do
    for by <- 0..(c.bh - 1) do
      blocks =
        for bx <- 0..(c.bw - 1), do: inverse(:array.get(by * c.stride + bx, c.blocks), quant)

      for y <- 0..7 do
        Enum.map(blocks, &binary_part(&1, y * 8, 8)) |> IO.iodata_to_binary()
      end
    end
    |> List.flatten()
    |> List.to_tuple()
  end

  defp inverse(block, quant) do
    if Enum.all?(1..63, &(elem(block, &1) == 0)) do
      :binary.copy(<<Limits.clamp(elem(block, 0) * elem(quant, 0) / 8 + 128)>>, 64)
    else
      rows =
        for v <- 0..7 do
          for u <- 0..7 do
            elem(block, v * 8 + u) * elem(quant, v * 8 + u)
          end
          |> List.to_tuple()
          |> inverse_line()
        end
        |> List.to_tuple()

      columns =
        for x <- 0..7 do
          for v <- 0..7, do: elem(elem(rows, v), x)
        end
        |> Enum.map(&inverse_line(List.to_tuple(&1)))
        |> List.to_tuple()

      for y <- 0..7, x <- 0..7, into: <<>> do
        <<Limits.clamp(elem(elem(columns, x), y) / 4 + 128)>>
      end
    end
  end

  # Factor the cosine matrix into even/odd butterflies. Apply this independently
  # to rows and columns; normalization stays in inverse/2. Constants are floats
  # to retain rounding accuracy without large fixed-point intermediates.
  defp inverse_line({b0, b1, b2, b3, b4, b5, b6, b7}) do
    a = @c4 * (b0 + b4)
    b = @c4 * (b0 - b4)
    c = @c2 * b2 + @c6 * b6
    d = @c6 * b2 - @c2 * b6
    e0 = a + c
    e3 = a - c
    e1 = b + d
    e2 = b - d
    u0 = @c1 * b1 + @c7 * b7
    v0 = @c7 * b1 - @c1 * b7
    u1 = @c3 * b3 + @c5 * b5
    v1 = @c5 * b3 - @c3 * b5
    o0 = u0 + u1
    o3 = v0 - v1
    o1 = @c4 * (u0 + v0 - u1 + v1)
    o2 = @c4 * (u0 - v0 - u1 - v1)
    {e0 + o0, e1 + o1, e2 + o2, e3 + o3, e3 - o3, e2 - o2, e1 - o1, e0 - o0}
  end

  defp ycbcr(y, cb, cr),
    do:
      {Limits.clamp(y + 1.402 * (cr - 128)),
       Limits.clamp(y - 0.344136 * (cb - 128) - 0.714136 * (cr - 128)),
       Limits.clamp(y + 1.772 * (cb - 128))}

  defp rgb([gray], _, _), do: <<gray, gray, gray, 255>>
  defp rgb([r, g, b], 0, _), do: <<r, g, b, 255>>
  defp rgb([r, g, b], _, [?R, ?G, ?B]), do: <<r, g, b, 255>>

  defp rgb([y, cb, cr], _, _) do
    {r, g, b} = ycbcr(y, cb, cr)
    <<r, g, b, 255>>
  end

  defp rgb([y, cb, cr, k], 2, _) do
    {r, g, b} = ycbcr(y, cb, cr)

    <<Limits.clamp((255 - r) * k / 255), Limits.clamp((255 - g) * k / 255),
      Limits.clamp((255 - b) * k / 255), 255>>
  end

  defp rgb([c, m, y, k], 0, _),
    do: <<Limits.clamp(c * k / 255), Limits.clamp(m * k / 255), Limits.clamp(y * k / 255), 255>>

  defp rgb([c, m, y, k], _, _),
    do:
      <<Limits.clamp((255 - c) * (255 - k) / 255), Limits.clamp((255 - m) * (255 - k) / 255),
        Limits.clamp((255 - y) * (255 - k) / 255), 255>>
end
