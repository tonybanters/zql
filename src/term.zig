const std = @import("std");
const posix = std.posix;

pub const Term = struct {
    original_termios: posix.termios,
    tty: std.fs.File,
    width: u16,
    height: u16,

    const Self = @This();

    pub fn init() !Self {
        const tty = try std.fs.openFileAbsolute("/dev/tty", .{ .mode = .read_write });

        var self = Self{
            .original_termios = undefined,
            .tty = tty,
            .width = 80,
            .height = 24,
        };

        self.original_termios = try posix.tcgetattr(tty.handle);
        try self.enable_raw_mode();
        try self.update_size();
        try self.enter_alt_screen();
        try self.hide_cursor();

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.show_cursor() catch {};
        self.leave_alt_screen() catch {};
        posix.tcsetattr(self.tty.handle, .FLUSH, self.original_termios) catch {};
        self.tty.close();
    }

    fn enable_raw_mode(self: *Self) !void {
        var raw = self.original_termios;

        raw.iflag.BRKINT = false;
        raw.iflag.ICRNL = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.IXON = false;

        raw.oflag.OPOST = false;

        raw.cflag.CSIZE = .CS8;

        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.IEXTEN = false;
        raw.lflag.ISIG = false;

        raw.cc[@intFromEnum(posix.V.MIN)] = 0;
        raw.cc[@intFromEnum(posix.V.TIME)] = 1;

        try posix.tcsetattr(self.tty.handle, .FLUSH, raw);
    }

    fn update_size(self: *Self) !void {
        var wsz: posix.winsize = undefined;
        const rc = posix.system.ioctl(self.tty.handle, posix.T.IOCGWINSZ, @intFromPtr(&wsz));
        if (rc == 0) {
            self.width = wsz.col;
            self.height = wsz.row;
        }
    }

    pub fn refresh_size(self: *Self) !void {
        try self.update_size();
    }

    fn enter_alt_screen(self: *Self) !void {
        try self.write_all("\x1b[?1049h");
    }

    fn leave_alt_screen(self: *Self) !void {
        try self.write_all("\x1b[?1049l");
    }

    fn hide_cursor(self: *Self) !void {
        try self.write_all("\x1b[?25l");
    }

    fn show_cursor(self: *Self) !void {
        try self.write_all("\x1b[?25h");
    }

    pub fn clear(self: *Self) !void {
        try self.write_all("\x1b[2J\x1b[H");
    }

    pub fn move_cursor(self: *Self, x: u16, y: u16) !void {
        var buf: [32]u8 = undefined;
        const seq = std.fmt.bufPrint(&buf, "\x1b[{};{}H", .{ y + 1, x + 1 }) catch return;
        try self.write_all(seq);
    }

    pub fn write_all(self: *Self, data: []const u8) !void {
        try self.tty.writeAll(data);
    }

    pub fn read_key(self: *Self) !?Key {
        var buf: [16]u8 = undefined;
        const n = self.tty.read(&buf) catch |err| {
            if (err == error.WouldBlock) return null;
            return err;
        };
        if (n == 0) return null;

        return parse_key(buf[0..n]);
    }

    fn parse_key(buf: []const u8) Key {
        if (buf.len == 0) return .{ .char = 0 };

        if (buf[0] == '\x1b') {
            if (buf.len == 1) return .escape;
            if (buf.len >= 3 and buf[1] == '[') {
                return switch (buf[2]) {
                    'A' => .arrow_up,
                    'B' => .arrow_down,
                    'C' => .arrow_right,
                    'D' => .arrow_left,
                    'H' => .home,
                    'F' => .end,
                    '3' => if (buf.len >= 4 and buf[3] == '~') .delete else .{ .char = buf[0] },
                    '5' => if (buf.len >= 4 and buf[3] == '~') .page_up else .{ .char = buf[0] },
                    '6' => if (buf.len >= 4 and buf[3] == '~') .page_down else .{ .char = buf[0] },
                    else => .{ .char = buf[0] },
                };
            }
            if (buf.len >= 2) {
                return .{ .alt = buf[1] };
            }
        }

        if (buf[0] == 127 or buf[0] == 8) {
            return .backspace;
        }

        if (buf[0] == 13 or buf[0] == 10) {
            return .enter;
        }

        if (buf[0] == 9) {
            return .tab;
        }

        if (buf[0] < 32) {
            return switch (buf[0]) {
                0 => .{ .ctrl = ' ' },
                1...26 => |c| .{ .ctrl = 'a' + c - 1 },
                27 => .escape,
                28...31 => |c| .{ .ctrl = '4' + c - 28 },
                else => .{ .char = buf[0] },
            };
        }

        return .{ .char = buf[0] };
    }
};

pub const Key = union(enum) {
    char: u8,
    ctrl: u8,
    alt: u8,
    escape,
    arrow_up,
    arrow_down,
    arrow_left,
    arrow_right,
    home,
    end,
    delete,
    page_up,
    page_down,
    enter,
    tab,
    backspace,

    pub fn is_ctrl(self: Key, c: u8) bool {
        return switch (self) {
            .ctrl => |ctrl_char| ctrl_char == c,
            else => false,
        };
    }
};
