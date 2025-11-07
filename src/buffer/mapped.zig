const std = @import("std");
const wgpu = @import("wgpu");
const util = @import("../util.zig");
const log = std.log.scoped(.@"olib-gpu");

const Interface = @import("../interface.zig");
const Slice = @import("./slice.zig");

pub const MapDir = enum (wgpu.WGPUBufferUsage) {
    read = wgpu.WGPUBufferUsage_MapRead | wgpu.WGPUBufferUsage_CopyDst,
    write = wgpu.WGPUBufferUsage_MapWrite | wgpu.WGPUBufferUsage_CopySrc
};

pub const Inner = struct {
    buffer: util.Known(wgpu.WGPUBuffer),
    mapping: ?[]u8,
    wants_mapping: bool,
    copy_queued: bool,
    dir: MapDir,
    byte_size: u32,

    pub fn map(self: *Inner) void {
        if (self.mapping != null) { log.err("Attempt to map buffer that is already mapped.", .{}); unreachable; }
        self.wants_mapping = true;
        const dir = switch (self.dir) {
            .read => wgpu.WGPUMapMode_Read,
            .write => wgpu.WGPUMapMode_Write
        };
        _ = wgpu.wgpuBufferMapAsync(self.buffer, dir, 0, self.byte_size, .{
            .callback = onMapped,
            .userdata1 = @ptrCast(self),
        });
    }

    fn onMapped(status: wgpu.WGPUMapAsyncStatus, message: wgpu.WGPUStringView, userdata1: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
        switch (status) {
            wgpu.WGPUMapAsyncStatus_Success => {
                const dest: *Inner = @ptrCast(@alignCast(userdata1));
                if (dest.dir == .write) dest.mapping = getMappedRange(dest.buffer, dest.byte_size)
                else dest.mapping = getConstMappedRange(dest.buffer, dest.byte_size);
            },
            wgpu.WGPUMapAsyncStatus_Aborted => {},
            else => { log.err("Buffer map failed: {s}", .{ util.fromStringView(message) orelse "No message." }); unreachable; }
        }
    }
};

fn getMappedRange(buf: util.Known(wgpu.WGPUBuffer), len: u32) []u8 {
    return @as([*]u8, @ptrCast(@alignCast(wgpu.wgpuBufferGetMappedRange(buf, 0, len))))[0..len];
}

fn getConstMappedRange(buf: util.Known(wgpu.WGPUBuffer), len: u32) []u8 {
    return @constCast(@as([*]const u8, @ptrCast(@alignCast(wgpu.wgpuBufferGetConstMappedRange(buf, 0, len))))[0..len]);
}

