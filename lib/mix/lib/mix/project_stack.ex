defmodule Mix.ProjectStack do
  @moduledoc false

  use Agent
  @timeout 30000

  @typep file :: binary
  @typep config :: keyword
  @typep project :: %{name: module, config: config, file: file}

  @spec start_link(keyword) :: {:ok, pid}
  def start_link(_opts) do
    initial = %{stack: [], post_config: [], cache: %{}}
    Agent.start_link(fn -> initial end, name: __MODULE__)
  end

  @spec push(module, config, file) :: :ok | {:error, file}
  def push(module, config, file) do
    get_and_update(fn %{stack: stack} = state ->
      # Consider the first children to always have io_done
      # because we don't need to print anything unless another
      # project takes ahold of the shell.
      io_done? = stack == []
      config = Keyword.merge(config, state.post_config)

      project = %{
        name: module,
        config: config,
        file: file,
        pos: length(stack),
        recursing?: false,
        io_done: io_done?,
        config_apps: [],
        config_files: [file],
        config_mtime: nil
      }

      cond do
        file = find_project_named(module, stack) ->
          {{:error, file}, state}

        true ->
          {:ok, %{state | post_config: [], stack: [project | state.stack]}}
      end
    end)
  end

  @spec loaded_config([atom], [binary()]) :: :ok
  def loaded_config(apps, files) do
    cast(fn state ->
      update_in(state.stack, fn
        [%{config_apps: h_apps, config_files: h_files} = h | t] ->
          h = %{
            h
            | config_apps: apps ++ h_apps,
              config_files: files ++ h_files,
              config_mtime: nil
          }

          [h | t]

        [] ->
          []
      end)
    end)
  end

  @spec config_mtime() :: [integer]
  def config_mtime() do
    get_and_update(fn state ->
      get_and_update_in(state.stack, fn
        [%{config_mtime: nil, config_files: files} = h | t] ->
          mtime = files |> Enum.map(&Mix.Utils.last_modified/1) |> Enum.max()
          {mtime, [%{h | config_mtime: mtime} | t]}

        [%{config_mtime: mtime} | _] = stack ->
          {mtime, stack}

        [] ->
          {0, []}
      end)
    end)
  end

  @spec config_apps() :: [atom]
  def config_apps() do
    get(fn
      %{stack: [h | _]} -> h.config_apps
      %{stack: []} -> []
    end)
  end

  @spec config_files() :: [binary]
  def config_files() do
    get(fn
      %{stack: [h | _]} -> h.config_files
      %{stack: []} -> []
    end)
  end

  @spec pop() :: project | nil
  def pop do
    get_and_update(fn %{stack: stack} = state ->
      case stack do
        [h | t] -> {take(h), %{state | stack: t}}
        [] -> {nil, state}
      end
    end)
  end

  @spec peek() :: project | nil
  def peek do
    get(fn %{stack: stack} ->
      case stack do
        [h | _] -> take(h)
        [] -> nil
      end
    end)
  end

  @spec root((() -> result)) :: result when result: var
  def root(fun) do
    {top, file} =
      get_and_update(fn %{stack: stack} = state ->
        {top, [mid | bottom]} = Enum.split_while(stack, &(not &1.recursing?))
        {{top, mid.file}, %{state | stack: [%{mid | recursing?: false} | bottom]}}
      end)

    try do
      File.cd!(Path.dirname(file), fun)
    after
      cast(fn %{stack: [mid | bottom]} = state ->
        %{state | stack: top ++ [%{mid | recursing?: true} | bottom]}
      end)
    end
  end

  @spec post_config(config) :: :ok
  def post_config(config) do
    cast(fn state ->
      %{state | post_config: Keyword.merge(state.post_config, config)}
    end)
  end

  @spec printable_app_name() :: atom | nil
  def printable_app_name do
    get_and_update(fn %{stack: stack} = state ->
      case stack do
        [] ->
          {nil, state}

        [%{io_done: true} | _] ->
          {nil, state}

        [h | t] ->
          h = %{h | io_done: true}
          t = Enum.map(t, &%{&1 | io_done: false})
          {h.config[:app], %{state | stack: [h | t]}}
      end
    end)
  end

  @spec clear_stack() :: :ok
  def clear_stack do
    cast(fn state ->
      %{state | stack: [], post_config: []}
    end)
  end

  @spec recur((() -> result)) :: result when result: var
  def recur(fun) do
    cast(fn %{stack: [h | t]} = state ->
      %{state | stack: [%{h | recursing?: true} | t]}
    end)

    try do
      fun.()
    after
      cast(fn %{stack: [h | t]} = state ->
        %{state | stack: [%{h | recursing?: false} | t]}
      end)
    end
  end

  @spec recursing :: module | nil
  def recursing do
    get(fn %{stack: stack} ->
      Enum.find_value(stack, &(&1.recursing? and &1.name))
    end)
  end

  @spec read_cache(term) :: term
  def read_cache(key) do
    get(fn %{cache: cache} ->
      cache[key]
    end)
  end

  @spec write_cache(term, term) :: term
  def write_cache(key, value) do
    cast(fn state ->
      %{state | cache: Map.put(state.cache, key, value)}
    end)

    value
  end

  @spec delete_cache(term) :: :ok
  def delete_cache(key) do
    cast(fn state ->
      %{state | cache: Map.delete(state.cache, key)}
    end)
  end

  @spec clear_cache :: :ok
  def clear_cache do
    cast(fn state ->
      %{state | cache: %{}}
    end)
  end

  defp find_project_named(name, stack) do
    name &&
      Enum.find_value(stack, fn
        %{name: n, file: file} when n === name -> file
        %{} -> nil
      end)
  end

  defp take(h) do
    Map.take(h, [:name, :config, :file, :pos])
  end

  defp get_and_update(fun) do
    Agent.get_and_update(__MODULE__, fun, @timeout)
  end

  defp get(fun) do
    Agent.get(__MODULE__, fun, @timeout)
  end

  defp cast(fun) do
    Agent.cast(__MODULE__, fun)
  end
end
