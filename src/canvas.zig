const wgpu = @import("wgpu");
const util = @import("./util.zig");
const enums = @import("./enums.zig");
const Interface = @import("./interface.zig");
const Window = @import("./window.zig");
const Buffer = @import("./buffer.zig");
const RenderPipeline = @import("./render_pipeline.zig");

pub const Usage = enums.TextureUsage;

const Self = @This();
interface: *Interface,
target: util.Known(wgpu.WGPUTexture),
view: util.Known(wgpu.WGPUTextureView),
encoder: util.Known(wgpu.WGPUCommandEncoder),
pass: wgpu.WGPURenderPassEncoder,

pub fn deinit(self: *Self) void {
    if (self.pass) |pass| wgpu.wgpuRenderPassEncoderRelease(pass);
    wgpu.wgpuCommandEncoderRelease(self.encoder);
    wgpu.wgpuTextureViewRelease(self.view);
    wgpu.wgpuTextureRelease(self.target);
}

fn _initInner(interface: *Interface, target: util.Known(wgpu.WGPUTexture)) !Self {
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

    const encoder = wgpu.wgpuDeviceCreateCommandEncoder(interface.device, &.{}) orelse return error.CreateEncoderFailed;
    errdefer wgpu.wgpuCommandEncoderRelease(encoder);

    const pass = wgpu.wgpuCommandEncoderBeginRenderPass(encoder, &.{
        .colorAttachmentCount = 1,
        .colorAttachments = &[_]wgpu.WGPURenderPassColorAttachment{.{
            .view = view,
            .depthSlice = wgpu.WGPU_DEPTH_SLICE_UNDEFINED,
            .loadOp = wgpu.WGPULoadOp_Clear,
            .storeOp = wgpu.WGPUStoreOp_Store
        }}
    }) orelse return error.CreateRenderPassFailed;

    return .{
        .interface = interface,
        .target = target,
        .view = view,
        .encoder = encoder,
        .pass = pass
    };
}

pub const Layout = struct {
    width: u32,
    height: u32,
    format: enums.TextureFormat = .bgra8_unorm_srgb
    // usage: enums.TextureUsage,
    // format: enums.TextureFormat
};

pub fn init(interface: *Interface, layout: Layout) !Self {
    const target: util.Known(wgpu.WGPUTexture) = wgpu.wgpuDeviceCreateTexture(interface.device, &.{
        // .usage = layout.usage,
        .usage = 17,
        .dimension = wgpu.WGPUTextureDimension_2D,
        .size = .{ .width = layout.width, .height = layout.height, .depthOrArrayLayers = 1 },
        .format = @intFromEnum(layout.format),
        .mipLevelCount = 1,
        .sampleCount = 1
    }) orelse return error.CreateTextureFailed;
    errdefer wgpu.wgpuTextureRelease(target);

    return try _initInner(interface, target);
}

pub fn fromWindow(window: Window) !Self {
    const target: util.Known(wgpu.WGPUTexture) = b: {
        var texture: wgpu.WGPUSurfaceTexture = undefined;
        wgpu.wgpuSurfaceGetCurrentTexture(window.surface, &texture);
        break :b texture.texture orelse return error.CreateTextureFailed;
    };
    errdefer wgpu.wgpuTextureRelease(target);

    return try _initInner(&(window.interface), target);
}

pub fn setPipeline(self: *Self, pipeline: RenderPipeline) void {
    wgpu.wgpuRenderPassEncoderSetPipeline(self.pass.?, pipeline.inner);
}

pub fn draw(self: *Self) void {
    wgpu.wgpuRenderPassEncoderDraw(self.pass.?, 3, 1, 0, 0);
}

pub fn copyToBuffer(self: *Self, buffer: *Buffer, bpr_temp: u32) void {
    wgpu.wgpuCommandEncoderCopyTextureToBuffer(self.encoder, &.{
        .texture = self.target,
        .mipLevel = 0,
        .origin = .{},
        .aspect = wgpu.WGPUTextureAspect_All
    }, &.{
        .buffer = buffer.inner,
        .layout = .{
            .offset = 0,
            .bytesPerRow = bpr_temp,
            .rowsPerImage = wgpu.wgpuTextureGetHeight(self.target)
        }
    }, &.{
        .height = wgpu.wgpuTextureGetHeight(self.target),
        .width = wgpu.wgpuTextureGetWidth(self.target),
        .depthOrArrayLayers = wgpu.wgpuTextureGetDepthOrArrayLayers(self.target)
    });
}

pub fn end(self: *Self) void {
    wgpu.wgpuRenderPassEncoderEnd(self.pass);
    self.pass = null;
}

pub fn submit(self: *Self) !void {
    defer self.deinit();

    const commands = wgpu.wgpuCommandEncoderFinish(self.encoder, &.{}) orelse return error.CommandEncodingError;
    defer wgpu.wgpuCommandBufferRelease(commands);

    const queue = [_]wgpu.WGPUCommandBuffer{commands};
    wgpu.wgpuQueueSubmit(self.interface.queue, queue.len, &queue);
    // switch (wgpu.wgpuSurfacePresent(self.canvas.surface)) {
    //     .success => {},
    //     else => return error.PresentationError
    // }
}