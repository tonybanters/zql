const std = @import("std");
const Term = @import("term.zig").Term;
const Key = @import("term.zig").Key;
const Buffer = @import("buffer.zig").Buffer;
const Color = @import("buffer.zig").Color;
const Style = @import("buffer.zig").Style;
const ConnectionStore = @import("connections.zig").ConnectionStore;
const SavedConnection = @import("connections.zig").SavedConnection;
const db = @import("db.zig");

const theme = struct {
    const border = Color.blue;
    const title = Color.cyan;
    const selected_bg = Color.blue;
    const selected_fg = Color.black;
    const hint = Color.bright_black;
    const error_fg = Color.red;
    const input_label = Color.cyan;
};

const Mode = enum {
    list,
    new_connection,
    connecting,
    error_display,
};

const InputField = enum {
    name,
    host,
    port,
    user,
    password,
    database,
};

pub const ConnectionPicker = struct {
    allocator: std.mem.Allocator,
    term: *Term,
    buffer: Buffer,
    store: ConnectionStore,
    selected: usize,
    mode: Mode,
    error_message: []const u8,
    input_field: InputField,
    input_buffers: struct {
        name: std.ArrayListUnmanaged(u8),
        host: std.ArrayListUnmanaged(u8),
        port: std.ArrayListUnmanaged(u8),
        user: std.ArrayListUnmanaged(u8),
        password: std.ArrayListUnmanaged(u8),
        database: std.ArrayListUnmanaged(u8),
    },

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, term: *Term) !Self {
        var store = try ConnectionStore.init(allocator);
        store.load() catch {};

        return Self{
            .allocator = allocator,
            .term = term,
            .buffer = Buffer.init(allocator),
            .store = store,
            .selected = 0,
            .mode = .list,
            .error_message = "",
            .input_field = .name,
            .input_buffers = .{
                .name = .{},
                .host = .{},
                .port = .{},
                .user = .{},
                .password = .{},
                .database = .{},
            },
        };
    }

    pub fn deinit(self: *Self) void {
        self.buffer.deinit();
        self.store.deinit();
        self.input_buffers.name.deinit(self.allocator);
        self.input_buffers.host.deinit(self.allocator);
        self.input_buffers.port.deinit(self.allocator);
        self.input_buffers.user.deinit(self.allocator);
        self.input_buffers.password.deinit(self.allocator);
        self.input_buffers.database.deinit(self.allocator);
    }

    pub fn run(self: *Self) !?db.Connection {
        while (true) {
            try self.render();

            if (try self.term.read_key()) |key| {
                const result = try self.handle_input(key);
                if (result) |conn| {
                    return conn;
                }
            }
        }
    }

    fn handle_input(self: *Self, key: Key) !?db.Connection {
        switch (self.mode) {
            .list => return try self.handle_list_input(key),
            .new_connection => {
                try self.handle_new_connection_input(key);
                return null;
            },
            .error_display => {
                if (key == .enter or key == .escape) {
                    self.mode = .list;
                    self.error_message = "";
                }
                return null;
            },
            .connecting => return null,
        }
    }

    fn handle_list_input(self: *Self, key: Key) !?db.Connection {
        switch (key) {
            .char => |c| switch (c) {
                'j' => {
                    if (self.selected < self.store.connections.items.len -| 1) {
                        self.selected += 1;
                    }
                },
                'k' => {
                    if (self.selected > 0) {
                        self.selected -= 1;
                    }
                },
                'n' => {
                    self.mode = .new_connection;
                    self.input_field = .name;
                    self.clear_inputs();
                },
                'd' => {
                    if (self.store.connections.items.len > 0) {
                        self.store.remove(self.selected);
                        self.store.save() catch {};
                        if (self.selected > 0 and self.selected >= self.store.connections.items.len) {
                            self.selected -= 1;
                        }
                    }
                },
                'q' => return error.Quit,
                else => {},
            },
            .arrow_down => {
                if (self.selected < self.store.connections.items.len -| 1) {
                    self.selected += 1;
                }
            },
            .arrow_up => {
                if (self.selected > 0) {
                    self.selected -= 1;
                }
            },
            .enter => {
                if (self.store.connections.items.len > 0) {
                    if (try self.try_connect(self.selected)) |conn| {
                        return conn;
                    }
                }
            },
            else => {},
        }

        if (key.is_ctrl('c') or key.is_ctrl('q')) {
            return error.Quit;
        }

        return null;
    }

    fn handle_new_connection_input(self: *Self, key: Key) !void {
        if (key == .escape) {
            self.mode = .list;
            return;
        }

        if (key == .tab or key == .arrow_down) {
            self.input_field = switch (self.input_field) {
                .name => .host,
                .host => .port,
                .port => .user,
                .user => .password,
                .password => .database,
                .database => .name,
            };
            return;
        }

        if (key == .arrow_up) {
            self.input_field = switch (self.input_field) {
                .name => .database,
                .host => .name,
                .port => .host,
                .user => .port,
                .password => .user,
                .database => .password,
            };
            return;
        }

        if (key == .enter) {
            try self.save_new_connection();
            return;
        }

        var current_buf = self.get_current_input_buf();

        switch (key) {
            .char => |c| {
                try current_buf.append(self.allocator, c);
            },
            .backspace => {
                if (current_buf.items.len > 0) {
                    _ = current_buf.pop();
                }
            },
            else => {},
        }
    }

    fn get_current_input_buf(self: *Self) *std.ArrayListUnmanaged(u8) {
        return switch (self.input_field) {
            .name => &self.input_buffers.name,
            .host => &self.input_buffers.host,
            .port => &self.input_buffers.port,
            .user => &self.input_buffers.user,
            .password => &self.input_buffers.password,
            .database => &self.input_buffers.database,
        };
    }

    fn clear_inputs(self: *Self) void {
        self.input_buffers.name.clearRetainingCapacity();
        self.input_buffers.host.clearRetainingCapacity();
        self.input_buffers.port.clearRetainingCapacity();
        self.input_buffers.user.clearRetainingCapacity();
        self.input_buffers.password.clearRetainingCapacity();
        self.input_buffers.database.clearRetainingCapacity();
    }

    fn save_new_connection(self: *Self) !void {
        if (self.input_buffers.name.items.len == 0) {
            self.error_message = "Name is required";
            self.mode = .error_display;
            return;
        }

        const port = std.fmt.parseInt(u16, self.input_buffers.port.items, 10) catch 3306;

        const conn = SavedConnection{
            .name = self.input_buffers.name.items,
            .host = if (self.input_buffers.host.items.len > 0) self.input_buffers.host.items else "localhost",
            .port = port,
            .user = self.input_buffers.user.items,
            .password = self.input_buffers.password.items,
            .database = self.input_buffers.database.items,
        };

        try self.store.add(conn);
        try self.store.save();

        self.mode = .list;
        self.selected = self.store.connections.items.len - 1;
    }

    fn try_connect(self: *Self, index: usize) !?db.Connection {
        const saved = self.store.connections.items[index];

        const host_z = try self.allocator.dupeZ(u8, saved.host);
        defer self.allocator.free(host_z);

        const user_z = try self.allocator.dupeZ(u8, saved.user);
        defer self.allocator.free(user_z);

        const pass_z = try self.allocator.dupeZ(u8, saved.password);
        defer self.allocator.free(pass_z);

        const db_z = try self.allocator.dupeZ(u8, saved.database);
        defer self.allocator.free(db_z);

        self.mode = .connecting;
        try self.render();

        const conn = db.Connection.connect(
            self.allocator,
            host_z,
            saved.port,
            user_z,
            pass_z,
            db_z,
        ) catch |err| {
            self.mode = .error_display;
            self.error_message = switch (err) {
                error.InitFailed => "MySQL init failed",
                error.ConnectionFailed => "Connection failed - check host/port/credentials",
            };
            return null;
        };

        return conn;
    }

    fn render(self: *Self) !void {
        self.buffer.clear();

        const w = self.term.width;
        const h = self.term.height;

        switch (self.mode) {
            .list => self.draw_list(w, h),
            .new_connection => self.draw_new_connection_form(w, h),
            .connecting => self.draw_connecting(w, h),
            .error_display => self.draw_error(w, h),
        }

        try self.buffer.flush(self.term);
    }

    fn draw_list(self: *Self, w: u16, h: u16) void {
        const box_w: u16 = @min(60, w -| 4);
        const box_h: u16 = @min(20, h -| 4);
        const box_x: u16 = (w -| box_w) / 2;
        const box_y: u16 = (h -| box_h) / 2;

        self.draw_box(box_x, box_y, box_w, box_h, "Connections");

        if (self.store.connections.items.len == 0) {
            self.buffer.write_styled(box_x + 2, box_y + 2, "No saved connections", theme.hint, .default, .{ .italic = true });
            self.buffer.write_styled(box_x + 2, box_y + 3, "Press 'n' to create one", theme.hint, .default, .{});
        } else {
            for (self.store.connections.items, 0..) |conn, i| {
                if (i + 2 >= box_h - 1) break;
                const row_y = box_y + @as(u16, @intCast(i)) + 1;
                const is_selected = i == self.selected;

                if (is_selected) {
                    var col: u16 = box_x + 1;
                    while (col < box_x + box_w - 1) : (col += 1) {
                        self.buffer.set_cell_styled(col, row_y, " ", theme.selected_fg, theme.selected_bg, .{});
                    }
                }

                const fg = if (is_selected) theme.selected_fg else Color.default;
                const bg = if (is_selected) theme.selected_bg else Color.default;

                self.buffer.print_styled(box_x + 2, row_y, fg, bg, .{}, "{s}", .{ conn.name });
            }
        }

        const hints = "j/k:navigate  Enter:connect  n:new  d:delete  q:quit";
        self.buffer.write_styled(box_x + 2, box_y + box_h - 1, hints, theme.hint, .default, .{});
    }

    fn draw_new_connection_form(self: *Self, w: u16, h: u16) void {
        const box_w: u16 = @min(50, w -| 4);
        const box_h: u16 = 16;
        const box_x: u16 = (w -| box_w) / 2;
        const box_y: u16 = (h -| box_h) / 2;

        self.draw_box(box_x, box_y, box_w, box_h, "New Connection");

        const fields = [_]struct { label: []const u8, field: InputField, buf: []const u8, is_pass: bool }{
            .{ .label = "Name:", .field = .name, .buf = self.input_buffers.name.items, .is_pass = false },
            .{ .label = "Host:", .field = .host, .buf = self.input_buffers.host.items, .is_pass = false },
            .{ .label = "Port:", .field = .port, .buf = self.input_buffers.port.items, .is_pass = false },
            .{ .label = "User:", .field = .user, .buf = self.input_buffers.user.items, .is_pass = false },
            .{ .label = "Password:", .field = .password, .buf = self.input_buffers.password.items, .is_pass = true },
            .{ .label = "Database:", .field = .database, .buf = self.input_buffers.database.items, .is_pass = false },
        };

        for (fields, 0..) |f, i| {
            const row_y = box_y + @as(u16, @intCast(i)) * 2 + 2;
            const is_active = self.input_field == f.field;

            self.buffer.write_styled(box_x + 2, row_y, f.label, theme.input_label, .default, .{});

            const input_x = box_x + 13;
            const input_w = box_w - 16;

            var col: u16 = 0;
            while (col < input_w) : (col += 1) {
                const bg = if (is_active) Color.bright_black else Color.default;
                self.buffer.set_cell_styled(input_x + col, row_y, " ", .default, bg, .{});
            }

            if (f.buf.len > 0) {
                if (f.is_pass) {
                    var stars: [64]u8 = undefined;
                    const star_len = @min(f.buf.len, 64);
                    for (0..star_len) |j| {
                        stars[j] = '*';
                    }
                    self.buffer.write(input_x, row_y, stars[0..star_len]);
                } else {
                    self.buffer.write(input_x, row_y, f.buf);
                }
            }

            if (is_active) {
                const cursor_x = input_x + @as(u16, @intCast(@min(f.buf.len, input_w - 1)));
                self.buffer.set_cell_styled(cursor_x, row_y, "▏", Color.cyan, Color.bright_black, .{});
            }
        }

        const hints = "Tab:next  Enter:save  Esc:cancel";
        self.buffer.write_styled(box_x + 2, box_y + box_h - 1, hints, theme.hint, .default, .{});
    }

    fn draw_connecting(self: *Self, w: u16, h: u16) void {
        const msg = "Connecting...";
        const x = (w -| @as(u16, @intCast(msg.len))) / 2;
        const y = h / 2;
        self.buffer.write_styled(x, y, msg, Color.yellow, .default, .{ .bold = true });
    }

    fn draw_error(self: *Self, w: u16, h: u16) void {
        const box_w: u16 = @min(40, w -| 4);
        const box_h: u16 = 6;
        const box_x: u16 = (w -| box_w) / 2;
        const box_y: u16 = (h -| box_h) / 2;

        self.draw_box(box_x, box_y, box_w, box_h, "Error");
        self.buffer.write_styled(box_x + 2, box_y + 2, self.error_message, theme.error_fg, .default, .{});
        self.buffer.write_styled(box_x + 2, box_y + 4, "Press Enter to continue", theme.hint, .default, .{});
    }

    fn draw_box(self: *Self, x: u16, y: u16, w: u16, h: u16, title: []const u8) void {
        if (w < 2 or h < 2) return;

        self.buffer.set_cell_styled(x, y, "┌", theme.border, .default, .{});
        var i: u16 = 1;
        while (i < w - 1) : (i += 1) {
            self.buffer.set_cell_styled(x + i, y, "─", theme.border, .default, .{});
        }
        self.buffer.set_cell_styled(x + w - 1, y, "┐", theme.border, .default, .{});

        if (title.len > 0 and w > title.len + 4) {
            self.buffer.set_cell_styled(x + 1, y, " ", theme.border, .default, .{});
            self.buffer.write_styled(x + 2, y, title, theme.title, .default, .{ .bold = true });
            self.buffer.set_cell_styled(x + 2 + @as(u16, @intCast(title.len)), y, " ", theme.border, .default, .{});
        }

        var row: u16 = 1;
        while (row < h - 1) : (row += 1) {
            self.buffer.set_cell_styled(x, y + row, "│", theme.border, .default, .{});
            self.buffer.set_cell_styled(x + w - 1, y + row, "│", theme.border, .default, .{});
        }

        self.buffer.set_cell_styled(x, y + h - 1, "└", theme.border, .default, .{});
        i = 1;
        while (i < w - 1) : (i += 1) {
            self.buffer.set_cell_styled(x + i, y + h - 1, "─", theme.border, .default, .{});
        }
        self.buffer.set_cell_styled(x + w - 1, y + h - 1, "┘", theme.border, .default, .{});
    }
};
