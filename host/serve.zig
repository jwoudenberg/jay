// Run a file server to allow the site to be previewed in the browser

const builtin = @import("builtin");
const std = @import("std");
const Site = @import("site.zig").Site;

pub fn serve(site: *const Site) !void {
    const loopback = try std.net.Ip4Address.parse("127.0.0.1", 0);
    const localhost = std.net.Address{ .in = loopback };
    var http_server = try localhost.listen(.{
        .reuse_port = true,
    });
    defer http_server.deinit();

    const addr = http_server.listen_address;
    const stdout = std.io.getStdOut().writer();
    var source_root = try site.openSourceRoot(.{});
    defer source_root.close();
    const output_dir = try source_root.openDir(site.output_root, .{});
    var buffer: ["http://localhost:00000".len]u8 = undefined;
    const url = try std.fmt.bufPrint(&buffer, "http://localhost:{}", .{addr.getPort()});
    try stdout.print("Listening on {s}\n", .{url});

    open(url) catch |err| {
        try stdout.print("Failed to open browser: {s}\n", .{@errorName(err)});
    };

    var request_buffer: [8000]u8 = undefined;
    accept: while (true) {
        const connection = try http_server.accept();
        defer connection.stream.close();
        var server = std.http.Server.init(connection, &request_buffer);
        while (server.state == .ready) {
            var request = server.receiveHead() catch |err| {
                // https://ziglang.org/documentation/0.13.0/std/#std.http.Server.ReceiveHeadError
                try stdout.print("Failed receiving request: {s}\n", .{@errorName(err)});
                continue :accept;
            };
            try respond(site, &request, output_dir);
        }
    }
}

fn respond(
    site: *const Site,
    request: *std.http.Server.Request,
    output_dir: std.fs.Dir,
) !void {
    if (site.web_paths.get(request.head.target)) |index| {
        const page = site.pages.at(@intFromEnum(index));
        return servePage(page, .ok, request, output_dir);
    } else if (site.web_paths.get("/404")) |index| {
        const page = site.pages.at(@intFromEnum(index));
        return servePage(page, .not_found, request, output_dir);
    } else {
        return request.respond("404 Not Found", .{ .status = .not_found });
    }
}

fn servePage(
    page: *const Site.Page,
    status: std.http.Status,
    request: *std.http.Server.Request,
    output_dir: std.fs.Dir,
) !void {
    const output_path_no_leading_slash = page.output_path[1..];

    var send_buffer: [8000]u8 = undefined;
    var response = request.respondStreaming(.{
        .send_buffer = &send_buffer,
        .content_length = page.output_len orelse return error.OutputLenUnset,
        .respond_options = .{
            .status = status,
            .extra_headers = &.{
                .{ .name = "content-type", .value = @tagName(page.mime_type) },
                .{ .name = "cache-control", .value = "max-age=0, must-revalidate" },
            },
        },
    });

    var fifo_buffer: [8000]u8 = undefined;
    var fifo = std.fifo.LinearFifo(u8, .Slice).init(&fifo_buffer);
    defer fifo.deinit();

    const file = try output_dir.openFile(output_path_no_leading_slash, .{});
    defer file.close();
    try fifo.pump(file.reader(), response.writer());

    try response.end();
}

fn open(resource: []const u8) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const open_command = switch (builtin.os.tag) {
        .linux => "xdg-open",
        .macos => "open",
        .windows => "open",
        else => return error.UnsupportedOs,
    };
    var child = std.process.Child.init(&.{ open_command, resource }, gpa.allocator());
    child.stdin_behavior = .Close;
    child.stdout_behavior = .Close;
    child.stderr_behavior = .Close;
    _ = try child.spawnAndWait();
}

// This code is starting out as an adapted version of andrewrk/StaticHTPPFileServer.
// The original sourcecode and license are found below.
//
// https://github.com/andrewrk/StaticHttpFileServer
//
// ---
//
// The MIT License (Expat)
//
// Copyright (c) contributors
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.
