defmodule TeslaMateWeb.SignInLive.Index do
  use TeslaMateWeb, :live_view
  on_mount {TeslaMateWeb.InitAssigns, :locale}

  @impl true
  def mount(_params, _session, socket) do
    portal = System.get_env("TESLA_FLEET_PORTAL_URL")
    portal = if is_binary(portal) and match?(%URI{scheme: "https", host: host} when is_binary(host), URI.parse(portal)), do: portal
    {:ok, assign(socket, page_title: gettext("Sign in"), portal: portal)}
  end
end
