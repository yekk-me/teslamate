defmodule TeslaApi do
  use Tesla

  @version Mix.Project.config()[:version]

  adapter Tesla.Adapter.Finch, name: TeslaMate.HTTP, receive_timeout: 35_000

  plug Tesla.Middleware.BaseUrl, "https://fleet-api.prd.cn.vn.cloud.tesla.cn"
  plug Tesla.Middleware.Headers, [{"user-agent", "TeslaMate/#{@version}"}]
  plug Tesla.Middleware.JSON
  plug TeslaApi.Middleware.TokenAuth
end

