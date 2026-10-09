#!/usr/bin/env bash
#
# GROMACS-RAMD 2026.4 functional test suite
#
# Usage:
#   ./run_ramd_tests.sh [--quick|--full] [--keep] [--test NAME] [--prefix DIR] [--src DIR]
#
# Options:
#   --quick         Only run fast tests (default)
#   --full          Also run the heavy multi-group GlyR test
#   --keep          Keep per-test working directories for inspection
#   --test NAME     Run only the named test (repeatable). Use --list to see names.
#   --list          List test names and exit
#   --prefix DIR    GROMACS installation prefix (default /opt/gromacs-2026.4-ramd)
#   --gmx PATH      Use this gmx binary directly (skips GMXRC sourcing); useful
#                   for CTest / build-tree runs. GMXDATA/GMXLIB must be set by
#                   the caller in that case.
#   --src DIR       Path to the migrated source tree (for test data)
#
# Notes:
#   * RAMD output (-ramd) is an OPTIONAL file option and is only written when
#     mdrun is explicitly given "-ramd" (with or without a filename). This
#     mirrors the reference behaviour; the tests always pass it explicitly.
#   * All mdrun calls force CPU execution (-nb cpu -pme cpu) for reproducibility.

set -u

# ----------------------------------------------------------------------------
# Configuration / argument parsing
# ----------------------------------------------------------------------------
GMXPREFIX_DEFAULT="/opt/gromacs-2026.4-ramd"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRCROOT_DEFAULT="$(cd "$SCRIPT_DIR/.." && pwd)"
GMXPREFIX="${GMXPREFIX:-$GMXPREFIX_DEFAULT}"
SRCROOT="${SRCROOT:-$SRCROOT_DEFAULT}"
GMX_OVERRIDE="${GMX:-}"
MODE="quick"
KEEP=0
SELECTED=()

while [ $# -gt 0 ]; do
    case "$1" in
        --quick) MODE="quick" ;;
        --full)  MODE="full" ;;
        --keep)  KEEP=1 ;;
        --list)  MODE="list" ;;
        --test)  SELECTED+=("$2"); shift ;;
        --prefix) GMXPREFIX="$2"; shift ;;
        --gmx)   GMX_OVERRIDE="$2"; shift ;;
        --src)   SRCROOT="$2"; shift ;;
        -h|--help)
            sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

GMXRC="$GMXPREFIX/bin/GMXRC.bash"
GMX="$GMXPREFIX/bin/gmx"
DB="$SRCROOT/src/testutils/simulationdatabase"
RAMDDATA="$SRCROOT/src/gromacs/ramd/tests/data/1WDHI"
WORKROOT="${WORKROOT:-$(mktemp -d /tmp/ramd-tests.XXXXXX)}"

ALL_TESTS=(version mdp_parse ramd_basic ramd_output_optin multigroup2 \
           connected_ligands restart_append old_angle_dist nonramd_control \
           reprod glyr_multigroup5)

if [ "$MODE" = "list" ]; then
    printf '%s\n' "${ALL_TESTS[@]}"
    exit 0
fi

# ----------------------------------------------------------------------------
# Preflight
# ----------------------------------------------------------------------------
if [ -n "$GMX_OVERRIDE" ]; then
    GMX="$GMX_OVERRIDE"
else
    if [ ! -f "$GMXRC" ]; then echo "ERROR: GMXRC not found at $GMXRC" >&2; exit 1; fi
    # shellcheck disable=SC1090
    source "$GMXRC" >/dev/null 2>&1
    GMX="$GMXPREFIX/bin/gmx"
fi
if [ ! -x "$GMX" ]; then echo "ERROR: gmx not found at $GMX" >&2; exit 1; fi
if [ ! -d "$DB" ]; then echo "ERROR: simulation database not found at $DB" >&2; exit 1; fi

# ----------------------------------------------------------------------------
# Result tracking
# ----------------------------------------------------------------------------
PASS=0; FAIL=0; SKIP=0
declare -a RESULTS=()

log()   { printf '  %s\n' "$*"; }
head1() { printf '\n=================================================================\n'; printf '== %s\n' "$*"; printf '=================================================================\n'; }

tname=""; tdir=""
begin() {
    tname="$1"; tdir="$WORKROOT/$tname"; rm -rf "$tdir"; mkdir -p "$tdir"
    head1 "TEST: $tname"
}
record() { RESULTS+=("$1|$2|$3"); }

