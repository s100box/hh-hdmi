# Console 60K EDID qualification probe

<!-- SPDX-License-Identifier: MIT OR Apache-2.0 -->
<!-- SPDX-FileCopyrightText: 2026 Howard M. Harte -->

<a id="purpose"></a>
Read the physical HDMI sink through `edid_i2c` without an 8051, printf, or video
pipeline. Binary UART output lets the host validate every advertised block and
compare repeated reads independently of a firmware decoder.

## Documentation

| Document | Contents |
|---|---|
| [Project README](../../README.md) | Shared tool requirements and library entry points. |
| [EDID design](../../doc/hh-hdmi-design.md#8-edid_i2c) | Reader interface, synchronization and timing limits. |

## Repository layout

| Path | Contents |
|---|---|
| `edid_probe.sv` | Board top and binary UART response. |
| `probe.cst`, `probe.sdc` | Pin and timing constraints. |
| `build.sh`, `build.tcl` | Gowin synthesis and volatile programming. |
| `qualify.py` | Repeated-read and EDID checksum validator. |

## Requirements

Tang Console 60K (GW5AT-LV60PG484AC1/I0), an attached HDMI sink, Gowin EDA,
Python with pyserial, and sibling `hh-uart` / `retrosim-build` checkouts.
`probe.cst` owns the board pins. DDC uses open-drain pads and board pull-ups;
check electrical compatibility before using another board. The host script uses
the shared bridge-aware serial opener and keeps DTR/RTS deasserted.

<a id="procedure"></a>
## Getting started

From this directory in Bash, with the shared tool environment on PATH:

```sh
./build.sh synth
./build.sh prog
```

`prog` loads volatile SRAM only.
The probe reads at 100 kHz from a 50 MHz clock. It emits `EDID`, one status byte
(`bit0=valid`, `bit1=error`), then the complete 512-byte CPU window. ASCII `r`
requests another read while idle. The validator requires valid status, the EDID
header, zero checksums for up to four advertised blocks, and identical valid
bytes across all requested reads. Output files are evidence for that run; keep
them outside tracked source or in an ignored output directory.

## Verification

From this directory, with the probe loaded and its console port available:

```sh
python qualify.py PORT --reads 20 --output results
```

Replace `PORT` with the board's console port. The validator exits zero on
success and nonzero on failed qualification.

<a id="qualified-scope"></a>
### Qualified scope

The Console 60K attached to a Ugreen UHD HDMI capture stick passed 20 identical
reads of its two advertised blocks. Both checksums were zero. The 256-byte
SHA-256 was `61fc6e51f5b4c879be1d7ecd97ea52ab1dd8276a0ed9abc96ec27fb37f5befd0`.
The probe's routed 50 MHz clock met timing with 153.534 MHz reported Fmax and
all five SDC constraints active. The normal `hdmi-tester` Console 60K image
also met timing; its firmware hex dump matched these binary bytes exactly.

This is one board/sink pair. It does not qualify other pull-ups, level shifters,
sink delays, clock stretching, or physical metastability behavior. The delayed-
SDA Icarus case separately exercises the minimum divider and ACK/data sampling.

## License

See the repository [license](../../README.md#license).
