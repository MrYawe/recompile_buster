defmodule Mix.Tasks.RecompileBusterTest do
  use ExUnit.Case

  alias Mix.Tasks.RecompileBuster

  # A -> B -> C -> D (linear chain)
  # A -> E (branch)
  # F -> B (F also depends on B)
  #
  # Full graph (file -> %{dep => label}):
  #   A depends on B (compile), E (runtime)
  #   B depends on C (compile)
  #   C depends on D (runtime)
  #   F depends on B (compile)
  #
  # Compile-connected graph (only compile edges):
  #   A -> B, B -> C, F -> B

  @full_graph %{
    "lib/a.ex" => %{"lib/b.ex" => "compile", "lib/e.ex" => "runtime"},
    "lib/b.ex" => %{"lib/c.ex" => "compile"},
    "lib/c.ex" => %{"lib/d.ex" => "runtime"},
    "lib/d.ex" => %{},
    "lib/e.ex" => %{},
    "lib/f.ex" => %{"lib/b.ex" => "compile"}
  }

  @compile_connected_graph %{
    "lib/a.ex" => %{"lib/b.ex" => "compile-connected"},
    "lib/b.ex" => %{"lib/c.ex" => "compile-connected"},
    "lib/c.ex" => %{},
    "lib/d.ex" => %{},
    "lib/e.ex" => %{},
    "lib/f.ex" => %{"lib/b.ex" => "compile-connected"}
  }

  describe "build_reverse_graph/1" do
    test "reverses compile-connected edges" do
      reverse = RecompileBuster.build_reverse_graph(@compile_connected_graph)

      assert "lib/a.ex" in Map.get(reverse, "lib/b.ex", [])
      assert "lib/f.ex" in Map.get(reverse, "lib/b.ex", [])
      assert "lib/b.ex" in Map.get(reverse, "lib/c.ex", [])
    end

    test "files with no dependents are absent from the reverse graph" do
      reverse = RecompileBuster.build_reverse_graph(@compile_connected_graph)

      refute Map.has_key?(reverse, "lib/a.ex")
      refute Map.has_key?(reverse, "lib/d.ex")
      refute Map.has_key?(reverse, "lib/e.ex")
      refute Map.has_key?(reverse, "lib/f.ex")
    end

    test "empty graph returns empty map" do
      assert RecompileBuster.build_reverse_graph(%{}) == %{}
    end
  end

  describe "count_deps_up_to_depth/3" do
    setup do
      forward_graph =
        Map.new(@full_graph, fn {file, deps} -> {file, Map.keys(deps)} end)

      %{forward_graph: forward_graph}
    end

    test "counts direct deps at depth 1", %{forward_graph: graph} do
      # A -> B, E
      assert RecompileBuster.count_deps_up_to_depth("lib/a.ex", graph, 1) == 2
    end

    test "counts transitive deps at depth 2", %{forward_graph: graph} do
      # A -> B, E (depth 1) -> C (depth 2) = 3 unique
      assert RecompileBuster.count_deps_up_to_depth("lib/a.ex", graph, 2) == 3
    end

    test "counts transitive deps at depth 3", %{forward_graph: graph} do
      # A -> B, E (depth 1) -> C (depth 2) -> D (depth 3) = 4 unique
      assert RecompileBuster.count_deps_up_to_depth("lib/a.ex", graph, 3) == 4
    end

    test "leaf node has zero deps", %{forward_graph: graph} do
      assert RecompileBuster.count_deps_up_to_depth("lib/d.ex", graph, 3) == 0
    end

    test "depth 0 returns 0", %{forward_graph: graph} do
      assert RecompileBuster.count_deps_up_to_depth("lib/a.ex", graph, 0) == 0
    end

    test "does not double-count shared deps" do
      # diamond: X -> Y, X -> Z, Y -> W, Z -> W
      graph = %{
        "x" => ["y", "z"],
        "y" => ["w"],
        "z" => ["w"],
        "w" => []
      }

      # X -> Y, Z (depth 1) -> W (depth 2) = 3 unique, not 4
      assert RecompileBuster.count_deps_up_to_depth("x", graph, 2) == 3
    end

    test "handles cycles" do
      graph = %{
        "a" => ["b"],
        "b" => ["c"],
        "c" => ["a"]
      }

      assert RecompileBuster.count_deps_up_to_depth("a", graph, 10) == 2
    end
  end

  describe "bfs_recompilation_count/2" do
    test "counts files that transitively recompile" do
      reverse = RecompileBuster.build_reverse_graph(@compile_connected_graph)

      # When B changes: A and F recompile
      assert RecompileBuster.bfs_recompilation_count("lib/b.ex", reverse) == 2
    end

    test "counts transitive recompilation chain" do
      reverse = RecompileBuster.build_reverse_graph(@compile_connected_graph)

      # When C changes: B recompiles, then A and F recompile = 3
      assert RecompileBuster.bfs_recompilation_count("lib/c.ex", reverse) == 3
    end

    test "leaf with no dependents returns 0" do
      reverse = RecompileBuster.build_reverse_graph(@compile_connected_graph)

      assert RecompileBuster.bfs_recompilation_count("lib/a.ex", reverse) == 0
    end

    test "file not in reverse graph returns 0" do
      assert RecompileBuster.bfs_recompilation_count("lib/unknown.ex", %{}) == 0
    end
  end

  describe "bfs_recompilation_files/2" do
    test "returns the files that would recompile" do
      reverse = RecompileBuster.build_reverse_graph(@compile_connected_graph)

      files = RecompileBuster.bfs_recompilation_files("lib/b.ex", reverse)

      assert Enum.sort(files) == ["lib/a.ex", "lib/f.ex"]
    end

    test "returns full transitive chain" do
      reverse = RecompileBuster.build_reverse_graph(@compile_connected_graph)

      files = RecompileBuster.bfs_recompilation_files("lib/c.ex", reverse)

      assert Enum.sort(files) == ["lib/a.ex", "lib/b.ex", "lib/f.ex"]
    end

    test "returns empty list for leaf files" do
      reverse = RecompileBuster.build_reverse_graph(@compile_connected_graph)

      assert RecompileBuster.bfs_recompilation_files("lib/a.ex", reverse) == []
    end
  end
end
