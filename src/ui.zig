const std = @import("std");
const Term = @import("term.zig").Term;
const Key = @import("term.zig").Key;
const Config = @import("config.zig").Config;
const Buffer = @import("buffer.zig").Buffer;
const Color = @import("buffer.zig").Color;
const Style = @import("buffer.zig").Style;
const db = @import("db.zig");

pub const Pane = enum {
    tables,
    query,
    results,
};

const theme = struct {
    const border_active = Color.blue;
    const border_inactive = Color.bright_black;
    const title_active = Color.cyan;
    const title_inactive = Color.bright_black;
    const selected_bg = Color.blue;
    const selected_fg = Color.white;
    const status_bg = Color.bright_black;
    const status_fg = Color.white;
    const hint = Color.bright_black;
    const header_bg = Color.bright_black;
    const header_fg = Color.white;
    const null_fg = Color.bright_black;
    const sql_keyword = Color.magenta;
    const sql_function = Color.cyan;
    const sql_number = Color.yellow;
    const sql_string = Color.green;
    const sql_operator = Color.red;
};

const sql_keywords = [_][]const u8{
    "SELECT", "FROM", "WHERE", "AND", "OR", "NOT", "IN", "LIKE", "BETWEEN",
    "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE", "CREATE", "TABLE",
    "ALTER", "DROP", "INDEX", "VIEW", "JOIN", "LEFT", "RIGHT", "INNER", "OUTER",
    "ON", "AS", "ORDER", "BY", "ASC", "DESC", "GROUP", "HAVING", "LIMIT", "OFFSET",
    "UNION", "ALL", "DISTINCT", "NULL", "IS", "TRUE", "FALSE", "CASE", "WHEN",
    "THEN", "ELSE", "END", "EXISTS", "COUNT", "SUM", "AVG", "MIN", "MAX",
};

const sql_functions = [_][]const u8{
    "COUNT", "SUM", "AVG", "MIN", "MAX", "COALESCE", "IFNULL", "NULLIF",
    "CONCAT", "SUBSTRING", "LENGTH", "UPPER", "LOWER", "TRIM", "REPLACE",
    "NOW", "CURDATE", "DATE", "YEAR", "MONTH", "DAY",
};

