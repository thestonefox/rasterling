defmodule Rasterling.Error do
  @moduledoc "A decoding failure with a stable reason and a safe message."
  defexception [:reason, :message]
  @type t :: %__MODULE__{reason: atom(), message: String.t()}

  @doc false
  def fail(reason \\ :invalid_image) do
    message =
      case reason do
        :too_large -> "Image exceeds a configured resource limit"
        :unsupported_format -> "Expected a PNG, JPEG, GIF or BMP image"
        :unsupported_feature -> "Image uses an unsupported encoding feature"
        :timeout -> "Image decoding exceeded the time limit"
        :resource_limit -> "Image decoding exceeded the worker memory limit"
        :file_error -> "Image file could not be read"
        _ -> "Image data is invalid or truncated"
      end

    raise __MODULE__, reason: reason, message: message
  end
end
