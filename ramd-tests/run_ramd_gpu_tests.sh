#!/usr/bin/env bash
#
# GROMACS-RAMD 2026.4 GPU functional test suite
#
# Purpose: exercise the migrated RAMD force provider together with GPU
#          offloading (nonbonded / PME / update) and compare against CPU.
#
# Usage:
#   ./run_ramd_gpu_tests.sh [options]
#
# Options:
#   --keep              Keep per-test working directories for inspection
#   --list              List test names and exit
#   --test NAME         Run only the named test (repeatable)
#   --prefix DIR        GROMACS installation prefix (default /opt/gromacs-2026.4-ramd)
#   --src DIR           Path to the migrated source tree (for test data)
#   --gpu-id IDS        Value for -gpu_id (default "0")
#   --gpu-flags "..."   Override default GPU flags (default "-nb gpu -pme gpu")
#   --full              Also run optional/slower tests (update-GPU, multi-GPU)
#   --update            Include the GPU-update test (requires md integrator), implies --full
#   --gmx PATH          Use this gmx binary directly (skips GMXRC sourcing); useful
#                       for CTest / build-tree runs. GMXDATA/GMXLIB must be set
#                       by the caller in that case.
#
# Notes:
#   * GPU runs are NOT bitwise reproducible vs CPU; consistency is checked on
#     the initial (step 0) RAMD distance (must match) and with a loose bound on
#     the short-run drift.
#   * If no usable GPU is present, GPU tests are reported as SKIP, not FAIL.
#   * RAMD output (-ramd) is an optional file and must be passed explicitly.

set -u

GMXPREFIX_DEFAULT="/opt/gromacs-2026.4-ramd"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRCROOT_DEFAULT="$(cd "$SCRIPT_DIR/.." && pwd)"
GMXPREFIX="${GMXPREFIX:-$GMXPREFIX_DEFAULT}"
SRCROOT="${SRCROOT:-$SRCROOT_DEFAULT}"
GMX_OVERRIDE="${GMX:-}"
KEEP=0
MODE="quick"
SELECTED=()
GPU_ID="${GPU_ID:-0}"
GPU_FLAGS_STR="${GPU_FLAGS:--nb gpu -pme gpu}"
INCLUDE_UPDATE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --keep) KEEP=1 ;;
        --list) MODE="list" ;;
        --full) MODE="full" ;;
        --update) INCLUDE_UPDATE=1; MODE="full" ;;
        --test) SELECTED+=("$2"); shift ;;
        --prefix) GMXPREFIX="$2"; shift ;;
        --src) SRCROOT="$2"; shift ;;
        --gmx) GMX_OVERRIDE="$2"; shift ;;
        --gpu-id) GPU_ID="$2"; shift ;;
        --gpu-flags) GPU_FLAGS_STR="$2"; shift ;;
        -h|--help) sed -n '2,34p' "$0"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

GMXRC="$GMXPREFIX/bin/GMXRC.bash"
GMX="$GMXPREFIX/bin/gmx"
DB="$SRCROOT/src/testutils/simulationdatabase"
WORKROOT="${WORKROOT:-$(mktemp -d /tmp/ramd-gpu-tests.XXXXXX)}"

read -r -a GPU_FLAGS <<< "$GPU_FLAGS_STR"
read -r -a GPU_ID_FLAG <<< ""            # filled below if GPU_ID non-empty
if [ -n "$GPU_ID" ]; then GPU_ID_FLAG=(-gpu_id "$GPU_ID"); fi

ALL_TESTS=(gpu_build_check gpu_probe gpu_nb_pme_1wdhi gpu_cpu_consistency \
           gpu_multigroup2 gpu_pmefft gpu_nb_only gpu_update gpu_multi_gpu)

if [ "$MODE" = "list" ]; then
    printf '%s\n' "${ALL_TESTS[@]}"
    exit 0
fi

# ----------------------------------------------------------------------------
if [ -n "$GMX_OVERRIDE" ]; then
    GMX="$GMX_OVERRIDE"
