const std = @import("std");
const wgpu = @import("wgpu");
const util = @import("./util.zig");
const Interface = @import("./interface.zig");
const Stage = @import("./shader.zig").Stage;

const Self = @This();

pub const Usage = enum (wgpu.WGPUBufferUsage) {
    none = wgpu.WGPUBufferUsage_None,
    map_read = wgpu.WGPUBufferUsage_MapRead,
    map_write = wgpu.WGPUBufferUsage_MapWrite,
    copy_source = wgpu.WGPUBufferUsage_CopySrc,
    copy_dest = wgpu.WGPUBufferUsage_CopyDst,
    index = wgpu.WGPUBufferUsage_Index,
    vertex = wgpu.WGPUBufferUsage_Vertex,
    uniform = wgpu.WGPUBufferUsage_Uniform,
    storage = wgpu.WGPUBufferUsage_Storage,
    _,

    pub fn with(a: Usage, b: Usage) Usage { return @enumFromInt(@intFromEnum(a) | @intFromEnum(b)); }
    pub fn is(a: Usage, b: Usage) bool { return (@intFromEnum(a) & @intFromEnum(b)) != 0; }
    pub fn isNot(a: Usage, b: Usage) bool { return !a.is(b); }
};

pub const Layout = union (enum) {
    vertex: FreeLayout,
    index: FreeLayout,
    uniform: BoundLayout,
    storage: BoundLayout,
    staging: FreeLayout,
    input: FreeLayout,
    output: FreeLayout,

    pub const FreeLayout = struct { size: u64 };

    pub const BoundLayout = struct {
        size: u64,
        visibility: Stage
    };
};

pub const MapType = enum { none, read, write };

interface: *Interface,
inner: util.Known(wgpu.WGPUBuffer),
size: u64,
bind_group: wgpu.WGPUBindGroup,
map_type: MapType,
is_mapped: bool,

pub fn deinit(self: *Self) void {
    if (self.bind_group) |bg| wgpu.wgpuBindGroupRelease(bg);
    wgpu.wgpuBufferRelease(self.inner);
}

pub fn init(interface: *Interface, layout: Layout) !Self {
    return switch (layout) {
        .vertex => |l| try .initRaw(interface, Usage.vertex.with(.copy_dest), l.size, false, null),
        .index  => |l| try .initRaw(interface, Usage.index.with(.copy_dest), l.size, false, null),
        .uniform => |l| try .initRaw(interface, Usage.uniform.with(.copy_dest), l.size, false, l),
        .storage => |l| try .initRaw(interface, Usage.storage.with(.copy_dest), l.size, false, l),
        .staging => |l| try .initRaw(interface, Usage.copy_source.with(.copy_dest), l.size, false, null),
        .input => |l| try .initRaw(interface, Usage.map_write.with(.copy_source), l.size, false, null),
        .output => |l| try .initRaw(interface, Usage.map_read.with(.copy_dest), l.size, false, null)
    };
}

pub fn initRaw(
    interface: *Interface,
    comptime usage: Usage,
    size: u64,
    mapped_at_creation: bool,
    bind_layout: ?Layout.BoundLayout,
) !Self {
    const inner = wgpu.wgpuDeviceCreateBuffer(interface.device, &.{
        .usage = @intFromEnum(usage),
        .size = size,
        .mappedAtCreation = @intFromBool(mapped_at_creation)
    }) orelse return error.CreateBufferFailed;

    // Either uniform or storage means bound
    var bind_group: wgpu.WGPUBindGroup = null;
    if (usage.is(Usage.uniform.with(.storage))) {
        const bg_layout = wgpu.wgpuDeviceCreateBindGroupLayout(interface.device, &.{
            .entryCount = 1,
            .entries = &[_]wgpu.WGPUBindGroupLayoutEntry{.{
                .binding = 0,
                .visibility = @intFromEnum(bind_layout.?.visibility),
                .buffer = .{
                    .@"type" = if (usage.is(.uniform)) wgpu.WGPUBufferBindingType_Uniform
                               else wgpu.WGPUBufferBindingType_Storage,
                    .hasDynamicOffset = @intFromBool(false),
                    .minBindingSize = 0
                },
                .sampler = .{ .@"type" = wgpu.WGPUSamplerBindingType_BindingNotUsed },
                .texture = .{ .sampleType = wgpu.WGPUTextureSampleType_BindingNotUsed },
                .storageTexture = .{ .access = wgpu.WGPUStorageTextureAccess_BindingNotUsed }
            }}
        }) orelse return error.CreateBindGroupLayoutFailed;
        defer wgpu.wgpuBindGroupLayoutRelease(bg_layout);

        bind_group = wgpu.wgpuDeviceCreateBindGroup(interface.device, &.{
            .layout = bg_layout,
            .entryCount = 1,
            .entries = &[_]wgpu.WGPUBindGroupEntry{.{
                .binding = 0,
                .buffer = inner,
                .offset = 0,
                .size = wgpu.WGPU_WHOLE_SIZE
            }}
        }) orelse return error.CreateBindGroupFailed;
    }

    return .{
        .interface = interface,
        .inner = inner,
        .size = size,
        .bind_group = bind_group,
        .map_type = if (usage.is(.map_read)) .read
            else if (usage.is(.map_write)) .write
            else .none,
        .is_mapped = mapped_at_creation
    };
}

fn map(self: *Self) void {
    if (self.map_type == .none) unreachable;
    // wgpu.WGPUBufferGetMapState is unimplemented.
    // switch (wgpu.wgpuBufferGetMapState(self.inner)) {
        // wgpu.WGPUBufferMapState_Unmapped => {
    if (self.is_mapped) return;
            const mode = switch (self.map_type) {
                .read => wgpu.WGPUMapMode_Read,
                else => wgpu.WGPUMapMode_Write
            };
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

pub fn mapRead(self: *Self) ![]const u8 {
    if (self.map_type != .read) return error.NotReadMapped;
    self.map();
    return @as([*]const u8, @ptrCast(@alignCast(wgpu.wgpuBufferGetConstMappedRange(self.inner, 0, self.size))))[0..self.size];
}

pub fn mapWrite(self: *Self) ![]u8 {
    if (self.map_type != .write) return error.NotWriteMapped;
    self.map();
    return @as([*]u8, @ptrCast(@alignCast(wgpu.wgpuBufferGetConstMappedRange(self.inner, 0, self.size))))[0..self.size];
}

pub fn unmap(self: *Self) void {
    // wgpu.WGPUBufferGetMapState is unimplemented.
    // if (self.map_type == .none or wgpu.WGPUBufferGetMapState(self.inner) != wgpu.WGPUBufferMapState_Mapped) return;
    if (self.map_type == .none or !self.is_mapped) return;
    wgpu.wgpuBufferUnmap(self.inner);
}