pub const UI = struct {
    allocator: std.mem.Allocator,
    term: *Term,
    config: *Config,
    conn: *db.Connection,
    buffer: Buffer,
    active_pane: Pane,
    running: bool,
    tables: [][]const u8,
    tables_scroll: usize,
    tables_selected: usize,
    results_scroll_x: usize,
    results_scroll_y: usize,
    query_cursor: usize,
    query_text: std.ArrayListUnmanaged(u8),
    window_mode: bool,
    result_set: ?db.ResultSet,
    error_message: []const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, term: *Term, config: *Config, conn: *db.Connection) !Self {
        var self = Self{
            .allocator = allocator,
            .term = term,
            .config = config,
            .conn = conn,
            .buffer = Buffer.init(allocator),
            .active_pane = .tables,
            .running = true,
            .tables = &[_][]const u8{},
            .tables_scroll = 0,
            .tables_selected = 0,
            .results_scroll_x = 0,
            .results_scroll_y = 0,
            .query_cursor = 0,
            .query_text = .{},
            .window_mode = false,
            .result_set = null,
            .error_message = "",
        };

        self.tables = conn.get_tables() catch &[_][]const u8{};

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.buffer.deinit();
        self.query_text.deinit(self.allocator);
        if (self.tables.len > 0) {
            self.conn.free_tables(self.tables);
        }
        if (self.result_set) |*rs| {
            rs.deinit();
        }
    }

    pub fn run(self: *Self) !void {
        while (self.running) {
            try self.render();

            if (try self.term.read_key()) |key| {
                try self.handle_input(key);
            }
        }
    }

    fn handle_input(self: *Self, key: Key) !void {
        if (self.window_mode) {
            self.window_mode = false;
            switch (key) {
                .char => |c| switch (c) {
                    'h' => self.move_pane_left(),
                    'j' => self.move_pane_down(),
                    'k' => self.move_pane_up(),
                    'l' => self.move_pane_right(),
                    'w' => self.cycle_pane(),
                    else => {},
                },
                else => {},
            }
            return;
        }

        if (key.is_ctrl('w')) {
            self.window_mode = true;
            return;
        }

        if (key.is_ctrl('c') or key.is_ctrl('q')) {
            self.running = false;
            return;
        }

        if (key.is_ctrl('l')) {
            try self.term.refresh_size();
            return;
        }

        if (key == .tab) {
            self.cycle_pane();
            return;
        }

        switch (self.active_pane) {
            .tables => try self.handle_tables_input(key),
            .query => try self.handle_query_input(key),
            .results => try self.handle_results_input(key),
        }
    }

    fn handle_tables_input(self: *Self, key: Key) !void {
        const max_idx = if (self.tables.len > 0) self.tables.len - 1 else 0;

        switch (key) {
            .char => |c| switch (c) {
                'j' => {
                    if (self.tables_selected < max_idx) {
                        self.tables_selected += 1;
                    }
                },
                'k' => {
                    if (self.tables_selected > 0) {
                        self.tables_selected -= 1;
                    }
                },
                'g' => self.tables_selected = 0,
                'G' => self.tables_selected = max_idx,
                else => {},
            },
            .arrow_down => {
                if (self.tables_selected < max_idx) {
                    self.tables_selected += 1;
                }
            },
            .arrow_up => {
                if (self.tables_selected > 0) {
                    self.tables_selected -= 1;
                }
            },
            .enter => {
                if (self.tables.len > 0) {
                    try self.select_table();
                }
            },
            else => {},
        }
    }

    fn select_table(self: *Self) !void {
        const table = self.tables[self.tables_selected];

        self.query_text.clearRetainingCapacity();
        const query = try std.fmt.allocPrint(self.allocator, "SELECT * FROM {s} LIMIT 100", .{table});
        defer self.allocator.free(query);

        try self.query_text.appendSlice(self.allocator, query);
        self.query_cursor = self.query_text.items.len;

        try self.execute_query();
    }

    fn handle_query_input(self: *Self, key: Key) !void {
        if (key.is_ctrl('e') or key == .enter) {
            try self.execute_query();
            return;
        }

        switch (key) {
            .char => |c| {
                try self.query_text.insert(self.allocator, self.query_cursor, c);
                self.query_cursor += 1;
            },
            .backspace => {
                if (self.query_cursor > 0) {
                    _ = self.query_text.orderedRemove(self.query_cursor - 1);
                    self.query_cursor -= 1;
                }
            },
            .delete => {
                if (self.query_cursor < self.query_text.items.len) {
                    _ = self.query_text.orderedRemove(self.query_cursor);
                }
            },
            .arrow_left => {
                if (self.query_cursor > 0) {
                    self.query_cursor -= 1;
                }
            },
            .arrow_right => {
                if (self.query_cursor < self.query_text.items.len) {
                    self.query_cursor += 1;
                }
            },
            .home => self.query_cursor = 0,
            .end => self.query_cursor = self.query_text.items.len,
            else => {},
        }
    }

    fn execute_query(self: *Self) !void {
        if (self.query_text.items.len == 0) return;

        self.error_message = "";

        if (self.result_set) |*rs| {
            rs.deinit();
            self.result_set = null;
        }

        const query_z = try self.allocator.dupeZ(u8, self.query_text.items);
        defer self.allocator.free(query_z);

        self.result_set = self.conn.execute(query_z) catch {
            self.error_message = self.conn.get_error();
            return;
        };

        self.results_scroll_x = 0;
        self.results_scroll_y = 0;
        self.active_pane = .results;
    }

    fn handle_results_input(self: *Self, key: Key) !void {
        switch (key) {
            .char => |c| switch (c) {
                'j' => self.results_scroll_y +|= 1,
                'k' => {
                    if (self.results_scroll_y > 0) {
                        self.results_scroll_y -= 1;
                    }
                },
                'h' => {
                    if (self.results_scroll_x > 0) {
                        self.results_scroll_x -= 1;
                    }
                },
                'l' => self.results_scroll_x +|= 1,
                else => {},
            },
            .arrow_down => self.results_scroll_y +|= 1,
            .arrow_up => {
                if (self.results_scroll_y > 0) {
                    self.results_scroll_y -= 1;
                }
            },
            .arrow_left => {
                if (self.results_scroll_x > 0) {
                    self.results_scroll_x -= 1;
                }
            },
            .arrow_right => self.results_scroll_x +|= 1,
            .page_down => self.results_scroll_y +|= 20,
            .page_up => {
                if (self.results_scroll_y >= 20) {
                    self.results_scroll_y -= 20;
                } else {
                    self.results_scroll_y = 0;
                }
            },
            else => {},
        }
    }

    fn move_pane_left(self: *Self) void {
        if (self.active_pane == .results or self.active_pane == .query) {
            self.active_pane = .tables;
        }
    }

    fn move_pane_right(self: *Self) void {
        if (self.active_pane == .tables) {
            self.active_pane = .results;
        }
    }

    fn move_pane_up(self: *Self) void {
        if (self.active_pane == .results) {
            self.active_pane = .query;
        }
    }

    fn move_pane_down(self: *Self) void {
        if (self.active_pane == .query) {
            self.active_pane = .results;
        }
    }

    fn cycle_pane(self: *Self) void {
        self.active_pane = switch (self.active_pane) {
            .tables => .query,
            .query => .results,
            .results => .tables,
        };
    }

    fn render(self: *Self) !void {
        self.buffer.clear();

        const w = self.term.width;
        const h = self.term.height;

        const tables_width: u16 = @min(30, w / 4);
        const query_height: u16 = 6;
        const status_height: u16 = 1;

        self.draw_tables_pane(0, 0, tables_width, h -| status_height);
        self.draw_query_pane(tables_width, 0, w -| tables_width, query_height);
        self.draw_results_pane(tables_width, query_height, w -| tables_width, h -| query_height -| status_height);
        self.draw_status_line(0, h -| 1, w);

        try self.buffer.flush(self.term);
    }

    fn draw_tables_pane(self: *Self, x: u16, y: u16, w: u16, h: u16) void {
        const active = self.active_pane == .tables;
        self.draw_box(x, y, w, h, "Tables", active);

        if (self.tables.len == 0) {
            self.buffer.write_styled(x + 2, y + 1, "No tables", theme.hint, .default, .{ .italic = true });
            return;
        }

        const visible_rows = h -| 2;
        if (self.tables_selected >= self.tables_scroll + visible_rows) {
            self.tables_scroll = self.tables_selected -| visible_rows + 1;
        }
        if (self.tables_selected < self.tables_scroll) {
            self.tables_scroll = self.tables_selected;
        }

        var row: u16 = 0;
        while (row < visible_rows) : (row += 1) {
            const idx = self.tables_scroll + row;
            if (idx >= self.tables.len) break;

            const row_y = y + row + 1;
            const selected = idx == self.tables_selected;

            if (selected) {
                var col: u16 = x + 1;
                while (col < x + w - 1) : (col += 1) {
                    self.buffer.set_cell_styled(col, row_y, " ", theme.selected_fg, theme.selected_bg, .{});
                }
            }

            const table_name = self.tables[idx];
            const max_len = w -| 4;
            const fg = if (selected) theme.selected_fg else Color.default;
            const bg = if (selected) theme.selected_bg else Color.default;
            const style: Style = if (selected) .{ .bold = true } else .{};

            if (table_name.len > max_len) {
                self.buffer.write_styled(x + 2, row_y, table_name[0 .. max_len -| 1], fg, bg, style);
                self.buffer.write_styled(x + 2 + max_len -| 1, row_y, "…", fg, bg, style);
            } else {
                self.buffer.write_styled(x + 2, row_y, table_name, fg, bg, style);
            }
        }
    }

    fn draw_query_pane(self: *Self, x: u16, y: u16, w: u16, h: u16) void {
        const active = self.active_pane == .query;
        self.draw_box(x, y, w, h, "Query", active);

        if (self.query_text.items.len > 0) {
            self.draw_sql_highlighted(x + 1, y + 1, w -| 2, self.query_text.items);
        } else {
            self.buffer.write_styled(x + 1, y + 1, "SELECT * FROM ...", theme.hint, .default, .{ .italic = true });
        }

        if (active and self.query_cursor <= w - 2) {
            const cursor_x = x + 1 + @as(u16, @intCast(@min(self.query_cursor, w - 2)));
            self.buffer.set_cell_styled(cursor_x, y + 1, "▏", Color.cyan, .default, .{});
        }
    }

    fn draw_sql_highlighted(self: *Self, x: u16, y: u16, max_w: u16, text: []const u8) void {
        var col: u16 = 0;
        var i: usize = 0;

        while (i < text.len and col < max_w) {
            const c = text[i];

            if (c == '\'' or c == '"') {
                const start = i;
                i += 1;
                while (i < text.len and text[i] != c) : (i += 1) {}
                if (i < text.len) i += 1;
                const str_slice = text[start..i];
                const draw_len = @min(str_slice.len, max_w - col);
                self.buffer.write_styled(x + col, y, str_slice[0..draw_len], theme.sql_string, .default, .{});
                col += @intCast(draw_len);
                continue;
            }

            if (c >= '0' and c <= '9') {
                const start = i;
                while (i < text.len and ((text[i] >= '0' and text[i] <= '9') or text[i] == '.')) : (i += 1) {}
                const num_slice = text[start..i];
                const draw_len = @min(num_slice.len, max_w - col);
                self.buffer.write_styled(x + col, y, num_slice[0..draw_len], theme.sql_number, .default, .{});
                col += @intCast(draw_len);
                continue;
            }

            if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_') {
                const start = i;
                while (i < text.len and ((text[i] >= 'a' and text[i] <= 'z') or
                    (text[i] >= 'A' and text[i] <= 'Z') or
                    (text[i] >= '0' and text[i] <= '9') or
                    text[i] == '_')) : (i += 1)
                {}
                const word = text[start..i];
                const draw_len = @min(word.len, max_w - col);
                const color = self.get_sql_token_color(word);
                self.buffer.write_styled(x + col, y, word[0..draw_len], color, .default, .{});
                col += @intCast(draw_len);
                continue;
            }

            if (c == '=' or c == '<' or c == '>' or c == '!' or c == '*') {
                self.buffer.set_cell_styled(x + col, y, text[i .. i + 1], theme.sql_operator, .default, .{});
            } else {
                self.buffer.set_cell_styled(x + col, y, text[i .. i + 1], .default, .default, .{});
            }
            col += 1;
            i += 1;
        }
    }

    fn get_sql_token_color(_: *Self, word: []const u8) Color {
        var upper_buf: [32]u8 = undefined;
        if (word.len > upper_buf.len) return .default;

        for (word, 0..) |c, j| {
            upper_buf[j] = if (c >= 'a' and c <= 'z') c - 32 else c;
        }
        const upper = upper_buf[0..word.len];

        for (sql_keywords) |kw| {
            if (std.mem.eql(u8, upper, kw)) return theme.sql_keyword;
        }
        for (sql_functions) |func| {
            if (std.mem.eql(u8, upper, func)) return theme.sql_function;
        }
        return .default;
    }

    fn draw_results_pane(self: *Self, x: u16, y: u16, w: u16, h: u16) void {
        const active = self.active_pane == .results;
        self.draw_box(x, y, w, h, "Results", active);

        if (self.error_message.len > 0) {
            self.buffer.write_styled(x + 2, y + 2, self.error_message, Color.red, .default, .{});
            return;
        }

        const rs = self.result_set orelse {
            self.buffer.write_styled(x + 2, y + 2, "No results yet", theme.hint, .default, .{ .italic = true });
            self.buffer.write_styled(x + 2, y + 3, "Enter on table or ^E in query", theme.hint, .default, .{});
            return;
        };

        if (rs.columns.len == 0) {
            self.buffer.write_styled(x + 2, y + 2, "Query executed successfully", Color.green, .default, .{});
            return;
        }

        const col_width: u16 = 15;
        const visible_rows = h -| 3;

        var col_x = x + 1;
        var col_idx: usize = self.results_scroll_x;
        while (col_idx < rs.columns.len and col_x + col_width <= x + w - 1) : (col_idx += 1) {
            const col = rs.columns[col_idx];
            const display_name = col.name[0..@min(col.name.len, col_width - 1)];
            self.buffer.write_styled(col_x, y + 1, display_name, theme.header_fg, theme.header_bg, .{ .bold = true });
            col_x += col_width;
        }

        var row_idx: usize = self.results_scroll_y;
        var draw_row: u16 = 0;
        while (row_idx < rs.rows.len and draw_row < visible_rows) : (row_idx += 1) {
            const row = rs.rows[row_idx];
            col_x = x + 1;
            col_idx = self.results_scroll_x;

            while (col_idx < row.values.len and col_x + col_width <= x + w - 1) : (col_idx += 1) {
                if (row.values[col_idx]) |val| {
                    const display_val = val[0..@min(val.len, col_width - 1)];
                    self.buffer.write(col_x, y + 2 + draw_row, display_val);
                } else {
                    self.buffer.write_styled(col_x, y + 2 + draw_row, "NULL", theme.null_fg, .default, .{ .italic = true });
                }
                col_x += col_width;
            }
            draw_row += 1;
        }

        var info_buf: [64]u8 = undefined;
        const info = std.fmt.bufPrint(&info_buf, "{d} rows", .{rs.rows.len}) catch return;
        const info_x = x + w -| @as(u16, @intCast(info.len)) -| 3;
        self.buffer.print_styled(info_x, y, theme.hint, .default, .{}, "{d} rows", .{rs.rows.len});
    }

    fn draw_status_line(self: *Self, x: u16, y: u16, w: u16) void {
        self.buffer.fill_rect(x, y, w, 1, " ", theme.status_fg, theme.status_bg);

        const mode_str = if (self.window_mode) " WINDOW " else "";
        const pane_str = switch (self.active_pane) {
            .tables => "TABLES",
            .query => "QUERY",
            .results => "RESULTS",
        };

        if (self.window_mode) {
            self.buffer.write_styled(x + 1, y, mode_str, Color.black, Color.yellow, .{ .bold = true });
            self.buffer.write_styled(x + 1 + @as(u16, @intCast(mode_str.len)), y, pane_str, theme.status_fg, theme.status_bg, .{});
        } else {
            self.buffer.write_styled(x + 1, y, pane_str, theme.status_fg, theme.status_bg, .{ .bold = true });
        }

        const hints = "^W:panes  Tab:cycle  ^E:exec  ^Q:quit";
        if (w > hints.len + 2) {
            self.buffer.write_styled(x + w - @as(u16, @intCast(hints.len)) - 1, y, hints, theme.hint, theme.status_bg, .{});
        }
    }

    fn draw_box(self: *Self, x: u16, y: u16, w: u16, h: u16, title: []const u8, active: bool) void {
        if (w < 2 or h < 2) return;

        const border_color = if (active) theme.border_active else theme.border_inactive;
        const title_color = if (active) theme.title_active else theme.title_inactive;

        self.buffer.set_cell_styled(x, y, "┌", border_color, .default, .{});
        var i: u16 = 1;
        while (i < w - 1) : (i += 1) {
            self.buffer.set_cell_styled(x + i, y, "─", border_color, .default, .{});
        }
        self.buffer.set_cell_styled(x + w - 1, y, "┐", border_color, .default, .{});

        if (title.len > 0 and w > title.len + 4) {
            self.buffer.set_cell_styled(x + 1, y, " ", border_color, .default, .{});
            self.buffer.write_styled(x + 2, y, title, title_color, .default, .{ .bold = active });
            self.buffer.set_cell_styled(x + 2 + @as(u16, @intCast(title.len)), y, " ", border_color, .default, .{});
        }

        var row: u16 = 1;
        while (row < h - 1) : (row += 1) {
            self.buffer.set_cell_styled(x, y + row, "│", border_color, .default, .{});
            self.buffer.set_cell_styled(x + w - 1, y + row, "│", border_color, .default, .{});
        }

        self.buffer.set_cell_styled(x, y + h - 1, "└", border_color, .default, .{});
        i = 1;
        while (i < w - 1) : (i += 1) {
            self.buffer.set_cell_styled(x + i, y + h - 1, "─", border_color, .default, .{});
        }
        self.buffer.set_cell_styled(x + w - 1, y + h - 1, "┘", border_color, .default, .{});
    }
};
