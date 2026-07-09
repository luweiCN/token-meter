#!/usr/bin/env bash
#
# reconcile-with-ccusage.sh — is our token accounting still correct?
#
# Scans the real local-agent corpora into a THROWAWAY SQLite database, sums
# usage_events.tokens_total per provider, and compares each provider against an
# independent implementation (ccusage). Prints our number, ccusage's number, the
# absolute delta, and the relative delta for every source, then exits non-zero if
# any source violates its per-source criterion.
#
# The reconciliation this repeats already paid for itself once: running it by hand
# during Tasks 14c–14h surfaced five real correctness fixes (codex archived dir,
# codex double-written token_count rows, ...). This script exists so the NEXT change
# can't quietly break the numbers without anyone noticing. It is meant to be run as a
# check, not just read as a report.
#
# ---------------------------------------------------------------------------------
# WHAT THIS SCRIPT CANNOT DO — read before trusting its headline number.
# ---------------------------------------------------------------------------------
# It validates the FULL-SCAN path only. It CANNOT catch the class of bug fixed in
# UsageEventWriter: a streamed response's frames all live in one file and land in one
# parse batch, so the in-memory UsageEventDeduplicator collapses them and the writer's
# own dedupe branch never fires. That bug produced a PERFECT full-scan total while
# silently truncating usage on every INCREMENTAL refresh. A green run here says nothing
# about the incremental path.
#
# The incremental path is guarded elsewhere, by a Swift test:
#   LocalAgentScannerTests.testIncrementalScanReplacesAPartialStreamedFrameWithTheFinalOne
# If that test is gone, this script's headline number means much less than it appears to.
# This script refuses to run unless that test is present in the tree.
#
# ---------------------------------------------------------------------------------
# THREE DISCIPLINES, each learned the hard way. They are load-bearing, not decoration.
# ---------------------------------------------------------------------------------
# 1. SAMPLE BOTH SIDES AT THE SAME MOMENT. The Claude corpus is live — the user (and, when
#    this runs from inside an agent session, the agent ITSELF) writes to it continuously, so
#    demanding a frozen corpus would mean it could never be reconciled. Instead: read
#    ccusage, run the scan, read ccusage AGAIN. The scan happened BETWEEN those two reads, so
#    our scanned total must fall INSIDE [before, after] (widened by the per-source tolerance).
#    Growth is thereby explicitly accounted for and never misread as a delta. A static corpus
#    makes before == after and the interval collapses to exact equality — one rule, no
#    live/static branch to keep in sync. Only a corpus that SHRANK is unexplained: that aborts.
#    (History: a fresh scan was once compared against a ccusage number captured hours earlier,
#    and the corpus growth in between was misread as a bug. Bracketing the scan with two fresh
#    reads is exactly what prevents that.)
#
# 2. NEVER WRITE THE USER'S DATA. ~/.claude/, ~/.codex/, ~/.omp/ are read-only here; we
#    only enumerate and read their .jsonl files. opencode.db is the sharp edge: the
#    Swift scanner opens it via SQLiteDatabase, which is SQLITE_OPEN_READWRITE|CREATE
#    (verified in Sources/TokenMeterCore/SQLiteDatabase.swift) — pointing the scanner at
#    the real file would open it for writing. So we do NOT scan the real DB at all: we
#    take a read-only, immutable snapshot of it (file:...?mode=ro&immutable=1) into the
#    temp dir and scan the COPY. As a belt-and-suspenders check, we record the real DB's
#    md5 before the run and re-verify it is unchanged at exit.
#
# 3. SCAN INTO mktemp -d, NEVER THE PRODUCTION DATABASE. The app's real database lives at
#    ~/.token-meter/tokenmeter.sqlite; this script never touches it. Everything — the temp
#    reconciliation DB, the opencode.db snapshot, the throwaway Swift driver — is created
#    under a mktemp -d and removed on exit, including on failure, via a trap.
#
# ---------------------------------------------------------------------------------
# ASSERT THE RELATIONSHIP, NEVER A CONSTANT.
# ---------------------------------------------------------------------------------
# Every absolute total is a snapshot that rots within hours (18,455,520,473 became
# 18,455,910,425 in one afternoon while the delta stayed exactly 0). This script asserts
# the RELATIONSHIP between our scan and the ccusage reads that bracket it (see discipline 1),
# never a literal total. Every source uses the SAME rule — our total ∈ [before, after] — and
# differs only in the tolerance added on each side:
#   codex     — tolerance 0. We match ccusage to the digit, so no slack is warranted. When
#               codex is idle, before == after and the interval collapses to a point: exact
#               equality. When it is not (the user may be running codex right now — a real run
#               showed it growing by 198,873 mid-scan), the interval still holds our number to
#               the exact window the scan observed. Do NOT relax this to a percentage: any
#               drift beyond the observed window is a real defect.
#   claude    — live corpus. Interval widened by 0.01% of the after-reading on each side —
#               enough to cover the ~50k residual claude drift on top of the corpus growth
#               during the scan.
#   opencode  — we scan a FROZEN read-only snapshot while ccusage reads the live DB, so its
#               two readings can move, and even SHRINK (it rewrites sessions); the interval is
#               therefore min/max-ordered and widened by 0.01%. We also deliberately fold ALL
#               `reasoning` into outputTokens (spec §4.3.1: 716 events have output < reasoning,
#               so reasoning is NOT a subset of output here); ccusage counts only part of it,
#               giving a small POSITIVE delta that sits well inside the slack. Printed
#               prominently, never hidden.
#   omp       — ccusage has no omp support: print our number, assert nothing.
#
# The numbers depend on the ccusage version, so `ccusage --version` is printed. A
# reconciliation without a version stamp is not reproducible.
#
# Usage:  scripts/reconcile-with-ccusage.sh
# Exit:   0 = all sources within criteria; non-zero = a source is off, or the run aborted
#             (drift / md5 mismatch / missing corpus / missing incremental guard).

