const std = @import("std");

pub const DbType = enum {
    sqlite,
    postgresql,
};

pub const Config = struct {
    allocator: std.mem.Allocator,
    db_path: ?[]const u8 = null,
    db_type: DbType = .sqlite,
    tables_width: u16 = 25,
    query_height: u16 = 5,
    show_line_numbers: bool = true,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        if (self.db_path) |path| {
            self.allocator.free(path);
        }
    }

    pub fn load(self: *Self) !void {
        const config_paths = [_][]const u8{
            "config.lua",
            ".config/zql/config.lua",
        };

        var home_buf: [256]u8 = undefined;
        const home = std.posix.getenv("HOME") orelse return;

        for (config_paths) |rel_path| {
            const full_path = std.fmt.bufPrint(&home_buf, "{s}/{s}", .{ home, rel_path }) catch continue;
            self.load_file(full_path) catch continue;
            return;
        }
    }

    fn load_file(self: *Self, path: []const u8) !void {
        _ = self;
        const file = try std.fs.openFileAbsolute(path, .{});
        defer file.close();
        _ = try file.stat();
    }

    pub fn get_config_dir(allocator: std.mem.Allocator) ![]const u8 {
        const home = std.posix.getenv("HOME") orelse return error.NoHome;
        return std.fmt.allocPrint(allocator, "{s}/.config/zql", .{home});
    }
};

pub const init = Config.init;
