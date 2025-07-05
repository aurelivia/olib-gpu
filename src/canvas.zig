const std = @import("std");
const wgpu = @import("wgpu");
const util = @import("./util.zig");
const enums = @import("./enums.zig");
const Interface = @import("./interface.zig");
const Surface = @import("./surface.zig");
const Buffer = @import("./buffer.zig").Buffer;
const RenderPipeline = @import("./render_pipeline.zig");
const Texture = @import("./texture.zig");
const BindGroup = @import("./bind_group.zig");

pub const Usage = enums.TextureUsage;

const Self = @This();
interface: *Interface,
target: util.Known(wgpu.WGPUTexture),
view: util.Known(wgpu.WGPUTextureView),
depth_view: wgpu.WGPUTextureView,
encoder: util.Known(wgpu.WGPUCommandEncoder),
pass: wgpu.WGPURenderPassEncoder,
pipeline_set: bool = false,

pub fn deinit(self: *Self) void {
    if (self.pass) |pass| wgpu.wgpuRenderPassEncoderRelease(pass);
    wgpu.wgpuCommandEncoderRelease(self.encoder);
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

    const encoder = wgpu.wgpuDeviceCreateCommandEncoder(interface.device, &.{}) orelse return error.CreateEncoderFailed;
    errdefer wgpu.wgpuCommandEncoderRelease(encoder);

    const pass = wgpu.wgpuCommandEncoderBeginRenderPass(encoder, &.{
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
        .encoder = encoder,
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

fn assertCanDraw(self: *Self) !util.Known(wgpu.WGPURenderPassEncoder) {
    if (self.pass) |pass| {
        if (!self.pipeline_set) return error.NoCanvasSource;
        return pass;
    } else return error.CanvasDrawingFinished;
}

pub fn source(self: *Self, pipeline: RenderPipeline) !void {
    if (self.pass) |pass| {
        wgpu.wgpuRenderPassEncoderSetPipeline(pass, pipeline.inner);
        self.pipeline_set = true;
    } else return error.CanvasDrawingFinished;
}

pub fn bind(self: *Self, num: u32, binding: BindGroup) !void {
    const pass = try self.assertCanDraw();
    wgpu.wgpuRenderPassEncoderSetBindGroup(pass, num, binding.inner, 0, null);
}

pub fn drawGenerated(self: *Self, start: u32, len: u32) !void {
    const pass = try self.assertCanDraw();
    wgpu.wgpuRenderPassEncoderDraw(pass, len, 1, start, 0);
}

pub fn draw(self: *Self, comptime T: type, vertices: Buffer(.vertex, T)) !void {
    try self.drawSlice(vertices, 0, vertices.len);
}

pub fn drawSlice(self: *Self, comptime T: type, vertices: Buffer(.vertex, T), start: u32, len: u32) !void {
    const pass = try self.assertCanDraw();
    wgpu.wgpuRenderPassEncoderSetVertexBuffer(pass, 0, vertices.inner, 0, vertices.size);
    wgpu.wgpuRenderPassEncoderDraw(pass, len, 0, start, 0);
}

pub fn drawIndexed(self: *Self, comptime T: type, vertices: Buffer(.vertex, T), indices: Buffer(.index, u32)) !void {
    try self.drawIndexedSlice(vertices, indices, 0, indices.len);
}

pub fn drawIndexedSlice(self: *Self, comptime T: type, vertices: Buffer(.vertex, T), indices: Buffer(.index, u32), start: u32, len: u32) !void {
    const pass = try self.assertCanDraw();
    wgpu.wgpuRenderPassEncoderSetVertexBuffer(pass, 0, vertices.inner, 0, vertices.size);
    wgpu.wgpuRenderPassEncoderSetIndexBuffer(pass, 0, indices.inner, wgpu.WGPUIndexFormat_Uint32, 0, indices.size);
    wgpu.wgpuRenderPassEncoderDraw(pass, vertices.len, len, 0, start);
}

pub fn finishDrawing(self: *Self) !void {
    if (self.pass) |pass| {
        wgpu.wgpuRenderPassEncoderEnd(pass);
        wgpu.wgpuRenderPassEncoderRelease(pass);
        self.pass = null;
        self.pipeline_set = false;
    }
}

pub fn submit(self: *Self) !void {
    if (self.pass != null) return error.CanvassDrawingNotFinished;
    defer self.deinit();

    const commands = wgpu.wgpuCommandEncoderFinish(self.encoder, &.{}) orelse return error.CommandEncodingError;
    defer wgpu.wgpuCommandBufferRelease(commands);

    const queue = [_]wgpu.WGPUCommandBuffer{commands};
    wgpu.wgpuQueueSubmit(self.interface.queue, queue.len, &queue);
}