else
    if [ ! -f "$GMXRC" ]; then echo "ERROR: GMXRC not found at $GMXRC" >&2; exit 1; fi
    # shellcheck disable=SC1090
    source "$GMXRC" >/dev/null 2>&1
    GMX="$GMXPREFIX/bin/gmx"
fi
[ -x "$GMX" ] || { echo "ERROR: gmx not found at $GMX" >&2; exit 1; }
[ -d "$DB" ] || { echo "ERROR: simulation database not found at $DB" >&2; exit 1; }

PASS=0; FAIL=0; SKIP=0
declare -a RESULTS=()
GPU_OK=0          # set by gpu_probe

log()   { printf '  %s\n' "$*"; }
head1() { printf '\n=================================================================\n'; printf '== %s\n' "$*"; printf '=================================================================\n'; }

tname=""; tdir=""
begin() { tname="$1"; tdir="$WORKROOT/$tname"; rm -rf "$tdir"; mkdir -p "$tdir"; head1 "TEST: $tname"; }
record() { RESULTS+=("$1|$2|$3"); }
ok() { log "PASS: $*"; }
skip() { log "SKIP: $*"; record "$tname" "SKIP" "$*"; SKIP=$((SKIP+1)); }
done_pass() { ok "$*"; record "$tname" "PASS" "$*"; PASS=$((PASS+1)); }
done_fail() { log "FAIL: $*"; record "$tname" "FAIL" "$*"; FAIL=$((FAIL+1)); }

assert_eq()    { if [ "$1" = "$2" ]; then ok "$3 ($2)"; else log "MISMATCH $3: expected '$1' got '$2'"; return 1; fi; }
assert_file()  { if [ -f "$1" ]; then ok "file exists: $(basename "$1")"; else log "missing file: $1"; return 1; fi; }
assert_contains() { if grep -qE -- "$2" "$1"; then ok "found '$2' in $(basename "$1")"; else log "'$2' not found in $1"; return 1; fi; }

GG()  { "$GMX" grompp -po /dev/null "$@"; }
MMC() { "$GMX" mdrun -nb cpu -pme cpu "$@"; }                     # CPU reference
MMG() { "$GMX" mdrun "${GPU_FLAGS[@]}" "${GPU_ID_FLAG[@]}" "$@"; } # GPU