ok()   { log "PASS: $*"; }
skip() { log "SKIP: $*"; record "$tname" "SKIP" "$*"; SKIP=$((SKIP+1)); }
done_pass() { ok "$*"; record "$tname" "PASS" "$*"; PASS=$((PASS+1)); }
done_fail() { log "FAIL: $*"; record "$tname" "FAIL" "$*"; FAIL=$((FAIL+1)); }

assert_eq() {  # assert_eq EXPECTED ACTUAL MESSAGE
    if [ "$1" = "$2" ]; then ok "$3 ($2)"; else log "MISMATCH $3: expected '$1' got '$2'"; return 1; fi
}
assert_file() { if [ -f "$1" ]; then ok "file exists: $1"; else log "missing file: $1"; return 1; fi; }
assert_contains() { if grep -qE -- "$2" "$1"; then ok "found '$2' in $(basename "$1")"; else log "'$2' not found in $1"; return 1; fi; }

MD_CPU=(-nb cpu -pme cpu)
run_grompp() { gmx grompp "$@" ; }   # relies on sourced GMXRC alias/path
# Use the absolute binary to avoid shell function/alias surprises
GG() { "$GMX" grompp -po /dev/null "$@"; }
MM() { "$GMX" mdrun "${MD_CPU[@]}" "$@"; }

