defmodule AcmeServer.Jobs.HttpVerifier do
  @moduledoc false

  # This module powers a single http verifier job, which issues an http challenge
  # to the server. If the challenge succeeds, the job updates the account info.
  #
  # Each verifier is running as a separate process, which ensure proper error
  # isolation. Failure or blockage of while verifying one site won't affect
  # other verifications.
  #
  # A verifier process is a Parent.GenServer which starts the actual verification
  # as a child task. This approach is chosen for better control with error
  # handling. The parent process can apply delay and retry logic, and give
  # up after some number of retries.
  #
  # Because failure of one verification shouldn't affect others, the restart
  # strategy is temporary. In principle, the Parent.GenServer has minimal logic,
  # since most of the action is happening in the child task, so it shouldn't
  # crash. But even if it does, we don't want to trip up the restart intensity,
  # and crash other verifiers.

  use Parent.GenServer, restart: :temporary

  def start_link(verification_data),
    # We're registering the job under the jobs registry to make sure no duplicate
    # registrations for the same site are running.
    do: Parent.GenServer.start_link(__MODULE__, verification_data, name: via(verification_data))

  @impl GenServer
  def init(verification_data) do
    state = Map.put(verification_data, :parent, self())
    start_verification(state)
    {:ok, state}
  end

  @impl GenServer
  def handle_info(:verification_succeeded, state), do: {:stop, :normal, state}

  def handle_info(:verification_failed, state) do
    # TODO: we should also give up at some point.
    Process.send_after(self(), :start_verification, :timer.seconds(5))
    {:noreply, state}
  end

  def handle_info(:start_verification, state) do
    start_verification(state)
    {:noreply, state}
  end

  def handle_info(other, state), do: super(other, state)

  @impl Parent.GenServer
  def handle_child_terminated(:verification, _meta, _pid, :normal, state), do: {:noreply, state}

  def handle_child_terminated(:verification, _meta, _pid, _abnormal_reason, state) do
    start_verification(state)
    {:noreply, state}
  end

  defp start_verification(state) do
    Parent.GenServer.start_child(%{
      id: :verification,
      start: {Task, :start_link, [fn -> verify(state) end]}
    })
  end

  defp verify(state) do
    if state.order.domains
       |> verify_domains(state.order.token, state.dns, state.key_thumbprint)
       |> Enum.all?(&(&1 == :ok)) do
      AcmeServer.Account.update_order(state.account_id, %{state.order | status: :valid})
      send(state.parent, :verification_succeeded)
    else
      send(state.parent, :verification_failed)
    end
  end

  defp verify_domains(domains, token, dns, key_thumbprint) do
    domains
    |> Task.async_stream(&verify_domain(http_server(&1, dns), token, key_thumbprint))
    |> Enum.map(fn
      {:ok, result} -> result
      _ -> :error
    end)
  end

  defp http_server(domain, dns) do
    case Map.fetch(dns, domain) do
      {:ok, resolver} -> resolver.()
      :error -> domain
    end
  end

  defp verify_domain(url, token, key_thumbprint) do
    with {:ok, {{_, 200, _}, _headers, response}} <- http_request(url, token),
         ^response <- "#{token}.#{key_thumbprint}" do
      :ok
    else
      _ -> :error
    end
  end

  defp http_request(server, token) do
    # Using httpc, because it doesn't require external dependency. Httpc is not
    # suitable for production, but AcmeServer is not meant to be used in
    # production anyway.
    :httpc.request(
      :get,
      {'http://#{server}/.well-known/acme-challenge/#{token}', []},
      [],
      body_format: :binary
    )
  end

  defp via(data), do: AcmeServer.Jobs.Registry.via({__MODULE__, data})
end
