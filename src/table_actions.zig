const std = @import("std");
const db = @import("db.zig");
const Buffer = @import("buffer.zig").Buffer;
const Color = @import("buffer.zig").Color;

const theme = struct {
    const selected_bg = Color.bright_black;
    const selected_fg = Color.default;
    const title = Color.cyan;
    const hint = Color.bright_black;
    const success = Color.green;
};

pub const Action = enum {
    copy_ddl,
    ddl_to_query,
    show_columns,
    show_indexes,
};

pub const TableActions = struct {
    allocator: std.mem.Allocator,
    conn: *db.Connection,
    visible: bool,
    selected: usize,
    table_name: []const u8,
    ddl: ?[]const u8,
    columns: ?db.ResultSet,
    indexes: ?db.ResultSet,
    info_mode: ?Action,
    message: ?[]const u8,

    const Self = @This();

    const actions = [_]struct { action: Action, label: []const u8 }{
        .{ .action = .copy_ddl, .label = "Copy CREATE TABLE to clipboard" },
        .{ .action = .ddl_to_query, .label = "Send CREATE TABLE to query editor" },
        .{ .action = .show_columns, .label = "Show columns" },
        .{ .action = .show_indexes, .label = "Show indexes" },
    };

    pub fn init(allocator: std.mem.Allocator, conn: *db.Connection) Self {
        return Self{
            .allocator = allocator,
            .conn = conn,
            .visible = false,
            .selected = 0,
            .table_name = "",
            .ddl = null,
            .columns = null,
            .indexes = null,
            .info_mode = null,
            .message = null,
        };
    }

    pub fn deinit(self: *Self) void {
        self.clear_data();
    }

    fn clear_data(self: *Self) void {
        if (self.ddl) |d| {
            self.allocator.free(d);
            self.ddl = null;
        }
        if (self.columns) |*c| {
            c.deinit();
            self.columns = null;
        }
        if (self.indexes) |*i| {
            i.deinit();
            self.indexes = null;
        }
        if (self.message) |m| {
            self.allocator.free(m);
            self.message = null;
        }
        self.info_mode = null;
    }

    pub fn open(self: *Self, table_name: []const u8) void {
        self.clear_data();
        self.table_name = table_name;
        self.visible = true;
        self.selected = 0;
    }

    pub fn close(self: *Self) void {
        self.visible = false;
        self.clear_data();
    }

    pub fn move_up(self: *Self) void {
        if (self.info_mode != null) return;
        if (self.selected > 0) self.selected -= 1;
    }

    pub fn move_down(self: *Self) void {
        if (self.info_mode != null) return;
        if (self.selected < actions.len - 1) self.selected += 1;
    }

    pub fn execute_selected(self: *Self) !?[]const u8 {
        if (self.info_mode != null) {
            self.info_mode = null;
            return null;
        }

        const action = actions[self.selected].action;
        return try self.execute_action(action);
    }

    fn execute_action(self: *Self, action: Action) !?[]const u8 {
        switch (action) {
            .copy_ddl => {
                const ddl = try self.fetch_ddl();
                try copy_to_clipboard(ddl);
                self.message = try self.allocator.dupe(u8, "DDL copied to clipboard");
                return null;
            },
            .ddl_to_query => {
                const ddl = try self.fetch_ddl();
                self.visible = false;
                return ddl;
            },
            .show_columns => {
                try self.fetch_columns();
                self.info_mode = .show_columns;
                return null;
            },
            .show_indexes => {
                try self.fetch_indexes();
                self.info_mode = .show_indexes;
                return null;
            },
        }
    }

    fn fetch_ddl(self: *Self) ![]const u8 {
        if (self.ddl) |d| return d;

        var query_buf: [256]u8 = undefined;
        const query = std.fmt.bufPrintZ(&query_buf, "SHOW CREATE TABLE `{s}`", .{self.table_name}) catch return error.QueryFailed;
        var rs = self.conn.execute(query) catch return error.QueryFailed;
        defer rs.deinit();

        if (rs.rows.len > 0 and rs.rows[0].values.len > 1) {
            if (rs.rows[0].values[1]) |sql| {
                self.ddl = try self.allocator.dupe(u8, sql);
                return self.ddl.?;
            }
        }
        return error.QueryFailed;
    }

    fn fetch_columns(self: *Self) !void {
        if (self.columns != null) return;

        var query_buf: [256]u8 = undefined;
        const query = std.fmt.bufPrintZ(&query_buf, "SHOW COLUMNS FROM `{s}`", .{self.table_name}) catch return error.QueryFailed;
        self.columns = self.conn.execute(query) catch return error.QueryFailed;
    }

    fn fetch_indexes(self: *Self) !void {
        if (self.indexes != null) return;

        var query_buf: [256]u8 = undefined;
        const query = std.fmt.bufPrintZ(&query_buf, "SHOW INDEX FROM `{s}`", .{self.table_name}) catch return error.QueryFailed;
        self.indexes = self.conn.execute(query) catch return error.QueryFailed;
    }

    pub fn draw(self: *Self, buffer: *Buffer, screen_w: u16, screen_h: u16) void {
        if (self.info_mode) |mode| {
            self.draw_info_modal(buffer, screen_w, screen_h, mode);
        } else {
            self.draw_action_menu(buffer, screen_w, screen_h);
        }
    }

    fn draw_action_menu(self: *Self, buffer: *Buffer, screen_w: u16, screen_h: u16) void {
        const modal_w: u16 = 44;
        const modal_h: u16 = @intCast(actions.len + 4);
        const modal_x = (screen_w -| modal_w) / 2;
        const modal_y = (screen_h -| modal_h) / 2;

        draw_box(buffer, modal_x, modal_y, modal_w, modal_h, self.table_name);

        for (actions, 0..) |item, i| {
            const row_y = modal_y + 2 + @as(u16, @intCast(i));
            const is_selected = i == self.selected;
            const fg = if (is_selected) theme.selected_fg else Color.default;
            const bg = if (is_selected) theme.selected_bg else Color.default;

            buffer.fill_rect(modal_x + 1, row_y, modal_w - 2, 1, " ", fg, bg);
            buffer.print_styled(modal_x + 2, row_y, fg, bg, .{}, " {s}", .{item.label});
        }

        if (self.message) |msg| {
            buffer.write_styled(modal_x + 2, modal_y + modal_h - 2, msg, theme.success, .default, .{});
        }
    }

    fn draw_info_modal(self: *Self, buffer: *Buffer, screen_w: u16, screen_h: u16, mode: Action) void {
        const rs = switch (mode) {
            .show_columns => self.columns,
            .show_indexes => self.indexes,
            else => null,
        } orelse return;

        const title = switch (mode) {
            .show_columns => "Columns",
            .show_indexes => "Indexes",
            else => "",
        };

        const modal_w: u16 = @min(screen_w -| 4, 80);
        const modal_h: u16 = @min(screen_h -| 4, @as(u16, @intCast(rs.rows.len)) + 5);
        const modal_x = (screen_w -| modal_w) / 2;
        const modal_y = (screen_h -| modal_h) / 2;

        draw_box(buffer, modal_x, modal_y, modal_w, modal_h, title);

        const content_w = modal_w -| 2;
        var col_widths: [10]u16 = .{0} ** 10;
        const num_cols = @min(rs.columns.len, 10);

        for (rs.columns[0..num_cols], 0..) |col, i| {
            col_widths[i] = @intCast(@min(col.name.len + 2, 20));
        }
        for (rs.rows) |row| {
            for (row.values[0..@min(row.values.len, num_cols)], 0..) |val, i| {
                if (val) |v| {
                    col_widths[i] = @max(col_widths[i], @as(u16, @intCast(@min(v.len + 2, 20))));
                }
            }
        }

        var header_x = modal_x + 1;
        for (rs.columns[0..num_cols], 0..) |col, i| {
            if (header_x >= modal_x + content_w) break;
            buffer.write_styled(header_x, modal_y + 2, col.name, Color.cyan, .default, .{ .bold = true });
            header_x += col_widths[i];
        }

        const visible_rows = modal_h -| 5;
        for (rs.rows[0..@min(rs.rows.len, visible_rows)], 0..) |row, row_i| {
            var cell_x = modal_x + 1;
            const row_y = modal_y + 3 + @as(u16, @intCast(row_i));
            for (row.values[0..@min(row.values.len, num_cols)], 0..) |val, i| {
                if (cell_x >= modal_x + content_w) break;
                const text = val orelse "NULL";
                const max_len = @min(text.len, col_widths[i] -| 1);
                buffer.write_styled(cell_x, row_y, text[0..max_len], Color.default, .default, .{});
                cell_x += col_widths[i];
            }
        }

        buffer.write_styled(modal_x + 2, modal_y + modal_h - 2, "Press Enter or Esc to close", theme.hint, .default, .{});
    }
};

