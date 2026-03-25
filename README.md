# Recompile Buster

Mix task that analyzes your xref graph to find modules causing excessive recompilation, and helps you fix them.

Recompile Buster analyzes your Elixir project's xref compile-connected graph to surface the modules whose changes trigger the most transitive recompilation. It ranks files by dependency depth, lets you drill into specific files with `--explain`, and can fail CI when recompilation hotspots exceed a threshold. Stop waiting for full rebuilds — bust the compile-time coupling.

## Installation

Add `recompile_buster` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:recompile_buster, "~> 0.1.0", only: :dev, runtime: false}
  ]
end
```

## Usage

```bash
# Show top 20 files causing the most recompilation
mix recompile_buster

# Show top 10 only
mix recompile_buster --limit 10

# Fail CI if more than 200 problematic files
mix recompile_buster --fail-above 200

# Drill into a specific file
mix recompile_buster --explain lib/my_app/accounts/user.ex
```

### Options

| Option | Description |
|---|---|
| `--limit N` | Show top N files (default: 20) |
| `--fail-above N` | Fail (exit 1) if problematic files exceed N |
| `--min-transitive-deps N` | Minimum transitive deps to be considered problematic (default: 5) |
| `--explain FILE` | Show detailed breakdown for a specific file |

### How it works

1. Generates two xref graphs: full (all labels) and compile-connected
2. Builds a reverse graph from compile-connected edges (recompilation impact)
3. Counts transitive dependencies per file (up to 3 levels deep) from the full graph
4. Filters to files that are compile dependencies (recompiles > 0)
5. Ranks by transitive_deps, optionally failing CI if a threshold is exceeded

### Understanding the output

The report shows a table with two key metrics per file:

- **Transitive deps**: Number of unique transitive dependencies (up to 3 levels). Higher means more volatile — changes in any of these files can trigger a cascade.
- **Recompiles**: Number of files that recompile when this file changes.

Use `--explain` to drill into a specific file and see:

- **(A)** Which files recompile when it changes
- **(B)** Its direct dependencies and their own transitive dep counts

Every file in (A) will recompile if any file in (B) changes. To fix this, either break the compile dependency (A) or reduce the transitive deps (B).

## License

MIT
