defmodule Huex do

  @moduledoc """

  Elixir client for Philips Hue connected light bulbs.

  * Query functions return the response from the API.
  * Command functions return a `Bridge` struct in order to be pipeline friendly.

  Read more on the [GitHub page](https://github.com/xavier/huex).

  """

  @typedoc """
  Light identifier can be either a numberic or a binary (e.g. "1")
  """
  @type light :: non_neg_integer | binary

  @typedoc """
  Scene identifier for a bridge
  """
  @type scene :: String.t

  @typedoc """
  Group identifier can be either a numberic or a binary (e.g. "1"). Special group 0 always contains all the lights.
  """
  @type group :: non_neg_integer | binary

  @typedoc """
  Tuple containing respectively the hue (0-65535), staturation (0-255) and value/brillance (0-255) components
  """
  @type hsv_color :: {non_neg_integer, non_neg_integer, non_neg_integer}

  @typedoc """
  Tuple containing the x (0-0.8) and y (0-0.8) component of the color
  """
  @type xy_color :: {float, float}

  @typedoc """
  Possible status of a `Bridge`
  """
  @type status :: nil | :ok | :error

  @typedoc """
  Application and device identifier used for authorization. Either a "app-name#device-name" string or {"app-name", "device-name"} tuple
  """
  @type devicetype :: binary | {binary, binary}

  @typedoc """
  Boolean; Indicating the state of streaming on the Hue Bridge
  """
  @type streaming_active :: boolean

  # Streaming headers and specs as specified in https://developers.meethue.com/develop/hue-entertainment/philips-hue-entertainment-api/
  @streaming_header <<"HueStream">> <> <<0x01, 0x00>>
  @streaming_device_type <<0x00>>
  @streaming_colorspace <<0x00>>

  # Public API

  defmodule Bridge do
    @moduledoc """
    Structure holding the state of the connection with the bridge device

    * `host`      - IP address or hostname of the bridge device
    * `username`  - Username generated by the bridge (see `authorize/2` and [Hue Configuration API](http://www.developers.meethue.com/documentation/configuration-api) for details)
    * `clientkey` - Client key generated by the bridge used in DTLS for using Hue Entertaintment API (see [Hue Entertaintment API](https://developers.meethue.com/develop/hue-entertainment/philips-hue-entertainment-api/) for details)
    * `status`    - `:ok` or `:error`
    * `error`     - error message
    """

    defstruct host: nil, username: nil, clientkey: nil, status: :ok, error: nil, socket: nil

    @type t :: %__MODULE__{
                 host: binary,
                 username: binary,
                 clientkey: binary,
                 status: Huex.status,
                 socket: port,
                 error: nil | binary}
  end

  @doc """
  Creates a connection with the bridge available on the given host or IP address.
  Username can be obtained using `authorize/2`.
  """
  @spec connect(binary, binary) :: Bridge.t
  def connect(host, username \\ nil, clientkey \\ nil) do
    %Bridge{host: host, username: username, clientkey: clientkey}
  end

  @doc """
  Requests authorization for the given `devicetype` on the given `bridge`.
  Returns an "authorized" connection.

  Bridge authorization is a one-time process per `devicetype` and goes as follow:

    1. **Press the link button** on your bridge device
    2. Call `authorize` to obtain a random username for the given `devicetype`
    3. The bridge `username` & `clientkey` will be set and the returned bridge can now be used to issue queries and commands
    4. Store the `username` to reuse it with `connect/2` next time your interact with this bridge
    5. Optionally store `clientkey` to use Hue Stremaing UDP API

  """
  @spec authorize(Bridge.t, devicetype) :: Bridge.t
  def authorize(bridge, devicetype) do
    bridge |> api_url |> post_json(%{
      devicetype: format_devicetype(devicetype),
      generateclientkey: :true
    }) |> update_bridge(bridge)
  end

  @doc """
  Does DTLS handshake with the Hue bridge when streaming is activated on one of it's groups.
  Returns socketed bridge or {:error, reason}. Will timeout to default value when streaming
  mode is not activated.
  """
  @spec open_streaming(Bridge.t) :: Bridge.t | {:error, atom}
  def open_streaming(bridge) do
    case open_streaming_dtls(bridge.host, to_charlist(bridge.username), bridge.clientkey) do
      {:ok, socket} -> update_bridge_socket(socket, bridge)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Closes streaming socket of a bridge
  """
  @spec close_streaming(Bridge.t) :: Bridge.t | {:error, atom}
  def close_streaming(bridge) do
    case :ssl.close(bridge.socket) do
      :ok -> update_bridge_socket(nil, bridge)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Fetches all informations available in the `bridge`.
  """
  @spec info(Bridge.t) :: Map.t
  def info(bridge) do
    bridge |> user_api_url |> get_json
  end

  @doc """
  Lists the lights connected to the given `bridge`.
  Requires the connection to be authorized.
  """
  @spec lights(Bridge.t) :: Map.t
  def lights(bridge) do
    bridge |> lights_url |> get_json
  end

  @doc """
  Lists the scenes setup in the given `bridge`.
  Requires the connection to be authorized
  """
  @spec scenes(Bridge.t) :: Map.t
  def scenes(bridge) do
    bridge |> scenes_url |> get_json
  end

  @doc """
  Fetches all informations available about the given `scene` connected to the `bridge`.
  Requires the connection to be authorized
  """
  @spec scene_info(Bridge.t, scene) :: Map.t
  def scene_info(bridge, scene) do
    bridge |> scene_url(scene) |> get_json
  end

  @doc """
  Fetches all informations available about the given `light` connected to the `bridge`.
  Requires the connection to be authorized.
  """
  @spec light_info(Bridge.t, light) :: Map.t
  def light_info(bridge, light) do
    bridge |> light_url(light) |> get_json
  end

  @doc """
  Turns the given light on.
  Requires the connection to be authorized.
  """
  @spec turn_on(Bridge.t, light) :: Bridge.t
  def turn_on(bridge, light) do
    bridge |> set_state(light, %{on: true})
  end

  @doc """
  Turns the given light on using the given transition time (in ms).
  Requires the connection to be authorized.
  """
  @spec turn_on(Bridge.t, light, non_neg_integer) :: Bridge.t
  def turn_on(bridge, light, transition_time_ms) do
    bridge |> set_state(light, %{on: true, transitiontime: transition_time(transition_time_ms)})
  end

  @doc """
  Turns the given light off.
  Requires the connection to be authorized.
  """
  @spec turn_off(Bridge.t, light) :: Bridge.t
  def turn_off(bridge, light) do
    bridge |> set_state(light, %{on: false})
  end

  @doc """
  Turns the given light off using the given transition time (in ms).
  Requires the connection to be authorized.
  """
  @spec turn_off(Bridge.t, light, non_neg_integer) :: Bridge.t
  def turn_off(bridge, light, transition_time_ms) do
    bridge |> set_state(light, %{on: false, transitiontime: transition_time(transition_time_ms)})
  end

  @doc """
  Sets the color (hue, saturation and brillance) of the given light.
  Requires the connection to be authorized.
  """
  @spec set_color(Bridge.t, light, hsv_color) :: Bridge.t
  def set_color(bridge, light, {h, s, v}) do
    bridge |> set_state(light, %{on: true, hue: h, sat: s, bri: v})
  end

  @doc """
  Sets the color of the given light using Philips' proprietary bi-dimensional color space.
  Requires the connection to be authorized.
  """
  @spec set_color(Bridge.t, light, xy_color) :: Bridge.t
  def set_color(bridge, light, {x, y}) do
    bridge |> set_state(light, %{on: true, xy: [x, y]})
  end

  @doc """
  Sends color data to a open DTLS socket to the Hue bridge.

  Takes light data in the form of [
    {light_id_1, {r1, g1, b1}}
    {light_id_2, {r2, g2, b2}}
    {light_id_3, {r3, g3, b3}}
  ]
  """
  def stream_color(bridge, light_data) do
    case :ssl.send(bridge.socket, stream_message(light_data)) do
      :ok -> bridge
      x -> x
    end
  end

  @doc """
  Sets the color (hue, saturation and brillance) of the given light using the given transition time (in ms).
  Requires the connection to be authorized.
  """
  @spec set_color(Bridge.t, light, hsv_color, non_neg_integer) :: Bridge.t
  def set_color(bridge, light, {h, s, v}, transition_time_ms) do
    bridge |> set_state(light, %{on: true, hue: h, sat: s, bri: v, transitiontime: transition_time(transition_time_ms)})
  end

  @doc """
  Sets the color of the given light using Philips' proprietary bi-dimensional color space using the given transition time (in ms).
  Requires the connection to be authorized.
  """
  @spec set_color(Bridge.t, light, xy_color, non_neg_integer) :: Bridge.t
  def set_color(bridge, light, {x, y}, transition_time_ms) do
    bridge |> set_state(light, %{on: true, xy: [x, y], transitiontime: transition_time(transition_time_ms)})
  end

  @doc """
  Sets the brigthness of the given light (a value between 0 and 1).
  Requires the connection to be authorized.
  """
  @spec set_brightness(Bridge.t, light, float) :: Bridge.t
  def set_brightness(bridge, light, brightness) do
    bridge |> set_state(light, %{on: true, bri: round(brightness * 255.0)})
  end

  @doc """
  Sets the brigthness of the given light (a value between 0 and 1) using the given transition time (in ms).
  Requires the connection to be authorized.
  """
  @spec set_brightness(Bridge.t, light, float, non_neg_integer) :: Bridge.t
  def set_brightness(bridge, light, brightness, transition_time_ms) do
    bridge |> set_state(light, %{on: true, bri: round(brightness * 255.0), transitiontime: transition_time(transition_time_ms)})
  end

  @doc """
  Sets the state of the given light. For a list of accepted keys, look at the `state` object in the response of `light_info`
  Requires the connection to be authorized.
  """
  @spec set_state(Bridge.t, light, Map.t) :: Bridge.t
  def set_state(bridge, light, new_state) do
    bridge |> light_state_url(light) |> put_json(new_state) |> update_bridge(bridge)
  end

  @doc """
  Lists the light groups configured for the given `bridge`.
  Requires the connection to be authorized.
  """
  @spec groups(Bridge.t) :: Map.t
  def groups(bridge) do
    bridge |> groups_url |> get_json
  end

  @doc """
  Fetches all informations available about the given `group` connected to the `bridge`.
  Requires the connection to be authorized.
  """
  @spec group_info(Bridge.t, group) :: Map.t
  def group_info(bridge, group) do
    bridge |> group_url(group) |> get_json
  end

  @doc """
  Turns the given group on.
  Requires the connection to be authorized.
  """
  @spec turn_group_on(Bridge.t, group) :: Bridge.t
  def turn_group_on(bridge, group) do
    bridge |> set_group_state(group, %{on: true})
  end

  @doc """
  Turns the given group on using the given transition time (in ms).
  Requires the connection to be authorized.
  """
  @spec turn_group_on(Bridge.t, group, non_neg_integer) :: Bridge.t
  def turn_group_on(bridge, group, transition_time_ms) do
    bridge |> set_group_state(group, %{on: true, transitiontime: transition_time(transition_time_ms)})
  end

  @doc """
  Turns the given group off.
  Requires the connection to be authorized.
  """
  @spec turn_group_off(Bridge.t, group) :: Bridge.t
  def turn_group_off(bridge, group) do
    bridge |> set_group_state(group, %{on: false})
  end

  @doc """
  Turns the given group off using the given transition time (in ms).
  Requires the connection to be authorized.
  """
  @spec turn_group_off(Bridge.t, group, non_neg_integer) :: Bridge.t
  def turn_group_off(bridge, group, transition_time_ms) do
    bridge |> set_group_state(group, %{on: false, transitiontime: transition_time(transition_time_ms)})
  end

  @doc """
  Sets the color (hue, saturation and brillance) of the given group.
  Requires the connection to be authorized.
  """
  @spec set_group_color(Bridge.t, group, hsv_color) :: Bridge.t
  def set_group_color(bridge, group, {h, s, v}) do
    bridge |> set_group_state(group, %{on: true, hue: h, sat: s, bri: v})
  end

  @doc """
  Sets the color of the given group using Philips' proprietary bi-dimensional color space.
  Requires the connection to be authorized.
  """
  @spec set_group_color(Bridge.t, group, xy_color) :: Bridge.t
  def set_group_color(bridge, group, {x, y}) do
    bridge |> set_group_state(group, %{on: true, xy: [x, y]})
  end

  @doc """
  Sets the color (hue, saturation and brillance) of the given group using the given transition time (in ms).
  Requires the connection to be authorized.
  """
  @spec set_group_color(Bridge.t, group, hsv_color, non_neg_integer) :: Bridge.t
  def set_group_color(bridge, group, {h, s, v}, transition_time_ms) do
    bridge |> set_group_state(group, %{on: true, hue: h, sat: s, bri: v, transitiontime: transition_time(transition_time_ms)})
  end

  @doc """
  Sets the color of the given group using Philips' proprietary bi-dimensional color space using the given transition time (in ms).
  Requires the connection to be authorized.
  """
  @spec set_group_color(Bridge.t, group, xy_color, non_neg_integer) :: Bridge.t
  def set_group_color(bridge, group, {x, y}, transition_time_ms) do
    bridge |> set_group_state(group, %{on: true, xy: [x, y], transitiontime: transition_time(transition_time_ms)})
  end

  @doc """
  Sets the brigthness of the given group (a value between 0 and 1).
  Requires the connection to be authorized.
  """
  @spec set_group_brightness(Bridge.t, group, float) :: Bridge.t
  def set_group_brightness(bridge, group, brightness) do
    bridge |> set_group_state(group, %{on: true, bri: round(brightness * 255.0)})
  end

  @doc """
  Sets the brigthness of the given group (a value between 0 and 1) using the given transition time (in ms).
  Requires the connection to be authorized.
  """
  @spec set_group_brightness(Bridge.t, group, float, non_neg_integer) :: Bridge.t
  def set_group_brightness(bridge, group, brightness, transition_time_ms) do
    bridge |> set_group_state(group, %{on: true, bri: round(brightness * 255.0), transitiontime: transition_time(transition_time_ms)})
  end

  @doc """
  Sets the state of the given group. For a list of accepted keys, look at the `state` object in the response of `group_info`
  Requires the connection to be authorized.
  """
  @spec set_group_state(Bridge.t, group, Map.t) :: Bridge.t
  def set_group_state(bridge, group, new_state) do
    bridge |> group_state_url(group) |> put_json(new_state) |> update_bridge(bridge)
  end

  @spec set_group_to_streaming(Bridge.t, group, streaming_active) :: Bridge.t
  def set_group_to_streaming(bridge, group, streaming_active) do
    bridge |> group_url(group) |> put_json(%{
      stream: %{
        active: streaming_active
      }
    }) |> update_bridge(bridge)
  end


  # Private API

  #
  # Keep track of errors in chainable operations
  #

  defp update_bridge(response, bridge) do
    case response do
      [%{"success" => %{"username" => username, "clientkey" => clientkey}}] ->
        %Bridge{bridge | username: username, clientkey: clientkey, status: :ok, error: nil}
      [%{"error" => error}|_] ->
        %Bridge{bridge | status: :error, error: error}
      _ ->
        %Bridge{bridge | status: :ok, error: nil}

    end
  end

  defp update_bridge_socket(socket, bridge) do
    %Bridge{bridge | socket: socket}
  end

  #
  # URLs
  #

  defp group_state_url(bridge, group), do: group_url(bridge, group) <> "/action"
  defp group_url(bridge, group), do: groups_url(bridge) <> "/#{group}"
  defp groups_url(bridge), do: user_api_url(bridge, "groups")

  defp scenes_url(bridge), do: user_api_url(bridge, "scenes")
  defp scene_url(bridge, scene), do: scenes_url(bridge) <> "/#{scene}"

  defp light_state_url(bridge, light), do: light_url(bridge, light) <> "/state"
  defp light_url(bridge, light), do: lights_url(bridge) <> "/#{light}"
  defp lights_url(bridge), do: user_api_url(bridge, "lights")

  defp user_api_url(bridge, relative_path), do: user_api_url(bridge) <> "/#{relative_path}"
  defp user_api_url(bridge), do: api_url(bridge, Map.fetch!(bridge, :username))

  defp api_url(bridge, relative_path), do: api_url(bridge) <> "/#{relative_path}"
  defp api_url(%Bridge{host: host}),   do: "http://#{host}/api"

  #
  # HTTP request / response helpers
  #

  defp get_json(url) do
    url |> HTTPoison.get |> handle_response
  end

  defp post_json(url, data) do
    json = encode_request(data)
    url |> HTTPoison.post(json) |> handle_response
  end

  defp put_json(url, data) do
    json = encode_request(data)
    url |> HTTPoison.put(json) |> handle_response
  end

  defp encode_request(data) do
    {:ok, json} = Poison.encode(data)
    json
  end

  ### Lower level Erlang routines

  @doc """
  Erlang level DTLS SSL connection function
  """
  @spec open_streaming_dtls(binary, binary, binary) :: {atom, SslSocket.t}
  def open_streaming_dtls(host, username, clientkey) do
    {:ok, decoded_key} = Base.decode16(clientkey)
    {:ok, address} = :inet.parse_address(to_charlist(host))

    # Special lookup function for use in PSK DTLS :ssl invocation.
    user_lookup = fn (:psk, _identity, key) ->
      {:ok, key}
    end

    :ssl.connect(address, 2100, [
      {:active, true},
      {:handshake, :full},
      {:protocol, :dtls},
      {:psk_identity, username},
      {:versions, [:"dtlsv1.2"]},
      {:user_lookup_fun, {user_lookup, decoded_key}},
      {:verify, :verify_none},
      {:ciphers,[ # As described in https://github.com/erlang/otp/wiki/Cipher-suite-correspondence-table
        {:psk, :aes_128_gcm, nil, :sha256}
      ]}
    ])
  end

  # Creates a streaming binary message to send to the Hue bridge streaming port
  defp stream_message(light_color_list) do
    Enum.reduce(
      light_color_list,
      @streaming_header <> <<0x01, 0x00, 0x00>> <> @streaming_colorspace <> <<0x00>>,
      fn ({light_id, {r, g, b}}, acc) ->
        light_id = <<light_id :: size(16)>>
        light_color = <<r :: size(16)>> <> <<g :: size(16)>> <> <<b :: size(16)>>
        acc <> @streaming_device_type <> light_id <> light_color
      end
    )
  end

  # TODO FIXME figure out why HTTPoison always treat the response as an error
  defp handle_response({:ok, response}), do: decode_response_body(response.body)
  #defp handle_response({:error, %HTTPoison.Error{id: nil, reason: {:closed, body}}}), do: decode_response_body(body)
  defp handle_response({:error, %HTTPoison.Error{reason: reason}}), do: {:error, reason}

  defp decode_response_body(body) do
    {:ok, object} = Poison.decode(body)
    object
  end

  #
  # Miscellaneous helpers
  #

  defp format_devicetype({application_name, device_name}), do: application_name <> "#" <> device_name
  defp format_devicetype(devicetype), do: devicetype

  defp transition_time(ms), do: div(ms, 100)

end
