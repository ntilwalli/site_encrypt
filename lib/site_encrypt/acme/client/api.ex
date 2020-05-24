defmodule SiteEncrypt.Acme.Client.API do
  alias SiteEncrypt.Acme.Client.{Crypto, Http}

  def new_session(http_pool, url, account_key) do
    session = %{
      http_pool: http_pool,
      account_key: account_key,
      kid: nil,
      directory: nil,
      nonce: nil
    }

    with {:ok, response, session} <- http_request(session, :get, url),
         :ok <- validate_response(response) do
      directory =
        normalize_keys(
          response.payload,
          ~w/keyChange newAccount newNonce newOrder revokeCert/
        )

      {:ok, %{session | directory: directory}}
    end
  end

  def new_nonce(session) do
    with {:ok, response, session} <- http_request(session, :head, session.directory.new_nonce),
         :ok <- validate_response(response),
         do: {:ok, session}
  end

  def new_account(session, emails) do
    url = session.directory.new_account
    payload = %{"contact" => Enum.map(emails, &"mailto:#{&1}"), "termsOfServiceAgreed" => true}

    with {:ok, response, session} <- jws_request(session, :post, url, :jwk, payload) do
      location = :proplists.get_value("location", response.headers)
      {:ok, %{session | kid: location}}
    end
  end

  def fetch_kid(session) do
    url = session.directory.new_account
    payload = %{"onlyReturnExisting" => true}

    with {:ok, response, session} <- jws_request(session, :post, url, :jwk, payload) do
      location = :proplists.get_value("location", response.headers)
      {:ok, %{session | kid: location}}
    end
  end

  def new_order(session, domains) do
    payload = %{"identifiers" => Enum.map(domains, &%{"type" => "dns", "value" => &1})}

    with {:ok, response, session} <-
           jws_request(session, :post, session.directory.new_order, :kid, payload) do
      location = :proplists.get_value("location", response.headers)

      result =
        response.payload
        |> normalize_keys(~w/authorizations expires finalize status/)
        |> Map.update!(:expires, &from_iso8601!/1)
        |> Map.update!(:status, &parse_status!/1)
        |> Map.put(:location, location)

      {:ok, result, session}
    end
  end

  def order_status(session, order) do
    with {:ok, response, session} <- jws_request(session, :post, order.location, :kid) do
      result =
        response.payload
        |> normalize_keys(~w/authorizations finalize status certificate/)
        |> Map.update!(:status, &parse_status!/1)

      {:ok, Map.merge(order, result), session}
    end
  end

  def authorization(session, authorization) do
    with {:ok, response, session} <- jws_request(session, :post, authorization, :kid) do
      challenges =
        response.payload
        |> Map.fetch!("challenges")
        |> Stream.map(&normalize_keys(&1, ~w/status token type url/))
        |> Enum.map(&Map.update!(&1, :status, fn value -> parse_status!(value) end))

      {:ok, challenges, session}
    end
  end

  def challenge(session, challenge) do
    payload = %{}

    with {:ok, response, session} <- jws_request(session, :post, challenge.url, :kid, payload) do
      result =
        response.payload
        |> normalize_keys(~w/status token/)
        |> Map.update!(:status, &parse_status!/1)

      {:ok, result, session}
    end
  end

  def finalize(session, order, csr) do
    payload = %{"csr" => Base.url_encode64(csr, padding: false)}

    with {:ok, response, session} <- jws_request(session, :post, order.finalize, :kid, payload) do
      cert_info =
        response.payload
        |> normalize_keys(~w/certificate identifier status/)
        |> Map.update!(:status, &parse_status!/1)

      {:ok, cert_info, session}
    end
  end

  def get_cert(session, order) do
    with {:ok, response, session} <- jws_request(session, :post, order.certificate, :kid) do
      [cert | chain] = String.split(response.body, ~r/^\-+END CERTIFICATE\-+$\K/m, parts: 2)
      {:ok, Crypto.normalize_pem(cert), Crypto.normalize_pem(to_string(chain)), session}
    end
  end

  defp jws_request(session, verb, url, id_field, payload \\ "") do
    if is_nil(session.nonce), do: raise("nonce missing")
    headers = [{"content-type", "application/jose+json"}]
    body = jws_body(session, url, id_field, payload)
    session = %{session | nonce: nil}

    case http_request(session, verb, url, headers: headers, body: body) do
      {:ok, %{status: status}, _session} = success when status in 200..299 ->
        success

      {:ok, %{payload: %{"type" => "urn:ietf:params:acme:error:badNonce"}}, session} ->
        jws_request(session, verb, url, id_field, payload)

      {:ok, response, session} ->
        {:error, response, session}

      error ->
        error
    end
  end

  defp jws_body(session, url, id_field, payload) do
    protected =
      Map.merge(
        %{"alg" => "RS256", "nonce" => session.nonce, "url" => url},
        id_map(id_field, session)
      )

    plain_text = if payload == "", do: "", else: Jason.encode!(payload)
    {_, signed} = JOSE.JWS.sign(session.account_key, plain_text, protected)
    Jason.encode!(signed)
  end

  defp id_map(:jwk, session) do
    {_modules, public_map} = JOSE.JWK.to_public_map(session.account_key)
    %{"jwk" => public_map}
  end

  defp id_map(:kid, session), do: %{"kid" => session.kid}

  defp http_request(session, verb, url, opts \\ []) do
    case Http.request(session.http_pool, verb, url, headers(opts), Keyword.get(opts, :body)) do
      {:ok, response} ->
        content_type = :proplists.get_value("content-type", response.headers, "")

        payload =
          if String.starts_with?(content_type, "application/json") or
               String.starts_with?(content_type, "application/problem+json"),
             do: Jason.decode!(response.body)

        session =
          case Enum.find(response.headers, &match?({"replay-nonce", _nonce}, &1)) do
            {"replay-nonce", nonce} -> %{session | nonce: nonce}
            nil -> session
          end

        response = Map.put(response, :payload, payload)

        {:ok, response, session}

      {:error, reason} ->
        {:error, reason, session}
    end
  end

  defp headers(opts),
    do: [{"user-agent", "site_encrypt native client"} | Keyword.get(opts, :headers, [])]

  defp from_iso8601!(value) do
    {:ok, datetime, _offset} = DateTime.from_iso8601(value)
    datetime
  end

  defp parse_status!("invalid"), do: :invalid
  defp parse_status!("pending"), do: :pending
  defp parse_status!("ready"), do: :ready
  defp parse_status!("processing"), do: :processing
  defp parse_status!("valid"), do: :valid

  def normalize_keys(map, allowed_keys) do
    map
    |> Map.take(allowed_keys)
    |> Enum.into(%{}, fn {key, value} ->
      {key |> Macro.underscore() |> String.to_atom(), value}
    end)
  end

  defp validate_response(response),
    do: if(response.status in 200..299, do: :ok, else: {:error, response})
end