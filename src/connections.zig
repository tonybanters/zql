const std = @import("std");

pub const SavedConnection = struct {
    name: []const u8,
    host: []const u8,
    port: u16,
    user: []const u8,
    password: []const u8,
    database: []const u8,
};

pub const ConnectionStore = struct {
    allocator: std.mem.Allocator,
    connections: std.ArrayListUnmanaged(SavedConnection),
    path: []const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        const home = std.posix.getenv("HOME") orelse return error.NoHome;
        const path = try std.fmt.allocPrint(allocator, "{s}/.config/zql/connections.lua", .{home});

        return Self{
            .allocator = allocator,
            .connections = .{},
            .path = path,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.connections.items) |conn| {
            self.allocator.free(conn.name);
            self.allocator.free(conn.host);
            self.allocator.free(conn.user);
            self.allocator.free(conn.password);
            self.allocator.free(conn.database);
        }
        self.connections.deinit(self.allocator);
        self.allocator.free(self.path);
    }

    pub fn load(self: *Self) !void {
        const file = std.fs.openFileAbsolute(self.path, .{}) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(content);

        try self.parse(content);
    }

    fn parse(self: *Self, content: []const u8) !void {
        var i: usize = 0;
        var depth: usize = 0;
        var block_start: ?usize = null;

        while (i < content.len) {
            if (content[i] == '{') {
                depth += 1;
                if (depth == 2) {
                    block_start = i + 1;
                }
            } else if (content[i] == '}') {
                if (depth == 2 and block_start != null) {
                    try self.parse_connection(content[block_start.?..i]);
                    block_start = null;
                }
                if (depth > 0) depth -= 1;
            }
            i += 1;
        }
    }

    fn parse_connection(self: *Self, block: []const u8) !void {
        var conn = SavedConnection{
            .name = "",
            .host = "localhost",
            .port = 3306,
            .user = "",
            .password = "",
            .database = "",
        };

        var lines = std.mem.splitScalar(u8, block, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r,");
            if (trimmed.len == 0) continue;

            if (parse_field(trimmed, "name")) |val| {
                conn.name = try self.allocator.dupe(u8, val);
            } else if (parse_field(trimmed, "host")) |val| {
                conn.host = try self.allocator.dupe(u8, val);
            } else if (parse_field(trimmed, "user")) |val| {
                conn.user = try self.allocator.dupe(u8, val);
            } else if (parse_field(trimmed, "password")) |val| {
                conn.password = try self.allocator.dupe(u8, val);
            } else if (parse_field(trimmed, "database")) |val| {
                conn.database = try self.allocator.dupe(u8, val);
            } else if (parse_number_field(trimmed, "port")) |val| {
                conn.port = val;
            }
        }

        if (conn.name.len > 0) {
            try self.connections.append(self.allocator, conn);
        }
    }

    pub fn save(self: *Self) !void {
        const dir_path = std.fs.path.dirname(self.path) orelse return error.InvalidPath;

        std.fs.makeDirAbsolute(dir_path) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        const file = try std.fs.createFileAbsolute(self.path, .{});
        defer file.close();

        var content = std.ArrayListUnmanaged(u8){};
        defer content.deinit(self.allocator);

        try content.appendSlice(self.allocator, "connections = {\n");

        for (self.connections.items) |conn| {
            try content.appendSlice(self.allocator, "  {\n");
            try self.append_field(&content, "name", conn.name);
            try self.append_field(&content, "host", conn.host);
            try self.append_port(&content, conn.port);
            try self.append_field(&content, "user", conn.user);
            try self.append_field(&content, "password", conn.password);
            try self.append_field(&content, "database", conn.database);
            try content.appendSlice(self.allocator, "  },\n");
        }

        try content.appendSlice(self.allocator, "}\n");
        try file.writeAll(content.items);
    }

    fn append_field(self: *Self, content: *std.ArrayListUnmanaged(u8), name: []const u8, value: []const u8) !void {
        try content.appendSlice(self.allocator, "    ");
        try content.appendSlice(self.allocator, name);
        try content.appendSlice(self.allocator, " = \"");
        try content.appendSlice(self.allocator, value);
        try content.appendSlice(self.allocator, "\",\n");
    }

    fn append_port(self: *Self, content: *std.ArrayListUnmanaged(u8), port: u16) !void {
        var buf: [16]u8 = undefined;
        const port_str = std.fmt.bufPrint(&buf, "{d}", .{port}) catch return;
        try content.appendSlice(self.allocator, "    port = ");
        try content.appendSlice(self.allocator, port_str);
        try content.appendSlice(self.allocator, ",\n");
    }

    pub fn add(self: *Self, conn: SavedConnection) !void {
        const new_conn = SavedConnection{
            .name = try self.allocator.dupe(u8, conn.name),
            .host = try self.allocator.dupe(u8, conn.host),
            .port = conn.port,
            .user = try self.allocator.dupe(u8, conn.user),
            .password = try self.allocator.dupe(u8, conn.password),
            .database = try self.allocator.dupe(u8, conn.database),
        };
        try self.connections.append(self.allocator, new_conn);
    }

    pub fn remove(self: *Self, index: usize) void {
        if (index >= self.connections.items.len) return;

        const conn = self.connections.items[index];
        self.allocator.free(conn.name);
        self.allocator.free(conn.host);
        self.allocator.free(conn.user);
        self.allocator.free(conn.password);
        self.allocator.free(conn.database);

        _ = self.connections.orderedRemove(index);
    }
};

fn parse_field(line: []const u8, field: []const u8) ?[]const u8 {
    var buf: [64]u8 = undefined;
    const prefix = std.fmt.bufPrint(&buf, "{s} = \"", .{field}) catch return null;

    if (std.mem.startsWith(u8, line, prefix)) {
        const start = prefix.len;
        const end = std.mem.indexOfPos(u8, line, start, "\"") orelse return null;
        return line[start..end];
    }
    return null;
}

fn parse_number_field(line: []const u8, field: []const u8) ?u16 {
    var buf: [64]u8 = undefined;
    const prefix = std.fmt.bufPrint(&buf, "{s} = ", .{field}) catch return null;

    if (std.mem.startsWith(u8, line, prefix)) {
        const start = prefix.len;
        var end = start;
        while (end < line.len and line[end] >= '0' and line[end] <= '9') {
            end += 1;
        }
        if (end > start) {
            return std.fmt.parseInt(u16, line[start..end], 10) catch null;
        }
    }
    return null;
}
