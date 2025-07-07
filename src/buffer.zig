const std = @import("std");
const wgpu = @import("wgpu");
const util = @import("./util.zig");
const Interface = @import("./interface.zig");
const BindGroup = @import("./bind_group.zig");
const log = std.log.scoped(.@"olib-gpu");

pub const Type = enum {
    vertex, index,
    uniform, storage,
    staging, input, output
};

pub const IndexBuffer = Buffer(.index, u32);

pub fn Buffer(comptime BufType: Type, comptime T: type) type { return struct {
    const Self = @This();
    const Type = BufType;
    const Inner = T;

    comptime {
        if (BufType == .index and T != u16 and T != u32) @compileError("Index buffers require u16 or u32 elements.");
        switch (@typeInfo(T)) {
            .@"struct" => |s| if (s.layout == .auto) @compileError("Buffers containing structs must have non-auto layout."),
            else => {}
        }
    }

    const read_mapped = switch (BufType) {
        .ouput => true,
        else => false
    };

    const write_mapped = switch (BufType) {
        .input => true,
        else => false
    };

    interface: *Interface,
    inner: util.Known(wgpu.WGPUBuffer) = undefined,
    len: u32 = 0,
    byte_len: u32 = 0,
    capacity: u64 = 0,
    byte_capacity: u64 = undefined,
    // TODO: wgpu.WGPUBufferGetMapState is unimplemented.
    is_mapped: bool = false,

    pub fn deinit(self: *Self) void {
        if (self.capacity != 0) wgpu.wgpuBufferRelease(self.inner);
    }

    pub fn init(interface: *Interface, capacity: u64) !Self {
        var self: Self = .{ .interface = interface };
        log.debug("Initialising new buffer with capacity {}.", .{ capacity });
        try self.ensureTotalCapacityPrecise(capacity);
        return self;
    }

    pub fn initMapped(interface: *Interface, capacity: u64) !Self {
        if (!read_mapped and !write_mapped)
            @compileError(std.fmt.comptimePrint("Buffer of type {} is not mappable.", .{ BufType }));
        var self: Self = .{ .interface = interface, .is_mapped = true };
        try self.ensureTotalCapacityPrecise(capacity);
        return self;
    }

    pub fn resize(self: *Self, capacity: u64) !void {
        if (self.capacity == capacity) return;
        log.debug("Resizing buffer from size {} to {}.", .{ self.capacity, capacity });
        if (capacity == 0) {
            if (self.capacity != 0) wgpu.wgpuBufferRelease(self.inner);
            return;
        }

        const new_byte_capacity, const overflow = @mulWithOverflow(@sizeOf(T), capacity);
        if (overflow != 0) return error.OutOfMemory;

        const usage: wgpu.WGPUBufferUsage = switch (BufType) {
            .vertex   => wgpu.WGPUBufferUsage_Vertex   | wgpu.WGPUBufferUsage_CopySrc | wgpu.WGPUBufferUsage_CopyDst,
            .index    => wgpu.WGPUBufferUsage_Index    | wgpu.WGPUBufferUsage_CopySrc | wgpu.WGPUBufferUsage_CopyDst,
            .uniform  => wgpu.WGPUBufferUsage_Uniform  | wgpu.WGPUBufferUsage_CopySrc | wgpu.WGPUBufferUsage_CopyDst,
            .storage  => wgpu.WGPUBufferUsage_Storage  | wgpu.WGPUBufferUsage_CopySrc | wgpu.WGPUBufferUsage_CopyDst,
            .staging  => wgpu.WGPUBufferUsage_CopySrc  | wgpu.WGPUBufferUsage_CopyDst,
            .input    => wgpu.WGPUBufferUsage_MapWrite | wgpu.WGPUBufferUsage_CopySrc,
            .output   => wgpu.WGPUBufferUsage_MapRead  | wgpu.WGPUBufferUsage_CopyDst
        };

        const new_buffer = wgpu.wgpuDeviceCreateBuffer(self.interface.device, &.{
            .usage = usage,
            .size = new_byte_capacity,
            .mappedAtCreation = @intFromBool(self.is_mapped)
        }) orelse return error.CreateBufferFailed;
        errdefer wgpu.wgpuBufferRelease(new_buffer);

        if (self.capacity != 0) {
            switch (BufType) {
                .input => {
                    @compileError("unimplemented");
                },
                .output => {
                    @compileError("unimplemented");
                },
                else => {
                    log.debug("Buffer resize requires move, executing copy to resized buffer.", .{});
                    const encoder = wgpu.wgpuDeviceCreateCommandEncoder(self.interface.device, &.{})
                        orelse return error.CreateEncoderFailed;
                    defer wgpu.wgpuCommandEncoderRelease(encoder);
                    wgpu.wgpuCommandEncoderCopyBufferToBuffer(encoder, self.inner, 0, new_buffer, 0, @min(new_byte_capacity, self.byte_capacity));
                    const commands = wgpu.wgpuCommandEncoderFinish(encoder, &.{})
                        orelse return error.CommandEncodingError;
                    defer wgpu.wgpuCommandBufferRelease(commands);
                    wgpu.wgpuQueueSubmit(self.interface.queue, 1, &[1]wgpu.WGPUCommandBuffer{commands});
                }
            }

            wgpu.wgpuBufferRelease(self.inner);
        }

        self.inner = new_buffer;
        self.capacity = capacity;
        self.byte_capacity = new_byte_capacity;
    }

    pub fn ensureTotalCapacityPrecise(self: *Self, capacity: u64) !void {
        if (self.capacity >= capacity) return;
        try self.resize(capacity);
    }

    pub fn ensureTotalCapacity(self: *Self, capacity: u64) !void {
        var new_capacity: u64 = self.capacity;
        while (true) {
            new_capacity +|= new_capacity / 2 + 1;
            if (new_capacity >= capacity) break;
        }
        try self.ensureTotalCapacityPrecise(new_capacity);
    }

    pub fn ensureUnusedCapacity(self: *Self, capacity: u64) !void {
        try self.ensureTotalCapacity(self.len +| capacity);
    }

    pub fn ensureUnusedCapacityPrecise(self: *Self, capacity: u64) !void {
        try self.ensureTotalCapacityPrecise(self.len +| capacity);
    }

    pub fn appendSliceAssumeCapacity(self: *Self, items: []T) void {
        std.debug.assert(self.len + items.len <= @min(std.math.maxInt(u32), self.capacity));
        const bytes = std.mem.sliceAsBytes(items);
        wgpu.wgpuQueueWriteBuffer(self.interface.queue, self.inner, self.len * @sizeOf(T), bytes.ptr, bytes.len);
        self.len += @intCast(items.len);
        self.byte_len = self.len * @sizeOf(T);
    }

    pub fn appendSlice(self: *Self, items: []T) !void {
        try self.ensureUnusedCapacity(items.len);
        self.appendSliceAssumeCapacity(items);
    }

    pub fn appendSlicePrecise(self: *Self, items: []T) !void {
        try self.ensureUnusedCapacityPrecise(items.len);
        self.appendSliceAssumeCapacity(items);
    }

    pub fn appendAssumeCapacity(self: *Self, item: T) void {
        std.debug.assert(self.len < @min(std.math.maxInt(u32), self.capacity));
        self.appendSliceAssumeCapacity(@constCast(&[1]T{ item }));
    }

    pub fn append(self: *Self, item: T) !void {
        try self.ensureTotalCapacity(self.len + 1);
        self.appendAssumeCapacity(item);
    }

    pub fn appendPrecise(self: *Self, item: T) !void {
        try self.ensureTotalCapacityPrecise(self.len + 1);
        self.appendAssumeCapacity(item);
    }

    pub fn pop(self: *Self) void {
        self.popNTimes(1);
    }

    pub fn popNTimes(self: *Self, n: u32) void {
        self.len -|= n;
        self.byte_len = self.len * @sizeOf(T);
    }

    pub fn replaceRangeAssumeCapacity(self: *Self, start: u32, len: u32, items: []T) void {
        std.debug.assert(start + len <= @max(std.math.maxInt(u32), self.capacity));
        if (items.len < len) {
            @panic("I don't know ;-;");
        } else {
            const bytes = std.mem.sliceAsBytes(items);
            wgpu.wgpuQueueWriteBuffer(self.interface.queue, self.inner, start * @sizeOf(T), bytes.ptr, bytes.len);
            self.len = start + @as(u32, @intCast(items.len));
            self.byte_len = self.len * @sizeOf(T);
        }
    }

    pub fn replaceRange(self: *Self, start: u32, len: u32, items: []T) !void {
        try self.ensureTotalCapacity(start + len);
        self.replaceRangeAssumeCapacity(start, len, items);
    }

    pub fn replace(self: *Self, index: u32, item: T) void {
        std.debug.assert(index < self.len);
        self.replaceRangeAssumeCapacity(index, 1, @constCast(&[1]T{ item }));
    }

    pub fn fill(self: *Self, items: []T) !void {
        try self.ensureTotalCapacityPrecise(items.len);
        std.debug.assert(items.len <= std.math.maxInt(u32));
        self.replaceRangeAssumeCapacity(0, @intCast(items.len), items);
    }

    fn map(self: *Self) void {
        if (!read_mapped and !write_mapped)
            @compileError(std.fmt.comptimePrint("Buffer of type {} is not mappable.", .{ BufType }));

        // TODO: wgpu.WGPUBufferGetMapState is unimplemented.
        // switch (wgpu.wgpuBufferGetMapState(self.inner)) {
            // wgpu.WGPUBufferMapState_Unmapped => {
        if (self.is_mapped) return;
                const mode = if (read_mapped) wgpu.WGPUMapMode_Read else wgpu.WGPUMapMode_Write;
                var complete: bool = false;
                _ = wgpu.wgpuBufferMapAsync(self.inner, mode, 0, self.size, .{
                    .callback = bufferMapCallback,
                    .userdata1 = @ptrCast(&complete)
                });

                while (!complete) wgpu.wgpuInstanceProcessEvents(self.interface.instance);
        self.is_mapped = true;
        //     },
        //     wgpu.WGPUBufferMapState_Mapped => {},
        //     else => unreachable
        // }
    }

    fn bufferMapCallback(status: wgpu.WGPUMapAsyncStatus, message: wgpu.WGPUStringView, userdata1: ?*anyopaque, _: ?*anyopaque) callconv(.C) void {
        switch (status) {
            wgpu.WGPUMapAsyncStatus_Success => {
                const complete: *bool = @ptrCast(@alignCast(userdata1));
                complete.* = true;
            },
            else => std.debug.panic("Buffer map failed: {s}", .{ util.fromStringView(message) orelse "" })
        }
    }

    // pub fn mapRead(self: *Self) ![]const self.elem_type {
    //     if (self.map_type != .read) return error.NotReadMapped;
    //     self.map();
    //     return @as([*]const u8, @ptrCast(@alignCast(wgpu.wgpuBufferGetConstMappedRange(self.inner, 0, self.size))))[0..self.size];
    // }
    //
    // pub fn mapWrite(self: *Self) ![]self.elem_type {
    //     if (self.map_type != .write) return error.NotWriteMapped;
    //     self.map();
    //     return @as([*]u8, @ptrCast(@alignCast(wgpu.wgpuBufferGetConstMappedRange(self.inner, 0, self.size))))[0..self.size];
    // }

    pub fn unmap(self: *Self) void {
        // TODO: wgpu.WGPUBufferGetMapState is unimplemented.
        // if (self.map_type == .none or wgpu.WGPUBufferGetMapState(self.inner) != wgpu.WGPUBufferMapState_Mapped) return;
        if (!self.is_mapped) return;
        wgpu.wgpuBufferUnmap(self.inner);
    }
};}