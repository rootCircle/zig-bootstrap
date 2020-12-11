// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2020 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.
const std = @import("std");
const builtin = std.builtin;

const linkage: builtin.GlobalLinkage = if (builtin.is_test) .Internal else .Weak;

// This parameter is true iff the target architecture supports the bare minimum
// to implement the atomic load/store intrinsics.
// Some architectures support atomic load/stores but no CAS, but we ignore this
// detail to keep the export logic clean and because we need some kind of CAS to
// implement the spinlocks.
const supports_atomic_ops = switch (builtin.arch) {
    .msp430, .avr => false,
    .arm, .armeb, .thumb, .thumbeb =>
    // The ARM v6m ISA has no ldrex/strex and so it's impossible to do CAS
    // operations (unless we're targeting Linux, the kernel provides a way to
    // perform CAS operations).
    // XXX: The Linux code path is not implemented yet.
    !std.Target.arm.featureSetHas(std.Target.current.cpu.features, .has_v6m),
    else => true,
};

// The size (in bytes) of the biggest object that the architecture can
// load/store atomically.
// Objects bigger than this threshold require the use of a lock.
const largest_atomic_size = switch (builtin.arch) {
    // XXX: On x86/x86_64 we could check the presence of cmpxchg8b/cmpxchg16b
    // and set this parameter accordingly.
    else => @sizeOf(usize),
};

const cache_line_size = 64;

const SpinlockTable = struct {
    // Allocate ~4096 bytes of memory for the spinlock table
    const max_spinlocks = 64;

    const Spinlock = struct {
        // Prevent false sharing by providing enough padding between two
        // consecutive spinlock elements
        v: enum(usize) { Unlocked = 0, Locked } align(cache_line_size) = .Unlocked,

        fn acquire(self: *@This()) void {
            while (true) {
                switch (@atomicRmw(@TypeOf(self.v), &self.v, .Xchg, .Locked, .Acquire)) {
                    .Unlocked => break,
                    .Locked => {},
                }
            }
        }
        fn release(self: *@This()) void {
            @atomicStore(@TypeOf(self.v), &self.v, .Unlocked, .Release);
        }
    };

    list: [max_spinlocks]Spinlock = [_]Spinlock{.{}} ** max_spinlocks,

    // The spinlock table behaves as a really simple hash table, mapping
    // addresses to spinlocks. The mapping is not unique but that's only a
    // performance problem as the lock will be contended by more than a pair of
    // threads.
    fn get(self: *@This(), address: usize) *Spinlock {
        var sl = &self.list[(address >> 3) % max_spinlocks];
        sl.acquire();
        return sl;
    }
};

var spinlocks: SpinlockTable = SpinlockTable{};

// The following builtins do not respect the specified memory model and instead
// uses seq_cst, the strongest one, for simplicity sake.

// Generic version of GCC atomic builtin functions.
// Those work on any object no matter the pointer alignment nor its size.

fn __atomic_load(size: u32, src: [*]u8, dest: [*]u8, model: i32) callconv(.C) void {
    var sl = spinlocks.get(@ptrToInt(src));
    defer sl.release();
    @memcpy(dest, src, size);
}

fn __atomic_store(size: u32, dest: [*]u8, src: [*]u8, model: i32) callconv(.C) void {
    var sl = spinlocks.get(@ptrToInt(dest));
    defer sl.release();
    @memcpy(dest, src, size);
}

fn __atomic_exchange(size: u32, ptr: [*]u8, val: [*]u8, old: [*]u8, model: i32) callconv(.C) void {
    var sl = spinlocks.get(@ptrToInt(ptr));
    defer sl.release();
    @memcpy(old, ptr, size);
    @memcpy(ptr, val, size);
}

fn __atomic_compare_exchange(
    size: u32,
    ptr: [*]u8,
    expected: [*]u8,
    desired: [*]u8,
    success: i32,
    failure: i32,
) callconv(.C) i32 {
    var sl = spinlocks.get(@ptrToInt(ptr));
    defer sl.release();
    for (ptr[0..size]) |b, i| {
        if (expected[i] != b) break;
    } else {
        // The two objects, ptr and expected, are equal
        @memcpy(ptr, desired, size);
        return 1;
    }
    @memcpy(expected, ptr, size);
    return 0;
}

