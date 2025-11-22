const std = @import("std");
const OOM = error { OutOfMemory };
const wgpu = @import("wgpu");
const util = @import("../util.zig");
const log = std.log.scoped(.@"olib-gpu");

const Interface = @import("../interface.zig");
const Mapped = @import("./mapped.zig")._Mapped;
const GPUSlice = @import("./gpu_slice.zig");

pub const StagedUsage = enum (wgpu.WGPUBufferUsage) {
    vertex = wgpu.WGPUBufferUsage_Vertex,
    index = wgpu.WGPUBufferUsage_Index,
    uniform = wgpu.WGPUBufferUsage_Uniform,
    storage = wgpu.WGPUBufferUsage_Storage
};

pub fn _Staged(comptime Usage: StagedUsage, comptime T: type) type { return struct {
    const Staged = @This();

    staging: Mapped(.input, T),
    staged: util.Known(wgpu.WGPUBuffer),

    pub fn deinit(self: *Staged) void {
        self.staging.deinit();
        wgpu.wgpuBufferRelease(self.staged);
        self.* = undefined;
    }

    pub fn init(interface: *Interface, length: u32) OOM!Staged {
        const byte_size, const overflow = @mulWithOverflow(length, @sizeOf(T));
        if (overflow != 0) {
            log.err("Length exceeds max u32.", .{});
            return error.OutOfMemory;
        }

        const staged = wgpu.wgpuDeviceCreateBuffer(interface.device, &.{
            .usage = @intFromEnum(Usage) | wgpu.WGPUBufferUsage_CopyDst,
            .size = byte_size,
            .mappedAtCreation = @intFromBool(false)
        }) orelse unreachable;

        const staging: Mapped(.input, T) = try .init(interface, length);

        return .{ .staged = staged, .staging = staging };
    }

    pub fn source(self: *Staged) util.Known(wgpu.WGPUBuffer) {
        return self.staged;
    }

    pub fn len(self: *Staged) u32 {
        return self.staging.len;
    }

    pub fn capacity(self: *Staged) u32 {
        return self.staging.capacity;
    }

    pub fn resize(self: *Staged, cap: u32) OOM!void {
        if (cap == self.staging.len) return;

        try self.staging.resize(cap);

        const new_byte_size, const overflow = @mulWithOverflow(cap, @sizeOf(T));
        if (overflow != 0) {
            log.err("Length exceeds max u32.", .{});
            return error.OutOfMemory;
        }

        wgpu.wgpuBufferRelease(self.staged);
        self.staged = wgpu.wgpuDeviceCreateBuffer(self.staging.interface.device, &.{
            .usage = @intFromEnum(Usage) | wgpu.WGPUBufferUsage_CopyDst,
            .size = new_byte_size,
            .mappedAtCreation = @intFromBool(false)
        }) orelse unreachable;
    }

    pub fn ensureTotalCapacityPrecise(self: *Staged, cap: u32) OOM!void {
        if (cap <= self.staging.capacity) return;
        try self.resize(cap);
    }

    pub fn ensureTotalCapacity(self: *Staged, cap: u32) OOM!void {
        var exp = self.staging.capacity;
        while (exp < cap) exp +|= exp / 2;
        try self.ensureTotalCapacityPrecise(exp);
    }

    pub fn items(self: *Staged) []T {
        self.staging.inner.queue(self.staging.interface, self.staged);
        return self.staging.items();
    }

    pub fn addOneAssumeCapacity(self: *Staged) *T {
        self.staging.inner.queue(self.staging.interface, self.staged);
        return self.staging.addOneAssumeCapacity();
    }

    pub fn addOne(self: *Staged) OOM!*T {
        try self.ensureTotalCapacity(self.staging.len + 1);
        return self.addOneAssumeCapacity();
    }

    pub fn addManyAssumeCapacity(self: *Staged, num: u32) []T {
        self.staging.inner.queue(self.staging.interface, self.staged);
        return self.staging.addManyAssumeCapacity(num);
    }

    pub fn addMany(self: *Staged, num: u32) OOM![]T {
        try self.ensureTotalCapacity(self.staging.len + num);
        return self.addManyAssumeCapacity(num);
    }

    pub fn appendAssumeCapacity(self: *Staged, val: T) void {
        self.addOneAssumeCapacity().* = val;
    }

    pub fn append(self: *Staged, val: T) OOM!void {
        (try self.addOne()).* = val;
    }

    pub fn appendSliceAssumeCapacity(self: *Staged, vals: []const T) void {
        @memcpy(self.addManyAssumeCapacity(vals.len), vals);
    }

    pub fn appendSlice(self: *Staged, vals: []const T) OOM!void {
        @memcpy(try self.addMany(vals.len), vals);
    }

    pub fn clearAndFree(self: *Staged) void {
        self.staging.inner.queue(self.staging.interface, self.staged);
        self.resize(0) catch unreachable;
    }

    pub fn clearRetainingCapacity(self: *Staged) void {
        self.staging.inner.queue(self.staging.interface, self.staged);
        self.staging.clearRetainingCapacity();
    }

    pub fn pop(self: *Staged) ?T {
        self.staging.inner.queue(self.staging.interface, self.staged);
        return self.staging.pop();
    }

    pub fn shrinkAndFree(self: *Mapped, length: u32) void {
        self.staging.inner.queue(self.staging.interface, self.staged);
        self.resize(length) catch unreachable;
    }

    pub fn shrinkRetainingCapacity(self: *Mapped, length: u32) void {
        self.staging.inner.queue(self.staging.interface, self.staged);
        self.staging.shrinkRetainingCapacity(length);
    }

    pub fn swapRemove(self: *Mapped, index: u32) T {
        self.staging.inner.queue(self.staging.interface, self.staged);
        return self.staging.swapRemove(index);
    }





    pub fn gpuSlice(self: *Staged, offset: u32, length: u32) GPUSlice {
        if (offset + length > self.staging.len) {
            log.err("Attempt to create slice ({}, {}) out of bounds of length {}.", .{ offset, length, self.staging.len });
            unreachable;
        }
        return .{
            .source = self.staged,
            .offset = offset,
            .len = length,
            .byte_offset = offset * @sizeOf(T),
            .byte_len = length * @sizeOf(T)
        };
    }

    pub fn gpuSliceFrom(self: *Staged, offset: u32) GPUSlice {
        return self.gpuSlice(offset, self.staging.len);
    }

    pub fn gpuSliceAll(self: *Staged) GPUSlice {
        return self.gpuSlice(0, self.staging.len);
    }
};}