set -euo pipefail

# --- relative-delta threshold, expressed for integer arithmetic --------------------
# 0.01% == 1/10000, so "|delta| / ccusage < 0.01%" is exactly "|delta| * 10000 < ccusage".
# Kept in pure 64-bit integer math (ccusage ~1e10, *1e4 ~1e14, well under 9.2e18) so the
# pass/fail decision never depends on floating point. The percentage is only *displayed*
# via awk.
readonly THRESHOLD_DEN=10000   # 1/10000 = 0.01%

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# --- corpus locations (must match TokenMeterPaths.defaultScanRoots) -----------------
readonly CLAUDE_ROOT="$HOME/.claude/projects"
readonly CODEX_ROOT="$HOME/.codex/sessions"
readonly CODEX_ARCHIVED_ROOT="$HOME/.codex/archived_sessions"
readonly OMP_ROOT="$HOME/.omp/agent/sessions"
readonly OPENCODE_DB="$HOME/.local/share/opencode/opencode.db"

# --- trap state (initialised before the trap can fire) ------------------------------
WORK=""
OPENCODE_MD5_BEFORE=""

cleanup() {
  local rc=$?
  # Discipline 2, verified at exit: the real opencode.db must be byte-identical to how
  # we found it. If it changed, something opened it for writing — fail loudly.
  if [ -n "$OPENCODE_MD5_BEFORE" ] && [ -f "$OPENCODE_DB" ]; then
    local after
    after="$(md5 -q "$OPENCODE_DB" 2>/dev/null || echo unreadable)"
    echo ""
    echo "opencode.db md5 before run: $OPENCODE_MD5_BEFORE"
    echo "opencode.db md5 after  run: $after"
    if [ "$after" != "$OPENCODE_MD5_BEFORE" ]; then
      echo "FATAL: opencode.db changed on disk during the run — user data was written. Aborting."
      rc=1
    fi
  fi
  if [ -n "$WORK" ] && [ -d "$WORK" ]; then
    rm -rf "$WORK"
  fi
  exit "$rc"
}
trap cleanup EXIT

die() { echo "ERROR: $*" >&2; exit 1; }

commafy() { awk 'BEGIN{n=ARGV[1]; s=(n<0)?"-":""; n=(n<0)?-n:n; x=sprintf("%d",n); r="";
  while(length(x)>3){r=","substr(x,length(x)-2)r; x=substr(x,1,length(x)-3)} print s x r}' "$1"; }

# sum(totalTokens) across all days ccusage reports for an agent, over the full time range.
ccusage_total() { ccusage "$1" daily --json 2>/dev/null | jq '[.daily[].totalTokens] | add // 0'; }

# our sum of usage_events.tokens_total for one provider_id, from the temp reconciliation DB.
our_total() {
  sqlite3 "$RECON_DB" \
    "SELECT COALESCE(SUM(e.tokens_total),0) FROM usage_events e
       JOIN agent_sessions s ON e.session_id = s.id
      WHERE s.provider_id = '$1';"
}

# -----------------------------------------------------------------------------------
# Preflight
# -----------------------------------------------------------------------------------
for tool in ccusage sqlite3 swift jq md5 awk; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool"
done

