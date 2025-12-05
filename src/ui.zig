const std = @import("std");
const Term = @import("term.zig").Term;
const Key = @import("term.zig").Key;
const Config = @import("config.zig").Config;
const Buffer = @import("buffer.zig").Buffer;
const Color = @import("buffer.zig").Color;
const Style = @import("buffer.zig").Style;

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
};

pub const UI = struct {
    allocator: std.mem.Allocator,
    term: *Term,
    config: *Config,
    buffer: Buffer,
    active_pane: Pane,
    running: bool,
    tables_scroll: usize,
    tables_selected: usize,
    results_scroll_x: usize,
    results_scroll_y: usize,
    query_cursor: usize,
    query_text: std.ArrayListUnmanaged(u8),
    window_mode: bool,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, term: *Term, config: *Config) !Self {
        return Self{
            .allocator = allocator,
            .term = term,
            .config = config,
            .buffer = Buffer.init(allocator),
            .active_pane = .tables,
            .running = true,
            .tables_scroll = 0,
            .tables_selected = 0,
            .results_scroll_x = 0,
            .results_scroll_y = 0,
            .query_cursor = 0,
            .query_text = .{},
            .window_mode = false,
        };
    }

    pub fn deinit(self: *Self) void {
        self.buffer.deinit();
        self.query_text.deinit(self.allocator);
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
        switch (key) {
            .char => |c| switch (c) {
                'j' => self.tables_selected +|= 1,
                'k' => if (self.tables_selected > 0) {
                    self.tables_selected -= 1;
                },
                'g' => self.tables_selected = 0,
                'G' => {},
                '/' => {},
                else => {},
            },
            .arrow_down => self.tables_selected +|= 1,
            .arrow_up => if (self.tables_selected > 0) {
                self.tables_selected -= 1;
            },
            .enter => {},
            else => {},
        }
    }

    fn handle_query_input(self: *Self, key: Key) !void {
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
            .arrow_left => if (self.query_cursor > 0) {
                self.query_cursor -= 1;
            },
            .arrow_right => if (self.query_cursor < self.query_text.items.len) {
                self.query_cursor += 1;
            },
            .home => self.query_cursor = 0,
            .end => self.query_cursor = self.query_text.items.len,
            else => {},
        }
    }

    fn handle_results_input(self: *Self, key: Key) !void {
        switch (key) {
            .char => |c| switch (c) {
                'j' => self.results_scroll_y +|= 1,
                'k' => if (self.results_scroll_y > 0) {
                    self.results_scroll_y -= 1;
                },
                'h' => if (self.results_scroll_x > 0) {
                    self.results_scroll_x -= 1;
                },
                'l' => self.results_scroll_x +|= 1,
                else => {},
            },
            .arrow_down => self.results_scroll_y +|= 1,
            .arrow_up => if (self.results_scroll_y > 0) {
                self.results_scroll_y -= 1;
            },
            .arrow_left => if (self.results_scroll_x > 0) {
                self.results_scroll_x -= 1;
            },
            .arrow_right => self.results_scroll_x +|= 1,
            .page_down => self.results_scroll_y +|= 20,
            .page_up => if (self.results_scroll_y >= 20) {
                self.results_scroll_y -= 20;
            } else {
                self.results_scroll_y = 0;
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

        const demo_tables = [_][]const u8{ "users", "posts", "comments", "tags", "sessions", "logs" };
        for (demo_tables, 0..) |table, i| {
            if (i + 1 >= h - 1) break;
            const row_y = y + @as(u16, @intCast(i)) + 1;
            const selected = i == self.tables_selected;

            if (selected) {
                var col: u16 = x + 1;
                while (col < x + w - 1) : (col += 1) {
                    self.buffer.set_cell_styled(col, row_y, " ", theme.selected_fg, theme.selected_bg, .{});
                }
                self.buffer.write_styled(x + 2, row_y, table, theme.selected_fg, theme.selected_bg, .{ .bold = true });
            } else {
                self.buffer.write(x + 2, row_y, table);
            }
        }
    }

    fn draw_query_pane(self: *Self, x: u16, y: u16, w: u16, h: u16) void {
        const active = self.active_pane == .query;
        self.draw_box(x, y, w, h, "Query", active);

        if (self.query_text.items.len > 0) {
            self.buffer.write(x + 1, y + 1, self.query_text.items);
        } else {
            self.buffer.write_styled(x + 1, y + 1, "SELECT * FROM ...", theme.hint, .default, .{ .italic = true });
        }

        if (active and self.query_cursor <= w - 2) {
            const cursor_x = x + 1 + @as(u16, @intCast(@min(self.query_cursor, w - 2)));
            self.buffer.set_cell_styled(cursor_x, y + 1, "▏", Color.cyan, .default, .{});
        }
    }

    fn draw_results_pane(self: *Self, x: u16, y: u16, w: u16, h: u16) void {
        const active = self.active_pane == .results;
        self.draw_box(x, y, w, h, "Results", active);

        self.buffer.write_styled(x + 2, y + 2, "No results yet", theme.hint, .default, .{ .italic = true });
        self.buffer.write_styled(x + 2, y + 3, "Execute a query with Ctrl+Enter", theme.hint, .default, .{});
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

        const hints = "^W:panes  Tab:cycle  ^Q:quit  /:search";
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
