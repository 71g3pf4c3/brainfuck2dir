// SPDX-License-Identifier: GPL-3.0-or-later
// brainfuck2dir: brainfuck source as directory trees.
//
//! A brainfuck interpreter. In this project it exists to run exactly
//! one program -- the embedded src/b2d.bf -- so it is deliberately
//! minimal: strip to the eight commands, precompute the jump table,
//! run. No step limit: the only program it ever executes is ours, and
//! ours terminates (input is finite; every loop it enters counts
//! something down).
//!
//! Semantics (documented, matching the debug tooling and the b2d.bf
//! generator's assumptions):
//!   * only "+-<>.,[]" are commands; everything else is a comment;
//!   * 30000 u8 cells, both pointer and values wrap;
//!   * ',' at EOF stores 0 -- this is how the b2d program detects the
//!     end of input (and why NUL bytes in input are rejected upstream);
//!   * ',' never rewinds: input is a one-way cursor.

const std = @import("std");

pub const tape_size: usize = 30000;

pub const Error = error{UnbalancedBrackets, OutOfMemory};

fn isCommand(c: u8) bool {
    return switch (c) {
        '+', '-', '<', '>', '.', ',', '[', ']' => true,
        else => false,
    };
}

pub const Program = struct {
    /// The program reduced to the eight commands, valid up to `count`.
    commands: []u8,
    count: usize,
    /// commands[i] jumps to jump[i] on skip/continue, for i < count.
    jump: []u32,

    pub fn deinit(self: *Program, gpa: std.mem.Allocator) void {
        gpa.free(self.commands);
        gpa.free(self.jump);
    }
};

/// Strip `program` to the eight commands and precompute the bracket
/// jump table. The returned slices own their memory.
pub fn compile(gpa: std.mem.Allocator, program: []const u8) Error!Program {
    const commands = try gpa.alloc(u8, program.len);
    errdefer gpa.free(commands);
    var n: usize = 0;
    for (program) |c| {
        if (isCommand(c)) {
            commands[n] = c;
            n += 1;
        }
    }

    const jump = try gpa.alloc(u32, n);
    errdefer gpa.free(jump);
    var stack: std.ArrayListUnmanaged(u32) = .empty;
    defer stack.deinit(gpa);

    for (commands[0..n], 0..) |c, i| {
        switch (c) {
            '[' => try stack.append(gpa, @intCast(i)),
            ']' => {
                const open = stack.pop() orelse return error.UnbalancedBrackets;
                jump[open] = @intCast(i);
                jump[i] = open;
            },
            else => {},
        }
    }
    if (stack.items.len != 0) return error.UnbalancedBrackets;

    return .{ .commands = commands, .count = n, .jump = jump };
}

/// Run a compiled program against `input`, writing produced bytes to
/// `out`. The tape starts zeroed; cells wrap mod 256; the pointer
/// wraps mod tape_size; reading past the end of input stores 0.
pub fn run(prog: Program, input: []const u8, out: *std.Io.Writer) !void {
    const gpa = std.heap.page_allocator;
    const tape = try gpa.alloc(u8, tape_size);
    defer gpa.free(tape);
    @memset(tape, 0);

    const commands = prog.commands[0..prog.count];
    var p: usize = 0;
    var ip: usize = 0;
    var ic: usize = 0;

    while (ip < commands.len) : (ip += 1) {
        switch (commands[ip]) {
            '>' => p = (p + 1) % tape_size,
            '<' => p = (p + tape_size - 1) % tape_size,
            '+' => tape[p] +%= 1,
            '-' => tape[p] -%= 1,
            '.' => try out.writeByte(tape[p]),
            ',' => {
                if (ic < input.len) {
                    tape[p] = input[ic];
                    ic += 1;
                } else {
                    tape[p] = 0;
                }
            },
            '[' => if (tape[p] == 0) {
                ip = prog.jump[ip];
            },
            ']' => if (tape[p] != 0) {
                ip = prog.jump[ip];
            },
            else => unreachable,
        }
    }
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

fn expectRunsTo(src: []const u8, input: []const u8, want: []const u8) !void {
    var prog = try compile(testing.allocator, src);
    defer prog.deinit(testing.allocator);

    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try run(prog, input, &w);
    try testing.expectEqualStrings(w.buffered(), want);
}

test "hello world" {
    try expectRunsTo(
        "++++++++[>++++[>++>+++>+++>+<<<<-]>+>+>->>+[<]<-]>>.>---.+++++++..+++.>>.<-.<.+++.------.--------.>>+.>++.",
        "",
        "Hello World!\n",
    );
}

test "comments are ignored" {
    try expectRunsTo("foo + bar !", "", "");
}

test "EOF stores zero, input is a one-way cursor" {
    try expectRunsTo(",.,.,.", "A", "A\x00\x00");
}

test "pointer and value wrap" {
    // 0-1 = 255; walking left off the tape wraps to the last cell,
    // which the '+' below proves by printing 1 from there
    try expectRunsTo("-.<+.", "", "\xff\x01");
}

test "unbalanced brackets fail to compile" {
    try testing.expectError(error.UnbalancedBrackets, compile(testing.allocator, "[[]"));
    try testing.expectError(error.UnbalancedBrackets, compile(testing.allocator, "[]]"));
}