# Refuse to run if the incremental guard test is gone (see header). A green full-scan
# reconciliation on top of a missing incremental test is a false sense of security.
GUARD_TEST="testIncrementalScanReplacesAPartialStreamedFrameWithTheFinalOne"
grep -rq "$GUARD_TEST" "$REPO_ROOT/Tests" \
  || die "incremental guard test '$GUARD_TEST' not found under Tests/ — refusing to run (see header)."

[ -d "$CLAUDE_ROOT" ] || die "claude corpus not found: $CLAUDE_ROOT"
[ -d "$CODEX_ROOT" ]  || die "codex corpus not found: $CODEX_ROOT"
[ -f "$OPENCODE_DB" ] || die "opencode.db not found: $OPENCODE_DB"

echo "=== reconcile-with-ccusage ================================================"
echo "repo:            $REPO_ROOT"
echo "ccusage version: $(ccusage --version)"
echo "sqlite3 version: $(sqlite3 --version | awk '{print $1}')"
echo "date:            $(date '+%Y-%m-%d %H:%M:%S %z')"
echo "==========================================================================="

WORK="$(mktemp -d "${TMPDIR:-/tmp}/reconcile-ccusage.XXXXXX")"
# Not readonly: it is re-exported as an inline env var to the scan driver below, which a
# readonly shell variable would refuse.
RECON_DB="$WORK/reconcile.sqlite"
readonly OPENCODE_COPY="$WORK/opencode-snapshot.db"

OPENCODE_MD5_BEFORE="$(md5 -q "$OPENCODE_DB")"

# -----------------------------------------------------------------------------------
# Discipline 1, first sample: read ccusage for all three supported agents BEFORE scanning.
# The opencode read is taken immediately before the snapshot, so it is co-temporal with
# the frozen copy we actually scan.
# -----------------------------------------------------------------------------------
echo "[1/5] sampling ccusage (before scan)..."
CLAUDE_CCUSAGE_1="$(ccusage_total claude)"
CODEX_CCUSAGE_1="$(ccusage_total codex)"
OPENCODE_CCUSAGE_1="$(ccusage_total opencode)"

# -----------------------------------------------------------------------------------
# Discipline 2: snapshot opencode.db read-only + immutable, then scan the copy — never
# the live file (the scanner opens its source READWRITE).
# -----------------------------------------------------------------------------------
echo "[2/5] snapshotting opencode.db (read-only, immutable)..."
sqlite3 "file:${OPENCODE_DB}?mode=ro&immutable=1" ".backup '${OPENCODE_COPY}'"

# -----------------------------------------------------------------------------------
# Discipline 3: build a throwaway Swift driver that scans the real corpora into the temp
# DB. It is a separate SwiftPM package with a path dependency on this repo, generated in
# $WORK and never committed; it only migrates a temp DB, seeds scan_roots, and calls the
# real LocalAgentScanner — no scan logic is reimplemented here (that would risk sharing a
# blind spot with the code under test).
# -----------------------------------------------------------------------------------
echo "[3/5] scanning corpora into throwaway DB (release build, may take a few minutes)..."
mkdir -p "$WORK/driver/Sources/recon"

cat > "$WORK/driver/Package.swift" <<PKG
// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "recon",
    platforms: [.macOS(.v13)],
    dependencies: [.package(path: "${REPO_ROOT}")],
    targets: [
        .executableTarget(
            name: "recon",
            dependencies: [.product(name: "TokenMeterCore", package: "token-meter")]
        )
    ]
)
PKG

# The driver reads corpus paths from the environment, seeds one scan_root per source, and
# runs the production LocalAgentScanner against each. A root that finishes 'partial' (e.g.
# a live Claude file whose last line is still being written) is tolerated per-root, exactly
# as fullRescan() does — its complete events are already committed.
cat > "$WORK/driver/Sources/recon/Recon.swift" <<'SWIFT'
import Foundation
import TokenMeterCore

@main
struct Recon {
    struct Root { let id: Int64; let kind: String; let path: String; let name: String }

