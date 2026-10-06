{
  lib,
  runCommand,
  brainfuck2dir,
}:

runCommand "brainfuck2dir-smoke-test"
  {
    meta = {
      description = "Functional smoke test for brainfuck2dir";
      platforms = lib.platforms.unix;
    };
  }
  ''
    set -euo pipefail
    cd "$(mktemp -d)"

    exe="${lib.getExe brainfuck2dir}"

    # the classic: 106 chars of hello world
    cat > hello.bf <<'EOF'
    ++++++++[>++++[>++>+++>+++>+<<<<-]>+>+>->>+[<]<-]>>.>---.+++++++..+++.>>.<-.<.+++.------.--------.>>+.>++.
    EOF

    # 1. transpile: single-line json2dir-scheme JSON
    json="$($exe hello.bf)"
    case "$json" in
      '{"001+": "008","002loop": '*'}') ;;
      *) echo "FAIL: unexpected transpile output: $json" >&2; exit 1 ;;
    esac

    # 2. materialize from the source file: JSON scheme -> tree
    $exe -o out hello.bf >/dev/null
    test -d out/002loop/003loop
    test "$(cat out/001+)" = "008"
    test "$(cat out/002loop/002+)" = "004"

    # 3. stdin mode
    cat hello.bf | $exe -o out
    test "$(cat out/001+)" = "008"

    # 4. --dry-run prints the plan and writes nothing
    $exe -o empty hello.bf --dry-run > plan.txt
    test -z "$(ls -A empty 2>/dev/null || true)"
    grep -q '002loop' plan.txt

    # 5. --no-clobber refuses to replace
    if $exe -o out hello.bf --no-clobber 2>err.txt; then
      echo "FAIL: --no-clobber run unexpectedly succeeded" >&2
      exit 1
    fi
    grep -q -- '--no-clobber' err.txt

    # 6. invalid brainfuck exits 2: unbalanced bracket
    echo '][' > bad.bf
    set +e
    $exe -o x bad.bf 2>/dev/null
    rc=$?
    set -e
    test "$rc" -eq 2

    # 7. NUL bytes exit 2 (0 is the interpreter's EOF marker)
    printf 'a\0b' > nul.bf
    set +e
    $exe -o x nul.bf 2>/dev/null
    rc=$?
    set -e
    test "$rc" -eq 2

    # 8. empty input -> empty object -> empty tree
    : > empty.bf
    test "$($exe empty.bf)" = '{}'
    $exe -o e2 empty.bf
    test -z "$(ls -A e2)"

    # 9. usage error exits 1
    set +e
    $exe --wat 2>/dev/null
    rc=$?
    set -e
    test "$rc" -eq 1

    # 10. the 1000-run cap splits entries: 999 + 1
    # (coreutils only: 1000 '+', no trailing newline)
    printf '%0.s+' $(seq 1000) > k.bf
    test "$($exe k.bf)" = '{"001+": "999","002+": "001"}'

    touch "$out"
  ''
