const Canvas = @This();

const std = @import("std");
const OOM = error { OutOfMemory };
const wgpu = @import("wgpu");
const util = @import("./util.zig");
const enums = @import("./enums.zig");
const log = std.log.scoped(.@"olib-gpu");

const Interface = @import("./interface.zig");
const Surface = @import("./surface.zig");
const RenderPipeline = @import("./pipeline/render.zig");
const GPUSlice = @import("./buffer/gpu_slice.zig");
const Texture = @import("./texture.zig");
const BindGroup = @import("./bind_group.zig");

pub const Usage = enums.TextureUsage;

pass: wgpu.WGPURenderPassEncoder,
pipeline_set: bool = false,

pub fn deinit(self: *Canvas) void {
    if (self.pass) |pass| wgpu.wgpuRenderPassEncoderRelease(pass);
    self.* = undefined;
}

pub fn init(interface: *Interface, targets: []const Texture, depth: ?Texture) OOM!Canvas {
    if (targets.len > 64) {
        log.err("Target slice of length {d} exceeds maximum of 64.", .{ targets.len });
        unreachable;
    }

    var color_attachments: [64]wgpu.WGPURenderPassColorAttachment = undefined;
    for (targets, 0..) |target, i| {
        color_attachments[i] = .{
            .view = target.view,
            .depthSlice = wgpu.WGPU_DEPTH_SLICE_UNDEFINED,
            .loadOp = wgpu.WGPULoadOp_Clear,
            .storeOp = wgpu.WGPUStoreOp_Store
        };
    }

    const pass = wgpu.wgpuCommandEncoderBeginRenderPass(interface.encoder, &.{
        .colorAttachmentCount = targets.len,
        .colorAttachments = @as([*c]wgpu.WGPURenderPassColorAttachment, &color_attachments),
        .depthStencilAttachment = if (depth) |d| &.{
            .view = d.view,
            .depthLoadOp = wgpu.WGPULoadOp_Clear,
            .depthStoreOp = wgpu.WGPUStoreOp_Store,
            .depthClearValue = 1.0,
            .depthReadOnly = @intFromBool(false)
        } else null
    }) orelse unreachable;

    return .{ .pass = pass };
}

fn assertCanDraw(self: *Canvas) util.Known(wgpu.WGPURenderPassEncoder) {
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

pub fn source(self: *Canvas, pipeline: RenderPipeline) void {
    if (self.pass) |pass| {
        wgpu.wgpuRenderPassEncoderSetPipeline(pass, pipeline.inner);
        self.pipeline_set = true;
    } else {
        log.err("Attempt to source pipeline on finished canvas.", .{});
        unreachable;
    }
}

pub fn bind(self: *Canvas, num: u32, binding: BindGroup) void {
    const pass = self.assertCanDraw();
    wgpu.wgpuRenderPassEncoderSetBindGroup(pass, num, binding.inner, 0, null);
}

pub fn drawGenerated(self: *Canvas, offset: u32, len: u32) void {
    const pass = self.assertCanDraw();
    wgpu.wgpuRenderPassEncoderDraw(pass, len, 1, offset, 0);
}

pub fn draw(self: *Canvas, vertices: GPUSlice, indexes: ?GPUSlice, instances: ?GPUSlice) void {
    const pass = self.assertCanDraw();
    wgpu.wgpuRenderPassEncoderSetVertexBuffer(pass, 0, vertices.source, vertices.byte_offset, vertices.byte_len);
    const instance_offset: u32 = if (instances) |i| i.offset else 0;
    const instance_len: u32 = if (instances) |i| i.len else 1;
    if (instances) |i| wgpu.wgpuRenderPassEncoderSetVertexBuffer(pass, 1, i.source, i.byte_offset, i.byte_len);
    if (indexes) |i| {
        wgpu.wgpuRenderPassEncoderSetIndexBuffer(pass, i.source, wgpu.WGPUIndexFormat_Uint32, i.byte_offset, i.byte_len);
        wgpu.wgpuRenderPassEncoderDrawIndexed(pass, i.len, instance_len, i.offset, 0, instance_offset);
    } else wgpu.wgpuRenderPassEncoderDraw(pass, vertices.len, instance_len, vertices.offset, instance_offset);
}

pub fn finish(self: *Canvas) void {
    if (self.pass) |pass| {
        wgpu.wgpuRenderPassEncoderEnd(pass);
        wgpu.wgpuRenderPassEncoderRelease(pass);
        self.pass = null;
        self.pipeline_set = false;
    }
}
