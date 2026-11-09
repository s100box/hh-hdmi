#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
# SPDX-FileCopyrightText: 2026 Howard M. Harte
# Run the self-checking iverilog benches for the hh-hdmi cores. Every bench is
# prim-free (the vendor primitives live only in the serializers, which the benches
# take in their generic simulation form), so a plain iverilog runs them with no
# vendor library.
# Each bench prints PASS on success; this script fails if any bench does not.
set -euo pipefail
cd "$(dirname "$0")"
# Locate iverilog / vvp: an explicit $OSS_CAD_SUITE wins, else PATH, else an OSS CAD
# Suite unzipped under the user's home (mirrors lint.sh's Verible discovery; $HOME can
# be redirected, e.g. Cadence sets it to C:\SPB_Data, so also try $USERPROFILE and
# /c/Users/<name>). If none is found, skip gracefully (exit 0) so a plain clone
# without iverilog still gates on lint -- override with OSS_CAD_SUITE=/path or PATH.
if [ -z "${OSS_CAD_SUITE:-}" ] && ! command -v iverilog >/dev/null 2>&1; then
  for base in "$HOME" "${USERPROFILE:-}" "/c/Users/${USERNAME:-${USER:-}}"; do
    [ -n "$base" ] || continue
    command -v cygpath >/dev/null 2>&1 && base="$(cygpath -u "$base" 2>/dev/null || echo "$base")"
    if [ -x "$base/oss-cad-suite/bin/iverilog" ] || [ -x "$base/oss-cad-suite/bin/iverilog.exe" ]; then
      OSS_CAD_SUITE="$base/oss-cad-suite"; break
    fi
  done
fi
# Prepend both bin/ and lib/ (the lib/ is needed on Windows -- bin/ alone silently
# exits 127 on missing DLLs). Normalize a Windows root (C:\... / C:/...) to a POSIX
# path first: a raw drive-letter colon would split PATH on the ':' and lose entries.
if [ -n "${OSS_CAD_SUITE:-}" ]; then
  ocs="$OSS_CAD_SUITE"
  command -v cygpath >/dev/null 2>&1 && ocs="$(cygpath -u "$ocs")"
  export PATH="$ocs/bin:$ocs/lib:$PATH"
fi
if ! command -v iverilog >/dev/null 2>&1; then
  echo "gate: iverilog not found (set OSS_CAD_SUITE or add to PATH) -- skipping benches"
  exit 0
fi

fail=0
run() {  # <name> <toplevel> [iverilog options] <sources...>
  local name=$1 top=$2; shift 2
  iverilog -g2012 -s "$top" -o "$name.vvp" "$@" 2>/dev/null
  local out; out=$(vvp "$name.vvp" 2>&1)
  if echo "$out" | grep -q "PASS"; then
    echo "[$name] $(echo "$out" | grep PASS | head -1)"
  else
    echo "[$name] FAIL"; echo "$out" | tail -8; fail=1
  fi
}

# Encoder: the data-island pipeline (DI_PIPE) is bit-identical to the reference.
run tb_di_equiv tb_di_equiv tb_di_equiv.sv ../rtl/hdmi_encoder.sv \
    ../rtl/hdmi_audio_src.sv ../rtl/hdmi_packet.sv ../rtl/hdmi_channel.sv
# Encoder: data-island ECC + content integrity, at aligned AND unaligned h_active
# (h_active % 32 != 0, the 1680x1050 class, exercises the packet-window alignment).
run tb_di_bch   tb_di_bch   tb_di_bch.sv   ../rtl/hdmi_encoder.sv \
    ../rtl/hdmi_audio_src.sv ../rtl/hdmi_packet.sv ../rtl/hdmi_channel.sv
# Encoder: HSYNC/VSYNC land exactly where CEA-861 puts them against the video,
# decoded from the TMDS lanes as a sink sees them.
run tb_sync_timing tb_sync_timing tb_sync_timing.sv ../rtl/hdmi_encoder.sv \
    ../rtl/hdmi_audio_src.sv ../rtl/hdmi_packet.sv ../rtl/hdmi_channel.sv
# Encoder: one instance reconfigured at run time across ten modes, every pixel of
# every lane checked against the period, sync and video model; then the same
# raster through the DVI-only build.
run tb_encoder_modes tb_encoder_modes tb_encoder_modes.sv ../rtl/hdmi_encoder.sv \
    ../rtl/hdmi_audio_src.sv ../rtl/hdmi_packet.sv ../rtl/hdmi_channel.sv
run tb_encoder_dvi tb_encoder_modes -DHDMI_DVI_ONLY tb_encoder_modes.sv \
    ../rtl/hdmi_encoder.sv ../rtl/hdmi_audio_src.sv ../rtl/hdmi_packet.sv ../rtl/hdmi_channel.sv
# One TMDS lane of each kind against the DVI 1.0 / HDMI coding model.
run tb_channel  tb_channel      tb_channel.sv      ../rtl/hdmi_channel.sv
# Packet assembly and BCH against a polynomial-division model, DI_PIPE 0 and 1.
run tb_packet   tb_packet       tb_packet.sv       ../rtl/hdmi_packet.sv
# Audio source: the island schedule, audio samples, ACR, and every InfoFrame.
run tb_audio_src tb_audio_src   tb_audio_src.sv    ../rtl/hdmi_audio_src.sv
# Audio source: the SPD InfoFrame comes from the SPD_* parameters.
run tb_spd      tb_spd          tb_spd.sv          ../rtl/hdmi_audio_src.sv
# Audio source: the AVI InfoFrame's active format comes from AVI_AFD_VALID/AVI_AFD.
run tb_avi      tb_avi          tb_avi.sv          ../rtl/hdmi_audio_src.sv
# DDC/E-DDC EDID reader: happy path + error handling.
run tb_edid     tb_edid_i2c     tb_edid_i2c.sv     ../rtl/edid_i2c.sv
run tb_edid_delayed tb_edid_i2c -Ptb_edid_i2c.SDA_DELAY_NS=90 -Ptb_edid_i2c.BUS_QUARTER=4 \
    tb_edid_i2c.sv ../rtl/edid_i2c.sv
run tb_edid_err tb_edid_i2c_err tb_edid_i2c_err.sv ../rtl/edid_i2c.sv
# CEC follower.
run tb_cec      tb_cec          tb_cec.sv          ../rtl/hdmi_cec.sv
# The generic 10:1 serializer model: every symbol on the wire in order, LSB first.
run tb_serializer tb_serializer -DPLL_SIM_FREE_RUN tb_serializer.sv ../rtl/hdmi_serializer.sv
# UltraScale serializer: 10:8 gearbox + 8:1 DDR, bit-exact from reset, no slips.
run tb_serializer_us tb_serializer_us tb_serializer_us.sv ../rtl/hdmi_serializer_us.sv
# 10:8 gearbox for a native-mode serializer: every lane bit-exact from reset at
# every word-clock phase, a stopped pixel side reported and re-aligned.
run tb_gearbox tb_gearbox tb_gearbox.sv ../rtl/hdmi_gearbox_10to8.sv
run tb_pll_video_60k tb_pll_video -DPLL_SIM_FREE_RUN tb_pll_video.sv ../pll/pll_video_60k.v
run tb_pll_video_138k tb_pll_video -DPLL_SIM_FREE_RUN tb_pll_video.sv ../pll/pll_video_138k.v

[ "$fail" -eq 0 ] && echo "ALL BENCHES PASS" || { echo "BENCH FAILURE"; exit 1; }
