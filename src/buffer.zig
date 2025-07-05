const std = @import("std");
const wgpu = @import("wgpu");
const util = @import("./util.zig");
const Interface = @import("./interface.zig");
const BindGroup = @import("./bind_group.zig");

pub const Type = enum {
    vertex, index,
    uniform, storage,
    staging, input, output
};

pub fn Buffer(comptime BufType: Type, comptime T: type) type { return struct {
    const Self = @This();

    const read_mapped = switch (BufType) {
        .ouput => true,
        else => false
    };

    const write_mapped = switch (BufType) {
        .input => true,
        else => false
    };

    interface: *Interface,
    inner: util.Known(wgpu.WGPUBuffer),
    len: u64,
    size: u64,
    // TODO: wgpu.WGPUBufferGetMapState is unimplemented.
    is_mapped: bool,

    pub fn deinit(self: *Self) void {
        wgpu.wgpuBufferRelease(self.inner);
    }

    fn _init(interface: *Interface, len: u64, mapped: bool) !Self {
        if (BufType == .index and T != u32) @compileError("Index buffers require u32 elements.");

        const usage: wgpu.WGPUBufferUsage = switch (BufType) {
            .vertex  => wgpu.WGPUBufferUsage_Vertex | wgpu.WGPUBufferUsage_CopyDst,
            .index   => wgpu.WGPUBufferUsage_Index | wgpu.WGPUBufferUsage_CopyDst,
            .uniform => wgpu.WGPUBufferUsage_Uniform | wgpu.WGPUBufferUsage_CopyDst,
            .storage => wgpu.WGPUBufferUsage_Storage | wgpu.WGPUBufferUsage_CopyDst,
            .staging => wgpu.WGPUBufferUsage_CopySrc | wgpu.WGPUBufferUsage_CopyDst,
            .input   => wgpu.WGPUBufferUsage_MapWrite | wgpu.WGPUBufferUsage_CopySrc,
            .output  => wgpu.WGPUBufferUsage_MapRead | wgpu.WGPUBufferUsage_CopyDst
        };

        const size: u64 = @sizeOf(T) * len;

        const inner = wgpu.wgpuDeviceCreateBuffer(interface.device, &.{
            .usage = usage,
            .size = size,
            .mappedAtCreation = @intFromBool(mapped)
        }) orelse return error.CreateBufferFailed;

        return .{
            .interface = interface,
            .inner = inner,
            .len = len,
            .size = size,
            .is_mapped = mapped
        };
    }

    pub fn init(interface: *Interface, len: u64) !Self {
        return _init(interface, len, false);
    }

    pub fn initMapped(interface: *Interface, len: u64) !Self {
        if (!read_mapped and !write_mapped)
            @compileError(std.fmt.comptimePrint("Buffer of type {} is not mappable.", .{ BufType }));
        return _init(interface, len, true);
    }

    pub fn write(self: *Self, data: []T) !void {
        return self.writeFrom(0, data);
    }

    pub fn writeFrom(self: *Self, offset: u32, data: []T) !void {
        const bytes = std.mem.sliceAsBytes(data);
        wgpu.wgpuQueueWriteBuffer(self.interface.queue, self.inner, offset, bytes.ptr, bytes.len);
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