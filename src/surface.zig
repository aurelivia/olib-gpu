const std = @import("std");
const OOM = error { OutOfMemory };
const wgpu = @import("wgpu");
const util = @import("./util.zig");
const enums = @import("./enums.zig");
const log = std.log.scoped(.@"olib-gpu");

const Self = @This();
const Interface = @import("./interface.zig");
const Canvas = @import("./canvas.zig");
const Texture = @import("./texture.zig");

interface: *Interface,
inner: util.Known(wgpu.WGPUSurface),
depth: ?Texture,
format: enums.TextureFormat,
config: wgpu.WGPUSurfaceConfiguration,

pub fn deinit(self: *Self) void {
    wgpu.wgpuSurfaceRelease(self.inner);
    self.* = undefined;
}

pub const Source = union (enum) {
    android_native: *anyopaque,
    hwnd: struct { hinstance: *anyopaque, hwnd: *anyopaque },
    metal: *anyopaque,
    wayland: struct { display: *anyopaque, surface: *anyopaque },
    xcb: struct { connection: *anyopaque, window: u32 },
    xlib: struct { display: *anyopaque, window: u32 }
};

pub fn init(interface: *Interface, source: Source, width: u32, height: u32, useDepth: bool) OOM!Self {
    log.info("Configuring surface for: {s}", .{ @tagName(source) });
    const desc: wgpu.WGPUSurfaceDescriptor = .{
        .nextInChain = switch (source) {
            .android_native => |win| @ptrCast(&wgpu.WGPUSurfaceSourceAndroidNativeWindow{
                .chain = .{ .sType = wgpu.WGPUSType_SurfaceSourceAndroidNativeWindow },
                .window = win
            }),
            .hwnd => |desc| @ptrCast(&wgpu.WGPUSurfaceSourceWindowsHWND{
                .chain = .{ .sType = wgpu.WGPUSType_SurfaceSourceWindowsHWND },
                .hinstance = desc.hinstance,
                .hwnd = desc.hwnd
            }),
            .metal => |layer| @ptrCast(&wgpu.WGPUSurfaceSourceMetalLayer{
                .chain = .{ .sType = wgpu.WGPUSType_SurfaceSourceMetalLayer },
                .layer = layer
            }),
            .wayland => |desc| @ptrCast(&wgpu.WGPUSurfaceSourceWaylandSurface{
                .chain = .{ .sType = wgpu.WGPUSType_SurfaceSourceWaylandSurface },
                .display = desc.display,
                .surface = desc.surface
            }),
            .xcb => |desc| @ptrCast(&wgpu.WGPUSurfaceSourceXCBWindow{
                .chain = .{ .sType = wgpu.WGPUSType_SurfaceSourceXCBWindow },
                .connection = desc.connection,
                .window = desc.window
            }),
            .xlib => |desc| @ptrCast(&wgpu.WGPUSurfaceSourceXlibWindow{
                .chain = .{ .sType = wgpu.WGPUSType_SurfaceSourceXlibWindow },
                .display = desc.display,
                .window = desc.window
            }),
        }
    };

    const inner = wgpu.wgpuInstanceCreateSurface(interface.instance, &desc) orelse unreachable;

    var capabilities: wgpu.WGPUSurfaceCapabilities = undefined;
    switch (wgpu.wgpuSurfaceGetCapabilities(inner, interface.adapter, &capabilities)) {
        wgpu.WGPUStatus_Success => {},
        else => return error.SurfaceCapabilitiesFailed
    }
    defer wgpu.wgpuSurfaceCapabilitiesFreeMembers(capabilities);

    const format = b: {
        const preference = [_]wgpu.WGPUTextureFormat {
            wgpu.WGPUTextureFormat_BC7RGBAUnormSrgb,
            wgpu.WGPUTextureFormat_BC3RGBAUnormSrgb,
            wgpu.WGPUTextureFormat_BGRA8UnormSrgb
        };
        var best: ?usize = null;
        for (0..capabilities.formatCount) |i| {
            const format = capabilities.formats[i];
            const idx = for (preference, 0..) |p, j| { if (p == format) break j; } else continue;
            best = if (best) |b| @max(idx, b) else idx;
        }
        break :b if (best) |b| preference[b] else capabilities.formats[0];
    };
    log.info("Surface color format set to: {s}", .{ @tagName(@as(enums.TextureFormat, @enumFromInt(format))) });

    const present_mode = for (0..capabilities.presentModeCount) |i| {
        const mode = capabilities.presentModes[i];
        if (mode == wgpu.WGPUPresentMode_Mailbox) break mode;
    } else wgpu.WGPUPresentMode_Fifo;
    log.info("Surface present mode set to: {s}", .{ if (present_mode == wgpu.WGPUPresentMode_Mailbox) "Mailbox" else "FIFO" });

    const config: wgpu.WGPUSurfaceConfiguration = .{
        .device = interface.device,
        .format = format,
        .usage = wgpu.WGPUTextureUsage_RenderAttachment,
        .width = width,
        .height = height,
        .alphaMode = capabilities.alphaModes[0],
        .presentMode = present_mode,
        .nextInChain = @ptrCast(&wgpu.WGPUSurfaceConfigurationExtras{
            .chain = .{ .sType = wgpu.WGPUSType_SurfaceConfigurationExtras },
            .desiredMaximumFrameLatency = 2
        })
    };

    wgpu.wgpuSurfaceConfigure(inner, &config);

    var surface: Self = .{
        .interface = interface,
        .inner = inner,
        .depth = null,
        .format = @enumFromInt(format),
        .config = config
    };

    if (useDepth) surface.depth = try surface.getDepthTexture();

    return surface;
}

pub fn resize(self: *Self, width: u32, height: u32) OOM!void {
    self.config.width = width;
    self.config.height = height;
    wgpu.wgpuSurfaceConfigure(self.inner, &self.config);
    if (self.depth) |*depth| {
        depth.deinit();
        depth.* = try self.getDepthTexture();
    }
}

pub fn canvas(self: *Self) OOM!Canvas {
    return Canvas.fromSurface(self);
}

pub fn present(self: *Self) void {
    switch (wgpu.wgpuSurfacePresent(self.inner)) {
        wgpu.WGPUStatus_Success => {},
        else => unreachable
    }
}

fn getDepthTexture(self: *Self) OOM!Texture {
    return try .init(self.interface, self.config.width, self.config.height, .{
        .usage = Texture.Usage.render_attachment.with(.texture_binding),
        .format = .depth32_float,
        .sampler = .{
            .mag_filter = .linear,
            .min_filter = .linear,
            .lod_min_clamp = 0.0,
            .lod_max_clamp = 100.0,
            .compare = .less_equal
        }
    });
}