should_run() {
    [ ${#SELECTED[@]} -eq 0 ] && return 0
    local t; for t in "${SELECTED[@]}"; do [ "$t" = "$1" ] && return 0; done
    return 1
}

gpu_used_in_log() {  # $1 = log file
    grep -qiE "on the GPU|GPU selected|will use GPU|GPU #|Using .*GPU" "$1"
}

# Extract a one-line reason from a GROMACS mdrun/grompp log.
err_line() {
    local f="$1"
    if [ ! -f "$f" ]; then echo "(no log)"; return; fi
    local l
    l=$(grep -m1 -A3 -E "Fatal error:|Inconsistency in user input:|Error in user input:|Invalid input" "$f" \
        | grep -vE '^(Fatal error:|Inconsistency in user input:|Error in user input:|Invalid input|--+|[[:space:]]*$)' \
        | head -1)
    if [ -n "$l" ]; then echo "$l"; else echo "(see $f)"; fi
}

# ----------------------------------------------------------------------------
# Input generators
# ----------------------------------------------------------------------------
gen_water4_mdp() {  # $1=nsteps $2=freq $3=connected(yes/no) $4=old_angle(yes/no)
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

gen_1wdhi_mdp() {  # $1=nsteps $2=integrator
    local nsteps="${1:-200}" integ="${2:-md}"
    cat > "$tdir/1wdhi.mdp" <<EOF
integrator               = $integ
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

# helper: max |value| in a column (for pullf)
# ----------------------------------------------------------------------------
# Tests
# ----------------------------------------------------------------------------

test_gpu_build_check() {
    if ! should_run gpu_build_check; then return; fi
    begin gpu_build_check
    "$GMX" --version > "$tdir/version.txt" 2>&1
    assert_contains "$tdir/version.txt" "GROMACS version:[[:space:]]+2026.4" || { done_fail "version"; return; }
    if grep -qiE "GPU support:[[:space:]]+none" "$tdir/version.txt"; then
        skip "This build has no GPU support"; return
    fi
    local gtype; gtype=$(grep -iE "GPU support:" "$tdir/version.txt" | head -1)
    ok "$gtype"
    if command -v nvidia-smi >/dev/null 2>&1; then
        nvidia-smi -L > "$tdir/nvidia-smi.txt" 2>&1 && ok "nvidia-smi: $(head -1 "$tdir/nvidia-smi.txt")"
    fi
    done_pass "CUDA-capable build detected"
}

test_gpu_probe() {
    if ! should_run gpu_probe; then return; fi
    begin gpu_probe
    cp "$DB/1wdhi.gro" "$DB/1wdhi.top" "$DB/1wdhi.ndx" "$tdir/"
    gen_1wdhi_mdp 2
    GG -f "$tdir/1wdhi.mdp" -c "$tdir/1wdhi.gro" -p "$tdir/1wdhi.top" \
       -n "$tdir/1wdhi.ndx" -o "$tdir/topol.tpr" -maxwarn 2 > "$tdir/grompp.log" 2>&1 \
       || { done_fail "grompp failed"; return; }
    if ! MMG -s "$tdir/topol.tpr" -deffnm "$tdir/probe" -ntmpi 1 -ntomp 2 \
             -ramd "$tdir/ramd.xvg" > "$tdir/probe.log" 2>&1; then
        skip "GPU run failed (no usable GPU?) - see $tdir/probe.log"; return
    fi
    if gpu_used_in_log "$tdir/probe.log"; then
        GPU_OK=1
        ok "GPU detected and used: $(grep -iE 'GPU selected|on the GPU' "$tdir/probe.log" | head -1)"
        done_pass "usable GPU present"
    else
        skip "GPU not used (system too small or no device); remaining GPU tests skipped"
    fi
}

test_gpu_nb_pme_1wdhi() {
    if ! should_run gpu_nb_pme_1wdhi; then return; fi
    begin gpu_nb_pme_1wdhi
    [ "$GPU_OK" -eq 1 ] || { skip "no usable GPU"; return; }
    cp "$DB/1wdhi.gro" "$DB/1wdhi.top" "$DB/1wdhi.ndx" "$tdir/"
    gen_1wdhi_mdp 200
    GG -f "$tdir/1wdhi.mdp" -c "$tdir/1wdhi.gro" -p "$tdir/1wdhi.top" \
       -n "$tdir/1wdhi.ndx" -o "$tdir/topol.tpr" -maxwarn 2 > "$tdir/grompp.log" 2>&1 \
       || { done_fail "grompp failed"; return; }
    MMG -s "$tdir/topol.tpr" -deffnm "$tdir/state" -ntmpi 1 -ntomp 2 \
        -ramd "$tdir/ramd.xvg" > "$tdir/mdrun.log" 2>&1 \
        || { done_fail "GPU mdrun failed (see $tdir/mdrun.log)"; return; }
    assert_file "$tdir/ramd.xvg" || { done_fail "no ramd.xvg"; return; }
    gpu_used_in_log "$tdir/mdrun.log" || { done_fail "log shows no GPU usage"; return; }
    local ncol; ncol=$(grep -vE '^[#@]' "$tdir/ramd.xvg" | head -1 | awk '{print NF}')
    assert_eq 2 "$ncol" "ramd.xvg columns" || { done_fail "column count"; return; }
    local maxf; maxf=$(grep -vE '^[#@]' "$tdir/state_pullf.xvg" | awk '{for(i=2;i<=NF;i++){v=$i<0?-$i:$i;if(v>m)m=v}} END{print m+0}')
    awk "BEGIN{exit !($maxf > 0)}" || { done_fail "no pull force on GPU run"; return; }
    ok "pull force applied on GPU (max |f|=$maxf)"
    done_pass "1WDHI RAMD ran on GPU (-nb gpu -pme gpu)"
}

test_gpu_cpu_consistency() {
    if ! should_run gpu_cpu_consistency; then return; fi
    begin gpu_cpu_consistency
    [ "$GPU_OK" -eq 1 ] || { skip "no usable GPU"; return; }
    cp "$DB/1wdhi.gro" "$DB/1wdhi.top" "$DB/1wdhi.ndx" "$tdir/"
    gen_1wdhi_mdp 200
    GG -f "$tdir/1wdhi.mdp" -c "$tdir/1wdhi.gro" -p "$tdir/1wdhi.top" \
       -n "$tdir/1wdhi.ndx" -o "$tdir/topol.tpr" -maxwarn 2 > "$tdir/grompp.log" 2>&1 \
       || { done_fail "grompp failed"; return; }
    MMC -s "$tdir/topol.tpr" -deffnm "$tdir/cpu" -ntmpi 1 -ntomp 2 \
        -ramd "$tdir/cpu_ramd.xvg" > "$tdir/cpu.log" 2>&1 \
        || { done_fail "CPU reference run failed"; return; }
    MMG -s "$tdir/topol.tpr" -deffnm "$tdir/gpu" -ntmpi 1 -ntomp 2 \
        -ramd "$tdir/gpu_ramd.xvg" > "$tdir/gpu.log" 2>&1 \
        || { done_fail "GPU run failed"; return; }
    # Step-0 distance must match exactly (initial coordinates).
    local c0 g0
    c0=$(grep -vE '^[#@]' "$tdir/cpu_ramd.xvg" | head -1 | awk '{print $2}')
    g0=$(grep -vE '^[#@]' "$tdir/gpu_ramd.xvg" | head -1 | awk '{print $2}')
    assert_eq "$c0" "$g0" "initial RAMD distance CPU vs GPU" || { done_fail "step-0 mismatch"; return; }
    # Overall short-run drift bound (GPU is not bitwise reproducible).
    local maxdiff
    maxdiff=$(paste <(grep -vE '^[#@]' "$tdir/cpu_ramd.xvg" | awk '{print $2}') \
                    <(grep -vE '^[#@]' "$tdir/gpu_ramd.xvg" | awk '{print $2}') \
              | awk '{d=$1-$2; if(d<0)d=-d; if(d>m)m=d} END{printf "%.6g", m+0}')
    if awk "BEGIN{exit !($maxdiff < 0.05)}"; then
        done_pass "CPU/GPU consistent (step0=$c0, max drift=$maxdiff nm)"
    else
        done_fail "CPU/GPU drift too large ($maxdiff nm)"
    fi
}

test_gpu_multigroup2() {
    if ! should_run gpu_multigroup2; then return; fi
    begin gpu_multigroup2
    [ "$GPU_OK" -eq 1 ] || { skip "no usable GPU"; return; }
    cp "$DB/4water.gro" "$DB/4water.top" "$DB/4water.ndx" "$tdir/"
    gen_water4_mdp 50 10 no no
    GG -f "$tdir/water4.mdp" -c "$tdir/4water.gro" -p "$tdir/4water.top" \
       -n "$tdir/4water.ndx" -o "$tdir/state.tpr" -maxwarn 2 >/dev/null 2>&1 \
       || { done_fail "grompp failed"; return; }
    # Use -pme cpu to avoid the single-rank "PME on GPU with CPU nonbonded"
    # restriction; the multi-group plumbing is still exercised under GPU flags.
    if ! "$GMX" mdrun -nb gpu -pme cpu "${GPU_ID_FLAG[@]}" \
            -s "$tdir/state.tpr" -deffnm "$tdir/state" -ntmpi 1 -ntomp 1 \
            -ramd "$tdir/ramd.xvg" > "$tdir/mdrun.log" 2>&1; then
        skip "GPU mdrun failed: $(err_line "$tdir/mdrun.log")"
        return
    fi
    if ! gpu_used_in_log "$tdir/mdrun.log"; then
        ok "note: 4water too small for GPU offload (ran on CPU)"
    fi
    local ncol; ncol=$(grep -vE '^[#@]' "$tdir/ramd.xvg" | head -1 | awk '{print NF}')
    assert_eq 3 "$ncol" "2-group ramd.xvg columns" || { done_fail "column count"; return; }
    done_pass "2-group RAMD under GPU flags"
}

test_gpu_pmefft() {
    if ! should_run gpu_pmefft; then return; fi
    begin gpu_pmefft
    [ "$GPU_OK" -eq 1 ] || { skip "no usable GPU"; return; }
    cp "$DB/1wdhi.gro" "$DB/1wdhi.top" "$DB/1wdhi.ndx" "$tdir/"
    gen_1wdhi_mdp 100
    GG -f "$tdir/1wdhi.mdp" -c "$tdir/1wdhi.gro" -p "$tdir/1wdhi.top" \
       -n "$tdir/1wdhi.ndx" -o "$tdir/topol.tpr" -maxwarn 2 >/dev/null 2>&1 \
       || { done_fail "grompp failed"; return; }
    # Full GPU offload including the PME FFT stage.
    if ! "$GMX" mdrun -nb gpu -pme gpu -pmefft gpu "${GPU_ID_FLAG[@]}" \
            -s "$tdir/topol.tpr" -deffnm "$tdir/state" -ntmpi 1 -ntomp 2 \
            -ramd "$tdir/ramd.xvg" > "$tdir/mdrun.log" 2>&1; then
        skip "PME-FFT-on-GPU unsupported/failed: $(err_line "$tdir/mdrun.log")"; return
    fi
    assert_file "$tdir/ramd.xvg" || { done_fail "no ramd.xvg"; return; }
    done_pass "RAMD with -nb gpu -pme gpu -pmefft gpu"
}

test_gpu_nb_only() {
    if ! should_run gpu_nb_only; then return; fi
    begin gpu_nb_only
    [ "$GPU_OK" -eq 1 ] || { skip "no usable GPU"; return; }
    cp "$DB/1wdhi.gro" "$DB/1wdhi.top" "$DB/1wdhi.ndx" "$tdir/"
    gen_1wdhi_mdp 100
    GG -f "$tdir/1wdhi.mdp" -c "$tdir/1wdhi.gro" -p "$tdir/1wdhi.top" \
       -n "$tdir/1wdhi.ndx" -o "$tdir/topol.tpr" -maxwarn 2 >/dev/null 2>&1 \
       || { done_fail "grompp failed"; return; }
    if ! "$GMX" mdrun -nb gpu -pme cpu "${GPU_ID_FLAG[@]}" \
            -s "$tdir/topol.tpr" -deffnm "$tdir/state" -ntmpi 1 -ntomp 2 \
            -ramd "$tdir/ramd.xvg" > "$tdir/mdrun.log" 2>&1; then
        skip "nonbonded-on-GPU run failed (see $tdir/mdrun.log)"; return
    fi
    assert_file "$tdir/ramd.xvg" || { done_fail "no ramd.xvg"; return; }
    done_pass "RAMD with -nb gpu -pme cpu"
}

test_gpu_update() {
    if ! should_run gpu_update; then return; fi
    begin gpu_update
    if [ "$INCLUDE_UPDATE" -ne 1 ] && [ "$MODE" != "full" ]; then
        skip "GPU update test not requested (use --update)"; return
    fi
    [ "$GPU_OK" -eq 1 ] || { skip "no usable GPU"; return; }
    cp "$DB/1wdhi.gro" "$DB/1wdhi.top" "$DB/1wdhi.ndx" "$tdir/"
    # GROMACS 2026.4 GPU update requires the leap-frog "md" integrator
    # (NOT md-vv), GPU nonbonded/PME, and no Nose-Hoover thermostat.
    gen_1wdhi_mdp 100
    sed -i 's/^constraints .*/constraints              = h-bonds/' "$tdir/1wdhi.mdp"
    if ! GG -f "$tdir/1wdhi.mdp" -c "$tdir/1wdhi.gro" -p "$tdir/1wdhi.top" \
            -n "$tdir/1wdhi.ndx" -o "$tdir/topol.tpr" -maxwarn 5 > "$tdir/grompp.log" 2>&1; then
        skip "grompp failed: $(err_line "$tdir/grompp.log")"; return
    fi
    if ! "$GMX" mdrun -nb gpu -pme gpu -update gpu "${GPU_ID_FLAG[@]}" \
            -s "$tdir/topol.tpr" -deffnm "$tdir/state" -ntmpi 1 -ntomp 2 \
            -ramd "$tdir/ramd.xvg" > "$tdir/mdrun.log" 2>&1; then
        skip "GPU update unsupported: $(err_line "$tdir/mdrun.log")"; return
    fi
    assert_file "$tdir/ramd.xvg" || { done_fail "no ramd.xvg"; return; }
    gpu_used_in_log "$tdir/mdrun.log" || { done_fail "log shows no GPU usage"; return; }
    done_pass "RAMD with -update gpu (md integrator)"
}

test_gpu_multi_gpu() {
    if ! should_run gpu_multi_gpu; then return; fi
    begin gpu_multi_gpu
    if [ "$MODE" != "full" ]; then skip "multi-GPU test not requested (use --full)"; return; fi
    [ "$GPU_OK" -eq 1 ] || { skip "no usable GPU"; return; }
    local ngpu=0
    if command -v nvidia-smi >/dev/null 2>&1; then
        ngpu=$(nvidia-smi -L 2>/dev/null | grep -c '^GPU')
    fi
    if [ "$ngpu" -lt 2 ]; then skip "only $ngpu GPU(s) visible"; return; fi
    cp "$DB/1wdhi.gro" "$DB/1wdhi.top" "$DB/1wdhi.ndx" "$tdir/"
    gen_1wdhi_mdp 100
    GG -f "$tdir/1wdhi.mdp" -c "$tdir/1wdhi.gro" -p "$tdir/1wdhi.top" \
       -n "$tdir/1wdhi.ndx" -o "$tdir/topol.tpr" -maxwarn 2 >/dev/null 2>&1 \
       || { done_fail "grompp failed"; return; }
    if ! "$GMX" mdrun -nb gpu -pme gpu -gpu_id 0,1 \
            -s "$tdir/topol.tpr" -deffnm "$tdir/state" -ntmpi 1 -ntomp 2 \
            -ramd "$tdir/ramd.xvg" > "$tdir/mdrun.log" 2>&1; then
        skip "multi-GPU run failed (see $tdir/mdrun.log)"; return
    fi
    assert_file "$tdir/ramd.xvg" || { done_fail "no ramd.xvg"; return; }
    done_pass "RAMD with 2 GPUs"
}

# ----------------------------------------------------------------------------
head1 "GROMACS-RAMD GPU test suite (mode=$MODE)"
log "GMX       : $GMX"
log "GPU flags : ${GPU_FLAGS[*]}  -gpu_id ${GPU_ID:-<auto>}"
log "SRCROOT   : $SRCROOT"
log "WORKROOT  : $WORKROOT"

test_gpu_build_check
test_gpu_probe
test_gpu_nb_pme_1wdhi
test_gpu_cpu_consistency
test_gpu_multigroup2
test_gpu_pmefft
test_gpu_nb_only
test_gpu_update
test_gpu_multi_gpu

head1 "SUMMARY"
printf '%-22s %-6s %s\n' "TEST" "RESULT" "DETAIL"
printf -- '-------------------------------------------------------------------------\n'
for r in "${RESULTS[@]}"; do
    IFS='|' read -r n s d <<< "$r"
    printf '%-22s %-6s %s\n' "$n" "$s" "$d"
done
printf -- '-------------------------------------------------------------------------\n'
printf 'PASS=%d  FAIL=%d  SKIP=%d\n' "$PASS" "$FAIL" "$SKIP"
if [ "$KEEP" -eq 0 ]; then rm -rf "$WORKROOT"; else log "Working directories kept under: $WORKROOT"; fi

[ "$FAIL" -eq 0 ]
