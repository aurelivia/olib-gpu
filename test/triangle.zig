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

pub fn main() !void {
    var interface: gpu.Interface = try .init();
    defer interface.deinit();

    var shader: gpu.Shader = try .init(&interface, shader_src);
    defer shader.deinit();

    var output: gpu.Buffer = try .init(&interface, .{ .output = .{ .size = total_size }});
    defer output.deinit();

    var canvas: gpu.Canvas = try .init(&interface, .{ .width = width, .height = height });
    defer canvas.deinit();

    var pipeline: gpu.Pipeline.Render = try .init(&interface, shader, .{
        .vertex = .{},
        .fragment = .{
            .target = .{
                .blend = .{
                    .color = .{ .op = .add, .source_factor = .src_alpha, .dest_factor = .one_minus_src_alpha },
                    .alpha = .{ .op = .add, .source_factor = .zero, .dest_factor = .one }
                }
            }
        }
    });
    defer pipeline.deinit();

    canvas.setPipeline(pipeline);
    canvas.draw();
    canvas.end();

    canvas.copyToBuffer(&output, bytes_per_row);
    try canvas.submit();

    const result = try output.mapRead();
    defer output.unmap();

    var dest = try zigimg.Image.fromRawPixels(std.testing.allocator, width, height, result, .bgra32);
    defer dest.deinit();

    try dest.writeToFilePath("./test/triangle.bmp", .{ .bmp = .{} });
}