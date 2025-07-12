const std = @import("std");
const wgpu = @import("wgpu");
const util = @import("./util.zig");
const enums = @import("./enums.zig");
const log = std.log.scoped(.@"olib-gpu");

const Interface = @import("./interface.zig");
const Surface = @import("./surface.zig");
const RenderPipeline = @import("./render_pipeline.zig");
const BufferSlice = @import("./buffer/slice.zig");
const Texture = @import("./texture.zig");
const BindGroup = @import("./bind_group.zig");

pub const Usage = enums.TextureUsage;

const Self = @This();
interface: *Interface,
target: util.Known(wgpu.WGPUTexture),
view: util.Known(wgpu.WGPUTextureView),
depth_view: wgpu.WGPUTextureView,
pass: wgpu.WGPURenderPassEncoder,
pipeline_set: bool = false,

pub fn deinit(self: *Self) void {
    if (self.pass) |pass| wgpu.wgpuRenderPassEncoderRelease(pass);
    if (self.depth_view) |depth_view| wgpu.wgpuTextureViewRelease(depth_view);
    wgpu.wgpuTextureViewRelease(self.view);
}

fn initInner(interface: *Interface, target: util.Known(wgpu.WGPUTexture), depth: ?wgpu.WGPUTexture) !Self {
    const view = wgpu.wgpuTextureCreateView(target, &.{
        .format = wgpu.WGPUTextureFormat_Undefined,
        .dimension = wgpu.WGPUTextureViewDimension_Undefined,
        .baseMipLevel = 0,
        .mipLevelCount = wgpu.WGPU_MIP_LEVEL_COUNT_UNDEFINED,
        .baseArrayLayer = 0,
        .arrayLayerCount = wgpu.WGPU_ARRAY_LAYER_COUNT_UNDEFINED,
        .aspect = wgpu.WGPUTextureAspect_All,
        .usage = wgpu.WGPUTextureUsage_None
    }) orelse return error.CreateTextureViewFailed;
    errdefer wgpu.wgpuTextureViewRelease(view);

    var depth_view: wgpu.WGPUTextureView = null;
    if (depth) |d| {
        depth_view = wgpu.wgpuTextureCreateView(d, &.{
            .format = wgpu.WGPUTextureFormat_Undefined,
            .dimension = wgpu.WGPUTextureViewDimension_Undefined,
            .baseMipLevel = 0,
            .mipLevelCount = wgpu.WGPU_MIP_LEVEL_COUNT_UNDEFINED,
            .baseArrayLayer = 0,
            .arrayLayerCount = wgpu.WGPU_ARRAY_LAYER_COUNT_UNDEFINED,
            .aspect = wgpu.WGPUTextureAspect_All,
            .usage = wgpu.WGPUTextureUsage_None
        }) orelse return error.CreateTextureViewFailed;
        errdefer wgpu.wgpuTextureViewRelease(depth_view);
    }

    const pass = wgpu.wgpuCommandEncoderBeginRenderPass(interface.encoder, &.{
        .colorAttachmentCount = 1,
        .colorAttachments = &[_]wgpu.WGPURenderPassColorAttachment{.{
            .view = view,
            .depthSlice = wgpu.WGPU_DEPTH_SLICE_UNDEFINED,
            .loadOp = wgpu.WGPULoadOp_Clear,
            .storeOp = wgpu.WGPUStoreOp_Store
        }},
        .depthStencilAttachment = if (depth) |_| &.{
            .view = depth_view,
            .depthLoadOp = wgpu.WGPULoadOp_Clear,
            .depthStoreOp = wgpu.WGPUStoreOp_Store,
            .depthClearValue = 1.0,
            .depthReadOnly = @intFromBool(false)
        } else null
    }) orelse return error.CreateRenderPassFailed;

    return .{
        .interface = interface,
        .target = target,
        .view = view,
        .depth_view = depth_view,
        .pass = pass
    };
}

pub fn init(interface: *Interface, target: Texture) !Self {
    return initInner(interface, target.inner, null);
}

pub fn initWithDepth(interface: *Interface, target: Texture, depth: Texture) !Self {
    return initInner(interface, target.inner, depth.inner);
}

pub fn fromSurface(surface: *Surface) !Self {
    const target: util.Known(wgpu.WGPUTexture) = b: {
        var texture: wgpu.WGPUSurfaceTexture = undefined;
        wgpu.wgpuSurfaceGetCurrentTexture(surface.inner, &texture);
        break :b texture.texture orelse return error.CreateTextureFailed;
    };

    return if (surface.depth) |depth| initInner(surface.interface, target, depth.inner)
         else initInner(surface.interface, target, null);
}

fn assertCanDraw(self: *Self) util.Known(wgpu.WGPURenderPassEncoder) {
    if (self.pass) |pass| {
        if (!self.pipeline_set) {
            log.err("Attempt to draw or bind to canvas without pipeline sourced.", .{});
            unreachable;
        }
        return pass;
    } else {
        log.err("Attempt to draw or bind to finished canvas.", .{});
        unreachable;
    }
}

pub fn source(self: *Self, pipeline: RenderPipeline) void {
    if (self.pass) |pass| {
        wgpu.wgpuRenderPassEncoderSetPipeline(pass, pipeline.inner);
        self.pipeline_set = true;
    } else {
        log.err("Attempt to source pipeline on finished canvas.", .{});
        unreachable;
    }
}

pub fn bind(self: *Self, num: u32, binding: BindGroup) void {
    const pass = self.assertCanDraw();
    wgpu.wgpuRenderPassEncoderSetBindGroup(pass, num, binding.inner, 0, null);
}

pub fn drawGenerated(self: *Self, start: u32, len: u32) void {
    const pass = self.assertCanDraw();
    wgpu.wgpuRenderPassEncoderDraw(pass, len, 1, start, 0);
}

pub fn draw(self: *Self, vertices: BufferSlice, indexes: ?BufferSlice, instances: ?BufferSlice) void {
    const pass = self.assertCanDraw();
    wgpu.wgpuRenderPassEncoderSetVertexBuffer(pass, 0, vertices.source, vertices.byte_start, vertices.byte_len);
    const instance_start: u32 = if (instances) |i| i.start else 0;
    const instance_len: u32 = if (instances) |i| i.len else 1;
    if (instances) |i| wgpu.wgpuRenderPassEncoderSetVertexBuffer(pass, 1, i.source, i.byte_start, i.byte_len);
    if (indexes) |i| {
        wgpu.wgpuRenderPassEncoderSetIndexBuffer(pass, i.source, wgpu.WGPUIndexFormat_Uint32, i.byte_start, i.byte_len);
        wgpu.wgpuRenderPassEncoderDrawIndexed(pass, i.len, instance_len, i.start, 0, instance_start);
    } else wgpu.wgpuRenderPassEncoderDraw(pass, vertices.len, instance_len, vertices.start, instance_start);
}

pub fn finish(self: *Self) void {
    if (self.pass) |pass| {
        wgpu.wgpuRenderPassEncoderEnd(pass);
        wgpu.wgpuRenderPassEncoderRelease(pass);
        self.pass = null;
        self.pipeline_set = false;
    }
}