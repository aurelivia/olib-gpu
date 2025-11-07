pub const BindGroup = @import("./bind_group.zig");
pub const Buffer = struct {
    pub const Slice = @import("./buffer/slice.zig");
    pub const Fixed = @import("./buffer/fixed.zig").Fixed;
    pub const Mapped = @import("./buffer/mapped.zig").Mapped;
    pub const Staged = @import("./buffer/staged.zig").Staged;
    pub fn Vertex(comptime T: type) type { return Fixed(.vertex, T); }
    pub const Index = Fixed(.index, u32);
    pub const Instance = Staged(.instance, [4]@Vector(4, f32));
    pub fn Uniform(comptime T: type) type { return Staged(.uniform, T); }
};
pub const Canvas = @import("./canvas.zig");
pub const Interface = @import("./interface.zig");
pub const Pipeline = struct {
    pub const Render = @import("./pipeline/render.zig");
};
pub const Surface = @import("./surface.zig");
pub const Texture = @import("./texture.zig");
