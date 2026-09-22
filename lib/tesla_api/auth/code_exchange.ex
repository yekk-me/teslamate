defmodule TeslaApi.Auth.CodeExchange do
  @moduledoc false
  defdelegate exchange_code(code, opts \\ []), to: TeslaApi.Fleet
end
