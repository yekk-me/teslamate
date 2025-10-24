defmodule TeslaMate.Locations.Geocoder do
  use Tesla, only: [:get]

  @version Mix.Project.config()[:version]

  adapter Tesla.Adapter.Finch, name: TeslaMate.HTTP, receive_timeout: 30_000

  plug Tesla.Middleware.BaseUrl, "https://nominatim-osm.mytesla.cc"
  plug Tesla.Middleware.Headers, [{"user-agent", "TeslaMate/#{@version}"}]
  plug Tesla.Middleware.JSON
  plug Tesla.Middleware.Logger, debug: true, log_level: &log_level/1

  alias TeslaMate.Locations.Address

  defp hash_coordinate(lat, lon) when is_float(lat) and is_float(lon) do
    lat_rounded = Float.round(lat, 6)
    lon_rounded = Float.round(lon, 6)
    :erlang.phash2({lat_rounded, lon_rounded}, 13_421_772_799)
  rescue
    _ -> :erlang.phash2({lat, lon})
  end

  def reverse_lookup(lat, lon, lang \\ "en") do
    # Check for Google Maps API key first
    google_api_key = System.get_env("GOOGLE_MAPS_API_KEY")
    trimmed_google_key = if google_api_key, do: String.trim(google_api_key), else: ""
    
    # Check for Baidu Maps API keys
    bd_map_ak = System.get_env("BD_MAP_AK")
    trimmed_ak = if bd_map_ak, do: String.trim(bd_map_ak), else: ""
    bd_map_sk = System.get_env("BD_MAP_SK")
    trimmed_sk = if bd_map_sk, do: String.trim(bd_map_sk), else: ""
    
    cond do
      # Prefer Google Maps if API key is available
      trimmed_google_key != "" ->
        with {:ok, address_raw} <- google_reverse_lookup(lat, lon, lang),
             {:ok, address} <- into_address_google(address_raw) do
          {:ok, address}
        end
        
      # Fall back to Baidu Maps if API keys are available
      trimmed_ak != "" && trimmed_sk != "" ->
        with {:ok, address_raw} <- baidu_reverse_lookup(lat, lon, lang),
            {:ok, address} <- into_address_baidu(address_raw) do
          {:ok, address}
        end
        
      # Default to OSM
      true ->
        opts = [
          format: :jsonv2,
          addressdetails: 1,
          extratags: 1,
          namedetails: 1,
          zoom: 19,
          lat: lat,
          lon: lon
        ]

        with {:ok, address_raw} <- query("/reverse", lang, opts),
             {:ok, address} <- into_address(address_raw) do
          {:ok, address}
        end
    end
  end

  def google_reverse_lookup(lat, lon, lang) do
    api_key = System.get_env("GOOGLE_MAPS_API_KEY")
    
    params = [
      latlng: "#{lat},#{lon}",
      key: api_key,
      language: lang
    ]
    
    headers = [
      {"Content-Type", "application/json"},
      {"X-Goog-Api-Key", api_key}
    ]
    
    url = "https://maps.googleapis.com/maps/api/geocode/json"
    
    case get(url, query: params, headers: headers) do
      {:ok, %Tesla.Env{status: 200, body: %{"status" => "OK"} = body}} -> 
        {:ok, body}
      {:ok, %Tesla.Env{status: 200, body: %{"status" => status}}} -> 
        {:error, {:google_api_error, status}}
      {:ok, %Tesla.Env{} = env} -> 
        {:error, reason: "Unexpected response", env: env}
      {:error, reason} -> 
        {:error, reason}
    end
  end

  def baidu_reverse_lookup(lat, lon, lang) do
    ak = System.get_env("BD_MAP_AK")
    sk = System.get_env("BD_MAP_SK")

    base_params = [
      ak: ak,
      extensions_poi: 1,
      entire_poi: 1,
      sort_strategy: "distance",
      output: :json,
      coordtype: :wgs84ll,
      location: "#{lat},#{lon}"
    ]

    {sorted_params, query_str} =
      base_params
      |> Enum.reject(fn {_, v} -> is_nil(v) end)
      |> Enum.map(fn {k, v} -> {to_string(k), to_string(v)} end)
      |> then(fn sorted ->
        query_str = Enum.map_join(sorted, "&", fn {k, v} -> "#{k}=#{v}" end)
        {sorted, query_str}
      end)

    uri_path = "/reverse_geocoding/v3"
    raw_str = "#{uri_path}?#{query_str}#{sk}"
    encoded_str = URI.encode_www_form(String.replace(raw_str, ",", "%2C"))
    sn = :crypto.hash(:md5, encoded_str) |> Base.encode16(case: :lower)

    final_params =
      sorted_params
      |> Enum.map(fn {k, v} -> {String.to_atom(k), v} end)
      |> Keyword.put(:sn, sn)

    url = "https://api.map.baidu.com/reverse_geocoding/v3"
    case get(url, query: final_params, headers: [{"Accept-Language", lang}]) do
      {:ok, %Tesla.Env{status: 200, body: body}} -> {:ok, body}
      {:ok, %Tesla.Env{body: %{"error" => reason}}} -> {:error, reason}
      {:ok, %Tesla.Env{} = env} -> {:error, reason: "Unexpected response", env: env}
      {:error, reason} -> {:error, reason}
    end
  end

  def details(addresses, lang) when is_list(addresses) do
    osm_ids =
      addresses
      |> Enum.reject(fn %Address{} = a -> a.osm_id == nil or a.osm_type in [nil, "unknown"] end)
      |> Enum.map(fn %Address{} = a ->
        "#{String.upcase(String.at(a.osm_type, 0))}#{a.osm_id}"
      end)
      |> Enum.join(",")

    params = [
      osm_ids: osm_ids,
      format: :jsonv2,
      addressdetails: 1,
      extratags: 1,
      namedetails: 1,
      zoom: 19
    ]

    with {:ok, raw_addresses} <- query("/lookup", lang, params) do
      addresses =
        Enum.map(raw_addresses, fn attrs ->
          case into_address(attrs) do
            {:ok, address} -> address
            {:error, reason} -> throw({:invalid_address, reason})
          end
        end)

      {:ok, addresses}
    end
  catch
    {:invalid_address, reason} ->
      {:error, reason}
  end

  defp query(url, lang, params) do
    case get(url, query: params, headers: [{"Accept-Language", lang}]) do
      {:ok, %Tesla.Env{status: 200, body: body}} -> {:ok, body}
      {:ok, %Tesla.Env{body: %{"error" => reason}}} -> {:error, reason}
      {:ok, %Tesla.Env{} = env} -> {:error, reason: "Unexpected response", env: env}
      {:error, reason} -> {:error, reason}
    end
  end

  # Address Formatting
  # Source: https://github.com/OpenCageData/address-formatting/blob/master/conf/components.yaml

  @road_aliases [
    "road",
    "footway",
    "street",
    "street_name",
    "residential",
    "path",
    "pedestrian",
    "road_reference",
    "road_reference_intl",
    "square",
    "place"
  ]

  @neighbourhood_aliases [
    "neighbourhood",
    "suburb",
    "city_district",
    "district",
    "quarter",
    "borough",
    "city_block",
    "residential",
    "commercial",
    "houses",
    "subdistrict",
    "subdivision",
    "ward"
  ]

  @municipality_aliases [
    "municipality",
    "local_administrative_area",
    "subcounty"
  ]

  @village_aliases [
    "village",
    "municipality",
    "hamlet",
    "locality",
    "croft"
  ]

  @city_aliases [
                  "city",
                  "town",
                  "township"
                ] ++ @village_aliases ++ @municipality_aliases

  @county_aliases [
    "county",
    "county_code",
    "department"
  ]

  defp into_address(%{"error" => "Unable to geocode"} = raw) do
    unknown_address = %{
      display_name: "Unknown",
      osm_type: "unknown",
      osm_id: 0,
      latitude: 0.0,
      longitude: 0.0,
      raw: raw
    }

    {:ok, unknown_address}
  end

  defp into_address(%{"error" => reason}) do
    {:error, {:geocoding_failed, reason}}
  end

  defp into_address(raw) do
    address = %{
      display_name: Map.get(raw, "display_name"),
      osm_id: Map.get(raw, "osm_id"),
      osm_type: Map.get(raw, "osm_type"),
      latitude: Map.get(raw, "lat"),
      longitude: Map.get(raw, "lon"),
      name:
        Map.get(raw, "name") || get_in(raw, ["namedetails", "name"]) ||
          get_in(raw, ["namedetails", "alt_name"]),
      house_number: raw["address"] |> get_first(["house_number", "street_number"]),
      road: raw["address"] |> get_first(@road_aliases),
      neighbourhood: raw["address"] |> get_first(@neighbourhood_aliases),
      city: raw["address"] |> get_first(@city_aliases),
      county: raw["address"] |> get_first(@county_aliases),
      postcode: get_in(raw, ["address", "postcode"]),
      state: raw["address"] |> get_first(["state", "province", "state_code"]),
      state_district: get_in(raw, ["address", "state_district"]),
      country: raw["address"] |> get_first(["country", "country_name"]),
      raw: raw
    }

    {:ok, address}
  end

  defp get_first(nil, _aliases), do: nil
  defp get_first(_address, []), do: nil

  defp get_first(address, [key | aliases]) do
    with nil <- Map.get(address, key), do: get_first(address, aliases)
  end

  defp into_address_baidu(%{"status" => 0, "result" => result}) do
    lat = get_in(result, ["location", "lat"]) || 0.0
    lon = get_in(result, ["location", "lng"]) || 0.0

    # 安全获取第一个POI的名称
    poi_name = get_in(result, ["pois", Access.at(0), "name"])

    # 显示名称优先级：格式化地址 > POI名称 > 默认值
    display_name =
      result["formatted_address_poi"] ||
      result["formatted_address"] ||
      poi_name ||
      "未知位置"

    # 名称字段优先级：POI名称 > 商圈名称 > 默认值
    name = poi_name || result["business"] || "未命名区域"

    %{
      display_name: display_name,
      osm_id: hash_coordinate(lat, lon),
      osm_type: "node",
      latitude: lat,
      longitude: lon,
      name: name,
      house_number: nil,
      road: get_in(result, ["addressComponent", "street"]) || "未知街道",
      neighbourhood: get_in(result, ["addressComponent", "town"]) || "未知街道",
      city: get_in(result, ["addressComponent", "city"]) || "未知城市",
      county: get_in(result, ["addressComponent", "district"]) || "未知区县",
      postcode: nil,
      state: get_in(result, ["addressComponent", "province"]) || "未知省份",
      state_district: nil,
      country: get_in(result, ["addressComponent", "country"]) || "中国",
      raw: result
    }
    |> then(&{:ok, &1})
  end

  defp into_address_baidu(%{"status" => code, "message" => msg}) do
    {:error, {:baidu_api_failure, code, msg}}
  end

  defp into_address_baidu(_unexpected), do: {:error, :invalid_response_format}

  defp into_address_google(%{"results" => []}) do
    {:error, :no_results}
  end

  defp into_address_google(%{"results" => [first_result | _]}) do
    lat = get_in(first_result, ["geometry", "location", "lat"]) || 0.0
    lon = get_in(first_result, ["geometry", "location", "lng"]) || 0.0
    
    # 从地址组件中提取各个部分
    components = first_result["address_components"] || []
    
    # 辅助函数：根据类型获取地址组件
    get_component = fn types_to_find ->
      Enum.find_value(components, fn component ->
        types = component["types"] || []
        if Enum.any?(types_to_find, &(&1 in types)) do
          component["long_name"]
        end
      end)
    end
    
    # 获取各个地址组件
    house_number = get_component.(["street_number"])
    road = get_component.(["route"])
    neighbourhood = get_component.(["neighborhood", "sublocality", "sublocality_level_1", "sublocality_level_2", "sublocality_level_3", "sublocality_level_4"])
    city = get_component.(["locality", "administrative_area_level_2"])
    county = get_component.(["administrative_area_level_2", "administrative_area_level_3"])
    state = get_component.(["administrative_area_level_1"])
    country = get_component.(["country"])
    postcode = get_component.(["postal_code"])
    
    # 获取地点名称 - 取最后一个 sublocality 然后从 formatted_address 中取后边的部分
    name = components
    |> Enum.filter(fn component ->
      types = component["types"] || []
      "sublocality" in types
    end)
    |> then(fn sublocality_components ->
      if sublocality_components != [] do
        # 找到最后一个 sublocality
        last_sublocality = List.last(sublocality_components)
        sublocality_name = last_sublocality["long_name"]
        formatted_address = first_result["formatted_address"] || ""
        
        # 在 formatted_address 中查找最后一个 sublocality 的位置
        case String.split(formatted_address, sublocality_name) do
          [prefix, suffix] ->
            # 找到 sublocality，取从该 sublocality 开始的所有内容
            sublocality_name <> String.trim(suffix)
          _ ->
            # 没找到，返回 nil
            nil
        end
      else
        nil
      end
    end)
    
    %{
      display_name: first_result["formatted_address"] || "Unknown",
      osm_id: hash_coordinate(lat, lon),
      osm_type: "node",
      latitude: lat,
      longitude: lon,
      name: name,
      house_number: house_number,
      road: road,
      neighbourhood: neighbourhood,
      city: city,
      county: county,
      postcode: postcode,
      state: state,
      state_district: nil,
      country: country,
      raw: first_result
    }
    |> then(&{:ok, &1})
  end

  defp into_address_google(%{"status" => status}) do
    {:error, {:google_api_error, status}}
  end

  defp into_address_google(_unexpected), do: {:error, :invalid_response_format}

  defp log_level(%Tesla.Env{} = env) when env.status >= 400, do: :warning
  defp log_level(%Tesla.Env{}), do: :info
end
