const std = @import("std");
const wgpu = @import("wgpu");
const util = @import("./util.zig");

const Self = @This();

instance: util.Known(wgpu.WGPUInstance),
adapter: util.Known(wgpu.WGPUAdapter),
device: util.Known(wgpu.WGPUDevice),
queue: util.Known(wgpu.WGPUQueue),

pub fn deinit(self: *Self) void {
    wgpu.wgpuQueueRelease(self.queue);
    wgpu.wgpuDeviceRelease(self.device);
    wgpu.wgpuAdapterRelease(self.adapter);
    wgpu.wgpuInstanceRelease(self.instance);
}

pub const Backend = enum (wgpu.WGPUBackendType) {
    any = wgpu.WGPUBackendType_Undefined,
    webgpu = wgpu.WGPUBackendType_WebGPU,
    d3d11 = wgpu.WGPUBackendType_D3D11,
    d3d12 = wgpu.WGPUBackendType_D3D12,
    metal = wgpu.WGPUBackendType_Metal,
    vulkan = wgpu.WGPUBackendType_Vulkan,
    opengl = wgpu.WGPUBackendType_OpenGL,
    opengles = wgpu.WGPUBackendType_OpenGLES
};

pub const Layout = struct {
    backend: Backend = .any
};

pub fn init(comptime layout: Layout) !Self {
    const instance: util.Known(wgpu.WGPUInstance) = wgpu.wgpuCreateInstance(null) orelse return error.CreateInstanceFailed;
    errdefer wgpu.wgpuInstanceRelease(instance);

    var adapter_response: AdapterResponse = undefined;
    var adapter_completed: bool = false;
    _ = wgpu.wgpuInstanceRequestAdapter(instance, &.{
        .featureLevel = wgpu.WGPUFeatureLevel_Core,
        .powerPreference = wgpu.WGPUPowerPreference_Undefined,
        .forceFallbackAdapter = @intFromBool(false),
        .backendType = @intFromEnum(layout.backend)
    }, .{
        .mode = wgpu.WGPUCallbackMode_AllowProcessEvents,
        .callback = adapterCallback,
        .userdata1 = @ptrCast(&adapter_response),
        .userdata2 = @ptrCast(&adapter_completed)
    });

    wgpu.wgpuInstanceProcessEvents(instance);
    while (!adapter_completed) wgpu.wgpuInstanceProcessEvents(instance);

    const adapter: util.Known(wgpu.WGPUAdapter) = switch (adapter_response.status) {
        wgpu.WGPURequestAdapterStatus_Success => adapter_response.adapter.?,
        else => return error.CreateAdapterFailed
    };
    errdefer wgpu.wgpuAdapterRelease(adapter);

    var device_response: DeviceResponse = undefined;
    var device_completed: bool = false;
    _ = wgpu.wgpuAdapterRequestDevice(adapter, &.{
        .deviceLostCallbackInfo = .{
            .mode = wgpu.WGPUCallbackMode_AllowProcessEvents,
            .callback = deviceLost
        },
        .uncapturedErrorCallbackInfo = .{ .callback = deviceUncapturedError }
    }, .{
        .mode = wgpu.WGPUCallbackMode_AllowProcessEvents,
        .callback = deviceCallback,
        .userdata1 = @ptrCast(&device_response),
        .userdata2 = @ptrCast(&device_completed)
    });

    wgpu.wgpuInstanceProcessEvents(instance);
    while (!device_completed) wgpu.wgpuInstanceProcessEvents(instance);

    const device = switch (device_response.status) {
        wgpu.WGPURequestDeviceStatus_Success => device_response.device.?,
        else => return error.CreateDeviceFailed
    };
    errdefer wgpu.wgpuDeviceRelease(device);

    const queue = wgpu.wgpuDeviceGetQueue(device) orelse return error.CreateQueueFailed;

    wgpu.wgpuSetLogCallback(logCallback, null);
    wgpu.wgpuSetLogLevel(2);

    return .{
        .instance = instance,
        .adapter = adapter,
        .device = device,
        .queue = queue
    };
}

const AdapterResponse = struct {
    status: wgpu.WGPURequestAdapterStatus,
    message: []const u8,
    adapter: wgpu.WGPUAdapter
};

fn adapterCallback(
    status: wgpu.WGPURequestAdapterStatus, adapter: wgpu.WGPUAdapter, message: wgpu.WGPUStringView,
    userdata1: ?*anyopaque, userdata2: ?*anyopaque
) callconv(.C) void {
    const response: *AdapterResponse = @ptrCast(@alignCast(userdata1));
    response.* = .{
        .status = status,
        .message = util.fromStringView(message) orelse "",
        .adapter = adapter
    };

    const completed: *bool = @ptrCast(@alignCast(userdata2));
    completed.* = true;
}

const DeviceResponse = struct {
    status: wgpu.WGPURequestDeviceStatus,
    message: []const u8,
    device: wgpu.WGPUDevice
};

fn deviceCallback(
    status: wgpu.WGPURequestDeviceStatus, device: wgpu.WGPUDevice, message: wgpu.WGPUStringView,
    userdata1: ?*anyopaque, userdata2: ?*anyopaque
) callconv(.C) void {
    const response: *DeviceResponse = @ptrCast(@alignCast(userdata1));
    response.* = .{
        .status = status,
        .message = util.fromStringView(message) orelse "",
        .device = device
    };

    const completed: *bool = @ptrCast(@alignCast(userdata2));
    completed.* = true;
}

fn deviceLost(
    device: [*c]const wgpu.WGPUDevice, reason: wgpu.WGPUDeviceLostReason, message: wgpu.WGPUStringView,
    userdata1: ?*anyopaque, userdata2: ?*anyopaque
) callconv(.C) void {
    _ = device; _ = userdata1; _ = userdata2;

    const r = switch (reason) {
        wgpu.WGPUDeviceLostReason_Destroyed => "Destroyed",
        wgpu.WGPUDeviceLostReason_InstanceDropped => "Instance Dropped",
        wgpu.WGPUDeviceLostReason_FailedCreation => "Failed Creation",
        else => "Unknown"
    };

    std.debug.panic("Device Lost: {s}, Message: {s}\n", .{ r, util.fromStringView(message) orelse "" });
}

fn deviceUncapturedError(
    device: [*c]const wgpu.WGPUDevice, error_type: wgpu.WGPUErrorType, message: wgpu.WGPUStringView,
    userdata1: ?*anyopaque, userdata2: ?*anyopaque
) callconv(.C) void {
    _ = device; _ = userdata1; _ = userdata2;

    const e = switch (error_type) {
        wgpu.WGPUErrorType_NoError => "No Error",
        wgpu.WGPUErrorType_Validation => "Validation",
        wgpu.WGPUErrorType_OutOfMemory => "Out of Memory",
        wgpu.WGPUErrorType_Internal => "Internal",
        else => "Unknown"
    };

    std.debug.panic("Device Uncaptured Error: {s}, Message: {s}\n", .{ e, util.fromStringView(message) orelse "" });
}

fn logCallback(level: wgpu.WGPULogLevel, message: wgpu.WGPUStringView, _: ?*anyopaque) callconv(.C) void {
    _ = level;
    std.debug.print("{s}\n", .{ util.fromStringView(message) orelse "" });
}