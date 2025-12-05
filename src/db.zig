const std = @import("std");
const c = @cImport({
    @cInclude("mysql/mysql.h");
});

pub const Column = struct {
    name: []const u8,
    type_name: []const u8,
};

pub const Row = struct {
    values: []?[]const u8,
};

pub const ResultSet = struct {
    allocator: std.mem.Allocator,
    columns: []Column,
    rows: []Row,

    pub fn deinit(self: *ResultSet) void {
        for (self.columns) |col| {
            self.allocator.free(col.name);
            self.allocator.free(col.type_name);
        }
        self.allocator.free(self.columns);

        for (self.rows) |row| {
            for (row.values) |val| {
                if (val) |v| {
                    self.allocator.free(v);
                }
            }
            self.allocator.free(row.values);
        }
        self.allocator.free(self.rows);
    }
};

pub const Connection = struct {
    allocator: std.mem.Allocator,
    mysql: *c.MYSQL,

    const Self = @This();

    pub fn connect(
        allocator: std.mem.Allocator,
        host: [:0]const u8,
        port: u16,
        user: [:0]const u8,
        password: [:0]const u8,
        database: [:0]const u8,
    ) !Self {
        const mysql = c.mysql_init(null) orelse return error.InitFailed;
        errdefer c.mysql_close(mysql);

        const result = c.mysql_real_connect(
            mysql,
            host.ptr,
            user.ptr,
            password.ptr,
            database.ptr,
            port,
            null,
            0,
        );

        if (result == null) {
            return error.ConnectionFailed;
        }

        return Self{
            .allocator = allocator,
            .mysql = mysql,
        };
    }

    pub fn disconnect(self: *Self) void {
        c.mysql_close(self.mysql);
    }

    pub fn get_error(self: *Self) []const u8 {
        const err = c.mysql_error(self.mysql);
        return std.mem.span(err);
    }

    pub fn get_tables(self: *Self) ![][]const u8 {
        const res = c.mysql_list_tables(self.mysql, null);
        if (res == null) {
            return error.QueryFailed;
        }
        defer c.mysql_free_result(res);

        const num_rows = c.mysql_num_rows(res);
        var tables = try self.allocator.alloc([]const u8, @intCast(num_rows));
        var count: usize = 0;

        while (c.mysql_fetch_row(res)) |row| {
            const lengths = c.mysql_fetch_lengths(res);
            if (row[0]) |ptr| {
                const len: usize = @intCast(lengths[0]);
                const table_name = try self.allocator.alloc(u8, len);
                @memcpy(table_name, ptr[0..len]);
                tables[count] = table_name;
                count += 1;
            }
        }

        if (count < tables.len) {
            tables = try self.allocator.realloc(tables, count);
        }

        return tables;
    }

    pub fn free_tables(self: *Self, tables: [][]const u8) void {
        for (tables) |table| {
            self.allocator.free(table);
        }
        self.allocator.free(tables);
    }

    pub fn get_columns(self: *Self, table: []const u8) ![]Column {
        var query_buf: [256]u8 = undefined;
        const query = std.fmt.bufPrintZ(&query_buf, "DESCRIBE {s}", .{table}) catch return error.QueryTooLong;

        if (c.mysql_query(self.mysql, query.ptr) != 0) {
            return error.QueryFailed;
        }

        const res = c.mysql_store_result(self.mysql);
        if (res == null) {
            return error.QueryFailed;
        }
        defer c.mysql_free_result(res);

        const num_rows = c.mysql_num_rows(res);
        var columns = try self.allocator.alloc(Column, @intCast(num_rows));
        var count: usize = 0;

        while (c.mysql_fetch_row(res)) |row| {
            const lengths = c.mysql_fetch_lengths(res);

            var col = Column{
                .name = "",
                .type_name = "",
            };

            if (row[0]) |ptr| {
                const len: usize = @intCast(lengths[0]);
                const name = try self.allocator.alloc(u8, len);
                @memcpy(name, ptr[0..len]);
                col.name = name;
            }

            if (row[1]) |ptr| {
                const len: usize = @intCast(lengths[1]);
                const type_name = try self.allocator.alloc(u8, len);
                @memcpy(type_name, ptr[0..len]);
                col.type_name = type_name;
            }

            columns[count] = col;
            count += 1;
        }

        if (count < columns.len) {
            columns = try self.allocator.realloc(columns, count);
        }

        return columns;
    }

    pub fn free_columns(self: *Self, columns: []Column) void {
        for (columns) |col| {
            if (col.name.len > 0) self.allocator.free(col.name);
            if (col.type_name.len > 0) self.allocator.free(col.type_name);
        }
        self.allocator.free(columns);
    }

    pub fn execute(self: *Self, query: [:0]const u8) !ResultSet {
        if (c.mysql_query(self.mysql, query.ptr) != 0) {
            return error.QueryFailed;
        }

        const res = c.mysql_store_result(self.mysql);
        if (res == null) {
            const field_count = c.mysql_field_count(self.mysql);
            if (field_count == 0) {
                return ResultSet{
                    .allocator = self.allocator,
                    .columns = &[_]Column{},
                    .rows = &[_]Row{},
                };
            }
            return error.QueryFailed;
        }
        defer c.mysql_free_result(res);

        const num_fields = c.mysql_num_fields(res);
        const num_rows = c.mysql_num_rows(res);
        const fields = c.mysql_fetch_fields(res);

        var columns = try self.allocator.alloc(Column, @intCast(num_fields));
        for (0..@intCast(num_fields)) |i| {
            const field = fields[i];
            const name_len = field.name_length;
            const name = try self.allocator.alloc(u8, name_len);
            @memcpy(name, field.name[0..name_len]);

            columns[i] = Column{
                .name = name,
                .type_name = try self.allocator.dupe(u8, get_type_name(field.type)),
            };
        }

        var rows = try self.allocator.alloc(Row, @intCast(num_rows));
        var row_idx: usize = 0;

        while (c.mysql_fetch_row(res)) |row| {
            const lengths = c.mysql_fetch_lengths(res);
            var values = try self.allocator.alloc(?[]const u8, @intCast(num_fields));

            for (0..@intCast(num_fields)) |i| {
                if (row[i]) |ptr| {
                    const len: usize = @intCast(lengths[i]);
                    const val = try self.allocator.alloc(u8, len);
                    @memcpy(val, ptr[0..len]);
                    values[i] = val;
                } else {
                    values[i] = null;
                }
            }

            rows[row_idx] = Row{ .values = values };
            row_idx += 1;
        }

        return ResultSet{
            .allocator = self.allocator,
            .columns = columns,
            .rows = rows,
        };
    }
};

