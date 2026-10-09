#!/usr/bin/env bash
#
# Generate the reference .tpr files used/archived by the RAMD test suite.
#
# Usage:
#   ./setup.sh [GMXPREFIX]
#
# Environment overrides:
#   GMXPREFIX   GROMACS installation prefix (default /opt/gromacs-2026.4-ramd)
#   SRCROOT     Path to this source tree (default: parent of this script)
#
# The generated tpr files land in ./tpr/ and correspond to the mdp files in
# ./mdp/. They are optional reference artifacts; the test scripts generate
# their own tpr files at run time from the simulation database.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRCROOT="${SRCROOT:-$(cd "$HERE/.." && pwd)}"
GMXPREFIX="${1:-${GMXPREFIX:-/opt/gromacs-2026.4-ramd}}"

GMXRC="$GMXPREFIX/bin/GMXRC.bash"
GMX="$GMXPREFIX/bin/gmx"
DB="$SRCROOT/src/testutils/simulationdatabase"
OUT="$HERE/tpr"

[ -f "$GMXRC" ] || { echo "ERROR: GMXRC not found: $GMXRC" >&2; exit 1; }
[ -d "$DB" ]    || { echo "ERROR: simulation database not found: $DB" >&2; exit 1; }
# shellcheck disable=SC1090
source "$GMXRC" >/dev/null 2>&1
[ -x "$GMX" ] || { echo "ERROR: gmx not found: $GMX" >&2; exit 1; }

mkdir -p "$OUT"
cd "$OUT"

echo "[1/3] 1wdhi_ramd.tpr (1 group)"
"$GMX" grompp -f "$HERE/mdp/1wdhi_ramd.mdp" \
    -c "$DB/1wdhi.gro" -p "$DB/1wdhi.top" -n "$DB/1wdhi.ndx" \
    -o 1wdhi_ramd.tpr -po /dev/null -maxwarn 5 >/dev/null

echo "[2/3] water4_ramd2grp.tpr (2 groups)"
"$GMX" grompp -f "$HERE/mdp/water4_ramd2grp.mdp" \
    -c "$DB/4water.gro" -p "$DB/4water.top" -n "$DB/4water.ndx" \
    -o water4_ramd2grp.tpr -po /dev/null -maxwarn 5 >/dev/null

echo "[3/3] glyr_ramd5grp.tpr (5 groups)"
"$GMX" grompp -f "$HERE/mdp/glyr_ramd5grp.mdp" \
    -c "$DB/glyr.gro" -p "$DB/glyr.top" -n "$DB/glyr.ndx" \
    -o glyr_ramd5grp.tpr -po /dev/null -maxwarn 5 >/dev/null

echo "Done. tpr files written to $OUT"
ls -l "$OUT"
