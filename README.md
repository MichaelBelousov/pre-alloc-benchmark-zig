# zig-appendAssumeCapacity-benchmark

Benchmarks the cost of building a collection with vs. without pre-reserving
capacity, using [zBench](https://github.com/hendriknielaender/zBench).

Two collections are measured:

- `array_list` — `std.ArrayList(usize)`
- `hash_set` — `std.AutoHashMapUnmanaged(usize, void)` (a set)

Each is run across sizes 10, 100, 1000, 1_000_000, and 100_000_000 in three modes:

- `no_assume_capacity` — single pass, growing the collection as needed
  (`append` / `put`) on the `smp_allocator`.
- `assume_capacity` — a first pass counts the elements that will be kept, then
  `ensureTotalCapacity*` reserves once and a second pass uses the
  `*AssumeCapacity` variants.
- `no_assume_capacity_arena` — same as `no_assume_capacity` but the collection
  lives in an `ArenaAllocator` (backed by the page allocator).
- `no_assume_capacity_live` — same as `no_assume_capacity`, but all `reps`
  collections of a measured run are held live at once and freed together, forcing
  the allocator to grow its footprint and fragment instead of reusing one
  just-freed block. Only registered for sizes ≤ 1,000,000 to bound memory.

## Setup (not measured)

Before any benchmark runs, `main` generates a single shared array of random
structs, each with 8 `usize` members. Its length is the largest benchmarked
size (100_000_000); every case operates on a prefix of it. A case walks its
prefix, checks whether the first member is divisible by 10, and if so appends /
inserts that member. The `assume_capacity` case walks the prefix twice: once to
size the collection, once to fill it.

## Avoiding a best-case allocator

Building the same collection at the same size every time lets the allocator's
free list settle into an ideal state: it hands back the exact block it just
freed, with no syscall and a warm cache. That makes the numbers unrealistically
kind to allocation-heavy code. Two measures perturb it:

- **Jittered size** — each build shrinks the nominal size by a random
  `0..jitter`% (default 10%, downward so it stays within the shared array), so
  successive requests are rarely the same size and can't be trivially reused.
  A per-benchmark PRNG advances continuously across all builds, so the allocator
  never sees a short, cacheable cycle of sizes.
- **Repeated builds** — each measured run performs `reps` build/free cycles
  (default 10), so a single timing sample averages over several random sizes
  instead of reflecting one lucky one. (Reported times are therefore per `reps`
  builds; the mode-to-mode ratios are unaffected.)

zBench also ships two purpose-built knobs, exposed here as build options:

- `-Dshuffle=true` uses its experimental `ShufflingAllocator`, which randomises
  allocation addresses/layout to reduce predictability (at a real overhead cost).
- `-Dtrack=true` reports allocation counts/peaks per benchmark. Note: this
  zBench version's tracking allocator mis-accounts `remap`/`resize`, so its
  reported peak underflows to `16 EiB` once `ArrayList` growth kicks in; it is
  only trustworthy for the small, non-remap cases.

The rep count and jitter are also tunable: `-Dreps=N`, `-Djitter=N`.

## Running

Requires Zig 0.16.0. The dependency is pinned to zBench's `zig-0.16.0` branch —
its `main` branch targets Zig 0.17-dev and will not compile here.

```sh
zig build -Doptimize=ReleaseFast run
```

or run the built binary directly:

```sh
zig build -Doptimize=ReleaseFast
./zig-out/bin/collection_bench
```

## Plotting

`plot.py` parses the benchmark table and writes a self-contained HTML file with
a log-log Plotly chart (loaded from a CDN) of time-per-run versus size, one line
per collection/mode with min/max error bars:

```sh
./zig-out/bin/collection_bench > results.txt
python3 plot.py results.txt -o benchmark_plot.html
```

With no input file it runs the binary itself; it also accepts piped stdin
(`./zig-out/bin/collection_bench | python3 plot.py`). Open `benchmark_plot.html`
in a browser.
