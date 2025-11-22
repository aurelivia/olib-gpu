pub const BindGroup = @import("./bind_group.zig");
pub const Buffer = struct {
    pub const GPUSlice = @import("./buffer/gpu_slice.zig");
    pub const Fixed = @import("./buffer/fixed.zig")._Fixed;
    pub const Mapped = @import("./buffer/mapped.zig")._Mapped;
    pub const Staged = @import("./buffer/staged.zig")._Staged;
    pub const Vertex = struct {
        pub fn Fixed(comptime T: type) type { return Buffer.Fixed(.vertex, T); }
        pub fn Dynamic(comptime T: type) type { return Staged(.vertex, T); }
    };
    pub const Index = struct {
        pub const Fixed = Buffer.Fixed(.index, u32);
        pub const Dynamic = Staged(.index, u32);
    };
    pub const Instance = struct {
        pub const Fixed = Buffer.Fixed(.vertex, [4]@Vector(4, f32));
        pub const Dynamic = Staged(.vertex, [4]@Vector(4, f32));
    };
    pub fn Uniform(comptime T: type) type { return Staged(.uniform, T); }
    pub fn Storage(comptime T: type) type { return Staged(.storage, T); }
};
pub const Canvas = @import("./canvas.zig");
pub const Interface = @import("./interface.zig");
pub const Pipeline = struct {
    pub const Render = @import("./pipeline/render.zig");
    pub const Compute = @import("./pipeline/compute.zig");
};
pub const Surface = @import("./surface.zig");
pub const Texture = @import("./texture.zig");
