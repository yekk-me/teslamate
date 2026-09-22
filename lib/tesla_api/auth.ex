defmodule TeslaApi.Auth do
  @moduledoc "China Fleet credentials. Owner API credentials must be reauthorized."
  @derive {Inspect, except: [:token, :refresh_token]}
  defstruct [:token, :type, :expires_in, :refresh_token, :created_at, provider: "fleet_cn"]

  defdelegate exchange_code(code, opts \\ []), to: TeslaApi.Fleet
  def refresh(%__MODULE__{provider: "fleet_cn"} = auth), do: TeslaApi.Fleet.refresh(auth)
  def refresh(_), do: {:error, :fleet_reauthorization_required}
end
