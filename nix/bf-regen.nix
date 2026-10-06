{
  lib,
  stdenv,
  python3,
}:

# Guard: src/b2d.bf must be exactly what tools/gen_b2d.py emits.
# If this check fails, run:
#   python3 tools/gen_b2d.py > src/b2d.bf
# and commit the result.
stdenv.mkDerivation {
  pname = "brainfuck2dir-bf-regen-check";
  version = "0.1.0";

  src = ./..;

  nativeBuildInputs = [ python3 ];

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild

    python3 tools/gen_b2d.py > "$TMPDIR/b2d.bf"
    if ! cmp -s "$TMPDIR/b2d.bf" src/b2d.bf; then
      echo "src/b2d.bf is out of date:" >&2
      diff <(head -c 200 "$TMPDIR/b2d.bf") <(head -c 200 src/b2d.bf) >&2 || true
      echo "regenerate with: python3 tools/gen_b2d.py > src/b2d.bf" >&2
      exit 1
    fi

    runHook postBuild
  '';

  installPhase = ''
    touch "$out"
  '';

  meta = {
    description = "Check that src/b2d.bf matches tools/gen_b2d.py";
    platforms = lib.platforms.unix;
  };
}
