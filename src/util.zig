const std = @import("std");
const wgpu = @import("wgpu");

pub fn Known(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |o| o.child,
        else => T
    };
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

inline fn AnyUnionFieldResult(comptime u: type, comptime field_name: [:0]const u8) type {
    const TU = @typeInfo(u);
    var TR: ?type = null;
    switch (TU) {
        .@"union" => |U| {
            for (U.fields) |T| {
                for (@typeInfo(T.@"type").@"struct".fields) |field| {
                    if (std.mem.eql(u8, field.name, field_name)) {
                        if (TR) |tr| {
                            if (field.@"type" != tr) @compileError("Type mismatch.");
                        } else TR = field.@"type";
                        break;
                    }
                } else @compileError(std.fmt.comptimePrint("Union doesn't have field \"{s}\".", .{ field_name }));
            }
        },
        else => @compileError("Not a union.")
    }
    return TR.?;
}

pub inline fn anyUnionField(u: anytype, comptime field_name: [:0]const u8) AnyUnionFieldResult(@TypeOf(u), field_name) {
    return @field(@field(u, @tagName(u)), field_name);
}