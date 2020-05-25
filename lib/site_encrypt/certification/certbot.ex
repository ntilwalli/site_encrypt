defmodule SiteEncrypt.Certification.Certbot do
  @behaviour SiteEncrypt.Certification.Job
  require Logger

  @impl SiteEncrypt.Certification.Job
  def pems(config) do
    [
      privkey: keyfile(config),
      cert: certfile(config),
      chain: cacertfile(config)
    ]
    |> Stream.map(fn {type, path} ->
      case File.read(path) do
        {:ok, content} -> {type, content}
        _error -> nil
      end
    end)
    |> Enum.split_with(&is_nil/1)
    |> case do
      {[], pems} -> {:ok, pems}
      {[_ | _], _} -> :error
    end
  end

  @impl SiteEncrypt.Certification.Job
  def certify(config, _http_pool, opts) do
    ensure_folders(config)

    result =
      if match?({:ok, _}, pems(config)), do: renew(config, opts), else: certonly(config, opts)

    case result do
      {output, 0} ->
        SiteEncrypt.log(config, output)
        :ok

      {output, _error} ->
        Logger.error(output)
        :error
    end
  end

  @impl SiteEncrypt.Certification.Job
  def full_challenge(config, challenge) do
    Path.join([
      webroot_folder(config),
      ".well-known",
      "acme-challenge",
      challenge
    ])
    |> File.read!()
  end

  defp ensure_folders(config) do
    Enum.each(
      [config_folder(config), work_folder(config), webroot_folder(config)],
      &File.mkdir_p!/1
    )
  end

  defp certonly(config, opts) do
    certbot_cmd(
      config,
      opts,
      ~w(
        certonly
        --webroot
        --webroot-path #{webroot_folder(config)}
        --agree-tos
        ) ++
        domain_params(config)
    )
  end

  defp renew(config, opts) do
    args = ~w(
        renew
        --agree-tos
        --no-random-sleep-on-renew
        --cert-name #{hd(config.domains)}
        --force-renewal
      )

    certbot_cmd(config, opts, args)
  end

  defp certbot_cmd(config, opts, args),
    do: System.cmd("certbot", args ++ common_args(config, opts), stderr_to_stdout: true)

  defp common_args(config, opts) do
    ~w(
      -m #{Enum.join(config.emails, " ")}
      --server #{directory_url(config.directory_url)}
      --work-dir #{work_folder(config)}
      --config-dir #{config_folder(config)}
      --logs-dir #{log_folder(config)}
      --no-self-upgrade
      --non-interactive
      #{unless Keyword.get(opts, :verify_server_cert, true), do: "--no-verify-ssl"}
    )
  end

  defp directory_url({:internal, opts}),
    do: "https://localhost:#{Keyword.fetch!(opts, :port)}/directory"

  defp directory_url(directory_url), do: directory_url

  defp domain_params(config), do: Enum.map(config.domains, &"-d #{&1}")

  defp keys_folder(config), do: Path.join(~w(#{config_folder(config)} live #{hd(config.domains)}))
  defp config_folder(config), do: Path.join(root_folder(config), "config")
  defp log_folder(config), do: Path.join(root_folder(config), "log")
  defp work_folder(config), do: Path.join(root_folder(config), "work")
  defp webroot_folder(config), do: Path.join(root_folder(config), "webroot")
  defp root_folder(config), do: Path.join(config.db_folder, "certbot")

  defp keyfile(config), do: Path.join(keys_folder(config), "privkey.pem")
  defp certfile(config), do: Path.join(keys_folder(config), "cert.pem")
  defp cacertfile(config), do: Path.join(keys_folder(config), "chain.pem")
end
