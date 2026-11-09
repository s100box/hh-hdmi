# hh-hdmi formal verification coverage

<!-- SPDX-License-Identifier: MIT OR Apache-2.0 -->
<!-- SPDX-FileCopyrightText: 2026 Howard M. Harte -->

[README](../README.md) · [Design](hh-hdmi-design.md#113-formal-verification)

## 1. Scope

The optional suite establishes the digital contracts below, not complete HDMI
compliance. All positive safety jobs use unbounded induction or PDR; configured
depths are induction horizons, not execution limits. Simulation coverage is a
separate measure. RTL/properties use Yosys/slang; small native Yosys wrappers
drive non-stuttering global time for the multi-clock models.

## 2. Property and parameter matrix

| Family | Configuration | Contract |
|---|---|---|
| Channel | `CN=0,1,2` together; video, island, control and mode inputs free | Submitted video byte recovered by independent decode; emitted-symbol disparity accounting/bounds; control, TERC4 and guard tables; non-video disparity reset |
| Packet | `DI_PIPE=0,1` together; header/subpacket bits free | Counter/one-hot alignment, BCH residue zero after payload/parity, output and internal-state pipeline equivalence at one-cycle latency |
| Audio | 8-group FIFO; divider 4, fraction 0, 48 kHz declaration, 16-bit samples, VIC 4 | Accepted-group ordering, count/pointer bounds, preserved packet snapshots and no empty pop |
| Gearbox local data | One lane, common clock/reset, arbitrary symbols | Four-symbol packing, selected-buffer serialization, shift preservation and sticky slip |
| Gearbox stream | One lane, arbitrary complete 10-bit symbols; four word-clock phase offsets; three initial reset-release orders | Combined end-to-end byte ordering, independent five-byte reference cadence, consecutive group ownership, buffer initialization/selection, alignment and no slip at the required 4:5 rate |
| Gearbox clock faults | One lane; four phase offsets; arbitrary pixel-clock pauses and coordinated reset requests; word clock continuously runs | Missing-group detection, sticky slip, bounded reacquisition after uninterrupted clocks, and reset clearing/recovery |

The stream reference gathers symbols by shifting them into a 40-bit group.
It derives initial alignment from its own group-event pipeline and then emits
five reference bytes per group. Expected byte timing does not use the DUT's
counter. Internal buffer/pointer relationships are additional proved invariants,
not assumptions about the DUT. A cover reaches at least three transferred
groups with a nonzero byte, and a false output claim yields a counterexample.

## 3. Assumptions and interpretation

The channel has no reset pin: initial mode is constrained to control so the
first clock establishes zero disparity. Later mode/data inputs are free.
Packet, audio and local-data jobs start in reset; later reset is free. Packet
`active` stays low during reset.

Audio requests occur only at 32-pixel boundaries; slots may be omitted. The
accelerated sample divider exercises full queues and wraps. A full-queue push
is dropped by the RTL and is not an accepted group. The proof does not promise
delivery if slots never arrive or cover every audio collector/rate configuration.

Stream clock rising-edge periods are five global units for pixels and four for
words, preserving exactly four pixel periods per five word periods. All four
integer word-phase offsets are elaborated. Resets are initially asserted
together; release pairs `(pixel,word)` are `(31,31)`, `(31,39)` and `(39,31)`
global units. This provides enough clock edges to settle the unreset toggle
pipeline and exercises simultaneous, pixel-first and word-first release.
The twelve elaborations do not quantify over every reset skew or physical phase.

The fault model permits arbitrary pixel-clock pauses. A coordinated reset forces
both clocks to run while reset is held for 31 global units. After alignment,
ten word clocks without a new source group require lost alignment and sticky
slip. After 63 uninterrupted global units at the nominal ratio following the
last pause/reset, alignment must have recovered; slip remains sticky until
word reset. Covers exercise loss, recovery, and reset after a slip.

A stopped word domain cannot observe faults. Losing whole toggle periods can
also be unobservable; neither lossless data during clock faults nor detection
of every word-clock interruption is promised. Reset both domains after PLL or
clock changes before qualifying output. Vendor SERDES/PLL behavior, analog
metastability, routed multicycle timing, duty cycles and Gray/toggle settling
are physical integration obligations outside RTL formal.

## 4. Audit and reproduction

```sh
ninja -C sim formal
ninja -C sim formal-negative
```

Use the documented Yosys 0.65/slang, SymbiYosys, ABC and Boolector toolchain.
The shared runner creates fresh ignored work directories under
`sim/formal/build/`. Its `audit.json` records copied-source SHA-256 values,
verdicts, exit codes, logs and retained assertion/assumption/cover counts.
Counts describe this frontend/model, not a percentage of correctness.
Manifest assertion/cover floors retain the audited census, so losing properties
requires an explicit matrix review rather than passing a merely nonempty model.

| Positive safety job | Assert | Assume |
|---|---:|---:|
| Channel | 27 | 1 |
| Packet | 22 | 2 |
| Audio | 24 | 1 |
| Gearbox local data | 6 | 1 |
| Each gearbox stream phase/reset case | 20 | 0 |
| Each gearbox fault phase | 6 | 0 |

Covers retain six channel, one packet, three audio, two local-data, one per
stream case, and three per fault case. Each family has a false-property control
that must return FAIL with an actual VCD counterexample. ERROR, UNKNOWN, timeout,
empty models and missing traces fail the audit. Positive proofs and covers must
pass as well; these controls do not constitute mutation coverage of every fault.

## 5. Limits

CEC, EDID protocol safety, encoder scheduling and vendor serializers have no
formal jobs here. Complete HDMI/CTA/IEC compliance, every audio/gearbox parameter,
arbitrary clock-fault detection and physical timing remain outside this matrix.
Retain simulation, coverage, timing and hardware gates.