pub fn Mapped(comptime Dir: MapDir, comptime T: type) type { return struct {
    const Self = @This();

    interface: *Interface,
    inner: *Inner,
    len: u32,

    pub fn deinit(self: *Self) void {
        const index = for (self.interface.buffer_mappings.items, 0..) |buf, i| {
            if (buf == self.inner) break i;
        } else unreachable;
        _ = self.interface.buffer_mappings.swapRemove(index);
        wgpu.wgpuBufferUnmap(self.inner.buffer);
        wgpu.wgpuBufferRelease(self.inner.buffer);
        self.interface.mem.destroy(self.inner);
        self.* = undefined;
    }

    pub fn init(interface: *Interface, len: u32) !Self {
        const byte_size, const overflow = @mulWithOverflow(len, @sizeOf(T));
        if (overflow != 0) return error.BufferOverflow;

        const buffer = wgpu.wgpuDeviceCreateBuffer(interface.device, &.{
            .usage = @intFromEnum(Dir),
            .size = byte_size,
            .mappedAtCreation = @intFromBool(true)
        }) orelse return error.CreateBufferFailed;

        const mapping = if (Dir == .write)
                getMappedRange(buffer, byte_size)
            else getConstMappedRange(buffer, byte_size);

        const inner = try interface.mem.create(Inner);
        inner.* = .{
            .buffer = buffer,
            .mapping = mapping,
            .wants_mapping = true,
            .copy_queued = false,
            .dir = Dir,
            .byte_size = byte_size
        };

        const self: Self = .{
            .interface = interface,
            .inner = inner,
            .len = len,
        };

        try interface.buffer_mappings.append(interface.mem, inner);

        return self;
    }

    pub fn map(self: *Self) void {
        self.inner.map();
    }

    pub fn unmap(self: *Self) void {
        self.inner.wants_mapping = false;
        self.inner.mapping = null;
        wgpu.wgpuBufferUnmap(self.inner.buffer);
    }

    fn onSwapMapped(status: wgpu.WGPUMapAsyncStatus, message: wgpu.WGPUStringView, userdata1: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
        switch (status) {
            wgpu.WGPUMapAsyncStatus_Success => {
                const done: *bool = @ptrCast(@alignCast(userdata1));
                done.* = true;
            },
            else => { log.err("Buffer map failed: {s}", .{ util.fromStringView(message) orelse "No message." }); unreachable; }
        }
    }

    pub fn resize(self: *Self, new_len: u32) !void {
        std.debug.panic("no.", .{});
        const new_byte_size, const overflow = @mulWithOverflow(new_len, @sizeOf(T));
        if (overflow != 0) return error.BufferOverflow;

        const encoder = wgpu.wgpuDeviceCreateCommandEncoder(self.interface.device, &.{})
            orelse return error.CreateEncoderFailed;
        defer wgpu.wgpuCommandEncoderRelease(encoder);

        if (self.inner.dir == .write) {
            self.inner.mapping = null;
            wgpu.wgpuBufferUnmap(self.inner.buffer);

            const read = wgpu.wgpuDeviceCreateBuffer(self.interface.device, &.{
                .usage = .read,
                .size = new_byte_size,
                .mappedAtCreation = @intFromBool(false)
            }) orelse return error.CreateBufferFailed;
            defer wgpu.wgpuBufferRelease(read);

            const write = wgpu.wgpuDeviceCreateBuffer(self.interface.device, &.{
                .usage = .write,
                .size = new_byte_size,
                .mappedAtCreation = @intFromBool(true)
            }) orelse return error.CreateBufferFailed;

            wgpu.wgpuCommandEncoderCopyBufferToBuffer(encoder, self.inner.buffer, 0, read, 0, @min(new_byte_size, self.byte_capacity));
            const commands = wgpu.wgpuCommandEncoderFinish(encoder, &.{})
                orelse return error.CommandEncodingError;
            defer wgpu.wgpuCommandBufferRelease(commands);
            wgpu.wgpuQueueSubmit(self.interface.queue, 1, &[1]wgpu.WGPUCommandBuffer{commands});

            wgpu.wgpuBufferRelease(self.inner.buffer);

            var complete: bool = false;
            _ = wgpu.wgpuBufferMapAsync(read, wgpu.WGPUMapMode_Read, 0, new_byte_size, .{
                .callback = onSwapMapped,
                .userdata1 = &complete
            });
            while (!complete) wgpu.wgpuInstanceProcessEvents(self.interface.instance);

            const source = getConstMappedRange(read, new_byte_size);
            const dest = getMappedRange(write, new_byte_size);
            @memcpy(dest, source);

            if (!self.inner.wants_mapping) wgpu.wgpuBufferUnmap(write);

            self.inner.buffer = write;
            self.len = new_len;
            self.inner.byte_size = new_byte_size;
        } else {
            const read = wgpu.wgpuDeviceCreateBuffer(self.interface.device, &.{
                .usage = .read,
                .size = new_byte_size,
                .mappedAtCreation = @intFromBool(false)
            }) orelse return error.CreateBufferFailed;

            const write = wgpu.wgpuDeviceCreateBuffer(self.interface.device, &.{
                .usage = .write,
                .size = new_byte_size,
                .mappedAtCreation = @intFromBool(true)
            }) orelse return error.CreateBufferFailed;
            defer wgpu.wgpuBufferRelease(write);

            if (self.inner.mapping == null) {
                if (self.inner.wants_mapping == false) {
                    _ = wgpu.wgpuBufferMapAsync(self.inner.buffer, wgpu.WGPUMapMode_Read, 0, self.inner.byte_size, .{
                        .callback = self.inner.onMapped,
                        .userdata1 = self
                    });
                }
                while (self.inner.mapping == null) wgpu.wgpuInstanceProcessEvents(self.interface.instance);
            }

            const dest = getMappedRange(write, new_byte_size);
            @memcpy(dest[0..@min(new_byte_size, self.inner.byte_size)], self.inner.mapping.?[0..@min(new_byte_size, self.inner.byte_size)]);

            wgpu.wgpuBufferUnmap(write);
            self.inner.mapping = null;
            wgpu.wgpuBufferUnmap(self.inner.buffer);
            wgpu.wgpuBufferRelease(self.inner.buffer);

            wgpu.wgpuCommandEncoderCopyBufferToBuffer(encoder, read, 0, write, 0, new_byte_size);
            const commands = wgpu.wgpuCommandEncoderFinish(encoder, &.{})
                orelse return error.CommandEncodingError;
            defer wgpu.wgpuCommandBufferRelease(commands);
            wgpu.wgpuQueueSubmit(self.interface.queue, 1, &[1]wgpu.WGPUCommandBuffer{commands});

            self.inner.buffer = read;
            self.len = new_len;
            self.inner.byte_size = new_byte_size;

            if (self.inner.wants_mapping) self.map();
        }
    }

    pub fn getRange(self: *Self, offset: u32, len: u32) T {
        if (offset + len > self.len) { log.err("Attempt to access out of bounds range ({}, {}) of length {}.", .{ offset, offset + len, self.len }); unreachable; }
        if (self.inner.dir == .write) { log.err("Attempt to read from write-mapped buffer.", .{}); unreachable; }
        if (!self.inner.wants_mapping) { log.err("Attempt to read from unmapped buffer.", .{}); unreachable; }
        while (self.inner.mapping == null) wgpu.wgpuInstanceProcessEvents(self.interface.instance);
        const byte_offset = offset * @sizeOf(T);
        const byte_len = len * @sizeOf(T);
        return std.mem.bytesToValue(T, self.inner.mapping.?[byte_offset..(byte_offset + byte_len)]);
    }

    pub fn get(self: *Self, index: u32) T {
        return self.getRange(index, 1);
    }

    pub fn setRange(self: *Self, offset: u32, vals: []T) void {
        if (offset + vals.len > self.len) { log.err("Attempt to access out of bounds range ({}, {}) of length {}.", .{ offset, offset + vals.len, self.len }); unreachable; }
        if (self.inner.dir == .read) { log.err("Attempt to write to read-mapped buffer.", .{}); unreachable; }
        if (!self.inner.wants_mapping) { log.err("Attempt to write to unmapped buffer.", .{}); unreachable; }
        while (self.inner.mapping == null) wgpu.wgpuInstanceProcessEvents(self.interface.instance);
        const byte_offset = offset * @sizeOf(T);
        const bytes = std.mem.sliceAsBytes(vals);
        @memcpy(self.inner.mapping.?[byte_offset..(byte_offset + bytes.len)], bytes);
    }

    pub fn set(self: *Self, index: u32, val: T) void {
        self.setRange(index, @constCast(&[1]T{val}));
    }

    pub fn slice(self: *Self, start: u32, len: u32) Slice {
        if (start + len > self.len) { log.err("Attempt to create slice ({}, {}) out of bounds of length {}.", .{ start, len, self.len }); unreachable; }
        return .{
            .source = self.inner.buffer,
            .start = start,
            .len = len,
            .byte_start = start * @sizeOf(T),
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
