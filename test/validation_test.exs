defmodule Rasterling.ValidationTest do
  use ExUnit.Case, async: true
  import Bitwise
  alias Rasterling.{Error, Image}
  @png <<137, "PNG", 13, 10, 26, 10>>
  defp chunk(type, data),
    do: <<byte_size(data)::32, type::binary, data::binary, :erlang.crc32([type, data])::32>>

  defp png(width, height, depth, color, raw, extra \\ []) do
    @png <>
      chunk("IHDR", <<width::32, height::32, depth, color, 0, 0, 0>>) <>
      IO.iodata_to_binary(extra) <> chunk("IDAT", :zlib.compress(raw)) <> chunk("IEND", <<>>)
  end

  defp bmp(bits, pixels, compression \\ 0, masks \\ <<>>, height \\ 1) do
    offset = 54 + byte_size(masks)

    <<"BM", offset + byte_size(pixels)::little-32, 0::32, offset::little-32, 40::little-32,
      1::little-signed-32, height::little-signed-32, 1::little-16, bits::little-16,
      compression::little-32, byte_size(pixels)::little-32, 0::96, 0::32, masks::binary,
      pixels::binary>>
  end

  test "PNG grayscale packed bit depths and tRNS preserve raw sample semantics" do
    for depth <- [1, 2, 4] do
      maximum = (1 <<< depth) - 1
      row = <<0::size(depth), maximum::size(depth), 0::size(8 - depth * 2)>>
      bytes = png(2, 1, depth, 0, <<0, row::binary>>, [chunk("tRNS", <<0::16>>)])
      assert {:ok, image} = Rasterling.decode(bytes)
      assert image.pixels == <<0, 0, 0, 0, 255, 255, 255, 255>>
    end
  end

  test "PNG RGB transparency and palette alpha are distinct" do
    assert {:ok, image} =
             Rasterling.decode(
               png(2, 1, 8, 2, <<0, 3, 7, 9, 1, 2, 3>>, [chunk("tRNS", <<3::16, 7::16, 9::16>>)])
             )

    assert image.pixels == <<3, 7, 9, 0, 1, 2, 3, 255>>
    extra = [chunk("PLTE", <<10, 20, 30, 40, 50, 60>>), chunk("tRNS", <<0, 128>>)]
    assert {:ok, image} = Rasterling.decode(png(2, 1, 1, 3, <<0, 0b01000000>>, extra))
    assert image.pixels == <<10, 20, 30, 0, 40, 50, 60, 128>>
  end

  test "all PNG filters reconstruct the preceding row and channels" do
    previous = [10, 20, 30, 40, 50, 60]
    desired = [15, 25, 35, 45, 55, 65]

    for filter <- 0..4 do
      encoded =
        for i <- 0..5 do
          a = if i >= 3, do: Enum.at(desired, i - 3), else: 0
          b = Enum.at(previous, i)
          c = if i >= 3, do: Enum.at(previous, i - 3), else: 0

          predictor =
            case filter do
              0 ->
                0

              1 ->
                a

              2 ->
                b

              3 ->
                div(a + b, 2)

              4 ->
                p = a + b - c

                [{abs(p - a), 0, a}, {abs(p - b), 1, b}, {abs(p - c), 2, c}]
                |> Enum.min()
                |> elem(2)
            end

          Enum.at(desired, i) - predictor &&& 255
        end
        |> :binary.list_to_bin()

      assert {:ok, image} =
               Rasterling.decode(
                 png(2, 2, 8, 2, <<0, 10, 20, 30, 40, 50, 60, filter, encoded::binary>>)
               )

      assert image.pixels ==
               <<10, 20, 30, 255, 40, 50, 60, 255, 15, 25, 35, 255, 45, 55, 65, 255>>
    end
  end

  test "bounded PNG inflation rejects expansion beyond scanline budget" do
    bytes = png(1, 1, 8, 6, :binary.copy(<<0>>, 1_000_000))
    assert {:error, %Error{reason: :too_large}} = Rasterling.decode(bytes)
  end

  test "PNG checks CRCs, unknown critical chunks, and chunk ordering" do
    valid = png(1, 1, 8, 2, <<0, 1, 2, 3>>)
    <<prefix::binary-size(29), byte, rest::binary>> = valid

    assert {:error, %Error{reason: :invalid_image}} =
             Rasterling.decode(<<prefix::binary, bxor(byte, 1), rest::binary>>)

    assert {:error, %Error{reason: :unsupported_feature}} =
             Rasterling.decode(png(1, 1, 8, 2, <<0, 1, 2, 3>>, [chunk("ABCD", <<>>)]))

    assert {:error, %Error{}} = Rasterling.decode(png(1, 1, 8, 3, <<0, 0>>))

    assert {:error, %Error{}} =
             Rasterling.decode(png(1, 1, 8, 2, <<0, 1, 2, 3>>, [chunk("IHDR", <<>>)]))

    assert {:error, %Error{reason: :unsupported_feature}} =
             Rasterling.decode(png(1, 1, 8, 2, <<0, 1, 2, 3>>, [chunk("acTL", <<1::32, 0::32>>)]))
  end

  test "BMP handles RGB555, top-down RGB, core headers and alpha bitfields" do
    assert {:ok, image} = Rasterling.decode(bmp(16, <<0x7C00::little-16, 0::16>>))
    assert image.pixels == <<255, 0, 0, 255>>
    assert {:ok, image} = Rasterling.decode(bmp(24, <<3, 2, 1, 0>>, 0, <<>>, -1))
    assert image.pixels == <<1, 2, 3, 255>>

    core =
      <<"BM", 30::little-32, 0::32, 26::little-32, 12::little-32, 1::little-16, 1::little-16,
        1::little-16, 24::little-16, 0, 0, 255, 0>>

    assert {:ok, image} = Rasterling.decode(core)
    assert image.pixels == <<255, 0, 0, 255>>
    masks = <<0xFF0000::little-32, 0xFF00::little-32, 0xFF::little-32, 0xFF000000::little-32>>
    assert {:ok, image} = Rasterling.decode(bmp(32, <<3, 2, 1, 128>>, 6, masks))
    assert image.pixels == <<1, 2, 3, 128>>
  end

  test "BMP rejects overlapping masks, palette overruns, RLE and bad offsets" do
    masks = <<0xFF::little-32, 0xFF::little-32, 0xFF0000::little-32>>
    assert {:error, %Error{}} = Rasterling.decode(bmp(32, <<0::32>>, 3, masks))
    assert {:error, %Error{}} = Rasterling.decode(bmp(8, <<0::32>>))

    assert {:error, %Error{reason: :unsupported_feature}} =
             Rasterling.decode(bmp(8, <<0::32>>, 1))

    bytes = bmp(24, <<1, 2, 3, 0>>)
    <<head::binary-size(10), _offset::32, tail::binary>> = bytes
    assert {:error, %Error{}} = Rasterling.decode(<<head::binary, 0::little-32, tail::binary>>)
  end

  test "GIF offsets, background and transparency use the logical canvas" do
    bytes =
      <<"GIF89a", 2::little-16, 2::little-16, 0x80, 0, 0, 255, 0, 0, 0, 0, 255, 0x21, 0xF9, 4, 1,
        0::16, 1, 0, 0x2C, 1::little-16, 1::little-16, 1::little-16, 1::little-16, 0, 2, 2, 0x4C,
        0x01, 0, 0x3B>>

    assert {:ok, image} = Rasterling.decode(bytes)
    assert image.pixels == <<0::96, 0, 0, 255, 0>>
  end

  test "encoded byte and decoded pixel limits apply to every format" do
    for name <- ~w(mountain-lake.png mountain-lake.jpg mountain-lake.gif mountain-lake.bmp) do
      bytes = File.read!(Path.join("test/fixtures", name))
      assert {:error, %Error{reason: :too_large}} = Rasterling.decode(bytes, max_bytes: 1)
      assert {:error, %Error{reason: :too_large}} = Rasterling.decode(bytes, max_pixels: 1)
    end
  end

  test "worker timeout and memory failure are errors without killing the caller" do
    bytes = File.read!("test/fixtures/grace-hopper.jpg")
    assert {:error, %Error{reason: :timeout}} = Rasterling.decode(bytes, timeout: 1)

    assert {:error, %Error{reason: :resource_limit}} =
             Rasterling.decode(bytes, max_memory_bytes: 8192)

    refute_receive {_, {:ok, _}}, 20
    assert Process.alive?(self())
  end

  test "all fixture prefixes are rejected rather than returned as partial images" do
    for path <- Path.wildcard("test/fixtures/*.{png,jpg,gif,bmp}"),
        bytes = File.read!(path),
        length <- Enum.uniq([0, 1, 2, 8, div(byte_size(bytes), 2), byte_size(bytes) - 1]) do
      assert {:error, %Error{}} = Rasterling.decode(binary_part(bytes, 0, length)),
             "Accepted truncated #{path} at #{length}"
    end
  end

  test "deterministic malformed corpus never leaks parser exceptions" do
    :rand.seed(:exsss, {31, 47, 59})

    for signature <- [@png, <<255, 216>>, "GIF89a", "BM"], _ <- 1..40 do
      bytes = for _ <- 1..256, into: <<>>, do: <<:rand.uniform(256) - 1>>

      assert {:error, %Error{}} =
               Rasterling.decode(signature <> bytes, max_pixels: 4096, timeout: 500)
    end
  end

  test "mutated real inputs stay bounded and return only the public result types" do
    :rand.seed(:exsss, {71, 83, 97})
    names = ~w(edge-rgb.png edge-p.png edge-rgb.gif edge-p.gif edge-rgba.bmp
               jpeg-rgb-2-progressive.jpg jpeg-cmyk-0-baseline.jpg jpeg-progressive-restart.jpg)

    for name <- names, _ <- 1..32 do
      bytes = File.read!(Path.join("test/fixtures", name))
      index = :rand.uniform(byte_size(bytes)) - 1
      prefix = binary_part(bytes, 0, index)
      <<value, rest::binary>> = binary_part(bytes, index, byte_size(bytes) - index)
      mutated = <<prefix::binary, bxor(value, 1 <<< (:rand.uniform(8) - 1)), rest::binary>>

      case Rasterling.decode(mutated,
             max_pixels: 4096,
             max_memory_bytes: 16_777_216,
             timeout: 1000
           ) do
        {:ok, %Image{} = image} ->
          assert image.width * image.height <= 4096
          assert byte_size(image.pixels) == image.width * image.height * 4

        {:error, %Error{}} ->
          :ok

        other ->
          flunk("Invalid decoder result: #{inspect(other)}")
      end
    end
  end

  test "options, bang decoding, pixel bounds and local files have explicit contracts" do
    bytes = png(1, 1, 8, 2, <<0, 1, 2, 3>>)
    assert %Image{} = image = Rasterling.decode!(bytes)
    assert Image.pixel(image, 0, 0) == {1, 2, 3, 255}
    assert_raise FunctionClauseError, fn -> Image.pixel(image, -1, 0) end
    assert_raise Error, fn -> Rasterling.decode!(<<>>) end

    for opts <- [
          [max_bytes: 0],
          [max_pixels: -1],
          [timeout: nil],
          [max_memory_bytes: 0],
          [unexpected: 1]
        ] do
      assert_raise ArgumentError, fn -> Rasterling.decode(bytes, opts) end
    end

    assert {:ok, %Image{}} = Rasterling.open("test/fixtures/mountain-lake.png")

    assert {:error, %Error{reason: :too_large}} =
             Rasterling.open("test/fixtures/mountain-lake.png", max_bytes: 2)

    assert {:error, %Error{reason: :file_error}} = Rasterling.open("test/fixtures/not-a-file")
    assert {:error, %Error{reason: :file_error}} = Rasterling.open("test/fixtures")
  end
end