should_run() {
    [ ${#SELECTED[@]} -eq 0 ] && return 0
    local t; for t in "${SELECTED[@]}"; do [ "$t" = "$1" ] && return 0; done
    return 1
}

# ----------------------------------------------------------------------------
# Reusable input generators
# ----------------------------------------------------------------------------

# 4water RAMD mdp. $1=nsteps $2=eval_freq $3=connected(yes/no) $4=old_angle(yes/no)
gen_water4_mdp() {
    local nsteps="${1:-20}" freq="${2:-10}" conn="${3:-no}" oldang="${4:-no}"
    cat > "$tdir/water4.mdp" <<EOF
integrator               = md
dt                       = 0.001
nsteps                   = $nsteps
nstlog                   = 10
nstenergy                = 10
rlist                    = 1.0
coulombtype              = Cut-off
rcoulomb-switch          = 0
rcoulomb                 = 1.0
epsilon-r                = 1
epsilon-rf               = 1
vdw-type                 = Cut-off
rvdw-switch              = 0
rvdw                     = 1.0
DispCorr                 = no
Tcoupl                   = no
Pcoupl                   = no
ramd                     = yes
ramd-seed                = 1234
ramd-eval-freq           = $freq
ramd-force-out-freq      = $freq
ramd-old-angle-dist      = $oldang
ramd-connected-ligands   = $conn
ramd-ngroups             = 2
ramd-group1-receptor     = 1SOL
ramd-group1-ligand       = 2SOL
ramd-group1-force        = 100
ramd-group1-max-dist     = 1.0
ramd-group1-r-min-dist   = 0.0025
ramd-group2-receptor     = 1SOL
ramd-group2-ligand       = 3SOL
ramd-group2-force        = 100
ramd-group2-max-dist     = 1.0
ramd-group2-r-min-dist   = 0.0025
EOF
}

# 1WDHI RAMD mdp. $1=nsteps
gen_1wdhi_mdp() {
    local nsteps="${1:-200}"
    cat > "$tdir/1wdhi.mdp" <<EOF
integrator               = md
dt                       = 0.002
nsteps                   = $nsteps
nstlog                   = 50
nstenergy                = 50
nstxout-compressed       = 50
continuation             = yes
constraints              = all-bonds
constraint-algorithm     = lincs
cutoff-scheme            = Verlet
coulombtype              = PME
rcoulomb                 = 1.0
vdwtype                  = Cut-off
rvdw                     = 1.0
DispCorr                 = EnerPres
tcoupl                   = V-rescale
tc-grps                  = Protein  INH    SOL    Na+
tau-t                    = 0.1      0.1    0.1    0.1
ref-t                    = 300      300    300    300
pcoupl                   = Parrinello-Rahman
tau-p                    = 2.0
compressibility          = 4.5e-5
ref-p                    = 1.0
ramd                     = yes
ramd-seed                = 9876
ramd-ngroups             = 1
ramd-group1-receptor     = Protein
ramd-group1-ligand       = INH
ramd-group1-force        = 600.0
ramd-group1-r-min-dist   = 0.025
ramd-group1-max-dist     = 4.0
ramd-eval-freq           = 10
ramd-force-out-freq      = 20
ramd-group1-ligand-pbcatom   = 1631
ramd-group1-receptor-pbcatom = 3289
EOF
}

# ----------------------------------------------------------------------------
# Tests
# ----------------------------------------------------------------------------

test_version() {
    if ! should_run version; then return; fi
    begin version
    "$GMX" --version > "$tdir/version.txt" 2>&1
    assert_contains "$tdir/version.txt" "GROMACS version:[[:space:]]+2026.4" || { done_fail "version string"; return; }
    "$GMX" mdrun -h > "$tdir/mdrun_help.txt" 2>&1
    assert_contains "$tdir/mdrun_help.txt" "^[[:space:]]*-ramd[[:space:]]+\[<\.xvg>\]" || { done_fail "-ramd option missing"; return; }
    done_pass "2026.4 with -ramd registered"
}

test_mdp_parse() {
    if ! should_run mdp_parse; then return; fi
    begin mdp_parse
    cp "$DB/4water.gro" "$DB/4water.top" "$DB/4water.ndx" "$tdir/"
    gen_water4_mdp 20 10 no no
    if ! GG -f "$tdir/water4.mdp" -c "$tdir/4water.gro" -p "$tdir/4water.top" \
            -n "$tdir/4water.ndx" -o "$tdir/state.tpr" -maxwarn 2 > "$tdir/grompp.log" 2>&1; then
        done_fail "grompp failed (see $tdir/grompp.log)"; return
    fi
    "$GMX" dump -s "$tdir/state.tpr" > "$tdir/dump.txt" 2>&1
    assert_contains "$tdir/dump.txt" "ramd[[:space:]]+= true"            || { done_fail "ramd flag"; return; }
    assert_contains "$tdir/dump.txt" "potential-provider[[:space:]]+= RAMD" || { done_fail "provider"; return; }
    assert_contains "$tdir/dump.txt" "ramd-ngroups[[:space:]]+= 2"       || { done_fail "ngroups"; return; }
    done_pass "RAMD mdp parsed and serialized"
}

test_ramd_basic() {
    if ! should_run ramd_basic; then return; fi
    begin ramd_basic
    cp "$DB/1wdhi.gro" "$DB/1wdhi.top" "$DB/1wdhi.ndx" "$tdir/"
    gen_1wdhi_mdp 200
    GG -f "$tdir/1wdhi.mdp" -c "$tdir/1wdhi.gro" -p "$tdir/1wdhi.top" \
       -n "$tdir/1wdhi.ndx" -o "$tdir/topol.tpr" -maxwarn 2 > "$tdir/grompp.log" 2>&1 \
       || { done_fail "grompp failed"; return; }
    MM -s "$tdir/topol.tpr" -deffnm "$tdir/topol" -ntmpi 1 -ntomp 1 \
       -ramd "$tdir/ramd.xvg" > "$tdir/mdrun.log" 2>&1 \
       || { done_fail "mdrun failed (see $tdir/mdrun.log)"; return; }
    assert_file "$tdir/ramd.xvg" || { done_fail "no ramd.xvg"; return; }
    assert_contains "$tdir/ramd.xvg" "RAMD Ligand-receptor COM distance" || { done_fail "header"; return; }
    # exactly one ligand-receptor distance column (plus time) for 1 group
    local ncol; ncol=$(grep -vE '^[#@]' "$tdir/ramd.xvg" | head -1 | awk '{print NF}')
    assert_eq 2 "$ncol" "ramd.xvg columns" || { done_fail "column count"; return; }
    # pull forces must be non-zero (external RAMD force applied)
    local maxf; maxf=$(grep -vE '^[#@]' "$tdir/topol_pullf.xvg" | awk '{for(i=2;i<=NF;i++){v=$i<0?-$i:$i; if(v>m)m=v}} END{print m+0}')
    if awk "BEGIN{exit !($maxf > 0)}"; then ok "pull force applied (max |f|=$maxf)"; else done_fail "no pull force"; return; fi
    done_pass "1WDHI RAMD ran, output sane"
}

test_ramd_output_optin() {
    if ! should_run ramd_output_optin; then return; fi
    begin ramd_output_optin
    cp "$DB/4water.gro" "$DB/4water.top" "$DB/4water.ndx" "$tdir/"
    gen_water4_mdp 20 10 no no
    GG -f "$tdir/water4.mdp" -c "$tdir/4water.gro" -p "$tdir/4water.top" \
       -n "$tdir/4water.ndx" -o "$tdir/state.tpr" -maxwarn 2 >/dev/null 2>&1 \
       || { done_fail "grompp failed"; return; }
    # Without -ramd on the command line, the optional file must NOT be created.
    MM -s "$tdir/state.tpr" -deffnm "$tdir/state" -ntmpi 1 -ntomp 1 > "$tdir/mdrun.log" 2>&1 \
       || { done_fail "mdrun failed"; return; }
    if [ -e "$tdir/ramd.xvg" ]; then
        done_fail "ramd.xvg created although -ramd was not requested"
    else
        done_pass "RAMD output correctly opt-in via -ramd"
    fi
}

test_multigroup2() {
    if ! should_run multigroup2; then return; fi
    begin multigroup2
    cp "$DB/4water.gro" "$DB/4water.top" "$DB/4water.ndx" "$tdir/"
    gen_water4_mdp 20 10 no no
    GG -f "$tdir/water4.mdp" -c "$tdir/4water.gro" -p "$tdir/4water.top" \
       -n "$tdir/4water.ndx" -o "$tdir/state.tpr" -maxwarn 2 >/dev/null 2>&1 \
       || { done_fail "grompp failed"; return; }
    MM -s "$tdir/state.tpr" -deffnm "$tdir/state" -ntmpi 1 -ntomp 1 \
       -ramd "$tdir/ramd.xvg" >/dev/null 2>&1 || { done_fail "mdrun failed"; return; }
    local ncol; ncol=$(grep -vE '^[#@]' "$tdir/ramd.xvg" | head -1 | awk '{print NF}')
    assert_eq 3 "$ncol" "2-group ramd.xvg columns" || { done_fail "group column count"; return; }
    assert_contains "$tdir/ramd.xvg" 's0 legend "1"' || { done_fail "legend 1"; return; }
    assert_contains "$tdir/ramd.xvg" 's1 legend "2"' || { done_fail "legend 2"; return; }
    done_pass "two RAMD groups produce two columns"
}

test_connected_ligands() {
    if ! should_run connected_ligands; then return; fi
    begin connected_ligands
    cp "$DB/4water.gro" "$DB/4water.top" "$DB/4water.ndx" "$tdir/"
    gen_water4_mdp 100000 10 no no   # connected-ligands = no
    GG -f "$tdir/water4.mdp" -c "$tdir/4water.gro" -p "$tdir/4water.top" \
       -n "$tdir/4water.ndx" -o "$tdir/state.tpr" -maxwarn 2 >/dev/null 2>&1 \
       || { done_fail "grompp failed"; return; }
    MM -s "$tdir/state.tpr" -deffnm "$tdir/state" -ntmpi 1 -ntomp 1 \
       -ramd "$tdir/ramd.xvg" -reprod >/dev/null 2>&1
    local rc=$?
    # Reference behaviour: RAMD stop condition => mdrun returns 2
    assert_eq 2 "$rc" "mdrun exit code (RAMD stop)" || { done_fail "unexpected exit code"; return; }
    assert_contains "$tdir/state.log" "GROMACS will be stopped after 630 steps" \
        || { done_fail "stop step mismatch"; return; }
    local d1 p1 r1
    d1=$(grep -vE '^[#@]' "$tdir/ramd.xvg" | head -1 | awk '{print $2}')
    p1=$(grep -vE '^[#@]' "$tdir/state_pullx.xvg" | head -1 | awk '{print $2}')
    r1=$(grep -vE '^[#@]' "$tdir/ramd.xvg" | head -1 | awk '{print $1}')
    assert_eq "0.423961" "$d1" "ramd initial distance group1" || { done_fail "distance value"; return; }
    assert_eq "0.0593702" "$p1" "pullx initial coordinate group1" || { done_fail "pullx value"; return; }
    assert_eq "0.0000" "$r1" "ramd first time" || { done_fail "time value"; return; }
    done_pass "connected-ligands exit + numeric regression"
}

test_restart_append() {
    if ! should_run restart_append; then return; fi
    begin restart_append
    cp "$DB/4water.gro" "$DB/4water.top" "$DB/4water.ndx" "$tdir/"
    gen_water4_mdp 100 10 no no
    GG -f "$tdir/water4.mdp" -c "$tdir/4water.gro" -p "$tdir/4water.top" \
       -n "$tdir/4water.ndx" -o "$tdir/state.tpr" -maxwarn 2 >/dev/null 2>&1 \
       || { done_fail "grompp failed"; return; }
    # Both runs must share the same -deffnm so that the existing output files
    # can be appended to (GROMACS refuses -append if output files are missing).
    # Pull output files are named explicitly to avoid the known -deffnm/-cpi
    # pull-restart filename quirk.
    MM -s "$tdir/state.tpr" -deffnm "$tdir/part" -ntmpi 1 -ntomp 1 \
       -ramd "$tdir/ramd.xvg" -px "$tdir/pullx.xvg" -pf "$tdir/pullf.xvg" \
       -cpo "$tdir/part.cpt" > "$tdir/part1.log" 2>&1 \
       || { done_fail "first run failed"; return; }
    local n1; n1=$(grep -vcE '^[#@]' "$tdir/ramd.xvg")
    local h1; h1=$(grep -c "RAMD Ligand-receptor COM distance" "$tdir/ramd.xvg")
    [ "$n1" -gt 0 ] || { done_fail "no data after first run"; return; }
    # continue with append
    MM -s "$tdir/state.tpr" -deffnm "$tdir/part" -ntmpi 1 -ntomp 1 \
       -ramd "$tdir/ramd.xvg" -px "$tdir/pullx.xvg" -pf "$tdir/pullf.xvg" \
       -cpi "$tdir/part.cpt" -append -nsteps 200 > "$tdir/part2.log" 2>&1 \
       || { done_fail "restart+append failed (see $tdir/part2.log)"; return; }
    local n2 h2
    n2=$(grep -vcE '^[#@]' "$tdir/ramd.xvg")
    h2=$(grep -c "RAMD Ligand-receptor COM distance" "$tdir/ramd.xvg")
    if [ "$n2" -gt "$n1" ] && [ "$h2" -eq 1 ]; then
        done_pass "ramd.xvg appended without duplicate header ($n1 -> $n2 lines)"
    else
        done_fail "append failed (lines $n1->$n2, headers $h1->$h2)"
    fi
}

test_old_angle_dist() {
    if ! should_run old_angle_dist; then return; fi
    begin old_angle_dist
    cp "$DB/4water.gro" "$DB/4water.top" "$DB/4water.ndx" "$tdir/"
    gen_water4_mdp 20 10 no yes   # old-angle-dist = yes
    GG -f "$tdir/water4.mdp" -c "$tdir/4water.gro" -p "$tdir/4water.top" \
       -n "$tdir/4water.ndx" -o "$tdir/state.tpr" -maxwarn 2 >/dev/null 2>&1 \
       || { done_fail "grompp failed"; return; }
    MM -s "$tdir/state.tpr" -deffnm "$tdir/state" -ntmpi 1 -ntomp 1 \
       -ramd "$tdir/ramd.xvg" > "$tdir/mdrun.log" 2>&1 \
       || { done_fail "mdrun failed"; return; }
    assert_contains "$tdir/mdrun.log" "Old angle distribution is used" \
        || { done_fail "expected old-angle-dist warning"; return; }
    done_pass "old-angle-dist path exercised"
}

test_nonramd_control() {
    if ! should_run nonramd_control; then return; fi
    begin nonramd_control
    cp "$DB/4water.gro" "$DB/4water.top" "$DB/4water.ndx" "$tdir/"
    gen_water4_mdp 20 10 no no
    sed -i 's/^ramd  *= yes/ramd                     = no/' "$tdir/water4.mdp"
    # With ramd=no the remaining ramd-* options are simply ignored (as
    # documented), which produces warnings; allow them with a high maxwarn.
    GG -f "$tdir/water4.mdp" -c "$tdir/4water.gro" -p "$tdir/4water.top" \
       -n "$tdir/4water.ndx" -o "$tdir/state.tpr" -maxwarn 50 > "$tdir/grompp.log" 2>&1 \
       || { done_fail "grompp failed (see $tdir/grompp.log)"; return; }
    "$GMX" dump -s "$tdir/state.tpr" > "$tdir/dump.txt" 2>&1
    assert_contains "$tdir/dump.txt" "ramd[[:space:]]+= false" || { done_fail "ramd should be false"; return; }
    if grep -q "potential-provider[[:space:]]+= RAMD" "$tdir/dump.txt"; then
        done_fail "RAMD provider present although ramd=no"; return
    fi
    MM -s "$tdir/state.tpr" -deffnm "$tdir/state" -ntmpi 1 -ntomp 1 \
       -ramd "$tdir/ramd.xvg" > "$tdir/mdrun.log" 2>&1 \
       || { done_fail "mdrun failed"; return; }
    done_pass "ramd=no falls back to plain MD (no provider)"
}

test_reprod() {
    if ! should_run reprod; then return; fi
    begin reprod
    cp "$DB/4water.gro" "$DB/4water.top" "$DB/4water.ndx" "$tdir/"
    gen_water4_mdp 200 10 no no
    GG -f "$tdir/water4.mdp" -c "$tdir/4water.gro" -p "$tdir/4water.top" \
       -n "$tdir/4water.ndx" -o "$tdir/state.tpr" -maxwarn 2 >/dev/null 2>&1 \
       || { done_fail "grompp failed"; return; }
    MM -s "$tdir/state.tpr" -deffnm "$tdir/a" -ntmpi 1 -ntomp 1 -ramd "$tdir/a.xvg" -reprod >/dev/null 2>&1 || { done_fail "run a failed"; return; }
    MM -s "$tdir/state.tpr" -deffnm "$tdir/b" -ntmpi 1 -ntomp 1 -ramd "$tdir/b.xvg" -reprod >/dev/null 2>&1 || { done_fail "run b failed"; return; }
    if diff <(grep -vE '^[#@]' "$tdir/a.xvg") <(grep -vE '^[#@]' "$tdir/b.xvg") >/dev/null; then
        done_pass "two -reprod runs produce identical ramd.xvg"
    else
        done_fail "ramd.xvg differs between identical runs"
    fi
}

test_glyr_multigroup5() {
    if ! should_run glyr_multigroup5; then return; fi
    begin glyr_multigroup5
    if [ "$MODE" != "full" ]; then skip "heavy test skipped (use --full)"; return; fi
    cp "$DB/glyr.gro" "$DB/glyr.top" "$DB/glyr.ndx" "$DB/glyr-ramd.mdp" "$tdir/"
    sed -i 's/^nsteps.*/nsteps                   = 4/' "$tdir/glyr-ramd.mdp"
    GG -f "$tdir/glyr-ramd.mdp" -c "$tdir/glyr.gro" -p "$tdir/glyr.top" \
       -n "$tdir/glyr.ndx" -o "$tdir/state.tpr" -maxwarn 2 > "$tdir/grompp.log" 2>&1 \
       || { done_fail "grompp failed (see grompp.log)"; return; }
    MM -s "$tdir/state.tpr" -deffnm "$tdir/state" -ntmpi 1 -ntomp 2 \
       -ramd "$tdir/ramd.xvg" > "$tdir/mdrun.log" 2>&1 \
       || { done_fail "mdrun failed (see mdrun.log)"; return; }
    local ncol; ncol=$(grep -vE '^[#@]' "$tdir/ramd.xvg" | head -1 | awk '{print NF}')
    assert_eq 6 "$ncol" "5-group ramd.xvg columns" || { done_fail "column count"; return; }
    done_pass "GlyR 5-group RAMD ran"
}

# ----------------------------------------------------------------------------
# Run selected tests
# ----------------------------------------------------------------------------
head1 "GROMACS-RAMD test suite (mode=$MODE)"
log "GMX       : $GMX"
log "GMXRC     : $GMXRC"
log "SRCROOT   : $SRCROOT"
log "WORKROOT  : $WORKROOT"

test_version
test_mdp_parse
test_ramd_basic
test_ramd_output_optin
test_multigroup2
test_connected_ligands
test_restart_append
test_old_angle_dist
test_nonramd_control
test_reprod
test_glyr_multigroup5

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------
head1 "SUMMARY"
printf '%-22s %-6s %s\n' "TEST" "RESULT" "DETAIL"
printf -- '-------------------------------------------------------------------------\n'
for r in "${RESULTS[@]}"; do
    IFS='|' read -r n s d <<< "$r"
    printf '%-22s %-6s %s\n' "$n" "$s" "$d"
done
printf -- '-------------------------------------------------------------------------\n'
printf 'PASS=%d  FAIL=%d  SKIP=%d\n' "$PASS" "$FAIL" "$SKIP"
if [ "$KEEP" -eq 0 ]; then
    rm -rf "$WORKROOT"
else
    log "Working directories kept under: $WORKROOT"
fi

[ "$FAIL" -eq 0 ]
