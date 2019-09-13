defmodule MongoosePush.Service.APNS.Supervisor do
  @moduledoc """
  APNS module supervising Sparrow's PoolSupervisor and APNS State
  """
  use Supervisor, id: :apns_supervisor
  require Logger
  alias MongoosePush.Application

  @default_endpoints %{
    dev: "api.development.push.apple.com",
    prod: "api.push.apple.com"
  }

  @spec start_link([Application.pool_definition()]) :: Supervisor.on_start()
  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg)
  end

  @impl true
  def init(pool_configs) do
    sparrow_config = create_sparrow_config(pool_configs)

    children = [
      Supervisor.child_spec({Sparrow.APNS.Supervisor, sparrow_config},
        id: :apns_pool_supervisor
      ),
      {MongoosePush.Service.APNS.State, pool_configs}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp create_sparrow_config(pool_configs) do
    dev_cert_pools =
      pool_configs
      |> Enum.filter(fn {_, pool_config} ->
        pool_config[:mode] == :dev and
          pool_config[:auth][:type] == :certificate_based
      end)
      |> Enum.map(&convert_cert_pool_to_sparrow/1)

    prod_cert_pools =
      pool_configs
      |> Enum.filter(fn {_, pool_config} ->
        pool_config[:mode] == :prod and
          pool_config[:auth][:type] == :certificate_based
      end)
      |> Enum.map(&convert_cert_pool_to_sparrow/1)

    {dev_token_pools, dev_tokens} =
      pool_configs
      |> Enum.filter(fn {_, pool_config} ->
        pool_config[:mode] == :dev and
          pool_config[:auth][:type] == :token_based
      end)
      |> List.foldl({[], []}, &convert_token_pool_to_sparrow/2)

    {prod_token_pools, prod_tokens} =
      pool_configs
      |> Enum.filter(fn {_, pool_config} ->
        pool_config[:mode] == :prod and
          pool_config[:auth][:type] == :token_based
      end)
      |> List.foldl({[], []}, &convert_token_pool_to_sparrow/2)

    [
      {:dev, dev_cert_pools ++ dev_token_pools},
      {:prod, prod_cert_pools ++ prod_token_pools},
      {:tokens, dev_tokens ++ prod_tokens}
    ]
  end

  defp convert_cert_pool_to_sparrow({pool_name, pool_config}) do
    auth_type = {:auth_type, :certificate_based}
    cert = {:cert, pool_config[:auth][:cert]}
    key = {:key, pool_config[:auth][:key]}
    pool_size = {:worker_num, pool_config[:pool_size]}

    endpoint_mode = @default_endpoints[pool_config[:mode]]
    endpoint = {:endpoint, pool_config[:endpoint] || endpoint_mode}

    port_config = if pool_config[:use_2197], do: 2197, else: nil
    port = {:port, port_config}

    name = {:pool_name, pool_name}
    tags = {:tags, pool_config[:tags]}

    [auth_type, cert, key, pool_size, endpoint, port, name, tags]
    |> Enum.filter(fn {_key, value} -> !is_nil(value) end)
  end

  defp convert_token_pool_to_sparrow({pool_name, pool_config}, {mode_list, tokens}) do
    auth_type = {:auth_type, :token_based}
    pool_size = {:worker_num, pool_config[:pool_size]}

    endpoint_mode = @default_endpoints[pool_config[:mode]]
    endpoint = {:endpoint, pool_config[:endpoint] || endpoint_mode}

    port_config = if pool_config[:use_2197], do: 2197, else: nil
    port = {:port, port_config}

    name = {:pool_name, pool_name}
    tags = {:tags, pool_config[:tags]}

    key = pool_config[:auth][:key_id]
    team = pool_config[:auth][:team_id]
    p8_file_path = pool_config[:auth][:p8_file_path]

    if is_nil(key) or is_nil(team) or not File.exists?(p8_file_path) do
      Logger.error(~s"Required authentication elements are missing. Got:
      key=#{key}, team=#{team}, p8_file=#{p8_file_path}")

      Supervisor.stop(self(), {:error, "Required authentication elements are missing. Got:
      key=#{key}, team=#{team}, p8_file=#{p8_file_path}"})
    end

    key_id = {:key_id, key}
    team_id = {:team_id, team}
    p8_file = {:p8_file_path, p8_file_path}
    token_id = random_atom(15)
    pool_token = {:token_id, token_id}

    single_config =
      [auth_type, pool_token, pool_size, endpoint, port, name, tags]
      |> Enum.filter(fn {_key, value} -> !is_nil(value) end)

    token = [pool_token, key_id, team_id, p8_file]

    {[single_config | mode_list], [token | tokens]}
  end

  @chars for n <- ?A..?Z, do: <<n::utf8>>
  defp random_atom(len) do
    for _ <- 1..len, do: Enum.random(@chars)
  end
end
