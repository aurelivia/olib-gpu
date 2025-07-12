const std = @import("std");
const wgpu = @import("wgpu");
const util = @import("../util.zig");
const log = std.log.scoped(.@"olib-gpu");

const Interface = @import("../interface.zig");
const Mapped = @import("./mapped.zig").Mapped;
const Slice = @import("./slice.zig");

pub const StagedUsage = enum (wgpu.WGPUBufferUsage) {
    instance = wgpu.WGPUBufferUsage_Vertex,
    uniform = wgpu.WGPUBufferUsage_Uniform,
};

pub fn Staged(comptime Usage: StagedUsage, comptime T: type) type { return struct {
    const Self = @This();

    // pub const elem_size: u32 = @min(256, @sizeOf(T));
    // pub const elem_bytes: u32 = elem_size / 8;
    staged: util.Known(wgpu.WGPUBuffer),
    staging: Mapped(.write, u8),
    len: u32,
    byte_size: u64,

    pub fn deinit(self: *Self) void {
        self.staging.deinit();
        wgpu.wgpuBufferRelease(self.staged);
    }

    pub fn init(interface: *Interface, len: u32) !Self {
        const byte_size, const overflow = @mulWithOverflow(len, @sizeOf(T));
        if (overflow != 0) return error.BufferOverflow;
        // const byte_size = b: {
        //     if (num == 1) break :b @sizeOf(T);
        //     const byte_size, const overflow = @mulWithOverflow(num, elem_size);
        //     if (overflow != 0) return error.BufferOverflow;
        //     break :b byte_size;
        // };

        const staged = wgpu.wgpuDeviceCreateBuffer(interface.device, &.{
            .usage = @intFromEnum(Usage) | wgpu.WGPUBufferUsage_CopyDst,
            .size = byte_size,
            .mappedAtCreation = @intFromBool(false)
        }) orelse return error.CreateBufferFailed;

        const staging: Mapped(.write, u8) = try .init(interface, byte_size);

        return .{
            .staged = staged,
            .staging = staging,
            .len = len,
            .byte_size = byte_size,
        };
    }

    pub fn setRange(self: *Self, offset: u32, vals: []T) void {
        if (!self.staging.inner.copy_queued) {
            wgpu.wgpuCommandEncoderCopyBufferToBuffer(self.staging.interface.encoder, self.staging.inner.buffer, 0, self.staged, 0, self.byte_size);
            self.staging.inner.copy_queued = true;
        }
        self.staging.setRange(offset * @sizeOf(T), std.mem.sliceAsBytes(vals));
    }

    pub fn set(self: *Self, index: u32, val: T) void {
        self.setRange(index, @constCast(&[1]T{val}));
    }

    pub fn slice(self: *Self, start: u32, len: u32) Slice {
        if (start + len > self.len) { log.err("Attempt to create slice ({}, {}) out of bounds of length {}.", .{ start, len, self.len }); unreachable; }
        return .{
            .source = self.staged,
            .start = start,
            .len = len,
            .byte_start = 0,
            .byte_len = @intCast(self.byte_size)
            // TODO: Why break instances?
            // .byte_start = start * @sizeOf(T),
            // .byte_len = len * @sizeOf(T)
        };
    }

    pub fn from(self: *Self, start: u32) Slice {
        return self.slice(start, self.len);
    }

    pub fn all(self: *Self) Slice {
        return self.slice(0, self.len);
    }
};}