comptime {
    if (supports_atomic_ops) {
        @export(__atomic_load, .{ .name = "__atomic_load", .linkage = linkage });
        @export(__atomic_store, .{ .name = "__atomic_store", .linkage = linkage });
        @export(__atomic_exchange, .{ .name = "__atomic_exchange", .linkage = linkage });
        @export(__atomic_compare_exchange, .{ .name = "__atomic_compare_exchange", .linkage = linkage });
    }
}

// Specialized versions of the GCC atomic builtin functions.
// LLVM emits those iff the object size is known and the pointers are correctly
// aligned.

fn atomicLoadFn(comptime T: type) fn (*T, i32) callconv(.C) T {
    return struct {
        fn atomic_load_N(src: *T, model: i32) callconv(.C) T {
            if (@sizeOf(T) > largest_atomic_size) {
                var sl = spinlocks.get(@ptrToInt(src));
                defer sl.release();
                return src.*;
            } else {
                return @atomicLoad(T, src, .SeqCst);
            }
        }
    }.atomic_load_N;
}

comptime {
    if (supports_atomic_ops) {
        @export(atomicLoadFn(u8), .{ .name = "__atomic_load_1", .linkage = linkage });
        @export(atomicLoadFn(u16), .{ .name = "__atomic_load_2", .linkage = linkage });
        @export(atomicLoadFn(u32), .{ .name = "__atomic_load_4", .linkage = linkage });
        @export(atomicLoadFn(u64), .{ .name = "__atomic_load_8", .linkage = linkage });
    }
}

fn atomicStoreFn(comptime T: type) fn (*T, T, i32) callconv(.C) void {
    return struct {
        fn atomic_store_N(dst: *T, value: T, model: i32) callconv(.C) void {
            if (@sizeOf(T) > largest_atomic_size) {
                var sl = spinlocks.get(@ptrToInt(dst));
                defer sl.release();
                dst.* = value;
            } else {
                @atomicStore(T, dst, value, .SeqCst);
            }
        }
    }.atomic_store_N;
}

comptime {
    if (supports_atomic_ops) {
        @export(atomicStoreFn(u8), .{ .name = "__atomic_store_1", .linkage = linkage });
        @export(atomicStoreFn(u16), .{ .name = "__atomic_store_2", .linkage = linkage });
        @export(atomicStoreFn(u32), .{ .name = "__atomic_store_4", .linkage = linkage });
        @export(atomicStoreFn(u64), .{ .name = "__atomic_store_8", .linkage = linkage });
    }
}

fn atomicExchangeFn(comptime T: type) fn (*T, T, i32) callconv(.C) T {
    return struct {
        fn atomic_exchange_N(ptr: *T, val: T, model: i32) callconv(.C) T {
            if (@sizeOf(T) > largest_atomic_size) {
                var sl = spinlocks.get(@ptrToInt(ptr));
                defer sl.release();
                const value = ptr.*;
                ptr.* = val;
                return value;
            } else {
                return @atomicRmw(T, ptr, .Xchg, val, .SeqCst);
            }
        }
    }.atomic_exchange_N;
}

comptime {
    if (supports_atomic_ops) {
        @export(atomicExchangeFn(u8), .{ .name = "__atomic_exchange_1", .linkage = linkage });
        @export(atomicExchangeFn(u16), .{ .name = "__atomic_exchange_2", .linkage = linkage });
        @export(atomicExchangeFn(u32), .{ .name = "__atomic_exchange_4", .linkage = linkage });
        @export(atomicExchangeFn(u64), .{ .name = "__atomic_exchange_8", .linkage = linkage });
    }
}

fn atomicCompareExchangeFn(comptime T: type) fn (*T, *T, T, i32, i32) callconv(.C) i32 {
    return struct {
        fn atomic_compare_exchange_N(ptr: *T, expected: *T, desired: T, success: i32, failure: i32) callconv(.C) i32 {
            if (@sizeOf(T) > largest_atomic_size) {
                var sl = spinlocks.get(@ptrToInt(ptr));
                defer sl.release();
                const value = ptr.*;
                if (value == expected.*) {
                    ptr.* = desired;
                    return 1;
                }
                expected.* = value;
                return 0;
            } else {
                if (@cmpxchgStrong(T, ptr, expected.*, desired, .SeqCst, .SeqCst)) |old_value| {
                    expected.* = old_value;
                    return 0;
                }
                return 1;
            }
        }
    }.atomic_compare_exchange_N;
}

