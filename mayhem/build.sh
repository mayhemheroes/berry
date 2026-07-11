#!/usr/bin/env bash
# berry/mayhem/build.sh — build the Berry script-language interpreter as the fuzz target, plus a
# clean normal-flags build of the same interpreter for Berry's own assert-based test suite
# (mayhem/test.sh).
#
# Berry (berry-lang/berry) is a small embeddable dynamically-typed scripting language: a one-pass
# bytecode compiler + register-based VM written in ANSI C99. The whole language core is src/*.c; the
# CLI driver default/berry.c loads a .be source file, compiles it, and runs it. The Mayhem target is
# FILE-INPUT (CLI): the fuzz bytes are handed to /mayhem/berry as a .be source file, exercising the
# entire lexer -> one-pass compiler -> VM pipeline. There is NO libFuzzer harness — the interpreter
# binary IS the natural fuzz surface (like the lacc / my_basic file-input templates), so it is also
# its own single-input reproducer (no *-standalone needed).
#
# Build notes:
#   * The upstream Makefile force-links GNU readline (-DUSE_READLINE_LIB, -lreadline -ldl) for the
#     INTERACTIVE REPL only. The fuzz/test targets run a SCRIPT FILE (berry <file.be>), which never
#     touches readline, so we compile WITHOUT -DUSE_READLINE_LIB and drop -lreadline/-ldl. This keeps
#     the build self-contained (no readline dev package needed) and the fuzz surface identical for
#     file input.
#   * A prebuild step generates Berry's constant-string/object tables (generate/be_const_*.h) from the
#     sources via tools/coc/coc (a Python3 script). We run it once; both builds share the generated
#     headers.
#
# Two builds from the same sources:
#   (1) SANITIZED build -> /mayhem/berry        (the fuzz target; ASan+UBSan halting, by default)
#   (2) NORMAL-flags build -> /mayhem/berry-tests (honest oracle for test.sh; no sanitizer noise)
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs from the base ENV, overridable. SANITIZER_FLAGS uses `=` (not `:=`) so an explicit
# empty value (--build-arg SANITIZER_FLAGS=) is honored → no-sanitizer build (the interpreter's
# natural crash). Berry links only -lm (libc math), present without the sanitizer runtime, so the
# empty-sanitizer build links cleanly.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g}"
# DEBUG_FLAGS: force DWARF ≤ 3 so Mayhem's triage can read symbols (clang-19 plain -g emits DWARF-5).
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC MAYHEM_JOBS

cd "$SRC"

# Berry is C99; -pedantic-errors in the upstream Makefile is fine but we keep warnings quiet (-w) so a
# clean build stays silent. The interpreter reads its compile-time config from default/berry_conf.h.
# NOTE: we deliberately do NOT define USE_READLINE_LIB. default/berry.c gates readline on
# `#if defined(USE_READLINE_LIB)` (presence, not value — so -DUSE_READLINE_LIB=0 would STILL pull in
# <readline/readline.h>). Leaving the macro undefined compiles the REPL fallback (fgets) instead, so
# the interpreter needs no readline dev headers/lib. The file-input fuzz/test target runs a script
# file and never enters the REPL, so this does not change the fuzz surface.
INCLUDE="-Isrc -Idefault -Igenerate"
BASE_CFLAGS="-std=c99 -w"

# ---------------------------------------------------------------------------
# Prebuild: generate the constant tables (generate/be_const_*.h). tools/coc/coc parses the sources
# and the config header and emits the const-object tables the VM links against. Required before any
# compile; both builds reuse the output.
# ---------------------------------------------------------------------------
rm -rf generate; mkdir -p generate
python3 tools/coc/coc -o generate src default -c default/berry_conf.h
echo "build.sh: generated const tables in $SRC/generate"

# The interpreter sources: the language core (src/) + the default platform/CLI layer (default/).
SRCS=()
for d in src default; do
  for f in "$d"/*.c; do SRCS+=("$f"); done
done

# ---------------------------------------------------------------------------
# (1) FUZZ build — the WHOLE interpreter compiled WITH $SANITIZER_FLAGS so the fuzzed code (lexer,
#     one-pass compiler, VM, runtime libs) is instrumented (ASan+UBSan, halting, by default). The
#     file-input Mayhem target lands at /mayhem/berry.
#
#     NOTE: Berry's sanitized build does NOT flood under halting UBSan — every seed runs to exit 0
#     with no sanitizer output — so NO benign-UB relaxation is needed (unlike lacc/my_basic). ASan +
#     full UBSan stay ON and HALTING so real defects in the compiler/VM crash the fuzz target.
#
#     ASan leak detection is disabled IN-BINARY via a STRONG __asan_default_options (NOT an
#     ASAN_OPTIONS env var, and NOT a weak symbol — per the porting guidance for GC'd interpreters:
#     Berry is garbage-collected and an input that aborts/exits mid-run can leave the GC heap
#     unreclaimed, which LeakSanitizer would report as a (benign, input-shaped) "leak" and mask real
#     crashes. detect_leaks=0 keeps ASan's use-after-free/overflow detection (the real oracle) while
#     suppressing exit-time leak noise. The symbol is compiled into the fuzz binary only.)
# ---------------------------------------------------------------------------
cat > /tmp/berry-asan-opts.c <<'EOF'
/* Strong override so ASan does not run LeakSanitizer at exit (see build.sh rationale). */
const char *__asan_default_options(void) { return "detect_leaks=0"; }
EOF

rm -rf /tmp/berry-fuzz-obj; mkdir -p /tmp/berry-fuzz-obj
fuzz_objs=()
for f in "${SRCS[@]}"; do
  o="/tmp/berry-fuzz-obj/$(echo "$f" | tr '/' '_').o"
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS $BASE_CFLAGS -O1 $INCLUDE -c "$f" -o "$o"
  fuzz_objs+=("$o")
done
# Only link the __asan_default_options override when ASan is actually in the flags (so the empty
# off-switch build stays a plain build with no extra object).
asan_opt_obj=()
if printf '%s' "$SANITIZER_FLAGS" | grep -q address; then
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS $BASE_CFLAGS -O1 -c /tmp/berry-asan-opts.c -o /tmp/berry-asan-opts.o
  asan_opt_obj=(/tmp/berry-asan-opts.o)
fi
$CC $SANITIZER_FLAGS $DEBUG_FLAGS "${fuzz_objs[@]}" "${asan_opt_obj[@]}" -lm -o /mayhem/berry
echo "build.sh: built /mayhem/berry (sanitized fuzz target)"

# ---------------------------------------------------------------------------
# (2) TEST-ORACLE build — the SAME sources with NORMAL flags (no sanitizer), for mayhem/test.sh's
#     assert-based suite. A clean, independent build so the oracle reflects real shipped behavior;
#     test.sh only RUNS this binary (it never compiles).
# ---------------------------------------------------------------------------
rm -rf /tmp/berry-test-obj; mkdir -p /tmp/berry-test-obj
test_objs=()
for f in "${SRCS[@]}"; do
  o="/tmp/berry-test-obj/$(echo "$f" | tr '/' '_').o"
  $CC $BASE_CFLAGS -O2 $INCLUDE -c "$f" -o "$o"
  test_objs+=("$o")
done
$CC "${test_objs[@]}" -lm -o /mayhem/berry-tests
echo "build.sh: built /mayhem/berry-tests (normal-flags test oracle)"

ls -l /mayhem/berry /mayhem/berry-tests
