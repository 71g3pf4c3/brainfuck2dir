#!/usr/bin/env python3
"""gen_b2d.py -- brainfuck macro assembler + b2d program generator.

Generates src/b2d.bf: a brainfuck program that reads brainfuck source
on stdin and emits the json2dir conversion scheme as single-line JSON:

  run of n x command c  ->  "NNNc": "00M"     (sequence no. NNN, count M)
  [...]                 ->  "NNNloop": { ... }

Everything below the command level is brainfuck; this file only emits it.

Tape layout (cells):
    0        in   -- current input byte (0 == EOF)
    1        d    -- dispatch scratch (in - K test cell)
    2        x    -- copy temp / in - cur delta
    3        cur  -- command char being run-length encoded (0 == none)
    4..6     run  -- run count, three ASCII digits (hundreds tens ones)
    7        b    -- handle_cmd flag / subtraction temp
    8        fz   -- dispatch "will fire" flag
    9..12    active frame: seq digits (h t o) + first flag
    13..59   scratch pool; every cell is 0 outside a macro (invariant)
    60       eof  -- main loop flag
    61       p    -- output staging cell
    62       guard -- always 0; left walks stop here
    63       sentinel -- always 1; separates frames from the rest
    64..     frame stack: one 4-cell slot per open '[':
             [seq_h seq_t seq_o first_enc]

The nesting level is a runtime quantity, so generated code may not bake
it into addresses. Instead the active frame lives at fixed cells and
open/close PUSH/POP it to/from a stack of 4-cell slots. Slot cells are
always nonzero (digits 48..57, first encoded as 2/3), everything past
the stack top is zero, so:

  walk right from 64:  [>]   stops at the first free slot
  walk left to 62:     [<]   walks home through slots + sentinel

Conventions:
  * every macro is position-transparent: the tape pointer is back
    where it started when the macro returns (the assembler tracks it
    symbolically and emits the necessary moves);
  * every scratch cell is zeroed on release;
  * loops are balanced by construction.
"""

from __future__ import annotations

import sys
from contextlib import contextmanager

# --- tape addresses ---------------------------------------------------------

IN, D, X, CUR = 0, 1, 2, 3
RUN_H, RUN_T, RUN_O = 4, 5, 6
B = 7                       # handle_cmd flag / subtraction temp
FZ = 8                      # dispatch "will fire" flag
ACT_H, ACT_T, ACT_O, ACT_F = 9, 10, 11, 12
SCRATCH_LO, SCRATCH_HI = 13, 59              # inclusive
EOF, P, GUARD, SENTINEL = 60, 61, 62, 63
FRAMES = 64
TAPE_SIZE = 30000

# interpreter limits mirrored by the wrapper (src/main.zig)
MAX_LEVEL = 7400
MAX_ENTRIES = 999
MAX_RUN = 999

COMMANDS = "+-<>.,"


