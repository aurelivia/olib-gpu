const std = @import("std");
const gpu = @import("olib-gpu");
const zigimg = @import("zigimg");

const shader_src =
\\ struct VertexOutput {
\\     @builtin(position) pos: vec4<f32>
\\ };
\\
\\ @vertex
\\ fn vert(@builtin(vertex_index) idx: u32) -> VertexOutput {
\\     var out: VertexOutput;
\\     let x = f32(1 - i32(idx)) * 0.5;
\\     let y = f32(i32(idx & 1u) * 2 - 1) * 0.5;
\\     out.pos = vec4<f32>(x, y, 0.0, 1.0);
\\     return out;
\\ }
\\
\\ @fragment
\\ fn frag(in: VertexOutput) -> @location(0) vec4<f32> {
\\     return vec4<f32>(0.3, 0.2, 0.1, 1.0);
\\ }
;

const Vertex = extern struct {
    pos: [3]f32
};

const width = 640;
const height = 480;
const bytes_per_row = 4 * width;
const total_size = bytes_per_row * height;

const mem = std.testing.allocator;

pub fn main() !void {
    var interface: gpu.Interface = try .init(mem, .{});
    defer interface.deinit();

    var pipeline: gpu.Pipeline.Render = try .init(&interface, .{
        .vertex = .{},
        .depth = false,
        .fragment = .{
            .source = shader_src,
            .targets = &.{.{ .format = .bgra8_unorm_srgb, .blend = gpu.Pipeline.Render.BlendState.alpha_blending }}
        }
    }, .{});
    defer pipeline.deinit();

    var surface: gpu.Texture = try .init(&interface, width, height, .{
        .usage = gpu.Texture.Usage.surface.with(.copy_source),
        .format = .bgra8_unorm_srgb
    });
    defer surface.deinit();

    var output: gpu.Buffer.Mapped(.output, u8) = try .init(&interface, total_size);
    defer output.deinit();

    var canvas: gpu.Canvas = try .init(&interface, &.{ surface }, null);
    defer canvas.deinit();

    canvas.source(pipeline);
    canvas.drawGenerated(0, 3);
    canvas.finish();

    output.copyTexture(surface);

    interface.submit();

    var dest = try zigimg.Image.fromRawPixels(mem, width, height, output.items(), .bgra32);
    defer dest.deinit();

    try dest.writeToFilePath("./test/triangle.bmp", .{ .bmp = .{} });
}