fn get_type_name(field_type: c_uint) []const u8 {
    return switch (field_type) {
        c.MYSQL_TYPE_TINY => "TINYINT",
        c.MYSQL_TYPE_SHORT => "SMALLINT",
        c.MYSQL_TYPE_LONG => "INT",
        c.MYSQL_TYPE_LONGLONG => "BIGINT",
        c.MYSQL_TYPE_FLOAT => "FLOAT",
        c.MYSQL_TYPE_DOUBLE => "DOUBLE",
        c.MYSQL_TYPE_DECIMAL, c.MYSQL_TYPE_NEWDECIMAL => "DECIMAL",
        c.MYSQL_TYPE_STRING => "CHAR",
        c.MYSQL_TYPE_VAR_STRING => "VARCHAR",
        c.MYSQL_TYPE_BLOB, c.MYSQL_TYPE_TINY_BLOB, c.MYSQL_TYPE_MEDIUM_BLOB, c.MYSQL_TYPE_LONG_BLOB => "BLOB",
        c.MYSQL_TYPE_DATE => "DATE",
        c.MYSQL_TYPE_TIME => "TIME",
        c.MYSQL_TYPE_DATETIME => "DATETIME",
        c.MYSQL_TYPE_TIMESTAMP => "TIMESTAMP",
        c.MYSQL_TYPE_NULL => "NULL",
        else => "UNKNOWN",
    };
}
