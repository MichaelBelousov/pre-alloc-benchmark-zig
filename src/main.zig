const std = @import("std");
const zbench = @import("zbench");
const options = @import("build_options");

/// Number of build cycles performed per measured run.
const reps: usize = options.reps;
/// Each rep shrinks the nominal size by a random 0..jitter_pct percent, so the
/// allocator never sees a repeated, exactly-sized request it can trivially reuse.
const jitter_pct: usize = options.jitter;

/// A record with 8 usize members. Only the first member is inspected by the
/// benchmarks; the rest exist to give each element a realistic footprint.
const Item = struct {
    m0: usize,
    m1: usize,
    m2: usize,
    m3: usize,
    m4: usize,
    m5: usize,
    m6: usize,
    m7: usize,
};

const Collection = enum { array_list, hash_set };
const Mode = enum {
    no_assume_capacity,
    assume_capacity,
    no_assume_capacity_arena,
    /// Like `no_assume_capacity`, but all `reps` collections are held live at
    /// once before being freed together, forcing the allocator to actually grow
    /// its footprint and fragment rather than reuse one just-freed block.
    no_assume_capacity_live,
};

/// `no_assume_capacity_live` keeps `reps` collections resident simultaneously,
/// so it is only registered for sizes at or below this cap to bound memory use.
const live_max_size: usize = 1_000_000;

/// Benchmarked sizes. The largest is also the length of the shared backing
/// array generated once during setup; every case operates on a prefix of it.
const sizes = [_]usize{ 10, 100, 1_000, 1_000_000, 100_000_000 };
const max_size = blk: {
    var m: usize = 0;
    for (sizes) |s| m = @max(m, s);
    break :blk m;
};

/// Shared, pre-generated random data. Populated in `main` (not measured).
var items: []const Item = &.{};

/// The value we key/append on: the first member, kept only when divisible by 10.
inline fn kept(it: Item) ?usize {
    return if (it.m0 % 10 == 0) it.m0 else null;
}

/// Builds a benchmark context type for a given collection and mode. The context
/// carries the runtime prefix length; `run` has the signature zBench expects.
fn Bench(comptime collection: Collection, comptime mode: Mode) type {
    return struct {
        const Self = @This();
        size: usize,
        prng: std.Random.DefaultPrng,

        pub fn run(self: *Self, base: std.mem.Allocator) void {
            const rand = self.prng.random();
            const span = self.size * jitter_pct / 100;

            if (mode == .no_assume_capacity_live) {
                runLive(collection, base, rand, self.size, span);
                return;
            }

            var rep: usize = 0;
            while (rep < reps) : (rep += 1) {
                const n = @max(1, self.size - rand.uintLessThan(usize, span + 1));
                const prefix = items[0..n];

                var arena: std.heap.ArenaAllocator = undefined;
                const gpa = switch (mode) {
                    .no_assume_capacity_arena => a: {
                        arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                        break :a arena.allocator();
                    },
                    else => base,
                };
                defer if (mode == .no_assume_capacity_arena) arena.deinit();

                switch (collection) {
                    .array_list => runList(mode, gpa, prefix),
                    .hash_set => runSet(mode, gpa, prefix),
                }
            }
        }
    };
}

fn runList(comptime mode: Mode, gpa: std.mem.Allocator, prefix: []const Item) void {
    var list: std.ArrayList(usize) = .empty;
    defer list.deinit(gpa);

    if (mode == .assume_capacity) {
        var count: usize = 0;
        for (prefix) |it| {
            if (kept(it) != null) count += 1;
        }
        list.ensureTotalCapacityPrecise(gpa, count) catch @panic("OOM");
        for (prefix) |it| {
            if (kept(it)) |v| list.appendAssumeCapacity(v);
        }
    } else {
        for (prefix) |it| {
            if (kept(it)) |v| list.append(gpa, v) catch @panic("OOM");
        }
    }

    std.mem.doNotOptimizeAway(list.items.len);
}

