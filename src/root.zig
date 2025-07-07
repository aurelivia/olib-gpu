pub const BindGroup = @import("./bind_group.zig");
const buffer = @import("./buffer.zig");
pub const Buffer = struct {
    pub fn Vertex(comptime T: type) type { return buffer.Buffer(.vertex, T); }
    pub const Index = buffer.IndexBuffer;
    pub fn Uniform(comptime T: type) type { return buffer.Buffer(.uniform, T); }
    pub fn Storage(comptime T: type) type { return buffer.Buffer(.storage, T); }
    pub fn Staging(comptime T: type) type { return buffer.Buffer(.staging, T); }
    pub fn Input(comptime T: type) type { return buffer.Buffer(.input, T); }
    pub fn Output(comptime T: type) type { return buffer.Buffer(.output, T); }
};
pub const BufferType = @import("./buffer.zig").Type;
pub const Canvas = @import("./canvas.zig");
pub const Interface = @import("./interface.zig");
pub const Pipeline = struct {
    pub const Render = @import("./render_pipeline.zig");
};
pub const Surface = @import("./surface.zig");
pub const Texture = @import("./texture.zig");