    static func main() async throws {
        let env = ProcessInfo.processInfo.environment
        func require(_ key: String) -> String {
            guard let value = env[key], !value.isEmpty else {
                FileHandle.standardError.write(Data("recon: missing env \(key)\n".utf8))
                exit(2)
            }
            return value
        }

        let database = try SQLiteDatabase(path: require("RECON_DB"))
        try TokenMeterDatabaseMigrator.migrate(database)

        var roots: [Root] = []
        func add(_ id: Int64, _ kind: String, _ envKey: String, _ name: String) {
            if let path = env[envKey], !path.isEmpty {
                roots.append(Root(id: id, kind: kind, path: path, name: name))
            }
        }
        add(1, "claude_jsonl", "RECON_CLAUDE", "Claude Code")
        add(2, "codex_jsonl", "RECON_CODEX", "Codex")
        add(3, "codex_jsonl", "RECON_CODEX_ARCHIVED", "Codex (Archived)")
        add(4, "omp_jsonl", "RECON_OMP", "OMP")
        add(5, "opencode_sqlite", "RECON_OPENCODE_COPY", "OpenCode")

        for root in roots {
            try database.execute(
                "INSERT INTO scan_roots(id, kind, root_path, display_name, stable_source_key) VALUES (?,?,?,?,?)",
                [.int(root.id), .text(root.kind), .text(root.path), .text(root.name),
                 .text("\(root.kind):\(root.path)")]
            )
        }

        let scanner = LocalAgentScanner(database: database)
        for root in roots {
            do {
                try await scanner.scanRoot(id: root.id)
            } catch {
                // Tolerate a partial root (its complete events are already committed) and
                // keep going, so one in-progress file can't sink the whole reconciliation.
                FileHandle.standardError.write(Data("recon: root \(root.name) finished partial: \(error)\n".utf8))
            }
        }
        try database.close()
    }
}
SWIFT

CODEX_ARCHIVED_ARG=""
[ -d "$CODEX_ARCHIVED_ROOT" ] && CODEX_ARCHIVED_ARG="$CODEX_ARCHIVED_ROOT"
OMP_ARG=""
[ -d "$OMP_ROOT" ] && OMP_ARG="$OMP_ROOT"

RECON_CLAUDE="$CLAUDE_ROOT"
RECON_CODEX="$CODEX_ROOT"
RECON_CODEX_ARCHIVED="$CODEX_ARCHIVED_ARG"
RECON_OMP="$OMP_ARG"
RECON_OPENCODE_COPY="$OPENCODE_COPY"
export RECON_DB RECON_CLAUDE RECON_CODEX RECON_CODEX_ARCHIVED RECON_OMP RECON_OPENCODE_COPY

swift run --package-path "$WORK/driver" -c release recon > "$WORK/driver.log" 2>&1 \
  || { echo "--- driver output (tail) ---"; tail -40 "$WORK/driver.log"; die "scan driver failed"; }

# -----------------------------------------------------------------------------------
# Discipline 1, second sample: read ccusage again AFTER the scan. Together with the first
# sample this brackets the scan, so our scanned total must fall within [before, after]
# (widened per source, checked in report() below). A corpus that SHRANK is unexplained.
# -----------------------------------------------------------------------------------
echo "[4/5] sampling ccusage (after scan)..."
CLAUDE_CCUSAGE_2="$(ccusage_total claude)"
CODEX_CCUSAGE_2="$(ccusage_total codex)"
# opencode too: we scan a frozen snapshot, but ccusage reads the live database, so its
# reading can move for the same reason the Claude one does.
OPENCODE_CCUSAGE_2="$(ccusage_total opencode)"

# Demanding a frozen corpus is too strong: the user runs Claude Code, so ~/.claude grows
# continuously and the script could never reconcile it. What actually holds is weaker and
# always true — the scan happened BETWEEN the two ccusage samples, so our number must land
# inside [before, after] (widened by the threshold on each side).
#
# A static corpus makes before == after and the interval collapses to a point, i.e. exact
# equality. One rule serves both cases; there is no live/static branch to keep in sync.
#
# Only a corpus that SHRANK is unexplainable, and that is checked below.
if [ "$CLAUDE_CCUSAGE_2" -lt "$CLAUDE_CCUSAGE_1" ]; then
  echo "ABORT: the Claude corpus shrank during the run" \
       "(ccusage before=$CLAUDE_CCUSAGE_1, after=$CLAUDE_CCUSAGE_2)."
  echo "Growth is expected; shrinkage means files were deleted or rewritten. Investigate."
  exit 3
fi
if [ "$CODEX_CCUSAGE_2" -lt "$CODEX_CCUSAGE_1" ]; then
  echo "ABORT: the codex corpus shrank during the run" \
       "(ccusage before=$CODEX_CCUSAGE_1, after=$CODEX_CCUSAGE_2)."
  exit 3
fi

