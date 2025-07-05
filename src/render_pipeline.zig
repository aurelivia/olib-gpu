const std = @import("std");
const wgpu = @import("wgpu");
const util = @import("./util.zig");
const enums = @import("./enums.zig");
const Interface = @import("./interface.zig");
const BindGroup = @import("./bind_group.zig");

const Self = @This();

pub const BlendComponent = struct {
    op: enums.BlendOperation,
    source_factor: enums.BlendFactor,
    dest_factor: enums.BlendFactor,

    pub const replace: BlendComponent = .{
        .op = enums.BlendOperation.add,
        .source_factor = enums.BlendOperation.one,
        .dest_factor = enums.BlendOperation.zero
    };

    pub const over: BlendComponent = .{
        .op = enums.BlendOperation.add,
        .source_factor = enums.BlendFactor.one,
        .dest_factor = enums.BlendFactor.one_minus_src_alpha
    };
};

fn getBlendComponent(c: BlendComponent) wgpu.WGPUBlendComponent {
    return .{
        .operation = @intFromEnum(c.op),
        .srcFactor = @intFromEnum(c.source_factor),
        .dstFactor = @intFromEnum(c.dest_factor)
    };
}

pub const BlendState = struct {
    color: BlendComponent,
    alpha: BlendComponent,

    pub const replace: BlendState = .{
        .color = BlendComponent.replace,
        .alpha = BlendComponent.replace
    };

    pub const alpha_blending: BlendState = .{
        .color = .{
            .op = enums.BlendOperation.add,
            .source_factor = enums.BlendFactor.src_alpha,
            .dest_factor = enums.BlendFactor.one_minus_src_alpha
        },
        .alpha = BlendComponent.over
    };

    pub const premultiplied_alpha_blending: BlendState = .{
        .color = BlendComponent.over,
        .alpha = BlendComponent.over
    };
};

fn getBlendState(c: BlendState) wgpu.WGPUBlendState {
    return .{
        .color = getBlendComponent(c.color),
        .alpha = getBlendComponent(c.alpha)
    };
}

pub const ColorMask = enum (wgpu.WGPUColorWriteMask) {
    none = wgpu.WGPUColorWriteMask_None,
    red = wgpu.WGPUColorWriteMask_Red,
    green = wgpu.WGPUColorWriteMask_Green,
    blue = wgpu.WGPUColorWriteMask_Blue,
    alpha = wgpu.WGPUColorWriteMask_Alpha,
    _,

    pub const all = ColorMask.red.with(.green).with(.blue).with(.alpha);

    pub fn with(a: ColorMask, b: ColorMask) ColorMask { return @enumFromInt(@intFromEnum(a) | @intFromEnum(b)); }
    pub fn is(a: ColorMask, b: ColorMask) bool { return (@intFromEnum(a) & @intFromEnum(b)) != 0; }
    pub fn isNot(a: ColorMask, b: ColorMask) bool { return !a.is(b); }
};

inner: util.Known(wgpu.WGPURenderPipeline),
shader: util.Known(wgpu.WGPUShaderModule),

pub fn deinit(self: *Self) void {
    wgpu.wgpuRenderPipelineRelease(self.inner);
    wgpu.wgpuShaderModuleRelease(self.shader);
}

pub const Target = struct {
    format: enums.TextureFormat,
    blend: ?BlendState = null,
    mask: ColorMask = ColorMask.all
};

pub const Layout = struct {
    source: []const u8,
    bind_groups: []const BindGroup.Layout = &[0]BindGroup.Layout{},
    vertex: ?struct {
        entry: []const u8 = "vert",
        vertex_type: ?type = null,
        topology: enums.Topology = .triangle_list,
        clockwise: bool = false,
        cull_mode: enums.CullMode = .back
    } = null,
    depth: bool = true,
    fragment: struct {
        entry: []const u8 = "frag",
        targets: []const Target
    }
};

