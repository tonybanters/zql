const std = @import("std");
const Term = @import("term.zig").Term;
const Config = @import("config.zig");
const UI = @import("ui.zig").UI;
const ConnectionPicker = @import("connection_picker.zig").ConnectionPicker;
const db = @import("db.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var config = Config.init(allocator);
    defer config.deinit();
    config.load() catch {};

    var term = try Term.init();
    defer term.deinit();

    var picker = try ConnectionPicker.init(allocator, &term);
    defer picker.deinit();

    var conn = picker.run() catch |err| {
        if (err == error.Quit) return;
        return err;
    } orelse return;
    defer conn.disconnect();

    var ui = try UI.init(allocator, &term, &config, &conn);
    defer ui.deinit();

    try ui.run();
}