fn runSet(comptime mode: Mode, gpa: std.mem.Allocator, prefix: []const Item) void {
    var set: std.AutoHashMapUnmanaged(usize, void) = .empty;
    defer set.deinit(gpa);

    if (mode == .assume_capacity) {
        var count: usize = 0;
        for (prefix) |it| {
            if (kept(it) != null) count += 1;
        }
        set.ensureTotalCapacity(gpa, @intCast(count)) catch @panic("OOM");
        for (prefix) |it| {
            if (kept(it)) |v| set.putAssumeCapacity(v, {});
        }
    } else {
        for (prefix) |it| {
            if (kept(it)) |v| set.put(gpa, v, {}) catch @panic("OOM");
        }
    }

    std.mem.doNotOptimizeAway(set.count());
}

/// Build `reps` collections without freeing between them, so they all stay live
/// until freed together at the end. Each gets its own jittered size.
fn runLive(
    comptime collection: Collection,
    gpa: std.mem.Allocator,
    rand: std.Random,
    size: usize,
    span: usize,
) void {
    const nextSize = struct {
        fn f(r: std.Random, s: usize, sp: usize) usize {
            return @max(1, s - r.uintLessThan(usize, sp + 1));
        }
    }.f;

    switch (collection) {
        .array_list => {
            var lists: [reps]std.ArrayList(usize) = undefined;
            for (&lists) |*l| l.* = .empty;
            defer for (&lists) |*l| l.deinit(gpa);

            var total: usize = 0;
            for (&lists) |*l| {
                for (items[0..nextSize(rand, size, span)]) |it| {
                    if (kept(it)) |v| l.append(gpa, v) catch @panic("OOM");
                }
                total += l.items.len;
            }
            std.mem.doNotOptimizeAway(total);
        },
        .hash_set => {
            var sets: [reps]std.AutoHashMapUnmanaged(usize, void) = undefined;
            for (&sets) |*s| s.* = .empty;
            defer for (&sets) |*s| s.deinit(gpa);

            var total: usize = 0;
            for (&sets) |*s| {
                for (items[0..nextSize(rand, size, span)]) |it| {
                    if (kept(it)) |v| s.put(gpa, v, {}) catch @panic("OOM");
                }
                total += s.count();
            }
            std.mem.doNotOptimizeAway(total);
        },
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const stdout: std.Io.File = .stdout();
    const gpa = std.heap.smp_allocator;

    // ---- setup (not measured): one shared array of random structs ----
    const backing = try std.heap.page_allocator.alloc(Item, max_size);
    defer std.heap.page_allocator.free(backing);

    var prng = std.Random.DefaultPrng.init(0x9e3779b97f4a7c15);
    const rand = prng.random();
    for (backing) |*it| {
        inline for (std.meta.fields(Item)) |f| {
            @field(it, f.name) = rand.int(usize);
        }
    }
    items = backing;

    var bench = zbench.Benchmark.init(gpa, .{
        .time_budget_ns = 1_000_000_000,
        .track_allocations = options.track,
        .use_shuffling_allocator = options.shuffle,
    });
    defer bench.deinit();

    // Context instances need stable addresses for the duration of the run.
    var ctx_arena = std.heap.ArenaAllocator.init(gpa);
    defer ctx_arena.deinit();
    const ca = ctx_arena.allocator();

    @setEvalBranchQuota(20_000);
    var seed: u64 = 0x9e3779b97f4a7c15;
    inline for (.{ Collection.array_list, Collection.hash_set }) |collection| {
        inline for (.{
            Mode.no_assume_capacity,
            Mode.assume_capacity,
            Mode.no_assume_capacity_arena,
            Mode.no_assume_capacity_live,
        }) |mode| {
            inline for (sizes) |size| {
                if (mode == .no_assume_capacity_live and size > live_max_size) continue;
                const T = Bench(collection, mode);
                const ctx = try ca.create(T);
                ctx.* = .{ .size = size, .prng = std.Random.DefaultPrng.init(seed) };
                seed +%= 0x2545f4914f6cdd1d;
                const name = std.fmt.comptimePrint("{s}/{s}/{d}", .{
                    @tagName(collection),
                    @tagName(mode),
                    size,
                });
                try bench.addParam(name, @as(*const T, ctx), .{});
            }
        }
    }

    try bench.run(io, stdout);
}
