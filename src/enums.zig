const std = @import("std");
const wgpu = @import("wgpu");

const decls = @typeInfo(wgpu).@"struct".decls;

fn startsWith(comptime str: [:0]const u8, comptime pref: [:0]const u8) bool {
    @setEvalBranchQuota(200000);
    if (str.len < pref.len) return false;
    for (0..str.len) |i| {
        if (i >= pref.len) return true;
        if (str[i] != pref[i]) return false;
    }
    return true;
}

fn contains(comptime ex: []const [:0]const u8, comptime str: [:0]const u8) bool {
    @setEvalBranchQuota(200000);
    for (ex) |e| {
        if (std.mem.eql(u8, str, e)) return true;
    }
    return false;
}

fn toBreak(comptime mp: ?u8, comptime c: u8, comptime mn: ?u8) bool {
    if (std.ascii.isUpper(c)) {
        if (mp) |p| {
            if (mn) |n| {
                if (std.ascii.isDigit(p)) {
                    return true;
                } else if (std.ascii.isLower(p)) {
                    return true;
                } else return std.ascii.isLower(n);
            } else return std.ascii.isDigit(p) or std.ascii.isLower(p);
        } else return false;
    } else return false;
}

fn countCaps(comptime str: []const u8) usize {
    @setEvalBranchQuota(200000);
    var caps: usize = 0;
    var p: ?u8 = null;
    var n: ?u8 = null;
    for (0..str.len) |i| {
        if (i != (str.len - 1)) n = str[i + 1] else n = null;
        if (toBreak(p, str[i], n)) caps += 1;
        p = str[i];
    }

    return caps;
}

fn snakeCase(comptime str: []const u8) [:0]const u8 {
    @setEvalBranchQuota(200000);
    var snake: [(str.len + countCaps(str)):0]u8 = undefined;
    var s: usize = 0;
    var p: ?u8 = null;
    var n: ?u8 = null;
    for (0..str.len) |i| {
        if (i != (str.len - 1)) n = str[i + 1] else n = null;
        if (toBreak(p, str[i], n)) {
            snake[s] = '_'; s += 1;
        }
        snake[s] = std.ascii.toLower(str[i]);
        p = str[i];
        s += 1;
    }
    snake[s] = '0';
    return &snake;
}

fn buildEnum(comptime tag_type: type, comptime prefix: [:0]const u8, comptime exclude: []const [:0]const u8) type {
    @setEvalBranchQuota(200000);
    const len: comptime_int = b: {
        var len: comptime_int = 0;
        for (decls) |d| {
            if (startsWith(d.name, prefix)) {
                const name = d.name[prefix.len..d.name.len];
                if (!contains(exclude, name)) len += 1;
            }
        }
        break :b len;
    };
    var fields: [len]std.builtin.Type.EnumField = undefined;
    var i: usize = 0;
    for (decls) |d| {
        if (startsWith(d.name, prefix)) {
            const name = d.name[prefix.len..d.name.len];
            if (!contains(exclude, name)) {
                fields[i] = .{
                    .name = snakeCase(d.name[prefix.len..d.name.len]),
                    .value = @field(wgpu, d.name)
                };
                i += 1;
            }
        }
    }
    if (i != fields.len) @compileError("Field length mismatch.");

    const T: std.builtin.Type.Enum = .{
        .tag_type = tag_type,
        .fields = fields[0..fields.len],
        .decls = &.{},
        .is_exhaustive = true
    };

    return @Type(.{ .@"enum" = T });
}

pub const TextureUsage = buildEnum(wgpu.WGPUTextureUsage, "WGPUTextureUsage_", 6, &[_][:0]const u8 {
    "Undefined", "Force32"
});
pub const TextureFormat = buildEnum(wgpu.WGPUTextureFormat, "WGPUTextureFormat_", &[_][:0]const u8 {
    "Undefined", "Force32"
});
pub const Topology = buildEnum(wgpu.WGPUPrimitiveTopology, "WGPUPrimitiveTopology_", &[_][:0]const u8 {
    "Undefined", "Force32"
});
pub const CullMode = buildEnum(wgpu.WGPUCullMode, "WGPUCullMode_", &[_][:0]const u8 {
    "Undefined", "Force32"
});
pub const BlendOperation = buildEnum(wgpu.WGPUBlendOperation, "WGPUBlendOperation_", &[_][:0]const u8 {
    "Undefined", "Force32"
});
pub const BlendFactor = buildEnum(wgpu.WGPUBlendFactor, "WGPUBlendFactor_", &[_][:0]const u8 {
    "Undefined", "Force32"
});