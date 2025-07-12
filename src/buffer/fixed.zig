const std = @import("std");
const wgpu = @import("wgpu");
const util = @import("../util.zig");
const log = std.log.scoped(.@"olib-gpu");

const Interface = @import("../interface.zig");
const Slice = @import("./slice.zig");

pub const FixedUsage = enum (wgpu.WGPUBufferUsage) {
    vertex = wgpu.WGPUBufferUsage_Vertex,
    index = wgpu.WGPUBufferUsage_Index,
    uniform = wgpu.WGPUBufferUsage_Uniform,
    storage = wgpu.WGPUBufferUsage_Storage
};

pub fn Fixed(comptime Usage: FixedUsage, comptime T: type) type { return struct {
    const Self = @This();

    pub const Type = Usage;
    inner: util.Known(wgpu.WGPUBuffer),
    len: u32,

    pub fn deinit(self: *Self) void {
        wgpu.wgpuBufferRelease(self.inner);
    }

    pub fn init(interface: *Interface, data: []const T) !Self {
        const byte_size, const overflow = @mulWithOverflow(data.len, @sizeOf(T));
        if (overflow != 0) return error.BufferOverflow;

        const inner = wgpu.wgpuDeviceCreateBuffer(interface.device, &.{
            .usage = @intFromEnum(Usage),
            .size = byte_size,
            .mappedAtCreation = @intFromBool(true)
        }) orelse return error.CreateBufferFailed;

        const map = @as([*]u8, @ptrCast(@alignCast(wgpu.wgpuBufferGetMappedRange(inner, 0, byte_size))));
        const bytes = std.mem.sliceAsBytes(data);
        @memcpy(map, bytes);
        wgpu.wgpuBufferUnmap(inner);

        return .{
            .inner = inner,
            .len = @intCast(data.len)
        };
    }

    pub fn slice(self: *Self, start: u32, len: u32) Slice {
        if (start + len > self.len) { log.err("Attempt to create slice ({}, {}) out of bounds of length {}.", .{ start, len, self.len }); unreachable; }
        return .{
            .source = self.inner,
            .start = start,
            .byte_start = start * @sizeOf(T),
            .len = len,
            .byte_len = len * @sizeOf(T)
        };
    }

    pub fn from(self: *Self, start: u32) Slice {
        return self.slice(start, self.len);
    }

    pub fn all(self: *Self) Slice {
        return self.slice(0, self.len);
    }
};}