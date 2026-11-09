#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# SPDX-FileCopyrightText: 2026 Howard M. Harte
set -euo pipefail
cd "$(dirname "$0")"
. ../../../retrosim-build/gowin.sh
gowin_board console60k
export GOWIN_RTL_DIRS=". ../../rtl ../../../hh-uart/rtl"
case "${1:-synth}" in
  synth) gowin_synth edid_probe probe.sdc ;;
  prog) gowin_prog edid_probe ;;
  *) echo 'usage: build.sh [synth|prog]' >&2; exit 2 ;;
esac
