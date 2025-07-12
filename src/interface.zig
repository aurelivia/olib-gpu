const std = @import("std");
const wgpu = @import("wgpu");
const util = @import("./util.zig");
const log = std.log.scoped(.@"olib-gpu");
const wgpuLog = std.log.scoped(.wgpu);
const MappedBuffer = @import("./buffer/mapped.zig");

const Self = @This();

mem: std.mem.Allocator,
instance: util.Known(wgpu.WGPUInstance),
adapter: util.Known(wgpu.WGPUAdapter),
device: util.Known(wgpu.WGPUDevice),
queue: util.Known(wgpu.WGPUQueue),
encoder: util.Known(wgpu.WGPUCommandEncoder),

buffer_mappings: std.ArrayListUnmanaged(*MappedBuffer.Inner),

pub fn deinit(self: *Self) void {
    wgpu.wgpuCommandEncoderRelease(self.encoder);
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
    backend: Backend = .any,
    log_level: std.log.Level =
        if (std.log.logEnabled(.debug, .wgpu)) .debug
        else if (std.log.logEnabled(.info, .wgpu)) .info
        else if (std.log.logEnabled(.warn, .wgpu)) .warn
        else .err
};

pub fn init(mem: std.mem.Allocator, comptime layout: Layout) !Self {
    wgpu.wgpuSetLogCallback(logCallback, null);
    wgpu.wgpuSetLogLevel(switch (layout.log_level) {
        .debug => wgpu.WGPULogLevel_Debug,
        .info => wgpu.WGPULogLevel_Info,
        .warn => wgpu.WGPULogLevel_Warn,
        else => wgpu.WGPULogLevel_Error
    });

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
    errdefer wgpu.wgpuQueueRelease(queue);

    const encoder = wgpu.wgpuDeviceCreateCommandEncoder(device, &.{}) orelse return error.CreateEncoderFailed;

    return .{
        .mem = mem,
        .instance = instance,
        .adapter = adapter,
        .device = device,
        .queue = queue,
        .encoder = encoder,
        .buffer_mappings = .empty
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
    _: [*c]const wgpu.WGPUDevice, _: wgpu.WGPUDeviceLostReason, message: wgpu.WGPUStringView,
    _: ?*anyopaque, _: ?*anyopaque
) callconv(.C) void {
    if (util.fromStringView(message)) |m| wgpuLog.err("{s}", .{ m });
    @panic("WGPU Error");
}

fn deviceUncapturedError(
    _: [*c]const wgpu.WGPUDevice, error_type: wgpu.WGPUErrorType, message: wgpu.WGPUStringView,
    _: ?*anyopaque, _: ?*anyopaque
) callconv(.C) void {
    if (util.fromStringView(message)) |m| wgpuLog.err("{s}", .{ m });
    switch (error_type) {
        wgpu.WGPUErrorType_NoError => {},
        else => @panic("WGPU Error")
    }
}

fn logCallback(level: wgpu.WGPULogLevel, message: wgpu.WGPUStringView, _: ?*anyopaque) callconv(.C) void {
    switch (level) {
        wgpu.WGPULogLevel_Error => {
            if (util.fromStringView(message)) |m| wgpuLog.err("{s}", .{ m });
            @panic("WGPU Error");
        },
        wgpu.WGPULogLevel_Warn  => if (util.fromStringView(message)) |m| wgpuLog.warn("{s}", .{ m }),
        wgpu.WGPULogLevel_Info  => if (util.fromStringView(message)) |m| wgpuLog.info("{s}", .{ m }),
        wgpu.WGPULogLevel_Debug => if (util.fromStringView(message)) |m| wgpuLog.debug("{s}", .{ m }),
        else => {}
    }
}

pub fn submit(self: *Self) !void {
    for (self.buffer_mappings.items) |buf| {
        buf.mapping = null;
        wgpu.wgpuBufferUnmap(buf.buffer);
    }

    const commands = wgpu.wgpuCommandEncoderFinish(self.encoder, &.{}) orelse return error.CommandEncodingError;
    defer wgpu.wgpuCommandBufferRelease(commands);
    wgpu.wgpuQueueSubmit(self.queue, 1, &[1]wgpu.WGPUCommandBuffer{commands});
    wgpu.wgpuCommandEncoderRelease(self.encoder);

    for (self.buffer_mappings.items) |buf| {
        buf.copy_queued = false;
        if (buf.wants_mapping) buf.map();
    }

    self.encoder = wgpu.wgpuDeviceCreateCommandEncoder(self.device, &.{}) orelse return error.CreateEncoderFailed;
}