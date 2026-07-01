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

## Setup (not measured)

Before any benchmark runs, `main` generates a single shared array of random
structs, each with 8 `usize` members. Its length is the largest benchmarked
size (100_000_000); every case operates on a prefix of it. A case walks its
prefix, checks whether the first member is divisible by 10, and if so appends /
inserts that member. The `assume_capacity` case walks the prefix twice: once to
size the collection, once to fill it.

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
