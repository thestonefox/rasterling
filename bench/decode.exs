# Run with mix run bench/decode.exs [iterations] [image ...]
[iterations | paths] =
  case System.argv() do
    [] -> ["9"]
    args -> args
  end

iterations = String.to_integer(iterations)
if iterations < 1, do: raise(ArgumentError, "iterations must be positive")
paths = if paths == [], do: Path.wildcard("test/fixtures/*.jpg"), else: paths
IO.puts("Elixir #{System.version()}, OTP #{System.otp_release()}; #{iterations} samples")

for path <- paths do
  bytes = File.read!(path)
  expected = Rasterling.decode!(bytes)
  for _ <- 1..2, do: Rasterling.decode!(bytes)

  times =
    for _ <- 1..iterations do
      {us, image} = :timer.tc(fn -> Rasterling.decode!(bytes) end)
      if image != expected, do: raise("inconsistent pixels")
      us / 1000
    end
    |> Enum.sort()

  n = length(times)
  median = (Enum.at(times, div(n - 1, 2)) + Enum.at(times, div(n, 2))) / 2
  p95 = Enum.at(times, ceil(n * 0.95) - 1)
  hash = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  IO.puts(
    "#{Path.basename(path)} median=#{Float.round(median, 3)}ms p95=#{Float.round(p95, 3)}ms sha256=#{hash}"
  )
end