class Asm:
    """Brainfuck macro assembler with symbolic pointer tracking.

    self.pos is the compile-time pointer position; None means "at a
    runtime-dependent address" (inside push/pop). Only relative steps
    and walks may be emitted while pos is None, and it must be brought
    back to a known cell (GUARD) before any go().
    """

    def __init__(self) -> None:
        self.buf: list[str] = []
        self.pos: int | None = 0
        self.free = list(range(SCRATCH_LO, SCRATCH_HI + 1))
        self.loops = 0

    # -- plumbing --------------------------------------------------------

    def emit(self, code: str) -> None:
        assert set(code) <= set("+-<>.,[]"), f"bad opcodes: {code!r}"
        for c in code:
            if c == "[":
                self.loops += 1
            elif c == "]":
                self.loops -= 1
                assert self.loops >= 0, "unbalanced ]"
        self.buf.append(code)

    def go(self, target: int) -> None:
        assert self.pos is not None, "go() from a runtime position"
        if target > self.pos:
            self.emit(">" * (target - self.pos))
        elif target < self.pos:
            self.emit("<" * (self.pos - target))
        self.pos = target

    def step(self, n: int) -> None:
        """Relative move; allowed from runtime positions."""
        if n > 0:
            self.emit(">" * n)
        elif n < 0:
            self.emit("<" * -n)
        if self.pos is not None:
            self.pos += n

    def at_runtime(self) -> None:
        self.pos = None

    def at_guard(self) -> None:
        # a [<] walk has just stopped on GUARD
        self.pos = GUARD

    @contextmanager
    def scratch(self):
        """Acquire a zeroed scratch cell; release it zeroed."""
        cell = self.free.pop()
        assert self.pos is not None
        try:
            yield cell
        finally:
            self.zero(cell)
            self.free.append(cell)

    def result(self) -> str:
        assert self.loops == 0, "unbalanced ["
        return "".join(self.buf)

    # -- primitive macros --------------------------------------------------

    def zero(self, c: int) -> None:
        self.go(c)
        self.emit("[-]")

    def move(self, src: int, dst: int) -> None:
        """dst += src; src = 0."""
        self.go(src)
        self.emit("[-")
        self.go(dst)
        self.emit("+")
        self.go(src)
        self.emit("]")

    def copy(self, src: int, dst: int) -> None:
        """dst += src (dst must be 0); src preserved."""
        with self.scratch() as t:
            self.split(src, dst, t)

    def split(self, src: int, dst: int, tmp: int) -> None:
        """dst += src (dst must be 0); src preserved; tmp must be 0."""
        self.move(src, tmp)
        self.go(tmp)
        self.emit("[-")
        self.go(src)
        self.emit("+")
        self.go(dst)
        self.emit("+")
        self.go(tmp)
        self.emit("]")

    def add_const(self, c: int, k: int) -> None:
        self.go(c)
        self.emit("+" * k)

    def sub_const(self, c: int, k: int) -> None:
        self.go(c)
        self.emit("-" * k)

    def readc(self, c: int) -> None:
        self.go(c)
        self.emit(",")

    # -- control flow -------------------------------------------------------

    def while_nz(self, c: int, body) -> None:
        self.go(c)
        self.emit("[")
        body()
        self.go(c)
        self.emit("]")

    def if_nz(self, v: int, body) -> None:
        """Run body once iff v != 0. v is preserved."""
        with self.scratch() as u, self.scratch() as t:
            self.move(v, t)
            # v = t; u = t; t = 0
            self.go(t)
            self.emit("[-")
            self.go(v)
            self.emit("+")
            self.go(u)
            self.emit("+")
            self.go(t)
            self.emit("]")
            # t = 1 if u != 0; u = 0
            self.go(u)
            self.emit("[-[-]")
            self.go(t)
            self.emit("+")
            self.go(u)
            self.emit("]")
            # one-shot guard
            self.go(t)
            self.emit("[-")
            body()
            self.go(t)
            self.emit("]")

    def if_z(self, v: int, body) -> None:
        """Run body once iff v == 0. v is preserved."""
        with self.scratch() as b:
            self.add_const(b, 1)
            self.if_nz(v, lambda: self.zero(b))
            self.if_nz(b, body)

    def if_eq(self, c: int, k: int, body) -> None:
        """Run body once iff c == k (byte value). c is preserved."""
        with self.scratch() as t:
            self.copy(c, t)
            self.sub_const(t, k)
            self.if_z(t, body)

    def guard_nz(self, c: int, body) -> None:
        """DESTRUCTIVE single-shot: run body once iff c != 0; c ends 0.

        The loop body executes at most once (c is cleared on entry),
        so the cost is O(body), not O(c). The body must not touch c.
        """
        self.go(c)
        self.emit("[")
        self.emit("-")
        self.emit("[-]")
        body()
        self.go(c)
        self.emit("]")

    # -- arithmetic / io -----------------------------------------------------

    def sub(self, a: int, b: int) -> None:
        """a -= b (mod 256); b preserved; a may wrap."""
        with self.scratch() as t:
            self.copy(b, t)
            self.go(t)
            self.emit("[-")
            self.go(a)
            self.emit("-")
            self.go(t)
            self.emit("]")

    def incr3(self, h: int, t: int, o: int) -> None:
        """Increment a 3-digit ASCII decimal counter (h t o)."""
        self.add_const(o, 1)
        # ':' (58) wraps to '0' and carries
        self.if_eq(o, 58, lambda: (self.sub_const(o, 10), self.add_const(t, 1)))
        self.if_eq(t, 58, lambda: (self.sub_const(t, 10), self.add_const(h, 1)))

    def set3(self, h: int, t: int, o: int, digits: str) -> None:
        assert len(digits) == 3
        for cell, ch in ((h, digits[0]), (t, digits[1]), (o, digits[2])):
            self.zero(cell)
            self.add_const(cell, ord(ch))

    def puts(self, s: str) -> None:
        for ch in s:
            self.add_const(P, ord(ch))
            self.go(P)
            self.emit(".")
            self.emit("[-]")

    def put(self, c: int) -> None:
        """Output the byte stored in c; c preserved."""
        with self.scratch() as t:
            self.copy(c, t)
            self.move(t, P)
            self.go(P)
            self.emit(".")
            self.emit("[-]")


