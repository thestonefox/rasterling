defmodule Rasterling do
  @moduledoc """
  Decodes PNG, baseline/progressive JPEG, the first GIF frame, and BMP on the BEAM.

  No third-party NIFs, executables, network requests or runtime dependencies.
  Standard OTP `:zlib` decompresses PNG data. Output is eight-bit RGBA.
  """
  alias Rasterling.Error

  @defaults [
    max_bytes: 10_000_000,
    max_pixels: 16_000_000,
    timeout: 10_000,
    max_memory_bytes: 268_435_456
  ]

  @doc """
  Decodes encoded bytes into `{:ok, image}` or `{:error, %Rasterling.Error{}}`.

  Options: `:max_bytes`, `:max_pixels`, `:timeout` (milliseconds) and
  `:max_memory_bytes` (worker heap budget). All must be positive integers.
  Large reference-counted binaries are bounded separately by byte/pixel limits;
  the worker heap budget is not a process RSS or VM-wide memory guarantee.
  """
  @spec decode(binary(), keyword()) :: {:ok, Rasterling.Image.t()} | {:error, Error.t()}
  def decode(bytes, opts \\ []) when is_binary(bytes) do
    limits = options!(opts)

    if byte_size(bytes) > limits.max_bytes do
      {:error, %Error{reason: :too_large, message: "Image exceeds the encoded byte limit"}}
    else
      worker(fn -> dispatch(bytes, limits) end, limits)
    end
  end

  @doc "Like `decode/2`, but raises `Rasterling.Error` on failure."
  def decode!(bytes, opts \\ []) do
    case decode(bytes, opts) do
      {:ok, image} -> image
      {:error, error} -> raise error
    end
  end

  @doc "Reads at most `:max_bytes + 1` bytes from a local file, then decodes them."
  def open(path, opts \\ []) do
    limits = options!(opts)

    worker(
      fn ->
        case File.stat(path) do
          {:ok, %{type: :regular, size: size}} when size <= limits.max_bytes -> :ok
          {:ok, %{type: :regular}} -> Error.fail(:too_large)
          _ -> Error.fail(:file_error)
        end

        case File.open(path, [:read, :binary]) do
          {:ok, file} ->
            try do
              case IO.binread(file, limits.max_bytes + 1) do
                bytes when is_binary(bytes) and byte_size(bytes) <= limits.max_bytes ->
                  dispatch(bytes, limits)

                bytes when is_binary(bytes) ->
                  Error.fail(:too_large)

                :eof ->
                  dispatch(<<>>, limits)

                _ ->
                  Error.fail(:file_error)
              end
            after
              File.close(file)
            end

          _ ->
            Error.fail(:file_error)
        end
      end,
      limits
    )
  end

  defp options!(opts) do
    unless Keyword.keyword?(opts), do: raise(ArgumentError, "expected keyword options")

    if Enum.any?(Keyword.keys(opts), &(&1 not in Keyword.keys(@defaults))),
      do: raise(ArgumentError, "unknown decoding option")

    Map.new(@defaults, fn {key, default} ->
      case Keyword.get(opts, key, default) do
        value when is_integer(value) and value > 0 -> {key, value}
        _ -> raise ArgumentError, "#{key} must be a positive integer"
      end
    end)
  end

  defp worker(fun, limits) do
    caller = self()
    reference = make_ref()

    {pid, monitor} =
      :erlang.spawn_opt(
        fn ->
          watch_caller(caller, self())

          result =
            try do
              {:ok, fun.()}
            rescue
              error in Error ->
                {:error, error}

              _ ->
                {:error,
                 %Error{reason: :invalid_image, message: "Image data is invalid or truncated"}}
            catch
              _, _ ->
                {:error,
                 %Error{reason: :invalid_image, message: "Image data is invalid or truncated"}}
            end

          send(caller, {reference, result})
        end,
        [
          :monitor,
          {:max_heap_size,
           %{
             size: max(1024, div(limits.max_memory_bytes, :erlang.system_info(:wordsize))),
             kill: true,
             error_logger: false
           }}
        ]
      )

    receive do
      {^reference, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, _} ->
        {:error,
         %Error{
           reason: :resource_limit,
           message: "Image decoding exceeded the worker memory limit"
         }}
    after
      limits.timeout ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^pid, _} -> :ok
        end

        receive do
          {^reference, _} -> :ok
        after
          0 -> :ok
        end

        {:error, %Error{reason: :timeout, message: "Image decoding exceeded the time limit"}}
    end
  end

  # The API caller may itself be a task terminated by an application's timeout.
  # Its receive timeout cannot clean up the decoder once that caller has died.
  defp watch_caller(caller, worker) do
    spawn(fn ->
      caller_monitor = Process.monitor(caller)
      worker_monitor = Process.monitor(worker)

      receive do
        {:DOWN, ^caller_monitor, :process, ^caller, _} ->
          Process.exit(worker, :kill)

        {:DOWN, ^worker_monitor, :process, ^worker, _} ->
          :ok
      end
    end)
  end

  defp dispatch(<<137, "PNG", 13, 10, 26, 10, _::binary>> = bytes, limits),
    do: Rasterling.PNG.decode(bytes, limits)

  defp dispatch(<<255, 216, _::binary>> = bytes, limits),
    do: Rasterling.JPEG.decode(bytes, limits)

  defp dispatch(<<"GIF", _::binary>> = bytes, limits), do: Rasterling.GIF.decode(bytes, limits)
  defp dispatch(<<"BM", _::binary>> = bytes, limits), do: Rasterling.BMP.decode(bytes, limits)
  defp dispatch(_, _), do: Error.fail(:unsupported_format)
end
