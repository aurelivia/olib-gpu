const std = @import("std");
const OOM = error { OutOfMemory };
const wgpu = @import("wgpu");
const util = @import("../util.zig");
const log = std.log.scoped(.@"olib-gpu");

const Interface = @import("../interface.zig");
const GPUSlice = @import("./gpu_slice.zig");

pub const FixedUsage = enum (wgpu.WGPUBufferUsage) {
    vertex = wgpu.WGPUBufferUsage_Vertex,
    index = wgpu.WGPUBufferUsage_Index,
    uniform = wgpu.WGPUBufferUsage_Uniform,
    storage = wgpu.WGPUBufferUsage_Storage
};

pub fn _Fixed(comptime Usage: FixedUsage, comptime T: type) type { return struct {
    const Fixed = @This();

    pub const Type = Usage;
    inner: util.Known(wgpu.WGPUBuffer),
    len: u32,

    pub fn deinit(self: *Fixed) void {
        wgpu.wgpuBufferRelease(self.inner);
        self.* = undefined;
    }

    pub fn init(interface: *Interface, data: []const T) OOM!Fixed {
        const byte_size, const overflow = @mulWithOverflow(data.len, @sizeOf(T));
        if (overflow != 0) {
            log.err("Length exceeds max u32.", .{});
            return error.OutOfMemory;
        }

        const inner = wgpu.wgpuDeviceCreateBuffer(interface.device, &.{
            .usage = @intFromEnum(Usage),
            .size = byte_size,
            .mappedAtCreation = @intFromBool(true)
        }) orelse unreachable;

        const map = @as([*]u8, @ptrCast(@alignCast(wgpu.wgpuBufferGetMappedRange(inner, 0, byte_size))));
        const bytes = std.mem.sliceAsBytes(data);
        @memcpy(map, bytes);
        wgpu.wgpuBufferUnmap(inner);

        return .{
            .inner = inner,
            .len = @intCast(data.len)
        };
    }

    pub fn source(self: *Fixed) util.Known(wgpu.WGPUBuffer) {
        return self.inner;
    }

    pub fn gpuSlice(self: *Fixed, offset: u32, len: u32) GPUSlice {
        if (offset + len > self.len) {
            log.err("Attempt to create slice ({}, {}) out of bounds of length {}.", .{ offset, len, self.len });
            unreachable;
        }
        return .{
            .source = self.inner,
            .offset = offset,
            .len = len,
            .byte_offset = offset * @sizeOf(T),
            .byte_len = len * @sizeOf(T)
        };
    }

    pub fn gpuSliceFrom(self: *Fixed, offset: u32) GPUSlice {
        return self.gpuSlice(offset, self.len);
    }

    pub fn gpuSliceAll(self: *Fixed) GPUSlice {
        return self.gpuSlice(0, self.len);
    }
};}
