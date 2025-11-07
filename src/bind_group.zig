const BindGroup = @This();

const std = @import("std");
const wgpu = @import("wgpu");
const util = @import("./util.zig");
const enums = @import("./enums.zig");
const log = std.log.scoped(.@"olib-gpu");
const Interface = @import("./interface.zig");
const Slice = @import("./buffer/slice.zig");
const Texture = @import("./texture.zig");

pub const Stage = enum (wgpu.WGPUShaderStage) {
    vertex = wgpu.WGPUShaderStage_Vertex,
    fragment = wgpu.WGPUShaderStage_Fragment,
    both = wgpu.WGPUShaderStage_Vertex | wgpu.WGPUShaderStage_Fragment,
    compute = wgpu.WGPUShaderStage_Compute,
    _
};

pub const EntryType = enum { uniform, storage, texture, sampler };
pub const Entry = union (EntryType) {
    uniform: struct {
        stage: Stage,
        type: type,
    },
    storage: struct {
        stage: Stage,
        type: type,
        writable: bool = false
    },
    texture: struct {
        stage: Stage
    },
    sampler: struct {
        stage: Stage
    }
};

pub fn Layout(comptime layout: anytype) type { return struct {
    const _Layout = @This();
    comptime { if (@typeInfo(@TypeOf(layout)) != .@"struct") @compileError("BindGroup layout must be a tuple."); }
    const meta = @typeInfo(@TypeOf(layout)).@"struct";
    comptime { if (!meta.is_tuple) @compileError("BindGroup layout must be a tuple."); }

    inner: util.Known(wgpu.WGPUBindGroupLayout),

    pub fn deinit(self: *_Layout) void {
        wgpu.wgpuBindGroupLayoutRelease(self.inner);
        self.* = undefined;
    }

    pub fn init(interface: *Interface) !_Layout {
        const entries: [meta.fields.len]wgpu.WGPUBindGroupLayoutEntry = comptime b: {
            var entries: [meta.fields.len]wgpu.WGPUBindGroupLayoutEntry = undefined;
            for (0..meta.fields.len) |i| {
                const entry = layout[i];
                if (@TypeOf(entry) != Entry) @compileError("All entries in layout tuple must be of Entry type.");
                entries[i] = .{
                    .binding = i,
                    .visibility = @intFromEnum(util.anyUnionField(entry, "stage")),
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

            break :b entries;
        };

        const inner = wgpu.wgpuDeviceCreateBindGroupLayout(interface.device, &.{
            .entryCount = entries.len,
            .entries = &entries
        }) orelse return error.CreateBindGroupFailed;

        return .{ .inner = inner };
    }

    pub const Values = b: {
        var fields: [meta.fields.len]std.builtin.Type.StructField = undefined;
        for (0..meta.fields.len) |i| {
            const T = switch (layout[i]) {
                .uniform, .storage => Slice,
                .texture, .sampler => Texture
            };

            fields[i] = .{
                .name = std.fmt.comptimePrint("{}", .{ i }),
                .@"type" = T,
                .default_value_ptr = null,
                .is_comptime = false,
                .alignment = @alignOf(T)
            };
        }

        break :b @Type(.{ .@"struct" = .{
            .layout = .auto,
            .fields = &fields,
            .decls = &.{},
            .is_tuple = true
        }});
    };

    fn instance(self: *const _Layout, interface: *Interface, values: Values) !BindGroup {
        var entries: [meta.fields.len]wgpu.WGPUBindGroupEntry = undefined;
        inline for (0..meta.fields.len) |i| {
            entries[i] = .{
                .binding = @intCast(i),
                .offset = 0,
                .size = wgpu.WGPU_WHOLE_SIZE,
                .buffer = switch (layout[i]) {
                    .uniform, .storage => values[i].source,
                    else => null
                },
                .sampler = switch (layout[i]) {
                    .sampler => values[i].sampler,
                    else => null
                },
                .textureView = switch (layout[i]) {
                    .texture => values[i].view,
                    else => null
                }
            };
        }

        const inner = wgpu.wgpuDeviceCreateBindGroup(interface.device, &.{
            .layout = self.inner,
            .entryCount = entries.len,
            .entries = &entries
        }) orelse return error.CreateBindGroupInstanceFailed;

        return .{ .inner = inner };
    }
};}

inner: util.Known(wgpu.WGPUBindGroup),

pub fn deinit(self: *BindGroup) void {
    wgpu.wgpuBindGroupRelease(self.inner);
    self.* = undefined;
}

pub fn init(interface: *Interface, comptime layout: anytype, values: Layout(layout).Values) !BindGroup {
    var bind_group: Layout(layout) = try .init(interface);
    defer bind_group.deinit();

    return try bind_group.instance(interface, values);
}
