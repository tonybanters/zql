const std = @import("std");
const Term = @import("term.zig").Term;

pub const Color = enum(u8) {
    default = 0,
    black = 30,
    red = 31,
    green = 32,
    yellow = 33,
    blue = 34,
    magenta = 35,
    cyan = 36,
    white = 37,
    bright_black = 90,
    bright_red = 91,
    bright_green = 92,
    bright_yellow = 93,
    bright_blue = 94,
    bright_magenta = 95,
    bright_cyan = 96,
    bright_white = 97,
};

pub const Style = packed struct {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    reverse: bool = false,
};

pub const Cell = struct {
    char: []const u8 = " ",
    fg: Color = .default,
    bg: Color = .default,
    style: Style = .{},
};

pub const Buffer = struct {
    allocator: std.mem.Allocator,
    cells: []Cell,
    width: u16,
    height: u16,
    output: std.ArrayListUnmanaged(u8),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .cells = &[_]Cell{},
            .width = 0,
            .height = 0,
            .output = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.cells.len > 0) {
            self.allocator.free(self.cells);
        }
        self.output.deinit(self.allocator);
    }

    pub fn resize(self: *Self, width: u16, height: u16) !void {
        if (self.width == width and self.height == height) return;

        if (self.cells.len > 0) {
            self.allocator.free(self.cells);
        }

        const size = @as(usize, width) * @as(usize, height);
        self.cells = try self.allocator.alloc(Cell, size);
        self.width = width;
        self.height = height;
        self.clear_cells();
    }

    fn clear_cells(self: *Self) void {
        for (self.cells) |*cell| {
            cell.* = Cell{};
        }
    }

    pub fn clear(self: *Self) void {
        self.clear_cells();
    }

    pub fn set_cell(self: *Self, x: u16, y: u16, char: []const u8) void {
        if (x >= self.width or y >= self.height) return;
        const idx = @as(usize, y) * @as(usize, self.width) + @as(usize, x);
        if (idx < self.cells.len) {
            self.cells[idx].char = char;
        }
    }

    pub fn set_cell_styled(self: *Self, x: u16, y: u16, char: []const u8, fg: Color, bg: Color, style: Style) void {
        if (x >= self.width or y >= self.height) return;
        const idx = @as(usize, y) * @as(usize, self.width) + @as(usize, x);
        if (idx < self.cells.len) {
            self.cells[idx] = .{ .char = char, .fg = fg, .bg = bg, .style = style };
        }
    }

    pub fn set_fg(self: *Self, x: u16, y: u16, fg: Color) void {
        if (x >= self.width or y >= self.height) return;
        const idx = @as(usize, y) * @as(usize, self.width) + @as(usize, x);
        if (idx < self.cells.len) {
            self.cells[idx].fg = fg;
        }
    }

    pub fn set_bg(self: *Self, x: u16, y: u16, bg: Color) void {
        if (x >= self.width or y >= self.height) return;
        const idx = @as(usize, y) * @as(usize, self.width) + @as(usize, x);
        if (idx < self.cells.len) {
            self.cells[idx].bg = bg;
        }
    }

    pub fn write(self: *Self, x: u16, y: u16, text: []const u8) void {
        self.write_styled(x, y, text, .default, .default, .{});
    }

    pub fn write_styled(self: *Self, x: u16, y: u16, text: []const u8, fg: Color, bg: Color, style: Style) void {
        var col = x;
        var i: usize = 0;
        while (i < text.len) {
            if (col >= self.width) break;

            const byte = text[i];
            const char_len: usize = if (byte < 0x80) 1 else if (byte < 0xE0) 2 else if (byte < 0xF0) 3 else 4;

            if (i + char_len <= text.len) {
                self.set_cell_styled(col, y, text[i .. i + char_len], fg, bg, style);
            }
            col += 1;
            i += char_len;
        }
    }

    pub fn print(self: *Self, x: u16, y: u16, comptime fmt: []const u8, args: anytype) void {
        var buf: [512]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
        self.write(x, y, text);
    }

    pub fn print_styled(self: *Self, x: u16, y: u16, fg: Color, bg: Color, style: Style, comptime fmt: []const u8, args: anytype) void {
        var buf: [512]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
        self.write_styled(x, y, text, fg, bg, style);
    }

    pub fn fill_rect(self: *Self, x: u16, y: u16, w: u16, h: u16, char: []const u8, fg: Color, bg: Color) void {
        var row: u16 = 0;
        while (row < h) : (row += 1) {
            var col: u16 = 0;
            while (col < w) : (col += 1) {
                self.set_cell_styled(x + col, y + row, char, fg, bg, .{});
            }
        }
    }

    pub fn flush(self: *Self, term: *Term) !void {
        if (self.width != term.width or self.height != term.height) {
            try self.resize(term.width, term.height);
        }

        self.output.clearRetainingCapacity();

        try self.output.appendSlice(self.allocator, "\x1b[H\x1b[0m");

        var last_fg: Color = .default;
        var last_bg: Color = .default;
        var last_style: Style = .{};

        var y: u16 = 0;
        while (y < self.height) : (y += 1) {
            var x: u16 = 0;
            while (x < self.width) : (x += 1) {
                const idx = @as(usize, y) * @as(usize, self.width) + @as(usize, x);
                if (idx < self.cells.len) {
                    const cell = self.cells[idx];

                    if (cell.fg != last_fg or cell.bg != last_bg or
                        @as(u5, @bitCast(cell.style)) != @as(u5, @bitCast(last_style)))
                    {
                        try self.emit_style(cell.fg, cell.bg, cell.style);
                        last_fg = cell.fg;
                        last_bg = cell.bg;
                        last_style = cell.style;
                    }

                    try self.output.appendSlice(self.allocator, cell.char);
                }
            }
            if (y < self.height - 1) {
                try self.output.appendSlice(self.allocator, "\r\n");
            }
        }

        try self.output.appendSlice(self.allocator, "\x1b[0m");

        try term.write_all(self.output.items);
    }

    fn emit_style(self: *Self, fg: Color, bg: Color, style: Style) !void {
        try self.output.appendSlice(self.allocator, "\x1b[0");

        if (style.bold) try self.output.appendSlice(self.allocator, ";1");
        if (style.dim) try self.output.appendSlice(self.allocator, ";2");
        if (style.italic) try self.output.appendSlice(self.allocator, ";3");
        if (style.underline) try self.output.appendSlice(self.allocator, ";4");
        if (style.reverse) try self.output.appendSlice(self.allocator, ";7");

        if (fg != .default) {
            var buf: [8]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, ";{d}", .{@intFromEnum(fg)}) catch return;
            try self.output.appendSlice(self.allocator, s);
        }

        if (bg != .default) {
            var buf: [8]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, ";{d}", .{@intFromEnum(bg) + 10}) catch return;
            try self.output.appendSlice(self.allocator, s);
        }

        try self.output.appendSlice(self.allocator, "m");
    }
};