pub fn init(interface: *Interface, comptime layout: Layout) !Self {
    const shader = wgpu.wgpuDeviceCreateShaderModule(interface.device, &.{
        .nextInChain = @ptrCast(&wgpu.WGPUShaderSourceWGSL{
            .chain = .{ .sType = wgpu.WGPUSType_ShaderSourceWGSL },
            .code = util.toStringView(layout.source)
        })
    }) orelse return error.CreateShaderFailed;
    errdefer wgpu.wgpuShaderModuleRelease(shader);

    var bg_layouts: [layout.bind_groups.len]wgpu.WGPUBindGroupLayout = undefined;
    inline for (layout.bind_groups, 0..) |bg, i| bg_layouts[i] = try BindGroup.instantiateLayout(interface, bg);
    defer inline for (bg_layouts) |bg| wgpu.wgpuBindGroupLayoutRelease(bg);

    const pipeline_layout = wgpu.wgpuDeviceCreatePipelineLayout(interface.device, &.{
        .bindGroupLayoutCount = layout.bind_groups.len,
        .bindGroupLayouts = &bg_layouts
    }) orelse return error.CreatePipelineLayoutFailed;
    defer wgpu.wgpuPipelineLayoutRelease(pipeline_layout);

    var targets: [layout.fragment.targets.len]wgpu.WGPUColorTargetState = undefined;
    inline for (layout.fragment.targets, 0..) |target, i| targets[i] = .{
        .format = @intFromEnum(target.format),
        .blend = if (target.blend) |b| &getBlendState(b) else null,
        .writeMask = @intFromEnum(target.mask)
    };

    const inner = wgpu.wgpuDeviceCreateRenderPipeline(interface.device, &.{
        .layout = pipeline_layout,
        .vertex = if (layout.vertex) |vert_layout| .{
            .module = shader,
            .entryPoint = util.toStringView(vert_layout.entry),
            .bufferCount = if (vert_layout.vertex_type != null) 1 else 0,
            .buffers = if (vert_layout.vertex_type) |vertex_type|
                &[_]wgpu.WGPUVertexBufferLayout{
                    layoutFor(vertex_type)
                }
            else null
        } else .{},
        .primitive = if (layout.vertex) |vert_layout| .{
            .topology = @intFromEnum(vert_layout.topology),
            .frontFace = if (vert_layout.clockwise) wgpu.WGPUFrontFace_CW else wgpu.WGPUFrontFace_CCW,
            .cullMode = @intFromEnum(vert_layout.cull_mode)
        } else null,
        .fragment = &.{
            .module = shader,
            .entryPoint = util.toStringView(layout.fragment.entry),
            .targetCount = layout.fragment.targets.len,
            .targets = &targets
        },
        .multisample = .{
            .count = 1,
            .mask = ~@as(u32, 0),
            .alphaToCoverageEnabled = @intFromBool(false)
        }
    }) orelse return error.CreatePipelineFailed;

    return .{
        .inner = inner,
        .shader = shader
    };
}

inline fn layoutFor(comptime T: type) wgpu.WGPUVertexBufferLayout {
    return switch (@typeInfo(T)) {
        .int, .float, .array => .{
            .stepMode = wgpu.WGPUVertexStepMode_Vertex,
            .arrayStride = @bitSizeOf(T),
            .attributeCount = 1,
            .attributes = &[_]wgpu.WGPUVertexAttribute{.{
                .shaderLocation = 0,
                .offset = 0,
                .format = comptime formatFor(T)
            }}
        },
        .@"struct" => |s| b: {
            if (s.layout == .auto) @compileError("Vertex struct must have known layout (extern or packed).");
            var attrs: [s.fields.len]wgpu.WGPUVertexAttribute = undefined;
            inline for (s.fields, 0..) |field, i| {
                attrs[i] = .{
                    .shaderLocation = i,
                    .offset = @bitOffsetOf(T, field.name),
                    .format = comptime formatFor(field.type)
                };
            }

            break :b .{
                .stepMode = wgpu.WGPUVertexStepMode_Vertex,
                .arrayStride = @bitSizeOf(T),
                .attributeCount = 1,
                .attributes = &attrs
            };
        },
        else => @compileError(std.fmt.comptimePrint("Unsupported vertex type: {s}", .{ @typeName(T) }))
    };
}

inline fn formatFor(comptime T: type) wgpu.WGPUVertexFormat {
    return switch (T) {
        u8 => wgpu.WGPUVertexFormat_Uint8,
        [2]u8 => wgpu.WGPUVertexFormat_Uint8x2,
        [4]u8 => wgpu.WGPUVertexFormat_Uint8x4,
        u16 => wgpu.WGPUVertexFormat_Uint16,
        [2]u16 => wgpu.WGPUVertexFormat_Uint16x2,
        [4]u16 => wgpu.WGPUVertexFormat_Uint16x4,
        u32 => wgpu.WGPUVertexFormat_Uint32,
        [2]u32 => wgpu.WGPUVertexFormat_Uint32x2,
        [3]u32 => wgpu.WGPUVertexFormat_Uint32x3,
        [4]u32 => wgpu.WGPUVertexFormat_Uint32x4,
        i8 => wgpu.WGPUVertexFormat_Sint8,
        [2]i8 => wgpu.WGPUVertexFormat_Sint8x2,
        [4]i8 => wgpu.WGPUVertexFormat_Sint8x4,
        i16 => wgpu.WGPUVertexFormat_Sint16,
        [2]i16 => wgpu.WGPUVertexFormat_Sint16x2,
        [4]i16 => wgpu.WGPUVertexFormat_Sint16x4,
        i32 => wgpu.WGPUVertexFormat_Sint32,
        [2]i32 => wgpu.WGPUVertexFormat_Sint32x2,
        [3]i32 => wgpu.WGPUVertexFormat_Sint32x3,
        [4]i32 => wgpu.WGPUVertexFormat_Sint32x4,
        f16 => wgpu.WGPUVertexFormat_Float16,
        [2]f16 => wgpu.WGPUVertexFormat_Float16x2,
        [3]f16 => wgpu.WGPUVertexFormat_Float16x3,
        [4]f16 => wgpu.WGPUVertexFormat_Float16x4,
        f32 => wgpu.WGPUVertexFormat_Float32,
        [2]f32 => wgpu.WGPUVertexFormat_Float32x2,
        [3]f32 => wgpu.WGPUVertexFormat_Float32x3,
        [4]f32 => wgpu.WGPUVertexFormat_Float32x4,
        else => @compileError(std.fmt.comptimePrint("Unsupported vertex type: {s}", .{ @typeName(T) }))
    };
}