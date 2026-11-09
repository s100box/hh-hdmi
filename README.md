# hh-hdmi

<!-- SPDX-License-Identifier: MIT OR Apache-2.0 -->
<!-- SPDX-FileCopyrightText: 2026 Howard M. Harte -->

SystemVerilog HDMI source building blocks: a TMDS encoder with audio and
InfoFrames, Gowin and AMD/Xilinx serializers, an EDID reader, a CEC
follower, and the 720p video PLLs for the Gowin Tang Console boards. Only the
serializers and the PLLs contain vendor primitives; the benches use portable
models.

## Documentation

| Document | Contents |
|---|---|
| [Design](doc/hh-hdmi-design.md) | Architecture, interfaces, integration rules, and verification scope. |
| [Coverage](doc/coverage.md) | Measured coverage and explanations of uncovered points. |
| [Formal coverage](doc/formal-coverage.md) | Property matrix, assumptions, audited results and limits. |
| [RTL style](https://github.com/s100box/retrosim-build/blob/main/doc/rtl-style.md) | Shared formatting, local lint exceptions, and checked scope. |

## Repository layout

| Path | Contents |
|---|---|
| `rtl/` | Reusable cores; module inventory in the design document. |
| `pll/` | 1280x720p60 video-clock wrappers for the GW5A Tang Console 60K and 138K. |
| `hh-hdmi.core` | FuseSoC file lists and targets. |
| `sim/` | Benches, lint rules, and optional coverage tools. |
| `tools/` | Coverage report generation. |
| `doc/` | Design and coverage references. |
| `hw/console60k/` | Optional binary EDID probe and host qualification procedure. |

## Requirements

### Tools

| Tool | Verified version | Used for |
|---|---|---|
| Python | 3.10 or later | shared hook checks and coverage/report tools |
| [Verible](https://github.com/chipsalliance/verible) | v0.0-4053 | lint and format check (`ninja`) |
| [Icarus Verilog](https://github.com/steveicarus/iverilog) (`iverilog`, `vvp`) from the [OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build) | 14.0 | the benches (`ninja sim`) |
| [Ninja](https://ninja-build.org/) | 1.10 or later | drives both |
| SymbiYosys, Yosys/slang, ABC and Boolector from the OSS CAD Suite | Yosys 0.65 | optional formal suite |
| [Verilator](https://www.veripool.org/verilator/) from the OSS CAD Suite, with Visual Studio (MSVC) and its CMake | 5.049 | the coverage suite (`sim/vl/cov.ps1`), opt-in |
| Gowin EDA | V1.9.12.03 | synthesis of the `OSER10` branch (board designs, not this repo) |
| AMD Vivado | 2025.1 | synthesis of the `OSERDESE2`/`OSERDESE3` branches (board designs, not this repo) |

`sim/lint.sh` finds `verible-verilog-lint` through `VERIBLE`, PATH, or a
release unzipped under `~/verible/`, and the formatter beside it; `sim/gate.sh` finds the OSS CAD Suite through
`OSS_CAD_SUITE`, PATH, or `~/oss-cad-suite`. Either script skips itself when
its tool is absent, so a clone with one tool still gates on that one.

### Sibling repositories

`sim/build.ninja` includes `../../retrosim-build/toolchain.ninja`, the
workspace's single file of tool install paths, so the checkout must sit next
to its sibling:

| Repository | Provides |
|---|---|
| `retrosim-build` | `toolchain.ninja`, which defines `bash_exe`, the Git for Windows bash the ninja rules run the two scripts with (a bare `bash` on a Windows host with WSL resolves to the Linux one); `hooks/gate-env.sh`, which the pre-commit hook sources to put Verible and the OSS CAD Suite on PATH; and `tools/vl_cov.ps1` + `tools/cov_summary_lib.py`, the coverage suite's driver and report renderer (which find Verilator and the MSVC build environment through `toolchain.ps1` and `tools/vs_env.ps1`) |

```text
<workspace>/
  hh-hdmi/
  retrosim-build/
```

The two scripts also run directly from any bash: `bash sim/lint.sh` and
`bash sim/gate.sh`.

## Getting started

Add the files in [hh-hdmi.core](hh-hdmi.core) to the consuming design, or use
the FuseSoC manifest directly. The RTL itself has no sibling dependencies.
The board top supplies clocks, output buffers, timing inputs, and pin constraints.
See the [integration example](doc/hh-hdmi-design.md#10-building-a-source) and
[serializer contracts](doc/hh-hdmi-design.md#7-serializers) before wiring them.

Module, port, and parameter names are public API. The
[RTL conventions](doc/hh-hdmi-design.md#101-integration-rules) also explain
the restriction on `unique` and `priority` qualifiers.

## Verification

From the repository root:

```sh
ninja -C sim                  # lint and format checks
ninja -C sim sim              # self-checking Icarus benches
ninja -C sim formal           # optional scoped SymbiYosys checks
ninja -C sim formal-negative  # include false-property controls
```

The scripts can also run directly as `bash sim/lint.sh` and `bash sim/gate.sh`.
Each bench must print `PASS`; the runner ends with `ALL BENCHES PASS`.
The [verification specification](doc/hh-hdmi-design.md#11-verification)
lists the checks performed by each bench.

### Coverage

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File sim/vl/cov.ps1
python tools/cov_summary.py
```

The optional suite writes annotated results under `sim/vl/build/cov/report/`
and regenerates [doc/coverage.md](doc/coverage.md), preserving its hole triage.
Refresh the baseline after RTL or bench changes; `--holes` lists uncovered points.
The CMake project uses the shared
[`retrosim_verilate` wrapper](https://github.com/s100box/retrosim-build/blob/main/doc/host-services.md#3-manifest-benches-and-coverage)
to refresh generated source lists after HDL or include changes.

### Commit checks

Enable the hook with `git config core.hooksPath .githooks`. It runs lint,
format checks, and simulation. `.rules.verible_lint` allows uppercase
localparams; `.verible.format` defines the shared formatting rules.
Reformat with `verible-verilog-format --flagfile=.verible.format --inplace <file>`.

## License

Licensed under either [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE), at your option.

### Contributions

Unless you explicitly state otherwise, any contribution intentionally
submitted for inclusion in the work by you, as defined in the Apache-2.0
license, shall be dual licensed as above, without any additional terms or
conditions.
