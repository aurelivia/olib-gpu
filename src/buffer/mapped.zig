const std = @import("std");
const OOM = error { OutOfMemory };
const wgpu = @import("wgpu");
const util = @import("../util.zig");
const log = std.log.scoped(.@"olib-gpu");

const Interface = @import("../interface.zig");
const GPUSlice = @import("./gpu_slice.zig");

pub const Direction = enum (wgpu.WGPUBufferUsage) {
    input = wgpu.WGPUBufferUsage_MapWrite | wgpu.WGPUBufferUsage_CopySrc,
    output = wgpu.WGPUBufferUsage_MapRead | wgpu.WGPUBufferUsage_CopyDst
};

pub const Inner = struct {
    buffer: util.Known(wgpu.WGPUBuffer),
    dir: Direction,
    mapping: ?[]u8,
    dest: wgpu.WGPUBuffer,
    byte_len: u32,

    pub fn queue(self: *Inner, interface: *Interface, dest: wgpu.WGPUBuffer) void {
        const queued = self.mapping != null or self.dest != null;
        if (dest) |d| self.dest = d;
        if (queued) return;
        interface.mapped.push(interface.mem, self) catch unreachable;
    }

    pub fn map(self: *Inner, interface: *Interface) []u8 {
        if (self.mapping) |mapping| return mapping;
        self.queue(interface, null);
        const dir = switch (self.dir) {
            .input => wgpu.WGPUMapMode_Write,
            .output => wgpu.WGPUMapMode_Read
        };
        var success: bool = false;
        var complete: bool = false;
        _ = wgpu.wgpuBufferMapAsync(self.buffer, dir, 0, self.byte_len, .{
            .callback = onMapped,
            .userdata1 = @ptrCast(&success),
            .userdata2 = @ptrCast(&complete)
        });
        while (!complete) wgpu.wgpuInstanceProcessEvents(interface.instance);
        if (!success) unreachable;

        self.mapping = if (self.dir == .input) getMappedRange(self.buffer, self.byte_len)
        else getConstMappedRange(self.buffer, self.byte_len);
        return self.mapping.?;
    }

    pub fn unmap(self: *Inner) void {
        if (self.mapping == null) return;
        self.mapping = null;
        wgpu.wgpuBufferUnmap(self.buffer);
    }

    pub fn onMapped(status: wgpu.WGPUMapAsyncStatus, message: wgpu.WGPUStringView, userdata1: ?*anyopaque, userdata2: ?*anyopaque) callconv(.c) void {
        const success: *bool = @ptrCast(@alignCast(userdata1));
        const complete: *bool = @ptrCast(@alignCast(userdata2));
        complete.* = true;
        success.* = switch (status) {
            wgpu.WGPUMapAsyncStatus_Success => true,
            else => b: {
                log.err("Buffer map failed: {s}", .{ util.fromStringView(message) orelse "No message." });
                break :b false;
            }
        };
    }
};

fn getMappedRange(buf: util.Known(wgpu.WGPUBuffer), len: u32) []u8 {
    return @as([*]u8, @ptrCast(@alignCast(wgpu.wgpuBufferGetMappedRange(buf, 0, len))))[0..len];
}

fn getConstMappedRange(buf: util.Known(wgpu.WGPUBuffer), len: u32) []u8 {
    return @constCast(@as([*]const u8, @ptrCast(@alignCast(wgpu.wgpuBufferGetConstMappedRange(buf, 0, len))))[0..len]);
}

