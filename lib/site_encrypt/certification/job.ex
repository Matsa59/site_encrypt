defmodule SiteEncrypt.Certification.Job do
  use Parent.GenServer
  require Logger

  @type pems :: [privkey: String.t(), cert: String.t(), chain: String.t()]

  @callback pems(SiteEncrypt.config()) :: {:ok, pems} | :error
  @callback full_challenge(SiteEncrypt.config(), String.t()) :: String.t()

  @callback certify(SiteEncrypt.config(), http_pool :: pid, force_renewal: boolean) ::
              :new_cert | :no_change | :error

  def start_link(config) do
    Parent.GenServer.start_link(
      __MODULE__,
      config,
      name: SiteEncrypt.Registry.name(config.id, __MODULE__)
    )
  end

  def post_certify(config) do
    {:ok, keys} = SiteEncrypt.client(config).pems(config)
    SiteEncrypt.store_pems(config, keys)
    :ssl.clear_pem_cache()

    unless is_nil(config.backup), do: backup(config)
    config.callback.handle_new_cert()

    :ok
  end

  @impl GenServer
  def init(config) do
    opts =
      if match?({:internal, _}, config.directory_url), do: [verify_server_cert: false], else: []

    {:ok, http_pool} = Parent.GenServer.start_child({SiteEncrypt.Acme.Client.Http, opts})

    Parent.GenServer.start_child(%{
      id: :job,
      start: {Task, :start_link, [fn -> certify(config, http_pool, opts) end]},
      timeout: :timer.minutes(5)
    })

    {:ok, config}
  end

  @impl Parent.GenServer
  def handle_child_terminated(:job, _meta, _pid, _reason, state), do: {:stop, :normal, state}

  defp certify(config, http_pool, opts) do
    case SiteEncrypt.client(config).certify(config, http_pool, opts) do
      :error ->
        Logger.error("Error obtaining certificate for #{hd(config.domains)}")

      :new_cert ->
        post_certify(config)
        valid_until = SiteEncrypt.Certification.Periodic.cert_valid_until(config)
        renewal_date = SiteEncrypt.Certification.Periodic.renewal_date(config)

        SiteEncrypt.log(config, [
          "Certificate successfully obtained! It is valid until #{valid_until}. ",
          "Next renewal is scheduled for #{renewal_date}. "
        ])

      :no_change ->
        :ok
    end
  end

  defp backup(config) do
    {:ok, tar} = :erl_tar.open(to_charlist(config.backup), [:write, :compressed])

    config.db_folder
    |> Path.join("*")
    |> Path.wildcard()
    |> Enum.each(fn path ->
      :ok =
        :erl_tar.add(
          tar,
          to_charlist(path),
          to_charlist(Path.relative_to(path, config.db_folder)),
          []
        )
    end)

    :ok = :erl_tar.close(tar)
    File.chmod!(config.backup, 0o600)
  catch
    type, error ->
      Logger.error(
        "Error backing up certificate: #{Exception.format(type, error, __STACKTRACE__)}"
      )
  end
end