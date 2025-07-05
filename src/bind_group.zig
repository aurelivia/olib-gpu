const std = @import("std");
const wgpu = @import("wgpu");
const util = @import("./util.zig");
const enums = @import("./enums.zig");
const Interface = @import("./interface.zig");
const Buffer = @import("./buffer.zig").Buffer;
const Texture = @import("./texture.zig");

pub const Self = @This();

pub const Stage = enum (wgpu.WGPUShaderStage) {
    vertex = wgpu.WGPUShaderStage_Vertex,
    fragment = wgpu.WGPUShaderStage_Fragment,
    both = wgpu.WGPUShaderStage_Vertex | wgpu.WGPUShaderStage_Fragment,
    compute = wgpu.WGPUShaderStage_Compute,
    _
};

pub const EntryType = enum { uniform, storage, texture, sampler };

pub const Layout = []const Entry;
pub const Entry = union (EntryType) {
    uniform: struct {
        elem_type: type,
        visibility: Stage
    },
    storage: struct {
        elem_type: type,
        visibility: Stage,
        writable: bool = false
    },
    texture: struct {
        visibility: Stage
    },
    sampler: struct {
        visibility: Stage
    }
};

inner: util.Known(wgpu.WGPUBindGroup),

pub fn deinit(self: *Self) void {
    wgpu.wgpuBindGroupRelease(self.inner);
}

inline fn entryLayout(comptime layout: Layout) type {
    var fields: [layout.len]std.builtin.Type.StructField = undefined;
    for (layout, 0..) |entry, i| {
        const T = switch (entry) {
            .uniform => |e| Buffer(.uniform, e.elem_type),
            .storage => |e| Buffer(.storage, e.elem_type),
            .texture => Texture,
            .sampler => Texture
        };

        fields[i] = .{
            .name = std.fmt.comptimePrint("{}", .{ i }),
            .@"type" = T,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(T)
        };
    }

    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &fields,
        .decls = &.{},
        .is_tuple = true
    }});
}

pub fn init(interface: *Interface, comptime layout: Layout, entries: entryLayout(layout)) !Self {
    std.debug.assert(layout.len == entries.len);
    const bg_layout = try instantiateLayout(interface, layout);
    defer wgpu.wgpuBindGroupLayoutRelease(bg_layout);

    var inner_entries: [layout.len]wgpu.WGPUBindGroupEntry = undefined;
    inline for (layout, 0..) |entry, i| inner_entries[i] = entryFor(i, entry, entries[i]);
    const inner = wgpu.wgpuDeviceCreateBindGroup(interface.device, &.{
        .layout = bg_layout,
        .entryCount = entries.len,
        .entries = &inner_entries
    }) orelse return error.CreateBindGroupFailed;

    return .{
        .inner = inner
    };
}

pub fn instantiateLayout(interface: *Interface, comptime layout: Layout) !util.Known(wgpu.WGPUBindGroupLayout) {
    var entries: [layout.len]wgpu.WGPUBindGroupLayoutEntry = undefined;
    inline for (layout, 0..) |entry, i| entries[i] = layoutEntryFor(i, entry);
    return wgpu.wgpuDeviceCreateBindGroupLayout(interface.device, &.{
        .entryCount = layout.len,
        .entries = &entries
    }) orelse error.CreateBindGroupLayoutFailed;
}

inline fn layoutEntryFor(comptime binding: u32, comptime entry: Entry) wgpu.WGPUBindGroupLayoutEntry {
    return .{
        .binding = binding,
        .visibility = @intFromEnum(util.anyUnionField(entry, "visibility")),
        .buffer = switch (entry) {
            .uniform => |_| .{
                .@"type" = wgpu.WGPUBufferBindingType_Uniform,
                .hasDynamicOffset = @intFromBool(false),
                .minBindingSize = 0
            },
            .storage => |e| .{
                .@"type" = if (e.writable) wgpu.WGPUBufferBindingType_Storage
                           else wgpu.WGPUBufferBindingType_ReadOnlyStorage,
                .hasDynamicOffset = @intFromBool(false),
                .minBindingSize = 0
            },
            else => .{ .@"type" = wgpu.WGPUBufferBindingType_BindingNotUsed }
        },
        .texture = switch (entry) {
            .texture => |_| .{
                .sampleType = wgpu.WGPUTextureSampleType_Float,
                .viewDimension = wgpu.WGPUTextureViewDimension_2D,
                .multisampled = @intFromBool(false)
            },
            else => .{ .sampleType = wgpu.WGPUTextureSampleType_BindingNotUsed }
        },
        .sampler = switch (entry) {
            .sampler => |_| .{
                .@"type" = wgpu.WGPUSamplerBindingType_Filtering
            },
            else => .{ .@"type" = wgpu.WGPUSamplerBindingType_BindingNotUsed }
        },
        .storageTexture = switch (entry) {
            else => .{ .access = wgpu.WGPUStorageTextureAccess_BindingNotUsed }
        }
    };
}

inline fn entryFor(comptime binding: u32, comptime entry: Entry, value: anytype) wgpu.WGPUBindGroupEntry {
    return .{
        .binding = binding,
        .offset = 0,
        .size = wgpu.WGPU_WHOLE_SIZE,
        .buffer = switch (entry) {
            .uniform => value.inner,
            .storage => value.inner,
            else => null
        },
        .sampler = switch (entry) {
            .sampler => value.sampler,
            else => null
        },
        .textureView = switch (entry) {
            .texture => value.view,
            else => null
        }
    };
}