pub fn _Mapped(comptime Dir: Direction, comptime T: type) type { return struct {
    const Mapped = @This();

    interface: *Interface,
    inner: Inner,
    capacity: u32,
    len: u32,

    pub fn deinit(self: *Mapped) void {
        self.inner.unmap();
        wgpu.wgpuBufferRelease(self.inner.buffer);
        self.* = undefined;
    }

    pub fn init(interface: *Interface, capacity: u32) OOM!Mapped {
        const byte_cap, const overflow = @mulWithOverflow(capacity, @sizeOf(T));
        if (overflow != 0) {
            log.err("Length exceeds max u32.", .{});
            return error.OutOfMemory;
        }

        const buffer = wgpu.wgpuDeviceCreateBuffer(interface.device, &.{
            .usage = @intFromEnum(Dir),
            .size = byte_cap,
            .mappedAtCreation = @intFromBool(false)
        }) orelse unreachable;

        return .{
            .interface = interface,
            .inner = .{
                .buffer = buffer,
                .mapping = null,
                .dest = null,
                .dir = Dir,
                .byte_len = byte_cap
            },
            .capacity = capacity,
            .len = 0
        };
    }

    pub fn source(self: *Mapped) util.Known(wgpu.WGPUBuffer) {
        return self.inner.buffer;
    }

    pub fn resize(self: *Mapped, cap: u32) OOM!void {
        if (cap == self.capacity) return;
        const byte_cap, const overflow = @mulWithOverflow(cap, @sizeOf(T));
        if (overflow != 0) {
            log.err("Length exceeds max u32.", .{});
            return error.OutOfMemory;
        }

        if (Dir == .input) {
            const mapped, var src_map = if (self.inner.mapping) |mapping| .{ true, mapping } else .{ false, self.inner.map(self.interface) };

            const new = wgpu.wgpuDeviceCreateBuffer(self.interface.device, &.{
                .usage = @intFromEnum(Dir),
                .size = byte_cap,
                .mappedAtCreation = @intFromBool(true)
            }) orelse unreachable;
            var dest_map = getMappedRange(new, byte_cap);
            const copy_len = @min(byte_cap, self.len * @sizeOf(T));
            @memcpy(dest_map[0..copy_len], src_map[0..copy_len]);

            self.inner.unmap();
            wgpu.wgpuBufferRelease(self.inner.buffer);
            self.inner.buffer = new;
            self.inner.mapping = dest_map;
            self.inner.byte_len = byte_cap;

            if (!mapped) self.inner.unmap();
        } else { // .output
            unreachable;
        }

        self.capacity = cap;
    }

    pub fn ensureTotalCapacityPrecise(self: *Mapped, cap: u32) OOM!void {
        if (cap <= self.capacity) return;
        try self.resize(cap);
    }

    pub fn ensureTotalCapacity(self: *Mapped, cap: u32) OOM!void {
        var exp = self.capacity;
        while (exp < cap) exp +|= exp / 2;
        try self.ensureTotalCapacityPrecise(exp);
    }

    pub fn items(self: *Mapped) (if (Dir == .input) []T else []const T) {
        return @alignCast(std.mem.bytesAsSlice(T, self.inner.map(self.interface)[0..(self.len * @sizeOf(T))]));
    }

    pub fn addOneAssumeCapacity(self: *Mapped) *T {
        if (Dir == .output) @compileError("Output buffers are read only.");
        std.debug.assert(self.len < self.capacity);
        self.len += 1;
        return &(self.items()[self.len - 1]);
    }

    pub fn addOne(self: *Mapped) OOM!*T {
        try self.ensureTotalCapacity(self.len + 1);
        return self.addOneAssumeCapacity();
    }

    pub fn addManyAssumeCapacity(self: *Mapped, num: u32) []T {
        if (Dir == .output) @compileError("Output buffers are read only.");
        std.debug.assert(self.len + num <= self.capacity);
        const offset = self.len;
        self.len += num;
        return self.items()[offset..][0..num];
    }

    pub fn addMany(self: *Mapped, num: u32) []T {
        try self.ensureTotalCapacity(self.len + num);
        return self.addManyAssumeCapacity(num);
    }

    pub fn appendAssumeCapacity(self: *Mapped, val: T) void {
        self.addOneAssumeCapacity().* = val;
    }

    pub fn append(self: *Mapped, val: T) OOM!void {
        (try self.addOne()).* = val;
    }

    pub fn appendSliceAssumeCapacity(self: *Mapped, vals: []const T) void {
        @memcpy(self.addManyAssumeCapacity(vals.len), vals);
    }

    pub fn appendSlice(self: *Mapped, vals: []const T) OOM!void {
        @memcpy(try self.addMany(vals.len), vals);
    }

    pub fn clearAndFree(self: *Mapped) void {
        self.resize(0) catch unreachable;
        self.len = 0;
    }

    pub fn clearRetainingCapacity(self: *Mapped) void {
        self.len = 0;
    }

    pub fn pop(self: *Mapped) ?T {
        if (Dir == .output) @compileError("Output buffers are read only.");
        if (self.len == 0) return null;
        const popped = self.items()[self.len - 1];
        self.len -= 1;
        return popped;
    }

    pub fn shrinkAndFree(self: *Mapped, len: u32) void {
        std.debug.assert(len <= self.len);
        self.resize(len) catch unreachable;
    }

    pub fn shrinkRetainingCapacity(self: *Mapped, len: u32) void {
        std.debug.assert(len <= self.len);
        self.len = len;
    }

    pub fn swapRemove(self: *Mapped, index: u32) T {
        if (Dir == .output) @compileError("Output buffers are read only.");
        if (index == (self.len - 1)) return self.pop().?;
        var itms = self.items();
        const prev = itms[index];
        itms[index] = self.pop().?;
        return prev;
    }





    pub fn gpuSlice(self: *Mapped, offset: u32, len: u32) GPUSlice {
        if (offset + len > self.len) {
            log.err("Attempt to create slice ({}, {}) out of bounds of length {}.", .{ offset, len, self.len });
            unreachable;
        }
        return .{
            .source = self.inner.buffer,
            .offset = offset,
            .len = len,
            .byte_offset = offset * @sizeOf(T),
            .byte_len = len * @sizeOf(T)
        };
    }

    pub fn gpuSliceFrom(self: *Mapped, offset: u32) GPUSlice {
        return self.gpuSlice(offset, self.len);
    }

    pub fn gpuSliceAll(self: *Mapped) GPUSlice {
        return self.gpuSlice(0, self.len);
    }
};}