comptime {
    if (supports_atomic_ops) {
        @export(atomicCompareExchangeFn(u8), .{ .name = "__atomic_compare_exchange_1", .linkage = linkage });
        @export(atomicCompareExchangeFn(u16), .{ .name = "__atomic_compare_exchange_2", .linkage = linkage });
        @export(atomicCompareExchangeFn(u32), .{ .name = "__atomic_compare_exchange_4", .linkage = linkage });
        @export(atomicCompareExchangeFn(u64), .{ .name = "__atomic_compare_exchange_8", .linkage = linkage });
    }
}

fn fetchFn(comptime T: type, comptime op: builtin.AtomicRmwOp) fn (*T, T, i32) callconv(.C) T {
    return struct {
        pub fn fetch_op_N(ptr: *T, val: T, model: i32) callconv(.C) T {
            if (@sizeOf(T) > largest_atomic_size) {
                var sl = spinlocks.get(@ptrToInt(ptr));
                defer sl.release();

                const value = ptr.*;
                ptr.* = switch (op) {
                    .Add => value +% val,
                    .Sub => value -% val,
                    .And => value & val,
                    .Nand => ~(value & val),
                    .Or => value | val,
                    .Xor => value ^ val,
                    else => @compileError("unsupported atomic op"),
                };

                return value;
            }

            return @atomicRmw(T, ptr, op, val, .SeqCst);
        }
    }.fetch_op_N;
}

comptime {
    if (supports_atomic_ops) {
        @export(fetchFn(u8, .Add), .{ .name = "__atomic_fetch_add_1", .linkage = linkage });
        @export(fetchFn(u16, .Add), .{ .name = "__atomic_fetch_add_2", .linkage = linkage });
        @export(fetchFn(u32, .Add), .{ .name = "__atomic_fetch_add_4", .linkage = linkage });
        @export(fetchFn(u64, .Add), .{ .name = "__atomic_fetch_add_8", .linkage = linkage });

        @export(fetchFn(u8, .Sub), .{ .name = "__atomic_fetch_sub_1", .linkage = linkage });
        @export(fetchFn(u16, .Sub), .{ .name = "__atomic_fetch_sub_2", .linkage = linkage });
        @export(fetchFn(u32, .Sub), .{ .name = "__atomic_fetch_sub_4", .linkage = linkage });
        @export(fetchFn(u64, .Sub), .{ .name = "__atomic_fetch_sub_8", .linkage = linkage });

        @export(fetchFn(u8, .And), .{ .name = "__atomic_fetch_and_1", .linkage = linkage });
        @export(fetchFn(u16, .And), .{ .name = "__atomic_fetch_and_2", .linkage = linkage });
        @export(fetchFn(u32, .And), .{ .name = "__atomic_fetch_and_4", .linkage = linkage });
        @export(fetchFn(u64, .And), .{ .name = "__atomic_fetch_and_8", .linkage = linkage });

        @export(fetchFn(u8, .Or), .{ .name = "__atomic_fetch_or_1", .linkage = linkage });
        @export(fetchFn(u16, .Or), .{ .name = "__atomic_fetch_or_2", .linkage = linkage });
        @export(fetchFn(u32, .Or), .{ .name = "__atomic_fetch_or_4", .linkage = linkage });
        @export(fetchFn(u64, .Or), .{ .name = "__atomic_fetch_or_8", .linkage = linkage });

        @export(fetchFn(u8, .Xor), .{ .name = "__atomic_fetch_xor_1", .linkage = linkage });
        @export(fetchFn(u16, .Xor), .{ .name = "__atomic_fetch_xor_2", .linkage = linkage });
        @export(fetchFn(u32, .Xor), .{ .name = "__atomic_fetch_xor_4", .linkage = linkage });
        @export(fetchFn(u64, .Xor), .{ .name = "__atomic_fetch_xor_8", .linkage = linkage });

        @export(fetchFn(u8, .Nand), .{ .name = "__atomic_fetch_nand_1", .linkage = linkage });
        @export(fetchFn(u16, .Nand), .{ .name = "__atomic_fetch_nand_2", .linkage = linkage });
        @export(fetchFn(u32, .Nand), .{ .name = "__atomic_fetch_nand_4", .linkage = linkage });
        @export(fetchFn(u64, .Nand), .{ .name = "__atomic_fetch_nand_8", .linkage = linkage });
    }
}
