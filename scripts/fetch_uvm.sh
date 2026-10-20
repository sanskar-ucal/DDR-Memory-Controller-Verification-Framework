#!/usr/bin/env bash
# Fetch the Accellera UVM reference implementation (IEEE 1800.2-2020, 2020.3.1).
set -euo pipefail
DEST="${1:-third_party/uvm-core}"
TAG="2020.3.1"
if [ -f "$DEST/src/uvm_pkg.sv" ]; then
  echo "UVM already present in $DEST"
  exit 0
fi
mkdir -p "$(dirname "$DEST")"
git clone --depth 1 --branch "$TAG" https://github.com/accellera-official/uvm-core.git "$DEST"
echo "UVM $TAG installed in $DEST"
