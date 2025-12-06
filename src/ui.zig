const std = @import("std");
const Term = @import("term.zig").Term;
const Key = @import("term.zig").Key;
const Config = @import("config.zig").Config;
const Buffer = @import("buffer.zig").Buffer;
const Color = @import("buffer.zig").Color;
const Style = @import("buffer.zig").Style;
const db = @import("db.zig");
const TableActions = @import("table_actions.zig").TableActions;

pub const Pane = enum {
    tables,
    query,
    results,
};

pub const VimMode = enum {
    normal,
    insert,
    visual,
    visual_line,
};

const theme = struct {
    const border_active = Color.blue;
    const border_inactive = Color.bright_black;
    const title_active = Color.cyan;
    const title_inactive = Color.bright_black;
    const selected_bg = Color.bright_black;
    const selected_fg = Color.default;
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

fn is_word_char(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '_';
}

fn contains_ignore_case(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    if (needle.len == 0) return true;

    outer: for (0..haystack.len - needle.len + 1) |i| {
        for (needle, 0..) |nc, j| {
            const hc = haystack[i + j];
            const nc_lower = if (nc >= 'A' and nc <= 'Z') nc + 32 else nc;
            const hc_lower = if (hc >= 'A' and hc <= 'Z') hc + 32 else hc;
            if (nc_lower != hc_lower) continue :outer;
        }
        return true;
    }
    return false;
}

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
    query_scroll: usize,
    query_text: std.ArrayListUnmanaged(u8),
    window_mode: bool,
    vim_mode: VimMode,
    vim_operator: ?u8,
    vim_count: usize,
    vim_register: std.ArrayListUnmanaged(u8),
    vim_register_linewise: bool,
    vim_visual_start: usize,
    tables_search_mode: bool,
    tables_search_text: std.ArrayListUnmanaged(u8),
    tables_filtered: std.ArrayListUnmanaged(usize),
    result_set: ?db.ResultSet,
    error_message: []const u8,
    undo_stack: std.ArrayListUnmanaged(UndoState),
    redo_stack: std.ArrayListUnmanaged(UndoState),
    table_actions: TableActions,

    const Self = @This();

    const UndoState = struct {
        text: []u8,
        cursor: usize,
    };

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
            .query_scroll = 0,
            .query_text = .{},
            .window_mode = false,
            .vim_mode = .normal,
            .vim_operator = null,
            .vim_count = 0,
            .vim_register = .{},
            .vim_register_linewise = false,
            .vim_visual_start = 0,
            .tables_search_mode = false,
            .tables_search_text = .{},
            .tables_filtered = .{},
            .result_set = null,
            .error_message = "",
            .undo_stack = .{},
            .redo_stack = .{},
            .table_actions = TableActions.init(allocator, conn),
        };

        self.tables = conn.get_tables() catch &[_][]const u8{};

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.buffer.deinit();
        self.query_text.deinit(self.allocator);
        self.vim_register.deinit(self.allocator);
        self.tables_search_text.deinit(self.allocator);
        self.tables_filtered.deinit(self.allocator);
        for (self.undo_stack.items) |state| {
            self.allocator.free(state.text);
        }
        self.undo_stack.deinit(self.allocator);
        for (self.redo_stack.items) |state| {
            self.allocator.free(state.text);
        }
        self.redo_stack.deinit(self.allocator);
        if (self.tables.len > 0) {
            self.conn.free_tables(self.tables);
        }
        if (self.result_set) |*rs| {
            rs.deinit();
        }
        self.table_actions.deinit();
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
        if (self.table_actions.visible) {
            try self.handle_table_actions_input(key);
            return;
        }

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

    fn handle_table_actions_input(self: *Self, key: Key) !void {
        switch (key) {
            .escape => self.table_actions.close(),
            .char => |c| switch (c) {
                'j' => self.table_actions.move_down(),
                'k' => self.table_actions.move_up(),
                'q' => self.table_actions.close(),
                else => {},
            },
            .enter => {
                if (try self.table_actions.execute_selected()) |ddl| {
                    self.query_text.clearRetainingCapacity();
                    try self.query_text.appendSlice(self.allocator, ddl);
                    self.query_cursor = 0;
                    self.active_pane = .query;
                }
            },
            else => {},
        }
    }

    fn handle_tables_input(self: *Self, key: Key) !void {
        if (self.tables_search_mode) {
            try self.handle_tables_search_input(key);
            return;
        }

        const max_idx = if (self.tables.len > 0) self.tables.len - 1 else 0;
        const half_page = self.term.height / 2;

        switch (key) {
            .char => |c| {
                if (c >= '0' and c <= '9') {
                    self.vim_count = self.vim_count * 10 + (c - '0');
                    return;
                }

                const count = if (self.vim_count == 0) 1 else self.vim_count;
                self.vim_count = 0;

                switch (c) {
                    'j' => self.tables_move_down(count, max_idx),
                    'k' => self.tables_move_up(count),
                    'g' => self.tables_selected = 0,
                    'G' => self.tables_selected = max_idx,
                    'K' => {
                        if (self.tables.len > 0) {
                            self.table_actions.open(self.tables[self.tables_selected]);
                        }
                    },
                    '/' => {
                        self.tables_search_mode = true;
                        self.tables_search_text.clearRetainingCapacity();
                        self.tables_filtered.clearRetainingCapacity();
                    },
                    'n' => self.tables_search_next(),
                    'N' => self.tables_search_prev(),
                    else => {},
                }
            },
            .arrow_down => self.tables_move_down(1, max_idx),
            .arrow_up => self.tables_move_up(1),
            .enter => {
                if (self.tables.len > 0) {
                    try self.select_table();
                }
            },
            else => {
                if (key.is_ctrl('d')) {
                    self.tables_move_down(half_page, max_idx);
                } else if (key.is_ctrl('u')) {
                    self.tables_move_up(half_page);
                }
            },
        }
    }

    fn handle_tables_search_input(self: *Self, key: Key) !void {
        switch (key) {
            .escape => {
                self.tables_search_mode = false;
            },
            .enter => {
                self.tables_search_mode = false;
                self.update_tables_filter();
                if (self.tables_filtered.items.len > 0) {
                    self.tables_selected = 0;
                }
            },
            .char => |c| {
                try self.tables_search_text.append(self.allocator, c);
                self.update_tables_filter();
            },
            .backspace => {
                if (self.tables_search_text.items.len > 0) {
                    _ = self.tables_search_text.pop();
                    self.update_tables_filter();
                }
            },
            else => {},
        }
    }

    fn update_tables_filter(self: *Self) void {
        self.tables_filtered.clearRetainingCapacity();

        if (self.tables_search_text.items.len == 0) return;

        for (self.tables, 0..) |table, i| {
            if (contains_ignore_case(table, self.tables_search_text.items)) {
                self.tables_filtered.append(self.allocator, i) catch {};
            }
        }
    }

    fn tables_search_next(self: *Self) void {
        if (self.tables_filtered.items.len == 0) return;
        for (self.tables_filtered.items) |idx| {
            if (idx > self.tables_selected) {
                self.tables_selected = idx;
                return;
            }
        }
        self.tables_selected = self.tables_filtered.items[0];
    }

    fn tables_search_prev(self: *Self) void {
        if (self.tables_filtered.items.len == 0) return;
        var i = self.tables_filtered.items.len;
        while (i > 0) {
            i -= 1;
            if (self.tables_filtered.items[i] < self.tables_selected) {
                self.tables_selected = self.tables_filtered.items[i];
                return;
            }
        }
        self.tables_selected = self.tables_filtered.items[self.tables_filtered.items.len - 1];
    }

    fn tables_move_down(self: *Self, count: usize, max_idx: usize) void {
        if (self.tables_selected + count <= max_idx) {
            self.tables_selected += count;
        } else {
            self.tables_selected = max_idx;
        }
    }

    fn tables_move_up(self: *Self, count: usize) void {
        if (self.tables_selected >= count) {
            self.tables_selected -= count;
        } else {
            self.tables_selected = 0;
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
        if (key.is_ctrl('e')) {
            try self.execute_query();
            return;
        }

        switch (self.vim_mode) {
            .normal => try self.handle_vim_normal(key),
            .insert => try self.handle_vim_insert(key),
            .visual, .visual_line => try self.handle_vim_visual(key),
        }
    }

    fn handle_vim_normal(self: *Self, key: Key) !void {
        if (self.vim_operator) |op| {
            try self.handle_vim_operator_pending(op, key);
            return;
        }

        switch (key) {
            .char => |c| {
                if (c >= '0' and c <= '9') {
                    if (c == '0' and self.vim_count == 0) {
                        self.query_cursor = 0;
                    } else {
                        self.vim_count = self.vim_count * 10 + (c - '0');
                    }
                    return;
                }

                const count = if (self.vim_count == 0) 1 else self.vim_count;
                self.vim_count = 0;

                switch (c) {
                    'i' => {
                        try self.save_undo_state();
                        self.vim_mode = .insert;
                    },
                    'a' => {
                        try self.save_undo_state();
                        if (self.query_cursor < self.query_text.items.len) {
                            self.query_cursor += 1;
                        }
                        self.vim_mode = .insert;
                    },
                    'A' => {
                        try self.save_undo_state();
                        self.query_cursor = self.find_line_end(self.query_cursor);
                        self.vim_mode = .insert;
                    },
                    'I' => {
                        try self.save_undo_state();
                        self.move_first_non_blank();
                        self.vim_mode = .insert;
                    },
                    'o' => {
                        try self.save_undo_state();
                        const line_end = self.find_line_end(self.query_cursor);
                        try self.query_text.insert(self.allocator, line_end, '\n');
                        self.query_cursor = line_end + 1;
                        self.vim_mode = .insert;
                    },
                    'O' => {
                        try self.save_undo_state();
                        const line_start = self.find_line_start(self.query_cursor);
                        try self.query_text.insert(self.allocator, line_start, '\n');
                        self.query_cursor = line_start;
                        self.vim_mode = .insert;
                    },
                    'h' => self.vim_move_left(count),
                    'j' => self.vim_move_down(count),
                    'k' => self.vim_move_up(count),
                    'l' => self.vim_move_right(count),
                    'w' => {
                        for (0..count) |_| self.move_word_forward();
                    },
                    'b' => {
                        for (0..count) |_| self.move_word_backward();
                    },
                    'e' => {
                        for (0..count) |_| self.move_word_end();
                    },
                    '0' => {
                        self.query_cursor = self.find_line_start(self.query_cursor);
                    },
                    '$' => {
                        const line_end = self.find_line_end(self.query_cursor);
                        const line_start = self.find_line_start(self.query_cursor);
                        if (line_end > line_start) {
                            self.query_cursor = line_end - 1;
                        } else {
                            self.query_cursor = line_start;
                        }
                    },
                    '^' => self.move_first_non_blank(),
                    'x' => {
                        try self.save_undo_state();
                        for (0..count) |_| {
                            if (self.query_cursor < self.query_text.items.len) {
                                try self.yank_range(self.query_cursor, self.query_cursor + 1);
                                _ = self.query_text.orderedRemove(self.query_cursor);
                            }
                        }
                        self.clamp_cursor();
                    },
                    'X' => {
                        try self.save_undo_state();
                        for (0..count) |_| {
                            if (self.query_cursor > 0) {
                                try self.yank_range(self.query_cursor - 1, self.query_cursor);
                                _ = self.query_text.orderedRemove(self.query_cursor - 1);
                                self.query_cursor -= 1;
                            }
                        }
                    },
                    'd', 'c', 'y' => {
                        self.vim_operator = c;
                    },
                    'D' => {
                        try self.save_undo_state();
                        const line_end = self.find_line_end(self.query_cursor);
                        try self.yank_range(self.query_cursor, line_end);
                        self.delete_range(self.query_cursor, line_end);
                        self.clamp_cursor();
                    },
                    'C' => {
                        try self.save_undo_state();
                        const line_end = self.find_line_end(self.query_cursor);
                        try self.yank_range(self.query_cursor, line_end);
                        self.delete_range(self.query_cursor, line_end);
                        self.vim_mode = .insert;
                    },
                    'Y' => {
                        const line_start = self.find_line_start(self.query_cursor);
                        const line_end = self.find_line_end(self.query_cursor);
                        try self.yank_range(line_start, line_end);
                        self.vim_register_linewise = true;
                    },
                    'p' => {
                        try self.save_undo_state();
                        for (0..count) |_| try self.vim_paste_after();
                    },
                    'P' => {
                        try self.save_undo_state();
                        for (0..count) |_| try self.vim_paste_before();
                    },
                    'v' => {
                        self.vim_visual_start = self.query_cursor;
                        self.vim_mode = .visual;
                    },
                    'V' => {
                        self.vim_visual_start = self.find_line_start(self.query_cursor);
                        self.query_cursor = self.find_line_end(self.query_cursor);
                        if (self.query_cursor > 0 and self.query_cursor > self.vim_visual_start) {
                            self.query_cursor -= 1;
                        }
                        self.vim_mode = .visual_line;
                    },
                    'u' => self.undo(),
                    'g' => {
                        self.vim_operator = 'g';
                    },
                    'G' => {
                        if (self.query_text.items.len > 0) {
                            self.query_cursor = self.query_text.items.len - 1;
                        }
                    },
                    else => {},
                }
            },
            .arrow_left => self.vim_move_left(1),
            .arrow_right => self.vim_move_right(1),
            .enter => try self.execute_query(),
            else => {
                if (key.is_ctrl('r')) {
                    self.redo();
                }
            },
        }
    }

    fn handle_vim_visual(self: *Self, key: Key) !void {
        switch (key) {
            .escape => {
                self.vim_mode = .normal;
                self.vim_count = 0;
            },
            .char => |c| {
                var sel_start = @min(self.vim_visual_start, self.query_cursor);
                var sel_end = @max(self.vim_visual_start, self.query_cursor) + 1;

                // For visual line mode, calculate yank_end (excludes newline) and delete_end (includes newline)
                var yank_end = sel_end;
                if (self.vim_mode == .visual_line) {
                    sel_start = self.find_line_start(sel_start);
                    yank_end = self.find_line_end(@max(self.vim_visual_start, self.query_cursor));
                    sel_end = if (yank_end < self.query_text.items.len) yank_end + 1 else yank_end;
                }

                switch (c) {
                    'h' => self.vim_move_left(1),
                    'j' => self.vim_move_down(1),
                    'k' => self.vim_move_up(1),
                    'l' => self.vim_move_right(1),
                    'w' => self.move_word_forward(),
                    'b' => self.move_word_backward(),
                    'e' => self.move_word_end(),
                    '0' => {
                        self.query_cursor = self.find_line_start(self.query_cursor);
                    },
                    '$' => {
                        const line_end = self.find_line_end(self.query_cursor);
                        const line_start = self.find_line_start(self.query_cursor);
                        if (line_end > line_start) {
                            self.query_cursor = line_end - 1;
                        } else {
                            self.query_cursor = line_start;
                        }
                    },
                    'd', 'x' => {
                        try self.save_undo_state();
                        try self.yank_range(sel_start, yank_end);
                        if (self.vim_mode == .visual_line) {
                            self.vim_register_linewise = true;
                        }
                        self.delete_range(sel_start, sel_end);
                        self.query_cursor = sel_start;
                        self.clamp_cursor();
                        self.vim_mode = .normal;
                    },
                    'c' => {
                        try self.save_undo_state();
                        try self.yank_range(sel_start, yank_end);
                        if (self.vim_mode == .visual_line) {
                            self.vim_register_linewise = true;
                        }
                        self.delete_range(sel_start, sel_end);
                        self.query_cursor = sel_start;
                        self.vim_mode = .insert;
                    },
                    'y' => {
                        try self.yank_range(sel_start, yank_end);
                        if (self.vim_mode == .visual_line) {
                            self.vim_register_linewise = true;
                        } else {
                            for (self.query_text.items[sel_start..yank_end]) |ch| {
                                if (ch == '\n') {
                                    self.vim_register_linewise = true;
                                    break;
                                }
                            }
                        }
                        self.query_cursor = sel_start;
                        self.vim_mode = .normal;
                    },
                    else => {},
                }
            },
            else => {},
        }
    }

    fn handle_vim_insert(self: *Self, key: Key) !void {
        switch (key) {
            .escape => {
                self.vim_mode = .normal;
                if (self.query_cursor > 0) {
                    self.query_cursor -= 1;
                }
            },
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
            .home => self.query_cursor = self.find_line_start(self.query_cursor),
            .end => self.query_cursor = self.find_line_end(self.query_cursor),
            .enter => {
                try self.query_text.insert(self.allocator, self.query_cursor, '\n');
                self.query_cursor += 1;
            },
            else => {},
        }
    }

    fn handle_vim_operator_pending(self: *Self, op: u8, key: Key) !void {
        var start = self.query_cursor;
        var end = start;
        var should_apply = false;

        switch (key) {
            .escape => {
                self.vim_operator = null;
                return;
            },
            .char => |c| {
                if (c == 'i' or c == 'a') {
                    if (try self.get_text_object(c)) |obj| {
                        start = obj.start;
                        end = obj.end;
                        should_apply = true;
                    }
                } else {
                    switch (c) {
                        'w' => {
                            self.move_word_forward();
                            end = self.query_cursor;
                            self.query_cursor = start;
                            should_apply = true;
                        },
                        'b' => {
                            self.move_word_backward();
                            end = start;
                            start = self.query_cursor;
                            should_apply = true;
                        },
                        'e' => {
                            self.move_word_end();
                            end = self.query_cursor + 1;
                            self.query_cursor = start;
                            should_apply = true;
                        },
                        '$' => {
                            end = self.find_line_end(self.query_cursor);
                            should_apply = true;
                        },
                        '0' => {
                            const line_start = self.find_line_start(self.query_cursor);
                            end = start;
                            start = line_start;
                            should_apply = true;
                        },
                        'g' => {
                            if (op == 'g') {
                                self.query_cursor = 0;
                                self.vim_operator = null;
                                return;
                            }
                        },
                        'd', 'c', 'y' => {
                            if (c == op) {
                                if (op != 'y') try self.save_undo_state();
                                const line_start = self.find_line_start(self.query_cursor);
                                const line_end = self.find_line_end(self.query_cursor);
                                // Calculate delete_end separately - delete includes newline, yank does not
                                const delete_end = if (line_end < self.query_text.items.len and self.query_text.items[line_end] == '\n')
                                    line_end + 1
                                else
                                    line_end;
                                try self.yank_range(line_start, line_end);
                                self.vim_register_linewise = true;
                                if (op != 'y') {
                                    self.delete_range(line_start, delete_end);
                                    self.query_cursor = line_start;
                                    self.clamp_cursor();
                                }
                                if (op == 'c') {
                                    self.vim_mode = .insert;
                                }
                                self.vim_operator = null;
                                return;
                            }
                        },
                        else => {},
                    }
                }
            },
            else => {},
        }

        self.vim_operator = null;

        if (should_apply and start < end) {
            if (op == 'd' or op == 'c') try self.save_undo_state();
            try self.yank_range(start, end);
            if (op == 'd' or op == 'c') {
                self.delete_range(start, end);
                self.query_cursor = start;
                self.clamp_cursor();
            }
            if (op == 'c') {
                self.vim_mode = .insert;
            }
        }
    }

    const TextObject = struct { start: usize, end: usize };

    fn get_text_object(self: *Self, kind: u8) !?TextObject {
        _ = kind;
        const text = self.query_text.items;
        if (text.len == 0) return null;

        const pos = @min(self.query_cursor, text.len - 1);

        if (is_word_char(text[pos])) {
            var start = pos;
            var end = pos;

            while (start > 0 and is_word_char(text[start - 1])) {
                start -= 1;
            }
            while (end < text.len and is_word_char(text[end])) {
                end += 1;
            }

            return TextObject{ .start = start, .end = end };
        }

        return null;
    }

    fn yank_range(self: *Self, start: usize, end: usize) !void {
        if (start >= end or start >= self.query_text.items.len) return;
        const actual_end = @min(end, self.query_text.items.len);

        self.vim_register.clearRetainingCapacity();
        self.vim_register_linewise = false;
        try self.vim_register.appendSlice(self.allocator, self.query_text.items[start..actual_end]);
    }

    fn delete_range(self: *Self, start: usize, end: usize) void {
        if (start >= end or start >= self.query_text.items.len) return;
        const actual_end = @min(end, self.query_text.items.len);

        var i: usize = 0;
        while (i < actual_end - start) : (i += 1) {
            if (start < self.query_text.items.len) {
                _ = self.query_text.orderedRemove(start);
            }
        }
    }

    fn clamp_cursor(self: *Self) void {
        if (self.query_text.items.len == 0) {
            self.query_cursor = 0;
        } else if (self.query_cursor >= self.query_text.items.len) {
            self.query_cursor = self.query_text.items.len - 1;
        }
    }

    fn save_undo_state(self: *Self) !void {
        const text_copy = try self.allocator.dupe(u8, self.query_text.items);
        try self.undo_stack.append(self.allocator, .{
            .text = text_copy,
            .cursor = self.query_cursor,
        });
        for (self.redo_stack.items) |state| {
            self.allocator.free(state.text);
        }
        self.redo_stack.clearRetainingCapacity();
    }

    fn undo(self: *Self) void {
        if (self.undo_stack.items.len == 0) return;

        const current_copy = self.allocator.dupe(u8, self.query_text.items) catch return;
        self.redo_stack.append(self.allocator, .{
            .text = current_copy,
            .cursor = self.query_cursor,
        }) catch {
            self.allocator.free(current_copy);
            return;
        };

        const state = self.undo_stack.pop() orelse return;
        self.query_text.clearRetainingCapacity();
        self.query_text.appendSlice(self.allocator, state.text) catch return;
        self.query_cursor = state.cursor;
        self.allocator.free(state.text);
        self.clamp_cursor();
    }

    fn redo(self: *Self) void {
        if (self.redo_stack.items.len == 0) return;

        const current_copy = self.allocator.dupe(u8, self.query_text.items) catch return;
        self.undo_stack.append(self.allocator, .{
            .text = current_copy,
            .cursor = self.query_cursor,
        }) catch {
            self.allocator.free(current_copy);
            return;
        };

        const state = self.redo_stack.pop() orelse return;
        self.query_text.clearRetainingCapacity();
        self.query_text.appendSlice(self.allocator, state.text) catch return;
        self.query_cursor = state.cursor;
        self.allocator.free(state.text);
        self.clamp_cursor();
    }

    fn vim_move_left(self: *Self, count: usize) void {
        if (self.query_cursor >= count) {
            self.query_cursor -= count;
        } else {
            self.query_cursor = 0;
        }
    }

    fn vim_move_right(self: *Self, count: usize) void {
        const max = if (self.query_text.items.len > 0) self.query_text.items.len - 1 else 0;
        self.query_cursor = @min(self.query_cursor + count, max);
    }

    fn move_word_forward(self: *Self) void {
        const text = self.query_text.items;
        var pos = self.query_cursor;

        while (pos < text.len and !is_word_char(text[pos])) {
            pos += 1;
        }
        while (pos < text.len and is_word_char(text[pos])) {
            pos += 1;
        }

        self.query_cursor = pos;
    }

    fn move_word_backward(self: *Self) void {
        if (self.query_cursor == 0) return;
        const text = self.query_text.items;
        var pos = self.query_cursor - 1;

        while (pos > 0 and !is_word_char(text[pos])) {
            pos -= 1;
        }
        while (pos > 0 and is_word_char(text[pos - 1])) {
            pos -= 1;
        }

        self.query_cursor = pos;
    }

    fn move_word_end(self: *Self) void {
        const text = self.query_text.items;
        if (self.query_cursor >= text.len -| 1) return;
        var pos = self.query_cursor + 1;

        while (pos < text.len and !is_word_char(text[pos])) {
            pos += 1;
        }
        while (pos < text.len -| 1 and is_word_char(text[pos + 1])) {
            pos += 1;
        }

        self.query_cursor = @min(pos, text.len -| 1);
    }

    fn move_first_non_blank(self: *Self) void {
        const text = self.query_text.items;
        const line_start = self.find_line_start(self.query_cursor);
        const line_end = self.find_line_end(self.query_cursor);
        var pos = line_start;

        while (pos < line_end and (text[pos] == ' ' or text[pos] == '\t')) {
            pos += 1;
        }

        self.query_cursor = pos;
    }

    fn vim_paste_after(self: *Self) !void {
        if (self.vim_register.items.len == 0) return;

        if (self.vim_register_linewise) {
            const line_end = self.find_line_end(self.query_cursor);

            if (line_end >= self.query_text.items.len) {
                try self.query_text.append(self.allocator, '\n');
            }

            const pos = if (line_end < self.query_text.items.len) line_end + 1 else self.query_text.items.len;
            for (self.vim_register.items, 0..) |c, i| {
                try self.query_text.insert(self.allocator, pos + i, c);
            }
            if (pos + self.vim_register.items.len >= self.query_text.items.len or
                self.query_text.items[pos + self.vim_register.items.len] != '\n')
            {
                try self.query_text.insert(self.allocator, pos + self.vim_register.items.len, '\n');
            }
            self.query_cursor = pos;
        } else {
            const pos = if (self.query_text.items.len > 0) @min(self.query_cursor + 1, self.query_text.items.len) else 0;
            for (self.vim_register.items, 0..) |c, i| {
                try self.query_text.insert(self.allocator, pos + i, c);
            }
            self.query_cursor = pos + self.vim_register.items.len - 1;
        }
    }

    fn vim_paste_before(self: *Self) !void {
        if (self.vim_register.items.len == 0) return;

        if (self.vim_register_linewise) {
            const line_start = self.find_line_start(self.query_cursor);

            for (self.vim_register.items, 0..) |c, i| {
                try self.query_text.insert(self.allocator, line_start + i, c);
            }
            try self.query_text.insert(self.allocator, line_start + self.vim_register.items.len, '\n');
            self.query_cursor = line_start;
        } else {
            const pos = self.query_cursor;
            for (self.vim_register.items, 0..) |c, i| {
                try self.query_text.insert(self.allocator, pos + i, c);
            }
            self.query_cursor = pos + self.vim_register.items.len - 1;
        }
    }

    fn find_line_start(self: *Self, pos: usize) usize {
        if (pos == 0 or self.query_text.items.len == 0) return 0;
        var p = pos;
        while (p > 0 and self.query_text.items[p - 1] != '\n') {
            p -= 1;
        }
        return p;
    }

    fn find_line_end(self: *Self, pos: usize) usize {
        const text = self.query_text.items;
        if (text.len == 0) return 0;
        var p = pos;
        while (p < text.len and text[p] != '\n') {
            p += 1;
        }
        return p;
    }

    fn get_cursor_line(self: *Self) usize {
        const text = self.query_text.items;
        var line: usize = 0;
        for (0..@min(self.query_cursor, text.len)) |i| {
            if (text[i] == '\n') line += 1;
        }
        return line;
    }

    fn get_cursor_col(self: *Self) usize {
        return self.query_cursor - self.find_line_start(self.query_cursor);
    }

    fn get_line_count(self: *Self) usize {
        const text = self.query_text.items;
        if (text.len == 0) return 1;
        var count: usize = 1;
        for (text) |c| {
            if (c == '\n') count += 1;
        }
        return count;
    }

    fn ensure_cursor_visible(self: *Self, visible_lines: usize) void {
        const cursor_line = self.get_cursor_line();
        if (cursor_line < self.query_scroll) {
            self.query_scroll = cursor_line;
        } else if (cursor_line >= self.query_scroll + visible_lines) {
            self.query_scroll = cursor_line - visible_lines + 1;
        }
    }

    fn vim_move_down(self: *Self, count: usize) void {
        const text = self.query_text.items;
        if (text.len == 0) return;

        for (0..count) |_| {
            const line_start = self.find_line_start(self.query_cursor);
            const col = self.query_cursor - line_start;
            const line_end = self.find_line_end(self.query_cursor);

            if (line_end >= text.len) return;

            const next_line_start = line_end + 1;
            const next_line_end = self.find_line_end(next_line_start);
            const next_line_len = next_line_end - next_line_start;

            self.query_cursor = next_line_start + @min(col, next_line_len);
            if (self.query_cursor > 0 and self.query_cursor == next_line_end and next_line_len > 0) {
                self.query_cursor -= 1;
            }
        }
    }

    fn vim_move_up(self: *Self, count: usize) void {
        const text = self.query_text.items;
        if (text.len == 0) return;

        for (0..count) |_| {
            const line_start = self.find_line_start(self.query_cursor);
            if (line_start == 0) return;

            const col = self.query_cursor - line_start;
            const prev_line_end = line_start - 1;
            const prev_line_start = self.find_line_start(prev_line_end);
            const prev_line_len = prev_line_end - prev_line_start;

            self.query_cursor = prev_line_start + @min(col, prev_line_len);
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
        const query_height: u16 = 8;
        const status_height: u16 = 1;

        self.draw_tables_pane(0, 0, tables_width, h -| status_height);
        self.draw_query_pane(tables_width, 0, w -| tables_width, query_height);
        self.draw_results_pane(tables_width, query_height, w -| tables_width, h -| query_height -| status_height);
        self.draw_status_line(0, h -| 1, w);

        if (self.table_actions.visible) {
            self.table_actions.draw(&self.buffer, w, h);
        }

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
            const is_match = self.is_table_search_match(idx);

            if (selected) {
                var col: u16 = x + 1;
                while (col < x + w - 1) : (col += 1) {
                    self.buffer.set_cell_styled(col, row_y, " ", theme.selected_fg, theme.selected_bg, .{});
                }
            }

            const table_name = self.tables[idx];
            const max_len = w -| 4;
            const fg = if (selected) theme.selected_fg else if (is_match) Color.yellow else Color.default;
            const bg = if (selected) theme.selected_bg else Color.default;
            const style: Style = if (selected) .{ .bold = true } else if (is_match) .{ .bold = true } else .{};

            if (table_name.len > max_len) {
                self.buffer.write_styled(x + 2, row_y, table_name[0 .. max_len -| 1], fg, bg, style);
                self.buffer.write_styled(x + 2 + max_len -| 1, row_y, "…", fg, bg, style);
            } else {
                self.buffer.write_styled(x + 2, row_y, table_name, fg, bg, style);
            }
        }

        if (self.tables_search_text.items.len > 0) {
            const search_display = self.tables_search_text.items[0..@min(self.tables_search_text.items.len, w -| 6)];
            self.buffer.write_styled(x + 1, y + h - 1, "/", Color.yellow, .default, .{ .bold = true });
            self.buffer.write_styled(x + 2, y + h - 1, search_display, theme.hint, .default, .{});
        }
    }

    fn is_table_search_match(self: *Self, idx: usize) bool {
        for (self.tables_filtered.items) |match_idx| {
            if (match_idx == idx) return true;
        }
        return false;
    }

    fn draw_query_pane(self: *Self, x: u16, y: u16, w: u16, h: u16) void {
        const active = self.active_pane == .query;
        self.draw_box(x, y, w, h, "Query", active);

        const inner_w = w -| 2;
        const inner_h = h -| 2;
        if (inner_h == 0 or inner_w == 0) return;

        self.ensure_cursor_visible(inner_h);

        // Line number gutter: 3 digits + 1 space separator
        const gutter_width: u16 = 4;
        const text_area_w = inner_w -| gutter_width;

        if (self.query_text.items.len == 0) {
            // Draw line number for empty state
            self.buffer.print_styled(x + 1, y + 1, theme.hint, .default, .{}, "{d:>3} ", .{1});
            self.buffer.write_styled(x + 1 + gutter_width, y + 1, "SELECT * FROM ...", theme.hint, .default, .{ .italic = true });
            if (active) {
                const is_insert = self.vim_mode == .insert;
                if (is_insert) {
                    self.buffer.set_cell_styled(x + 1 + gutter_width, y + 1, "▏", Color.bright_green, .default, .{ .bold = true });
                } else {
                    self.buffer.set_cell_styled(x + 1 + gutter_width, y + 1, " ", Color.black, Color.white, .{});
                }
            }
            return;
        }

        const text = self.query_text.items;
        const in_visual = self.vim_mode == .visual or self.vim_mode == .visual_line;
        var sel_start: usize = 0;
        var sel_end: usize = 0;
        if (in_visual) {
            sel_start = @min(self.vim_visual_start, self.query_cursor);
            sel_end = @max(self.vim_visual_start, self.query_cursor) + 1;
            if (self.vim_mode == .visual_line) {
                sel_start = self.find_line_start(sel_start);
                sel_end = self.find_line_end(@max(self.vim_visual_start, self.query_cursor));
                if (sel_end < text.len) sel_end += 1;
            }
        }

        var line: usize = 0;
        var col: u16 = 0;
        var i: usize = 0;
        var line_num_drawn: usize = std.math.maxInt(usize); // Track which line number we've drawn

        while (i < text.len) {
            if (line >= self.query_scroll + inner_h) break;

            // Draw line number at start of each visible line
            if (line >= self.query_scroll and line != line_num_drawn) {
                const draw_y = y + 1 + @as(u16, @intCast(line - self.query_scroll));
                self.buffer.print_styled(x + 1, draw_y, theme.hint, .default, .{}, "{d:>3} ", .{line + 1});
                line_num_drawn = line;
            }

            const c = text[i];

            if (c == '\n') {
                if (line >= self.query_scroll and in_visual and i >= sel_start and i < sel_end) {
                    const draw_y = y + 1 + @as(u16, @intCast(line - self.query_scroll));
                    self.buffer.set_cell_styled(x + 1 + gutter_width + col, draw_y, " ", Color.black, Color.magenta, .{});
                }
                line += 1;
                col = 0;
                i += 1;
                continue;
            }

            if (line >= self.query_scroll and col < text_area_w) {
                const draw_y = y + 1 + @as(u16, @intCast(line - self.query_scroll));
                const in_selection = in_visual and i >= sel_start and i < sel_end;
                const fg = if (in_selection) Color.black else self.get_char_color(text, i);
                const bg = if (in_selection) Color.magenta else Color.default;
                self.buffer.set_cell_styled(x + 1 + gutter_width + col, draw_y, text[i .. i + 1], fg, bg, .{});
            }
            col += 1;
            i += 1;
        }

        // Draw line number for last line if it ends without newline and hasn't been drawn
        if (line >= self.query_scroll and line < self.query_scroll + inner_h and line != line_num_drawn) {
            const draw_y = y + 1 + @as(u16, @intCast(line - self.query_scroll));
            self.buffer.print_styled(x + 1, draw_y, theme.hint, .default, .{}, "{d:>3} ", .{line + 1});
        }

        if (active) {
            const cursor_line = self.get_cursor_line();
            const cursor_col = self.get_cursor_col();

            if (cursor_line >= self.query_scroll and cursor_line < self.query_scroll + inner_h) {
                const cursor_x = x + 1 + gutter_width + @as(u16, @intCast(@min(cursor_col, text_area_w -| 1)));
                const cursor_y = y + 1 + @as(u16, @intCast(cursor_line - self.query_scroll));
                const is_insert = self.vim_mode == .insert;

                if (is_insert) {
                    self.buffer.set_cell_styled(cursor_x, cursor_y, "▏", Color.bright_green, .default, .{ .bold = true });
                } else {
                    const cursor_char = if (self.query_cursor < text.len and text[self.query_cursor] != '\n')
                        text[self.query_cursor .. self.query_cursor + 1]
                    else
                        " ";
                    self.buffer.write_styled(cursor_x, cursor_y, cursor_char, Color.black, Color.white, .{ .bold = true });
                }
            }
        }
    }

    fn get_char_color(self: *Self, text: []const u8, pos: usize) Color {
        _ = self;
        const c = text[pos];

        if (c == '\'' or c == '"') return theme.sql_string;
        if (c >= '0' and c <= '9') return theme.sql_number;
        if (c == '=' or c == '<' or c == '>' or c == '!' or c == '*') return theme.sql_operator;

        if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_') {
            var start = pos;
            while (start > 0 and is_word_char(text[start - 1])) start -= 1;
            var end = pos;
            while (end < text.len and is_word_char(text[end])) end += 1;

            const word = text[start..end];
            var upper_buf: [32]u8 = undefined;
            if (word.len <= upper_buf.len) {
                for (word, 0..) |wc, i| {
                    upper_buf[i] = if (wc >= 'a' and wc <= 'z') wc - 32 else wc;
                }
                const upper = upper_buf[0..word.len];
                for (sql_keywords) |kw| {
                    if (std.mem.eql(u8, upper, kw)) return theme.sql_keyword;
                }
                for (sql_functions) |fn_name| {
                    if (std.mem.eql(u8, upper, fn_name)) return theme.sql_function;
                }
            }
        }

        return Color.default;
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

        var offset: u16 = 1;

        if (self.window_mode) {
            const mode_str = " WINDOW ";
            self.buffer.write_styled(x + offset, y, mode_str, Color.black, Color.yellow, .{ .bold = true });
            offset += @intCast(mode_str.len);
        }

        if (self.active_pane == .query) {
            const vim_str = switch (self.vim_mode) {
                .normal => " NORMAL ",
                .insert => " INSERT ",
                .visual => " VISUAL ",
                .visual_line => " V-LINE ",
            };
            const vim_bg = switch (self.vim_mode) {
                .normal => Color.blue,
                .insert => Color.green,
                .visual, .visual_line => Color.magenta,
            };
            self.buffer.write_styled(x + offset, y, vim_str, Color.black, vim_bg, .{ .bold = true });
            offset += @intCast(vim_str.len);

            if (self.vim_operator) |op| {
                self.buffer.set_cell_char_styled(x + offset, y, op, Color.yellow, theme.status_bg, .{ .bold = true });
                offset += 1;
            }

            if (self.vim_count > 0) {
                self.buffer.print_styled(x + offset, y, Color.yellow, theme.status_bg, .{}, "{d}", .{self.vim_count});
                offset += 3;
            }
        }

        if (self.active_pane == .tables and self.tables_search_mode) {
            self.buffer.write_styled(x + offset, y, " /", Color.yellow, theme.status_bg, .{ .bold = true });
            offset += 2;
            if (self.tables_search_text.items.len > 0) {
                const search_len: u16 = @intCast(@min(self.tables_search_text.items.len, 20));
                self.buffer.write_styled(x + offset, y, self.tables_search_text.items[0..search_len], theme.status_fg, theme.status_bg, .{});
                offset += search_len;
            }
        } else {
            const pane_str = switch (self.active_pane) {
                .tables => " TABLES",
                .query => " QUERY",
                .results => " RESULTS",
            };
            self.buffer.write_styled(x + offset, y, pane_str, theme.status_fg, theme.status_bg, .{ .bold = true });
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
