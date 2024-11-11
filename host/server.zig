// HTTP server for the generated content

const std = @import("std");
const Site = @import("site.zig").Site;

pub fn start(site: *const Site, output_root: []const u8) !void {
    const loopback = try std.net.Ip4Address.parse("127.0.0.1", 0);
    const localhost = std.net.Address{ .in = loopback };
    var http_server = try localhost.listen(.{
        .reuse_port = true,
    });
    defer http_server.deinit();

    const addr = http_server.listen_address;
    const stdout = std.io.getStdOut().writer();
    const output_dir = try site.source_root.openDir(output_root, .{});
    try stdout.print("Listening on http://localhost:{}\n", .{addr.getPort()});

    // TODO: open browser

    var read_buffer: [8000]u8 = undefined;
    accept: while (true) {
        const connection = try http_server.accept();
        defer connection.stream.close();
        var server = std.http.Server.init(connection, &read_buffer);
        while (server.state == .ready) {
            var request = server.receiveHead() catch |err| {
                // TODO: maybe not log here? It's the client that's buggy:
                // https://ziglang.org/documentation/0.13.0/std/#std.http.Server.ReceiveHeadError
                // Or return an http error code.
                try stdout.print("Failed receiving request: {s}\n", .{@errorName(err)});
                continue :accept;
            };
            respond(site, &request, output_dir) catch |err| {
                try stdout.print("Failed responding to request: {s}\n", .{@errorName(err)});
                // TODO: considering crashing here - it indicates a bug.
                try request.respond("500 Internal Server Error", .{
                    .status = .internal_server_error,
                });
                continue :accept;
            };
        }
    }
}

pub fn respond(
    site: *const Site,
    request: *std.http.Server.Request,
    output_dir: std.fs.Dir,
) !void {
    const path = request.head.target;
    // TODO: perform this lookup more efficiently.
    const page = for (site.pages.items) |page| {
        // TODO: Return foo/index.html pages for a request to /
        if (std.mem.eql(u8, page.output_path, path)) break page;
    } else {
        // TODO: show a better 404 page.
        return request.respond("404 Not Found", .{ .status = .not_found });
    };

    const output_path_no_leading_slash = page.output_path[1..];

    // TODO: avoid file stat by storing file size upon generation.
    const len = (try output_dir.statFile(output_path_no_leading_slash)).size;

    var send_buffer: [8000]u8 = undefined;
    var response = request.respondStreaming(.{
        .send_buffer = &send_buffer,
        .content_length = len,
        .respond_options = .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "content-type", .value = @tagName(page.mime_type) },
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