# --- frame stack --------------------------------------------------------------


class B2D(Asm):
    """The b2d program on top of the assembler."""

    def init_active(self) -> None:
        """Fresh frame: seq 000, no entries yet."""
        self.set3(ACT_H, ACT_T, ACT_O, "000")
        self.zero(ACT_F)
        self.add_const(ACT_F, 2)  # 2 = no entries yet, 1 = entries emitted

    def push_frame(self) -> None:
        """Active frame -> next free stack slot; caller re-inits active."""
        # encode first: 1/2 -> 2/3 (slot cells must be nonzero)
        self.add_const(ACT_F, 1)
        # walk to the first free slot (first zero cell past the slots)
        self.go(FRAMES)
        self.emit("[>]")
        self.at_runtime()
        # prefill the slot with ones so [<] can walk home from inside it
        self.emit("+>+>+>+")  # Z..Z+3 = 1, ends at Z+3
        self.emit("[<]")
        self.at_guard()
        # transfer active -> slot, one unit per iteration; the prefill is
        # compensated by pre-decrementing each source cell
        for i, src in enumerate((ACT_H, ACT_T, ACT_O, ACT_F)):
            self.sub_const(src, 1)
            self.go(src)
            self.emit("[")
            self.go(FRAMES)
            self.emit("[>]")
            self.at_runtime()
            self.step(i - 4)  # walk stopped at Z+4; step back to Z+i
            self.emit("+")
            self.emit("[<]")
            self.at_guard()
            self.go(src)
            self.emit("-")
            self.emit("]")
        # active cells are zero now

    def pop_frame(self) -> None:
        """Top stack slot -> active frame; slot is zeroed."""
        for c in (ACT_H, ACT_T, ACT_O, ACT_F):
            self.zero(c)
        # walk to the first zero past the slots, then onto the slot
        self.go(FRAMES)
        self.emit("[>]")
        self.at_runtime()
        self.step(-4)  # S_0
        for i, dst in enumerate((ACT_H, ACT_T, ACT_O, ACT_F)):
            self.emit("[")
            # -> 62: the first [<] stops at S_{i-1} (or 62 for i=0);
            # i steps left cross the emptied cells onto the nearest
            # nonzero cell (slot below / sentinel), the second [<]
            # walks home
            self.emit("[<]")
            self.at_runtime()
            self.emit("<" * i)
            self.emit("[<]")
            self.at_guard()
            self.go(dst)
            self.emit("+")
            self.go(FRAMES)
            self.emit("[>]")
            self.at_runtime()
            # first zero from 64: Z for i=0 (S_0 still nonzero mid-body),
            # S_0 for i>=1 (already emptied)
            if i == 0:
                self.step(-4)  # Z -> S_0
            else:
                self.step(i)  # S_0 -> S_i
            self.emit("-")
            self.emit("]")
            if i < 3:
                self.emit(">")
        # pointer at S_3 (zero); walk home
        self.at_runtime()
        self.step(-4)  # last cell of the slot below, or the sentinel
        self.emit("[<]")
        self.at_guard()
        # decode first: 2/3 -> 1/2
        self.sub_const(ACT_F, 1)

    # -- entries ---------------------------------------------------------

    def entry_head(self) -> None:
        """"NNN prefix: comma if needed, quote, sequence number."""
        self.if_eq(ACT_F, 1, lambda: self.puts(","))  # 1 = entries emitted
        self.zero(ACT_F)
        self.add_const(ACT_F, 1)
        self.puts('"')
        self.incr3(ACT_H, ACT_T, ACT_O)
        self.put(ACT_H)
        self.put(ACT_T)
        self.put(ACT_O)

    def emit_entry(self) -> None:
        self.entry_head()
        self.put(CUR)
        self.puts('": "')
        self.put(RUN_H)
        self.put(RUN_T)
        self.put(RUN_O)
        self.puts('"')

    def flush(self) -> None:
        self.if_nz(CUR, self.emit_entry)
        self.zero(CUR)

    def reset_run(self) -> None:
        self.set3(RUN_H, RUN_T, RUN_O, "001")

    # -- commands ---------------------------------------------------------

    def handle_cmd(self) -> None:
        # x = in - cur (mod 256); x == 0 iff the run continues
        self.split(IN, X, D)
        self.split(CUR, B, D)
        self.go(B)
        self.emit("[-")
        self.go(X)
        self.emit("-")
        self.go(B)
        self.emit("]")
        # b = 1; if x != 0 -> new_run, b = 0; if b (x was 0) -> same_run
        self.add_const(B, 1)
        self.guard_nz(X, lambda: (self.new_run(), self.zero(B)))
        self.guard_nz(B, self.same_run)

    def same_run(self) -> None:
        self.incr3(RUN_H, RUN_T, RUN_O)
        self.cap_run()

    def new_run(self) -> None:
        self.flush()
        self.copy(IN, CUR)  # CUR is 0 after flush
        self.reset_run()

    def cap_run(self) -> None:
        # run hit 999: emit it now. flush() also zeroes cur, so the
        # next char of the same command correctly starts a fresh run
        # via new_run (x = c - 0 != 0) -- no phantom +1
        self.if_eq(
            RUN_H,
            ord("9"),
            lambda: self.if_eq(
                RUN_T,
                ord("9"),
                lambda: self.if_eq(RUN_O, ord("9"), self.flush),
            ),
        )

    # -- brackets ---------------------------------------------------------

    def open_loop(self) -> None:
        self.flush()
        self.entry_head()
        self.puts('loop": {')
        self.push_frame()
        self.init_active()

    def close_loop(self) -> None:
        self.flush()
        self.puts("}")
        self.pop_frame()

    def dispatch(self) -> None:
        # fast path: d = in - K; body iff d == 0 (via the fz flag
        # dance, since guard_nz fires on nonzero) -- O(1) per
        # comparison instead of O(in) boolean-conversion chains
        cases = [("[", self.open_loop), ("]", self.close_loop)]
        cases += [(c, self.handle_cmd) for c in COMMANDS]
        for ch, body in cases:
            self.split(IN, D, X)
            self.sub_const(D, ord(ch))
            self.add_const(FZ, 1)
            self.guard_nz(D, lambda: self.zero(FZ))
            self.guard_nz(FZ, body)

    # -- program -----------------------------------------------------------

    def main_body(self) -> None:
        self.readc(IN)
        self.split(IN, D, X)  # d = in; in preserved for the dispatch cases
        # dispatch if in != 0. The guard clears d before running the
        # body and every dispatch case leaves d at 0, so the guard
        # loop exits after one pass.
        self.guard_nz(D, self.dispatch)
        # eof: if in == 0, drop the loop flag. in is dead afterwards --
        # the next readc overwrites it.
        self.add_const(X, 1)
        self.guard_nz(IN, lambda: self.zero(X))
        self.guard_nz(X, lambda: self.zero(EOF))

    def program(self) -> str:
        # prologue
        self.add_const(SENTINEL, 1)
        self.puts("{")
        self.init_active()

        # main loop
        self.add_const(EOF, 1)
        self.while_nz(EOF, self.main_body)

        # epilogue
        self.flush()
        self.puts("}")
        return self.result()


def gen() -> str:
    return B2D().program()


if __name__ == "__main__":
    sys.stdout.write(gen())