fn draw_box(buffer: *Buffer, x: u16, y: u16, w: u16, h: u16, title: []const u8) void {
    buffer.fill_rect(x, y, w, h, " ", .default, .default);

    buffer.set_cell(x, y, "┌");
    buffer.set_cell(x + w - 1, y, "┐");
    buffer.set_cell(x, y + h - 1, "└");
    buffer.set_cell(x + w - 1, y + h - 1, "┘");

    var i: u16 = 1;
    while (i < w - 1) : (i += 1) {
        buffer.set_cell(x + i, y, "─");
        buffer.set_cell(x + i, y + h - 1, "─");
    }
    i = 1;
    while (i < h - 1) : (i += 1) {
        buffer.set_cell(x, y + i, "│");
        buffer.set_cell(x + w - 1, y + i, "│");
    }

    if (title.len > 0) {
        const title_x = x + (w -| @as(u16, @intCast(title.len)) -| 2) / 2;
        buffer.write_styled(title_x, y, " ", theme.title, .default, .{});
        buffer.write_styled(title_x + 1, y, title, theme.title, .default, .{ .bold = true });
        buffer.write_styled(title_x + 1 + @as(u16, @intCast(title.len)), y, " ", theme.title, .default, .{});
    }
}

fn copy_to_clipboard(text: []const u8) !void {
    const argv = [_][]const u8{ "sh", "-c", "xclip -selection clipboard 2>/dev/null || xsel --clipboard --input 2>/dev/null || pbcopy 2>/dev/null" };
    var child = std.process.Child.init(&argv, std.heap.page_allocator);
    child.stdin_behavior = .Pipe;
    try child.spawn();

    if (child.stdin) |stdin| {
        stdin.writeAll(text) catch {};
        stdin.close();
        child.stdin = null;
    }

    _ = child.wait() catch {};
}
