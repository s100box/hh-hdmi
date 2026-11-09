#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# SPDX-FileCopyrightText: 2026 Howard M. Harte
# Verible lint over the hh-hdmi RTL, then the Verible format check (--verify
# against ../.verible.format) over the RTL and the benches. Stamps lint.ok on success.
set -euo pipefail
cd "$(dirname "$0")"

# Resolve verible-verilog-lint: an explicit $VERIBLE wins, else PATH, else a release
# unzipped under ~/verible/. If none is found, skip gracefully (stamp lint.ok, exit 0)
# so a plain clone without verible still gates on the sims -- override with
# VERIBLE=/path/to/verible-verilog-lint.
VERIBLE="${VERIBLE:-}"
if [ -z "$VERIBLE" ]; then
  if command -v verible-verilog-lint >/dev/null 2>&1; then
    VERIBLE=verible-verilog-lint
  else
    for base in "$HOME" "${USERPROFILE:-}" "/c/Users/${USERNAME:-${USER:-}}"; do
      [ -n "$base" ] || continue
      command -v cygpath >/dev/null 2>&1 && base="$(cygpath -u "$base" 2>/dev/null || echo "$base")"
      for c in "$base"/verible/*/verible-verilog-lint "$base"/verible/*/verible-verilog-lint.exe; do
        [ -x "$c" ] && { VERIBLE="$c"; break 2; }
      done
    done
  fi
fi
if [ -z "$VERIBLE" ] || ! command -v "$VERIBLE" >/dev/null 2>&1; then
  echo "lint: verible not found (set VERIBLE or add to PATH) -- skipping"
  echo lint-ok > lint.ok
  exit 0
fi

RTL="../rtl/hdmi_channel.sv ../rtl/hdmi_packet.sv ../rtl/hdmi_audio_src.sv
     ../rtl/hdmi_encoder.sv ../rtl/hdmi_serializer.sv ../rtl/hdmi_serializer_us.sv
     ../rtl/hdmi_gearbox_10to8.sv ../rtl/edid_i2c.sv ../rtl/hdmi_cec.sv
     ../pll/pll_video_60k.v ../pll/pll_video_138k.v
     formal/channel_formal.sv formal/packet_formal.sv formal/audio_formal.sv
     formal/gearbox_data_formal.sv
     formal/gearbox_stream_formal.sv formal/gearbox_stream_clock_formal.sv
     formal/gearbox_fault_formal.sv formal/gearbox_fault_clock_formal.sv
     ../hw/console60k/edid_probe.sv"
TB="tb_di_equiv.sv tb_di_bch.sv tb_sync_timing.sv tb_encoder_modes.sv tb_channel.sv tb_packet.sv
    tb_audio_src.sv tb_spd.sv tb_avi.sv tb_edid_i2c.sv tb_edid_i2c_err.sv tb_cec.sv
    tb_serializer.sv tb_serializer_us.sv tb_gearbox.sv tb_pll_video.sv"

# shellcheck disable=SC2086
"$VERIBLE" --rules_config ../.rules.verible_lint $RTL

# Format check with the formatter beside the linter: every file must already be
# in the ../.verible.format style (apply it with --inplace, without --verify).
FORMAT="${VERIBLE%verible-verilog-lint*}verible-verilog-format${VERIBLE##*verible-verilog-lint}"
command -v "$FORMAT" >/dev/null 2>&1 || FORMAT=verible-verilog-format
if command -v "$FORMAT" >/dev/null 2>&1; then
  # shellcheck disable=SC2086
  "$FORMAT" --flagfile=../.verible.format --inplace --verify $RTL $TB
else
  echo "lint: verible-verilog-format not found beside the linter -- format check skipped"
fi
echo lint-ok > lint.ok
