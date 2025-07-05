const std = @import("std");
const wgpu = @import("wgpu");
const util = @import("./util.zig");
const enums = @import("./enums.zig");
const Self = @This();
const Interface = @import("./interface.zig");
const Canvas = @import("./canvas.zig");

interface: *Interface,
inner: util.Known(wgpu.WGPUSurface),
format: enums.TextureFormat,
config: wgpu.WGPUSurfaceConfiguration,

pub fn deinit(self: *Self) void {
    wgpu.wgpuSurfaceRelease(self.inner);
}

pub const Source = union (enum) {
    android_native: *anyopaque,
    hwnd: struct { hinstance: *anyopaque, hwnd: *anyopaque },
    metal: *anyopaque,
    wayland: struct { display: *anyopaque, surface: *anyopaque },
    xcb: struct { connection: *anyopaque, window: u32 },
    xlib: struct { display: *anyopaque, window: u32 }
};

pub fn init(interface: *Interface, source: Source, width: u32, height: u32) !Self {
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

    const inner = wgpu.wgpuInstanceCreateSurface(interface.instance, &desc) orelse return error.CreateSurfaceFailed;
    errdefer wgpu.wgpuSurfaceRelease(inner);

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

    const present_mode = for (0..capabilities.presentModeCount) |i| {
        const mode = capabilities.presentModes[i];
        if (mode == wgpu.WGPUPresentMode_Mailbox) break mode;
    } else wgpu.WGPUPresentMode_Fifo;

    const config: wgpu.WGPUSurfaceConfiguration = .{
        .device = interface.device,
        .format = format,
        .usage = wgpu.WGPUTextureUsage_RenderAttachment,
        .width = width,
        .height = height,
        .alphaMode = capabilities.alphaModes[0],
        .presentMode = present_mode,
        // .nextInChain = @ptrCast(&wgpu.WGPUSurfaceConfigurationExtras{
        //     .chain = .{ .sType = wgpu.WGPUSType_SurfaceConfigurationExtras },
        //     .desiredMaximumFrameLatency = 2
        // })
    };

    wgpu.wgpuSurfaceConfigure(inner, &config);

    return .{
        .interface = interface,
        .inner = inner,
        .depth = null,
        .format = @enumFromInt(format),
        .config = config
    };
}

pub fn resize(self: *Self, width: u32, height: u32) !void {
    self.config.width = width;
    self.config.height = height;
    wgpu.wgpuSurfaceConfigure(self.inner, &self.config);
}

pub fn canvas(self: *Self) !Canvas {
    return Canvas.fromSurface(self);
}

pub fn present(self: *Self) !void {
    switch (wgpu.wgpuSurfacePresent(self.inner)) {
        wgpu.WGPUStatus_Success => {},
        else => return error.PresentationError
    }
}
