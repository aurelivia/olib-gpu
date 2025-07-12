const std = @import("std");
const wgpu = @import("wgpu");
const util = @import("../util.zig");

const Self = @This();

source: util.Known(wgpu.WGPUBuffer),
start: u32 = 0,
byte_start: u32 = 0,
len: u32,
byte_len: u32