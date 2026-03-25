defmodule Mix.Tasks.RecompileBuster do
  @shortdoc "Analyzes compile dependency impact to find modules causing excessive recompilation"

  @moduledoc """
  Analyzes the xref graph to identify files whose changes cause the most transitive
  recompilation. This helps find the "worst offender" modules that create compile-time
  coupling across the codebase.

  Only files that are compile dependencies (i.e., at least one other file recompiles
  when they change) are shown. They are ranked by `transitive_deps` — the count of unique
  transitive dependencies up to 3 levels deep (all edge types). A large transitive dependency tree
  means more upstream files can trigger changes, making the file more volatile. Stable
  leaf modules with shallow or no dependencies score low even if they have high fan-out.

  ## Examples

      $ mix recompile_buster
      $ mix recompile_buster --limit 10
      $ mix recompile_buster --fail-above 200
      $ mix recompile_buster --explain lib/my_app/accounts/user.ex

  ## Command line options

    * `--fail-above` - Fail (exit 1) if the number of problematic files exceeds N. When omitted, report only.
    * `--limit` - Show top N files (default: 20)
    * `--min-transitive-deps` - Minimum transitive deps to consider a file problematic (default: 5)
    * `--explain` - Show detailed breakdown for a specific file: its direct dependencies,
      and the files that would recompile when it changes.

  The task will:
  1. Generate two xref graphs: full (all labels) and compile-connected
  2. Build a reverse graph from compile-connected edges (recompilation impact)
  3. Count transitive dependencies per file (up to 3 levels deep) from the full graph
  4. Filter to files that are compile dependencies (recompiles > 0)
  5. Rank by transitive_deps, optionally failing CI if a fail_above is exceeded
  """

  use Mix.Task

  alias IO.ANSI

  @default_limit 20
  @default_min_transitive_deps 5

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          fail_above: :integer,
          limit: :integer,
          min_transitive_deps: :integer,
          explain: :string
        ]
      )

    case Keyword.get(opts, :explain) do
      nil -> run_report(opts)
      file -> run_explain(file)
    end
  end

  defp run_report(opts) do
    limit = Keyword.get(opts, :limit, @default_limit)
    fail_above = Keyword.get(opts, :fail_above)
    min_transitive_deps = Keyword.get(opts, :min_transitive_deps, @default_min_transitive_deps)

    full_graph = load_xref_graph()
    compile_connected_graph = load_xref_graph(label: "compile-connected")

    reverse_graph = build_reverse_graph(compile_connected_graph)

    forward_full_graph =
      Map.new(full_graph, fn {file, deps} -> {file, Map.keys(deps)} end)

    all_files = Map.keys(full_graph)

    file_stats =
      Enum.map(all_files, fn file ->
        recompiles = bfs_recompilation_count(file, reverse_graph)
        transitive_deps = count_deps_up_to_depth(file, forward_full_graph, 3)
        {file, recompiles, transitive_deps}
      end)

    compile_dep_stats =
      Enum.filter(file_stats, fn {_file, recompiles, transitive_deps} ->
        recompiles > 0 and transitive_deps > min_transitive_deps
      end)

    print_report(compile_dep_stats, limit)
    check_fail_above(compile_dep_stats, fail_above)
  end

  defp run_explain(file) do
    full_graph = load_xref_graph()
    compile_connected_graph = load_xref_graph(label: "compile-connected")

    if !Map.has_key?(full_graph, file) do
      Mix.raise("File not found in xref graph: #{file}")
    end

    reverse_graph = build_reverse_graph(compile_connected_graph)

    forward_full_graph =
      Map.new(full_graph, fn {f, deps} -> {f, Map.keys(deps)} end)

    direct_deps =
      full_graph
      |> Map.get(file, %{})
      |> Enum.sort_by(fn {dep, _label} -> dep end)

    transitive_deps = count_deps_up_to_depth(file, forward_full_graph, 3)

    recompile_files =
      file
      |> bfs_recompilation_files(reverse_graph)
      |> Enum.sort()

    short_name = Path.basename(file)

    Mix.shell().info("""

    Explain: #{file}
    ===================================
    Unique transitive deps (3 levels): #{transitive_deps} | Direct deps: #{length(direct_deps)} | Recompiles: #{length(recompile_files)}
    """)

    if recompile_files == [] do
      print_green("No file compile-depends on #{short_name}. Everything is fine for this file :)")
    else
      print_recompile_section(short_name, recompile_files)
      print_direct_deps_section(short_name, direct_deps, transitive_deps, forward_full_graph)
      print_recommendation(file, transitive_deps)
    end

    Mix.shell().info("")
  end

  defp print_recompile_section(short_name, recompile_files) do
    Mix.shell().info(
      "A) Files that recompile when #{short_name} changes (#{length(recompile_files)}):"
    )

    Enum.each(recompile_files, fn dep ->
      Mix.shell().info("  #{dep}")
    end)

    Mix.shell().info("")
  end

  defp print_direct_deps_section(_short_name, [], _transitive_deps, _forward_full_graph) do
    Mix.shell().info("No direct dependencies. This file is a stable leaf module.")
  end

  defp print_direct_deps_section(short_name, direct_deps, transitive_deps, forward_full_graph) do
    Mix.shell().info(
      "B) Direct dependencies of #{short_name} (#{transitive_deps} unique transitive deps):"
    )

    direct_deps
    |> Enum.map(fn {dep, _label} ->
      dep_transitive = count_deps_up_to_depth(dep, forward_full_graph, 2)
      {dep, dep_transitive}
    end)
    |> Enum.sort_by(fn {_dep, dep_transitive} -> dep_transitive end, :desc)
    |> Enum.each(&print_dep_line/1)
  end

  defp print_dep_line({dep, dep_transitive}) when dep_transitive > 5 do
    print_red("  #{dep} (#{dep_transitive} transitive deps)")
  end

  defp print_dep_line({dep, dep_transitive}) when dep_transitive > 0 do
    Mix.shell().info("  #{dep} (#{dep_transitive} transitive deps)")
  end

  defp print_dep_line({dep, _dep_transitive}) do
    Mix.shell().info("  #{dep}")
  end

  defp print_recommendation(_file, transitive_deps) when transitive_deps <= 0, do: :ok

  defp print_recommendation(file, transitive_deps) do
    Mix.shell().info("")

    Mix.shell().info(
      "Every file in (A) will recompile if any of the #{transitive_deps} files in (B) changes."
    )

    Mix.shell().info(
      "To fix this, break the compile dependency (A) or reduce the transitive deps (B) by removing direct dependencies with the most nested deps."
    )

    Mix.shell().info("")
    Mix.shell().info("To investigate why a specific file is in (A), run:")
    Mix.shell().info("  mix xref graph --source <file> --sink #{file} --label compile")
  end

  defp print_green(message) do
    Mix.shell().info(ANSI.green() <> message <> ANSI.reset())
  end

  defp print_red(message) do
    Mix.shell().info(ANSI.red() <> message <> ANSI.reset())
  end

  @doc false
  def load_xref_graph(opts \\ []) do
    tmp_path =
      Path.join(
        System.tmp_dir!(),
        "recompile_buster_xref_#{System.unique_integer([:positive])}.json"
      )

    xref_args = ["graph", "--format", "json", "--output", tmp_path]

    xref_args =
      case Keyword.get(opts, :label) do
        nil -> xref_args
        label -> xref_args ++ ["--label", label]
      end

    try do
      original_shell = Mix.shell()
      Mix.shell(Mix.Shell.Quiet)
      Mix.Task.rerun("xref", xref_args)
      Mix.shell(original_shell)

      tmp_path
      |> File.read!()
      |> JSON.decode!()
    after
      File.rm(tmp_path)
    end
  end

  @doc false
  def build_reverse_graph(graph) do
    Enum.reduce(graph, %{}, fn {file, deps}, reverse ->
      Enum.reduce(deps, reverse, fn {dep, _label}, acc ->
        Map.update(acc, dep, [file], &[file | &1])
      end)
    end)
  end

  @doc false
  def count_deps_up_to_depth(start, forward_graph, max_depth) do
    do_depth_limited_bfs([start], MapSet.new([start]), forward_graph, 0, max_depth)
  end

  defp do_depth_limited_bfs([], visited, _graph, _depth, _max_depth) do
    MapSet.size(visited) - 1
  end

  defp do_depth_limited_bfs(_queue, visited, _graph, depth, max_depth) when depth >= max_depth do
    MapSet.size(visited) - 1
  end

  defp do_depth_limited_bfs(queue, visited, graph, depth, max_depth) do
    next_queue =
      queue
      |> Enum.flat_map(fn node ->
        graph
        |> Map.get(node, [])
        |> Enum.reject(&MapSet.member?(visited, &1))
      end)
      |> Enum.uniq()

    new_visited = Enum.reduce(next_queue, visited, &MapSet.put(&2, &1))
    do_depth_limited_bfs(next_queue, new_visited, graph, depth + 1, max_depth)
  end

  @doc false
  def bfs_recompilation_count(start, reverse_graph) do
    bfs([start], MapSet.new([start]), reverse_graph) - 1
  end

  @doc false
  def bfs_recompilation_files(start, reverse_graph) do
    visited = bfs_visited([start], MapSet.new([start]), reverse_graph)

    visited
    |> MapSet.delete(start)
    |> MapSet.to_list()
  end

  defp bfs([], visited, _reverse_graph), do: MapSet.size(visited)

  defp bfs(queue, visited, reverse_graph) do
    {next_queue, new_visited} = bfs_step(queue, visited, reverse_graph)
    bfs(next_queue, new_visited, reverse_graph)
  end

  defp bfs_visited([], visited, _reverse_graph), do: visited

  defp bfs_visited(queue, visited, reverse_graph) do
    {next_queue, new_visited} = bfs_step(queue, visited, reverse_graph)
    bfs_visited(next_queue, new_visited, reverse_graph)
  end

  defp bfs_step(queue, visited, reverse_graph) do
    next_queue =
      queue
      |> Enum.flat_map(fn node ->
        reverse_graph
        |> Map.get(node, [])
        |> Enum.reject(&MapSet.member?(visited, &1))
      end)
      |> Enum.uniq()

    new_visited = Enum.reduce(next_queue, visited, &MapSet.put(&2, &1))
    {next_queue, new_visited}
  end

  defp print_report(file_stats, limit) do
    sorted =
      Enum.sort_by(
        file_stats,
        fn {_file, _recompiles, transitive_deps} -> transitive_deps end,
        :desc
      )

    Mix.shell().info("""

    Files causing excessive recompilation (sorted by transitive deps, 3 levels):
    """)

    header = "  # | Trans. deps | Recompiles | File"
    separator = "----+-------------+------------+---------------------------------------------"
    Mix.shell().info(header)
    Mix.shell().info(separator)

    sorted
    |> Enum.take(limit)
    |> Enum.with_index(1)
    |> Enum.each(fn {{file, recompiles, transitive_deps}, index} ->
      Mix.shell().info(
        String.pad_leading(Integer.to_string(index), 3) <>
          " | " <>
          String.pad_leading(Integer.to_string(transitive_deps), 11) <>
          " | " <>
          String.pad_leading(Integer.to_string(recompiles), 10) <>
          " | " <>
          file
      )
    end)

    total_transitive_deps =
      Enum.reduce(file_stats, 0, fn {_file, _recompiles, transitive_deps}, acc ->
        acc + transitive_deps
      end)

    top_file =
      case sorted do
        [{file, _, _} | _] -> file
        [] -> nil
      end

    Mix.shell().info("")

    Mix.shell().info(
      "Problematic files: #{length(sorted)} | Total transitive deps: #{total_transitive_deps}"
    )

    if top_file do
      Mix.shell().info("")
      Mix.shell().info("To start investigating the most problematic file, run:")
      Mix.shell().info("  mix recompile_buster --explain #{top_file}")
    end

    Mix.shell().info("")
  end

  defp check_fail_above(_file_stats, nil), do: :ok

  defp check_fail_above(file_stats, fail_above) do
    count = length(file_stats)

    if count <= fail_above do
      Mix.shell().info("PASSED - #{count} problematic files does not exceed #{fail_above}")
    else
      Mix.shell().error("FAILED - #{count} problematic files exceeds #{fail_above}")

      exit({:shutdown, 1})
    end
  end
end
