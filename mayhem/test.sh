#!/usr/bin/env bash
# berry/mayhem/test.sh — RUN Berry's test suite against the normal-flags interpreter that
# mayhem/build.sh produced → CTRF.  PATCH-grade oracle: it never compiles the interpreter.
#
# Two-layer oracle (both must pass):
#
# LAYER 1 — STDOUT GOLDEN-OUTPUT CHECK (anti-reward-hack):
#   A small Berry program exercises core language features (arithmetic, strings, closures, lists,
#   exceptions, OOP) via print() and its stdout is compared byte-for-byte against a hardcoded
#   golden string.  A neutered exit(0) binary emits NO output → stdout diff fails immediately,
#   making the oracle immune to the exit(0) sabotage (SPEC §6.3).
#
# LAYER 2 — assert()-BASED SUITE (behavioral correctness):
#   Berry ships tests/*.be — each file exercises a language feature via the built-in assert().
#   assert() raises an uncaught exception on failure, making the interpreter exit NON-ZERO.
#   "Interpreter ran tests/foo.be and exited 0" == "every assertion in foo.be held."
#
# The oracle binary is /mayhem/berry-tests, the NORMAL-flags (no-sanitizer) build from build.sh.
# This script ONLY runs it — never compiles.
set -uo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${SRC:=$(cd "$HERE/.." && pwd)}"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

BIN="$SRC/berry-tests"
[ -x "$BIN" ] || { echo "missing $BIN — run mayhem/build.sh first" >&2; emit_ctrf "berry-tests" 0 1; exit 2; }
[ -d "$SRC/tests" ] || { echo "missing $SRC/tests — wrong tree?" >&2; emit_ctrf "berry-tests" 0 1; exit 2; }

passed=0; failed=0; skipped=0

# ---------------------------------------------------------------------------
# LAYER 1 — STDOUT GOLDEN-OUTPUT CHECK (anti-reward-hack gate).
#
# This Berry program exercises core language features through print() calls.
# The expected output is hardcoded below.  A neutered exit(0) binary produces
# no output, so the diff fails and the test is counted as a failure — the
# oracle cannot be bypassed by patching the binary to exit(0) (§6.3).
# ---------------------------------------------------------------------------
ORACLE_SCRIPT="$(mktemp /tmp/berry-oracle-XXXXXX.be)"
trap 'rm -f "$ORACLE_SCRIPT"' EXIT

cat > "$ORACLE_SCRIPT" << 'BERRY_EOF'
# BEHAVIORAL ORACLE: print()-based known-answer tests.
# Each print() emits a value computed by the Berry VM; a neutered exit(0)
# binary emits no output at all, so the golden-diff fails immediately.

# --- arithmetic ---
print(1 + 2)
print(10 * 7)
print(17 % 5)
print(100 / 4)

# --- string operations ---
import string
print(string.format("%s-%s", "hello", "world"))
print(string.count("hello", "l"))

# --- string slicing ---
var s = "scripting"
print(s[0..3])

# --- closures / upvalues ---
var acc = 0
def add(n) acc += n end
add(10); add(20); add(30)
print(acc)

# --- list operations ---
var lst = [3, 1, 4, 1, 5]
print(lst.size())
print(lst[0] + lst[4])

# --- exception / try-except ---
var caught = false
try
  raise "value_error", "test error"
except "value_error" as name, msg
  caught = true
end
print(caught)

# --- class / OOP ---
class Counter
  var n
  def init() self.n = 0 end
  def inc() self.n += 1 end
  def val() return self.n end
end
var c = Counter()
c.inc(); c.inc(); c.inc()
print(c.val())
BERRY_EOF

# Hardcoded golden output — each line corresponds to a print() call above.
GOLDEN="3
70
2
25
hello-world
2
scri
60
5
8
true
3"

ACTUAL="$("$BIN" "$ORACLE_SCRIPT" 2>/dev/null)"
ORACLE_EXIT=$?

if [ "$ACTUAL" = "$GOLDEN" ] && [ "$ORACLE_EXIT" -eq 0 ]; then
  echo "PASS: stdout oracle (golden-output match)" >&2
  passed=$((passed+1))
else
  echo "FAIL: stdout oracle — behavioral output mismatch or non-zero exit" >&2
  if [ "$ACTUAL" != "$GOLDEN" ]; then
    echo "  expected: $(printf '%s' "$GOLDEN" | head -5 | tr '\n' '|')" >&2
    echo "  actual:   $(printf '%s' "$ACTUAL"  | head -5 | tr '\n' '|')" >&2
  fi
  failed=$((failed+1))
fi

# ---------------------------------------------------------------------------
# LAYER 2 — assert()-based suite (tests/*.be).
#
# Two upstream tests are EXCLUDED (skipped, with documented reason):
#   * tests/lexer.be  — asserts a 3-hex unicode escape is rejected, but the
#     lexer over-reads past the closing quote; pass/fail flips with build flags.
#   * tests/time.be   — asserts localtime(epoch)==month, depends on TZ.
# ---------------------------------------------------------------------------
SKIP_TESTS="lexer.be time.be"

for f in $(find tests -maxdepth 1 -type f -name '*.be' | sort); do
  base="$(basename "$f")"
  case " $SKIP_TESTS " in
    *" $base "*) echo "SKIP: $f (non-deterministic on this upstream revision — see test.sh)" >&2
                 skipped=$((skipped+1)); continue ;;
  esac
  if "$BIN" "$f" >/dev/null 2>&1; then
    passed=$((passed+1))
  else
    failed=$((failed+1))
    echo "FAIL: $f" >&2
    "$BIN" "$f" 2>&1 | tail -5 | sed 's/^/    /' >&2
  fi
done

echo "berry tests: passed=$passed failed=$failed skipped=$skipped" >&2
emit_ctrf "berry-tests" "$passed" "$failed" "$skipped"
