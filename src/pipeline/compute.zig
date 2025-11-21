const ComputePipeline = @This();

const std = @import("std");
const OOM = error { OutOfMemory };
const wgpu = @import("wgpu");
const util = @import("../util.zig");
const enums = @import("../enums.zig");
const Interface = @import("../interface.zig");
const BindGroup = @import("../bind_group.zig");

inner: util.Known(wgpu.WGPUComputePipeline),

pub fn deinit(self: *ComputePipeline) void {
    wgpu.wgpuComputePipelineRelease(self.inner);
    self.* = undefined;
}

pub const Layout = struct {
    source: []const u8,
    entry: []const u8 = "main"
};

pub fn init(interface: *Interface, comptime layout: Layout, comptime bind_groups: anytype) OOM!ComputePipeline {
    const shader = wgpu.wgpuDeviceCreateShaderModule(interface.device, &.{
        .nextInChain = @ptrCast(&wgpu.WGPUShaderSourceWGSL{
            .chain = .{ .sType = wgpu.WGPUSType_ShaderSourceWGSL },
            .code = util.toStringView(layout.source)
        })
    }) orelse unreachable;
    defer wgpu.wgpuShaderModuleRelease(shader);

    if (@typeInfo(@TypeOf(bind_groups)) != .@"struct") @compileError("bind_groups must be a tuple.");
    const meta = @typeInfo(@TypeOf(bind_groups)).@"struct";
    if (!meta.is_tuple) @compileError("bind_groups must be a tuple.");
    var bg_layouts: [meta.fields.len]wgpu.WGPUBindGroupLayout = undefined;
    inline for (0..meta.fields.len) |i| bg_layouts[i] = (try BindGroup.Layout(bind_groups[i]).init(interface)).inner;
    defer inline for (bg_layouts) |bg| wgpu.wgpuBindGroupLayoutRelease(bg);

    const pipeline_layout = wgpu.wgpuDeviceCreatePipelineLayout(interface.device, &.{
        .bindGroupLayoutCount = layout.bind_groups.len,
        .bindGroupLayouts = &bg_layouts
    }) orelse unreachable;
    defer wgpu.wgpuPipelineLayoutRelease(pipeline_layout);

    const inner = wgpu.wgpuDeviceCreateComputePipeline(interface.device, &.{
        .layout = pipeline_layout,
        .compute = &.{
            .module = shader,
            .entryPoint = util.toStringView(layout.entry)
        }
    }) orelse unreachable;

    return .{ .inner = inner };
}
