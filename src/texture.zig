const std = @import("std");
const wgpu = @import("wgpu");
const util = @import("./util.zig");
const enums = @import("./enums.zig");
const Interface = @import("./interface.zig");
const BindGroup = @import("./bind_group.zig");

const Self = @This();

pub const Format = enums.TextureFormat;

pub const Usage = enum (wgpu.WGPUTextureUsage) {
    none = wgpu.WGPUTextureUsage_None,
    copy_source = wgpu.WGPUTextureUsage_CopySrc,
    copy_dest = wgpu.WGPUTextureUsage_CopyDst,
    texture_binding = wgpu.WGPUTextureUsage_TextureBinding,
    storage_binding = wgpu.WGPUTextureUsage_StorageBinding,
    render_attachment = wgpu.WGPUTextureUsage_RenderAttachment,
    _,

    pub fn with(a: Usage, b: Usage) Usage { return @enumFromInt(@intFromEnum(a) | @intFromEnum(b)); }
    pub fn is(a: Usage, b: Usage) bool { return (@intFromEnum(a) & @intFromEnum(b)) != 0; }
    pub fn isNot(a: Usage, b: Usage) bool { return !a.is(b); }
};

pub const BindGroupLayout = .{
    .{ .texture = .{
        .stage = .fragment
    }},
    .{ .sampler = .{
        .stage = .fragment
    }}
};

inner: util.Known(wgpu.WGPUTexture),
width: u32,
height: u32,
format: enums.TextureFormat,
view: wgpu.WGPUTextureView,
sampler: wgpu.WGPUSampler,
bind_group: ?BindGroup,

pub fn deinit(self: *Self) void {
    if (self.bind_group) |*bg| bg.deinit();
    if (self.sampler) |samp| wgpu.wgpuSamplerRelease(samp);
    if (self.view) |view| wgpu.wgpuTextureViewRelease(view);
    wgpu.wgpuTextureRelease(self.inner);
    self.* = undefined;
}

pub const Layout = struct {
    usage: Usage,
    format: enums.TextureFormat,
    bound: bool = false,
    view: ?struct{} = null,
    sampler: ?struct {
        address_mode: enums.AddressMode = .clamp_to_edge,
        address_mode_u: ?enums.AddressMode = null,
        address_mode_v: ?enums.AddressMode = null,
        address_mode_w: ?enums.AddressMode = null,
        mag_filter: enums.FilterMode = .nearest,
        min_filter: enums.FilterMode = .nearest,
        mipmap_filter: enums.FilterMode = .nearest,
        lod_min_clamp: f32 = 0.0,
        lod_max_clamp: f32 = 32.0,
        compare: enums.CompareFunction = .none,
        max_anisotropy: u16 = 1
    } = null
};

pub fn init(interface: *Interface, width: u32, height: u32, comptime layout: Layout) !Self {
    const inner = wgpu.wgpuDeviceCreateTexture(interface.device, &.{
        .usage = @intFromEnum(layout.usage),
        .format = @intFromEnum(layout.format),
        .dimension = wgpu.WGPUTextureDimension_2D,
        .size = .{ .width = width, .height = height, .depthOrArrayLayers = 1 },
        .mipLevelCount = 1,
        .sampleCount = 1
    }) orelse return error.CreateTextureFailed;
    errdefer wgpu.wgpuTextureRelease(inner);

    var view: wgpu.WGPUTextureView = null;
    const view_layout: @FieldType(Layout, "view") =
        if (layout.usage.is(Usage.texture_binding) and layout.view == null) .{} else layout.view;
    if (view_layout) |_| {
        view = wgpu.wgpuTextureCreateView(inner, &.{
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
    }

    var sampler: wgpu.WGPUSampler = null;
    const sampler_layout: @FieldType(Layout, "sampler") =
        if (layout.usage.is(Usage.texture_binding) and layout.sampler == null) .{} else layout.sampler;
    if (sampler_layout) |samp| {
        sampler = wgpu.wgpuDeviceCreateSampler(interface.device, &.{
            .addressModeU = @intFromEnum(samp.address_mode_u orelse samp.address_mode),
            .addressModeV = @intFromEnum(samp.address_mode_v orelse samp.address_mode),
            .addressModeW = @intFromEnum(samp.address_mode_w orelse samp.address_mode),
            .magFilter = @intFromEnum(samp.mag_filter),
            .minFilter = @intFromEnum(samp.min_filter),
            .mipmapFilter = @intFromEnum(samp.mipmap_filter),
            .lodMinClamp = samp.lod_min_clamp,
            .lodMaxClamp = samp.lod_max_clamp,
            .compare = @intFromEnum(samp.compare),
            .maxAnisotropy = samp.max_anisotropy
        }) orelse return error.CreateSamplerFailed;
        errdefer wgpu.wgpuSamplerRelease(sampler);
    }

    var texture: Self = .{
        .inner = inner,
        .width = width,
        .height = height,
        .format = layout.format,
        .view = view,
        .sampler = sampler,
        .bind_group = null
    };

    var bind_group: ?BindGroup = null;
    if (layout.bound) {
        bind_group = try .init(interface, BindGroupLayout, .{
            texture,
            texture
        });
    }

    texture.bind_group = bind_group;

    return texture;
}

pub fn write(self: *Self, interface: *Interface, data: []u8) void {
    const bytes = bytesFor(self.format);
    wgpu.wgpuQueueWriteTexture(interface.queue,
        &.{
            .texture = self.inner,
            .mipLevel = 0,
            .origin = .{},
            .aspect = wgpu.WGPUTextureAspect_All
        },
        data.ptr,
        bytes * self.width * self.height,
        &.{ .offset = 0, .bytesPerRow = bytes * self.width, .rowsPerImage = self.height },
        &.{ .width = self.width, .height = self.height, .depthOrArrayLayers = 1 }
    );
}

pub fn bytesFor(format: enums.TextureFormat) u32 {
    return switch (format) {
        .bgra8_unorm_srgb => 4,
        else => @panic("Ionno.")
    };
}
