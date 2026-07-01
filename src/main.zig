const std = @import("std");
const zbench = @import("zbench");

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
const Mode = enum { no_assume_capacity, assume_capacity, no_assume_capacity_arena };

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

        pub fn run(self: *Self, base: std.mem.Allocator) void {
            const prefix = items[0..self.size];

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

    var bench = zbench.Benchmark.init(gpa, .{ .time_budget_ns = 1_000_000_000 });
    defer bench.deinit();

    // Context instances need stable addresses for the duration of the run.
    var ctx_arena = std.heap.ArenaAllocator.init(gpa);
    defer ctx_arena.deinit();
    const ca = ctx_arena.allocator();

    @setEvalBranchQuota(20_000);
    inline for (.{ Collection.array_list, Collection.hash_set }) |collection| {
        inline for (.{ Mode.no_assume_capacity, Mode.assume_capacity, Mode.no_assume_capacity_arena }) |mode| {
            inline for (sizes) |size| {
                const T = Bench(collection, mode);
                const ctx = try ca.create(T);
                ctx.* = .{ .size = size };
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
