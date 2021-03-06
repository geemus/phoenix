defmodule Phoenix.Config.Supervisor do
  @moduledoc false
  use Supervisor

  def start_link do
    Supervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init([]) do
    children = [
      worker(Phoenix.Config, [], restart: :transient)
    ]

    supervise children, strategy: :simple_one_for_one
  end
end

defmodule Phoenix.Config do
  # Handles Phoenix configuration.
  #
  # This module is private to Phoenix and should not be accessed
  # directly. The Phoenix Router configuration can be accessed at
  # runtime using the `config/2` function or at compilation time via
  # the `@config` attribute.
  @moduledoc false

  use GenServer

  @doc """
  Starts a supervised Phoenix configuration handler for runtime.

  Data is accessed by the module via ETS.
  """
  def start_supervised(module, defaults) do
    Supervisor.start_child(Phoenix.Config.Supervisor, [module, defaults])
  end

  @doc """
  Stops Phoenix configuration handler for the module.
  """
  def stop(module) do
    [__config__: pid] = :ets.lookup(module, :__config__)
    GenServer.call(pid, :stop)
  end

  @doc """
  Deep merges the given configuration.
  """
  def merge(config1, config2) do
    Keyword.merge(config1, config2, &merger/3)
  end

  @doc """
  Caches a value in Phoenix configuration handler for the module.

  Notice writes are not serialized to the server, we expect the
  function that generates the cache to be idempotent.
  """
  def cache(module, key, fun) do
    case :ets.lookup(module, key) do
      [{^key, val}] -> val
      [] ->
        val = fun.(module)
        store(module, [{key, val}])
        val
    end
  end

  ## Internal API

  @doc """
  Starts a linked Phoenix configuration handler.
  """
  def start_link(module, defaults) do
    GenServer.start_link(__MODULE__, {module, defaults})
  end

  @doc """
  Stores the given keywords in the Phoenix configuration handler for the module.
  """
  def store(module, pairs) do
    [__config__: pid] = :ets.lookup(module, :__config__)
    GenServer.call(pid, {:store, pairs})
  end

  @doc """
  Reloads all children.

  It receives a keyword list with changed config and another
  with removed ones. The changed config are updated while the
  removed ones stop, effectively removing the table.
  """
  def reload(changed, removed) do
    request = {:config_change, changed, removed}
    Supervisor.which_children(Phoenix.Config.Supervisor)
    |> Enum.map(&Task.async(GenServer, :call, [elem(&1, 1), request]))
    |> Enum.each(&Task.await(&1))
  end

  # Callbacks

  def init({module, defaults}) do
    :ets.new(module, [:named_table, :protected, read_concurrency: true])
    :ets.insert(module, [__config__: self()])
    config = Application.get_env(:phoenix, module, [])
    update(module, merge(defaults, config))
    {:ok, {module, defaults}}
  end

  def handle_call({:store, config}, _from, {module, defaults}) do
    :ets.insert(module, config)
    {:reply, :ok, {module, defaults}}
  end

  def handle_call({:config_change, changed, removed}, _from, {module, defaults}) do
    cond do
      changed = changed[module] ->
        update(module, merge(defaults, changed))
        {:reply, :ok, {module, defaults}}
      module in removed ->
        stop(module, defaults)
      true ->
        {:reply, :ok, {module, defaults}}
    end
  end

  def handle_call(:stop, _from, {module, defaults}) do
    stop(module, defaults)
  end

  # Helpers

  defp merger(_k, v1, v2) do
    if Keyword.keyword?(v1) and Keyword.keyword?(v2) do
      Keyword.merge(v1, v2, &merger/3)
    else
      v2
    end
  end

  defp update(module, config) do
    old_keys = keys(:ets.tab2list(module))
    new_keys = [:__config__|keys(config)]
    Enum.each old_keys -- new_keys, &:ets.delete(module, &1)
    :ets.insert(module, config)
  end

  defp keys(data) do
    Enum.map(data, &elem(&1, 0))
  end

  defp stop(module, defaults) do
    :ets.delete(module)
    {:stop, :normal, :ok, {module, defaults}}
  end
end
