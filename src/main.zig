const std = @import("std");
const Term = @import("term.zig").Term;
const Config = @import("config.zig");
const UI = @import("ui.zig").UI;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var config = Config.init(allocator);
    defer config.deinit();
    config.load() catch {};

    var term = try Term.init();
    defer term.deinit();

    var ui = try UI.init(allocator, &term, &config);
    defer ui.deinit();

    try ui.run();
}
