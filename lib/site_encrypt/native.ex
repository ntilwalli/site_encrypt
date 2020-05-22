defmodule SiteEncrypt.Native do
  @behaviour SiteEncrypt.Certifier.Job
  require Logger

  alias AcmeClient.Crypto
  alias SiteEncrypt.{Certifier.Job, Logger}

  @impl Job
  def pems(config) do
    {:ok, Enum.map(~w/privkey cert chain/a, &{&1, load_file!(config, "#{&1}.pem")})}
  catch
    _, _ ->
      :error
  end

  @impl Job
  def certify(config, http_pool, opts) do
    case account_key(config) do
      nil -> new_account(config, http_pool)
      account_key -> new_cert(config, http_pool, account_key, opts)
    end
  end

  @impl Job
  def full_challenge(_config, _challenge), do: raise("shouldn't land here")

  defp new_account(config, http_pool) do
    Logger.log(:info, "Creating new ACME account for domain #{config.domain}")
    ca_url = ca_url(config)
    session = AcmeClient.new_account(http_pool, ca_url, [config.email])
    store_account_key!(config, session.account_key)
    create_certificate(config, session)
  end

  defp new_cert(config, http_pool, account_key, opts) do
    if Keyword.get(opts, :force_renewal) == true or cert_needs_renewal?(config) do
      ca_url = ca_url(config)
      session = AcmeClient.for_existing_account(http_pool, ca_url, account_key)
      create_certificate(config, session)
    else
      :no_change
    end
  end

  defp cert_needs_renewal?(config) do
    case pems(config) do
      {:ok, pems} ->
        cert = Keyword.fetch!(pems, :cert)
        expires_in_seconds = DateTime.diff(Crypto.cert_valid_until(cert), DateTime.utc_now())
        expires_in_seconds < 30 * 24 * 60 * 60

      :error ->
        true
    end
  end

  defp create_certificate(config, session) do
    Logger.log(config.log_level, "Ordering a new certificate for domain #{config.domain}")

    {pems, _session} =
      AcmeClient.create_certificate(session, %{
        id: config.id,
        domains: [config.domain | config.extra_domains],
        register_challenge: &SiteEncrypt.Registry.register_challenge!(config.id, &1, &2),
        await_challenge: fn ->
          receive do
            :got_challenge -> true
          after
            :timer.minutes(1) -> false
          end
        end
      })

    store_pems!(config, pems)
    Logger.log(config.log_level, "New certificate for domain #{config.domain} obtained")
    :new_cert
  end

  def account_key(config) do
    config
    |> load_file!("account_key.json")
    |> Jason.decode!()
    |> JOSE.JWK.from_map()
  catch
    _, _ -> nil
  end

  defp store_account_key!(config, account_key) do
    {_, map} = JOSE.JWK.to_map(account_key)
    store_file!(config, "account_key.json", Jason.encode!(map))
  end

  defp store_pems!(config, pems) do
    Enum.each(
      pems,
      fn {type, content} -> store_file!(config, "#{type}.pem", content) end
    )
  end

  defp store_file!(config, name, content) do
    File.mkdir_p(root_folder(config))
    File.write!(Path.join(root_folder(config), name), content)
  end

  defp load_file!(config, name),
    do: File.read!(Path.join(root_folder(config), name))

  defp root_folder(config),
    do: Path.join([config.base_folder, "elixir_acme_client", ca_folder(config), config.domain])

  defp ca_folder(config), do: URI.parse(ca_url(config)).host

  defp ca_url(config) do
    with {:local_acme_server, opts} <- config.ca_url,
         do: "https://localhost:#{Keyword.fetch!(opts, :port)}/directory"
  end
end