defmodule TeslaApi.Auth.Refresh do
  @moduledoc false
  defdelegate refresh(auth), to: TeslaApi.Auth
end
