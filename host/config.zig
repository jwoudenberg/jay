// Configuration persisted between runs.

const std = @import("std");
const native_endian = @import("builtin").target.cpu.arch.endian();

const Config = struct {
    const config_file_name = "config";

    mutex: std.Thread.Mutex,
    config_dir: std.fs.Dir,

    // The version of the configuration file. As long as we only add new config
    // fields and don't change the order in which we persist these, we don't
    // need to increment this.
    config_file_version: u16 = 0,

    // Regular configuration values.
    last_used_file_server_port: u16 = 0,

    pub fn load(config_dir: std.fs.Dir) Config {
        var config = .{
            .mutex = std.Thread.Mutex{},
            .config_dir = config_dir,
        };
        from_file(&config) catch return config;
        return config;
    }

    fn from_file(config: *Config) !void {
        const file = try config.config_dir.openFile(config_file_name, .{ .mode = .read_only });
        defer file.close();
        var reader = file.reader();

        const file_version = try reader.readInt(u16, native_endian);
        if (config.config_file_version != file_version) return error.ConfigVersionMismatch;

        config.last_used_file_server_port = try reader.readInt(u16, native_endian);
    }

    pub fn save(config: *Config) !void {
        const file = try config.config_dir.createFile(config_file_name, .{ .truncate = true });
        defer file.close();
        var writer = file.writer();
        try writer.writeInt(u16, config.config_file_version, native_endian);
        try writer.writeInt(u16, config.last_used_file_server_port, native_endian);
    }
};

test Config {
    var tmpdir = std.testing.tmpDir(.{});
    defer tmpdir.cleanup();

    // Load when no config file exists returns default configuration values.
    var config = Config.load(tmpdir.dir);
    try std.testing.expectEqual(0, config.config_file_version);
    try std.testing.expectEqual(0, config.last_used_file_server_port);

    std.debug.print("--------\n", .{});
    // Save and load recovers previously written configuration.
    config.last_used_file_server_port = 8080;
    try config.save();
    config = Config.load(tmpdir.dir);
    try std.testing.expectEqual(8080, config.last_used_file_server_port);
}