claude_growth=$(( CLAUDE_CCUSAGE_2 - CLAUDE_CCUSAGE_1 ))
codex_growth=$(( CODEX_CCUSAGE_2 - CODEX_CCUSAGE_1 ))
echo "corpus growth during the run: claude=$(commafy "$claude_growth")  codex=$(commafy "$codex_growth")"

# -----------------------------------------------------------------------------------
# Compare + assert.
# -----------------------------------------------------------------------------------
echo "[5/5] comparing..."
CLAUDE_OURS="$(our_total claude-code)"
CODEX_OURS="$(our_total codex)"
OPENCODE_OURS="$(our_total opencode)"
OMP_OURS="$(our_total omp)"

FAIL=0

# Prints one source line and decides pass/fail.
#   $1 label  $2 ours  $3 ccusage_before  $4 ccusage_after  $5 mode(interval|slack|none)
#
# The scan ran BETWEEN the two ccusage samples, so our number must land inside
# [before, after]. That is the whole rule. A static corpus has before == after and the
# interval collapses to a point — exact equality — with no separate code path.
#
#   interval : tolerance 0. For corpora nothing should be writing to.
#   slack    : widen each end by 0.01% of `after`. For sources where we knowingly differ
#              from ccusage (see the opencode note in the header).
#   none     : print only; ccusage has no support for this source.
report() {
  local label="$1" ours="$2" before="$3" after="$4" mode="$5"
  local delta=$(( ours - after ))
  local pct="n/a"
  [ "$after" -gt 0 ] && pct="$(awk -v d="$delta" -v c="$after" 'BEGIN{printf "%+.6f%%", (d/c)*100}')"

  printf '  %-10s ours=%18s  ccusage=%18s  delta=%+15s  rel=%s\n' \
    "$label" "$(commafy "$ours")" "$(commafy "$after")" "$(commafy "$delta")" "$pct"

  # `delta` and `rel` above are measured against the AFTER reading, which is the number a
  # reader will instinctively compare to. But the pass/fail decision is the interval test,
  # so when the corpus moved, print the interval too — otherwise a PASS with rel > 0.01%
  # looks like a bug in the script rather than growth during the scan.
  if [ "$mode" != none ] && [ "$before" -ne "$after" ]; then
    printf '  %-10s   ccusage moved by %s during the scan; the decision is "ours ∈ interval", not this delta\n' \
      "" "$(commafy $(( after - before )))"
  fi

  [ "$mode" = none ] && return 0

  local tol=0
  [ "$mode" = slack ] && tol=$(( after / THRESHOLD_DEN ))

  # min/max, not before/after: opencode's live database can shrink (it rewrites sessions),
  # and an interval built as [before, after] would be empty in that case and fail spuriously.
  local lo=$before hi=$after
  [ "$before" -gt "$after" ] && { lo=$after; hi=$before; }
  lo=$(( lo - tol )); hi=$(( hi + tol ))

  if [ "$ours" -lt "$lo" ] || [ "$ours" -gt "$hi" ]; then
    echo "    -> FAIL: outside [$(commafy "$lo"), $(commafy "$hi")]" \
         "(ccusage moved by $(commafy $(( after - before ))) during the run; tolerance $(commafy "$tol"))"
    FAIL=1
  fi
}

echo ""
echo "source     our tokens_total          ccusage sum(totalTokens)         delta        rel"
echo "---------------------------------------------------------------------------------------"
report "codex"    "$CODEX_OURS"    "$CODEX_CCUSAGE_1"    "$CODEX_CCUSAGE_2"    interval
report "claude"   "$CLAUDE_OURS"   "$CLAUDE_CCUSAGE_1"   "$CLAUDE_CCUSAGE_2"   slack

# opencode: we fold ALL reasoning into output because 716 events have output < reasoning,
# which disproves the subset relation (spec §4.3.1). ccusage counts only part of it, so a
# small positive delta is expected and correct. `slack` lets it through; surface it loudly
# rather than hiding it, because a CHANGE in this delta means one side moved.
echo ""
echo "  opencode (expected small positive delta — we fold all reasoning into output, spec §4.3.1):"
report "opencode" "$OPENCODE_OURS" "$OPENCODE_CCUSAGE_1" "$OPENCODE_CCUSAGE_2" slack

# omp: ccusage has no omp support — report our number, assert nothing.
echo ""
printf '  %-10s ours=%18s  (ccusage has no omp support — nothing to assert)\n' \
  "omp" "$(commafy "$OMP_OURS")"

echo ""
if [ "$FAIL" -ne 0 ]; then
  echo "RESULT: FAIL — at least one source is outside its criterion."
  exit 1
fi
echo "RESULT: PASS — every source is within its criterion."
exit 0
