defmodule TeslaApi.Stream do
  @moduledoc "Compatibility for logger stream messages. No Owner API connection is opened."
  def disconnect(pid), do: WebSockex.cast(pid, :disconnect)
end
