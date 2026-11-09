#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
# SPDX-FileCopyrightText: 2026 Howard M. Harte
"""cov_summary.py -- render doc/coverage.md from the merged Verilator coverage
.dat produced by sim/vl/cov.ps1.

Declares this repository's report (scope, notes, prose); the parser and the
layout are retrosim-build/tools/cov_summary_lib.py. The hand-authored
"## Hole triage" section of doc/coverage.md is kept across regenerations.

Usage:  python tools/cov_summary.py [--report-dir <dir>] [--out doc/coverage.md]
        python tools/cov_summary.py --holes      # also list uncovered points to stderr
"""
import os
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
LIB = Path(os.environ.get("RETROSIM_BUILD", REPO.parent / "retrosim-build")) / "tools"
if not LIB.is_dir():
    sys.exit("cov_summary: missing ../retrosim-build sibling (check it out beside this repository)")
sys.path.insert(0, str(LIB))
import cov_summary_lib as cov  # noqa: E402

REPORT = cov.Report(
    repo=REPO,
    title="hh-hdmi RTL code coverage (Verilator)",
    body=[
        "- Suite (the benches `sim/vl/CMakeLists.txt` builds): the same "
        "self-checking benches `ninja sim` runs under iverilog, re-elaborated "
        "under Verilator with `--main`. Points are merged by logical identity "
        "across benches and instances (covered if any instance hit it).\n",
        "- Scope: coverage is instrumented on the synthesizable RTL only "
        "(`rtl/*.sv`); the testbenches are excluded by `sim/vl/coverage.vlt`.\n",
    ],
    sections=[cov.Section("RTL", cov.is_sv_under("rtl"))],
    notes={
        "hdmi_encoder.sv": "period sequencer, sync, DI_PIPE alignment",
        "hdmi_channel.sv": "8b/10b, control, TERC4, guard bands",
        "hdmi_packet.sv": "packet sequencer + BCH(8) parity",
        "hdmi_audio_src.sv": "audio divider, ACR, sample FIFO, InfoFrames",
        "hdmi_serializer.sv": "generic model only (vendor arms are primitives)",
        "hdmi_serializer_us.sv": "gearbox + generic model (OSERDESE3 arm is a primitive)",
        "hdmi_gearbox_10to8.sv": "double-buffered 10:8 gearbox",
        "edid_i2c.sv": "DDC/E-DDC bit engine + EDID store",
        "hdmi_cec.sv": "CEC RX/ACK/TX, key map, dump, One Touch Play",
    },
)

if __name__ == "__main__":
    raise SystemExit(cov.main(REPORT))
