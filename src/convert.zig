// SPDX-License-Identifier: GPL-3.0-or-later
// brainfuck2dir: brainfuck source as directory trees.
//
//! The pipeline: brainfuck source in, json2dir-scheme JSON out.
//! Compiles the embedded b2d.bf once per process and runs it over the
//! input with the brainfuck interpreter.

const std = @import("std");
const bfi = @import("bfi.zig");

pub const b2d_bf = @embedFile("b2d.bf");

/// Convert brainfuck source into the json2dir JSON scheme.
/// The result is a single line of JSON owned by `gpa`.
///
/// Structural validation (brackets, depth, NUL bytes) is the caller's
/// job; b2d.bf relies on it.
pub fn transpile(gpa: std.mem.Allocator, input: []const u8) ![]u8 {
    var prog = try bfi.compile(gpa, b2d_bf);
    defer prog.deinit(gpa);

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    try bfi.run(prog, input, &aw.writer);

    return try gpa.dupe(u8, aw.written());
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

fn expectConverts(src: []const u8, want: []const u8) !void {
    const got = try transpile(testing.allocator, src);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

test "golden: ++[->+<]." {
    try expectConverts(
        "++[->+<].",
        "{\"001+\": \"002\",\"002loop\": {\"001-\": \"001\",\"002>\": \"001\",\"003+\": \"001\",\"004<\": \"001\"},\"003.\": \"001\"}",
    );
}

test "golden: single ." {
    try expectConverts(".", "{\"001.\": \"001\"}");
}

test "golden: empty input" {
    try expectConverts("", "{}");
}

test "golden: comments ignored" {
    try expectConverts(
        "foo + bar [baz qux -] the end",
        "{\"001+\": \"001\",\"002loop\": {\"001-\": \"001\"}}",
    );
}

test "golden: nested empty loops" {
    try expectConverts("[[]]", "{\"001loop\": {\"001loop\": {}}}");
}

test "golden: run cap at 999 splits the entry" {
    // 1000 '+' -> "999" + "1"
    const src = "+" ** 1000;
    try expectConverts(src, "{\"001+\": \"999\",\"002+\": \"001\"}");
}

test "golden: every command is run-length encoded" {
    try expectConverts(
        "+-<>.,",
        "{\"001+\": \"001\",\"002-\": \"001\",\"003<\": \"001\",\"004>\": \"001\",\"005.\": \"001\",\"006,\": \"001\"}",
    );
}
