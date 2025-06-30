const std = @import("std");
const wgpu = @import("wgpu");

pub fn Known(comptime T: type) type {
    return @typeInfo(T).optional.child;
}

pub fn toStringView(str: []const u8) wgpu.WGPUStringView {
    return .{
        .data = str.ptr,
        .length = str.len
    };
}

pub fn fromStringView(str: wgpu.WGPUStringView) ?[]const u8 {
    const data = str.data orelse return null;
    if (str.length == wgpu.WGPU_STRLEN)
        return std.mem.sliceTo(@as([*:0]const u8, @ptrCast(data)), 0);
    return data[0..str.length];
}