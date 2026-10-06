b2d(1) "brainfuck2dir" "General Commands Manual"

# NAME

b2d - materialize brainfuck source as a directory tree

# SYNOPSIS

*b2d* [_OPTIONS_] [_FILE_]

# DESCRIPTION

Reads brainfuck source (from _FILE_, or standard input when _FILE_ is absent
or *-*) and converts it into a directory tree. Non-command bytes are
comments. The conversion scheme:

```
run of n of command c  ->  file "NNNc" with the count as contents
[ ... ]                ->  directory "NNNloop"
```

NNN is the zero-padded three-digit sequence number of the entry within its
parent; a run's count is likewise zero-padded to three digits. Runs longer
than 999 are split into consecutive entries. Without *--out* the same
information is printed as single-line JSON in the json2dir scheme, which
pipes straight into *json2dir*(1).

The conversion logic is itself a brainfuck program (b2d.bf, about 98KB of
generated *+* *-* *<* *>* *.* *,* *[* *]*), executed by a built-in
interpreter. The binary is the VM, the CLI and the materializer; the
thinking happens in brainfuck. The generator, tools/gen_b2d.py, is checked
in, and a flake check verifies that src/b2d.bf is exactly its output.

Input is validated before the interpreter runs: NUL bytes (0 is the
brainfuck EOF marker on the tape), unbalanced brackets, nesting deeper than
7400 loops and more than 999 entries per nesting level are rejected.

Files are written under a temporary name and *rename*(2)d into place; a
run interrupted mid-tree never leaves a truncated file behind. A
pre-existing symlink at an entry path is replaced, never followed.

# OPTIONS

*-o*, *--out* _DIR_
	Materialize into _DIR_ instead of printing JSON. _DIR_ is created
	if missing.

*-n*, *--dry-run*
	Validate and print the plan; write nothing. Only meaningful with
	*--out*.

*-v*, *--verbose*
	Print one line per entry while applying.

*--no-clobber*
	Fail instead of replacing existing entries.

*-h*, *--help*
	Print usage and exit.

*-V*, *--version*
	Print version and exit.

# EXIT STATUS

0
	Success.
1
	Usage error.
2
	Invalid brainfuck source.
3
	Filesystem error.

# EXAMPLES

Transpile to JSON:

```
$ b2d hello.bf
{"001+": "008","002loop": {...}, ...}
```

Materialize, then reconstruct the original source by walking the tree in
order (find | sort) and concatenating file names and contents:

```
$ b2d -o tree hello.bf
$ find tree -type f | sort
```

Round-trip the JSON through json2dir(1) instead:

```
$ b2d hello.bf | json2dir -o tree
```

# SEE ALSO

*json2dir*(1)
