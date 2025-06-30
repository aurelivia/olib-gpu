const std = @import("std");
const wgpu = @import("wgpu");
const util = @import("./util.zig");
const Interface = @import("./interface.zig");

const Self = @This();

pub const Stage = enum (wgpu.WGPUShaderStage) {
    vertex = wgpu.WGPUShaderStage_Vertex,
    fragment = wgpu.WGPUShaderStage_Fragment,
    both = wgpu.WGPUShaderStage_Vertex | wgpu.WGPUShaderStage_Fragment,
    compute = wgpu.WGPUShaderStage_Compute,
    _
};

inner: util.Known(wgpu.WGPUShaderModule),

pub fn deinit(self: *Self) void {
    wgpu.wgpuShaderModuleRelease(self.inner);
}

pub fn init(interface: *Interface, code: []const u8) !Self {
    return .{
        .inner = wgpu.wgpuDeviceCreateShaderModule(interface.device, &.{
            .nextInChain = @ptrCast(&wgpu.WGPUShaderSourceWGSL{
                .chain = .{ .sType = wgpu.WGPUSType_ShaderSourceWGSL },
                .code = util.toStringView(code)
            })
        }) orelse return error.CreateShaderFailed
    };
}