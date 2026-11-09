# hh-hdmi design

<!-- SPDX-License-Identifier: MIT OR Apache-2.0 -->
<!-- SPDX-FileCopyrightText: 2026 Howard M. Harte -->

For setup, build commands, and commit checks, see the [README](../README.md).
This document defines the design and its verification scope.

**Contents**

- [1. Purpose](#1-purpose)
- [2. Video architecture](#2-video-architecture)
- [3. `hdmi_encoder`](#3-hdmi_encoder)
- [4. `hdmi_channel`](#4-hdmi_channel)
- [5. `hdmi_packet`](#5-hdmi_packet)
- [6. `hdmi_audio_src`](#6-hdmi_audio_src)
- [7. Serializers](#7-serializers)
- [8. `edid_i2c`](#8-edid_i2c)
- [9. `hdmi_cec`](#9-hdmi_cec)
- [10. Building a source](#10-building-a-source)
- [11. Verification](#11-verification)

## 1. Purpose

The source side of an HDMI link for an FPGA design, as vendor-neutral
SystemVerilog building blocks: a TMDS encoder that carries video, L-PCM
audio and InfoFrames, the 10:1 serializers that put its symbols on the
wire, a DDC reader that fetches the sink's EDID for a processor to parse,
and a CEC follower that turns a TV remote into key inputs. A board top
supplies the clocks, the serializer instances, the differential buffers
and the mode timing; everything else is here.

| Module | File | Role |
|---|---|---|
| `hdmi_encoder` | `rtl/hdmi_encoder.sv` | the line and frame sequencer: video, guard bands, preambles, data islands, sync; drives three lanes |
| `hdmi_channel` | `rtl/hdmi_channel.sv` | one TMDS lane: 8b/10b video, control, TERC4, guard-band symbols |
| `hdmi_packet` | `rtl/hdmi_packet.sv` | serializes one 32-pixel data-island packet and computes its five BCH(8) parity bytes |
| `hdmi_audio_src` | `rtl/hdmi_audio_src.sv` | the packet content and schedule: audio samples, ACR, GCP, AVI, Audio and SPD InfoFrames, Null |
| `hdmi_serializer` | `rtl/hdmi_serializer.sv` | 10:1 serializer: Gowin `OSER10`, Xilinx 7-series `OSERDESE2` pair, or a generic simulation model |
| `hdmi_serializer_us` | `rtl/hdmi_serializer_us.sv` | 10:1 serializer for UltraScale/UltraScale+: a 10:8 gearbox into an 8:1 `OSERDESE3` |
| `hdmi_gearbox_10to8` | `rtl/hdmi_gearbox_10to8.sv` | the 10:8 gearbox alone, double-buffered, any number of lanes, for a serializer that takes bytes |
| `edid_i2c` | `rtl/edid_i2c.sv` | DDC/E-DDC master that reads up to four EDID blocks into a CPU-readable byte window |
| `hdmi_cec` | `rtl/hdmi_cec.sv` | CEC follower: ACK, remote keys through a parameter map, One Touch Play, OSD name, standby, a debug dump |
| `pll_video` | `pll/pll_video_60k.v`, `pll/pll_video_138k.v` | the 74.25 MHz pixel and 371.25 MHz 5x clocks from 50 MHz on the GW5AT-60 and GW5AST-138 (section 10) |

Module, port and parameter names are public API; downstream designs
instantiate them by name. Most pixel-domain modules use synchronous active-low
reset. `hdmi_channel` has no reset input: a non-video clock clears its running
disparity, so the caller must supply a control period before video. The generic
serializer's behavioral model also asserts reset
asynchronously; vendor branches use their primitive reset contracts. The
UltraScale+ gearbox has separate pixel- and word-domain reset requirements
(section 7). The `pll_video` wrappers have no reset input. Only serializers
and PLL wrappers instantiate vendor primitives.

<a id="2-the-video-path"></a>
## 2. Video architecture

```text
cx, cy ──► hdmi_encoder ──► hdmi_channel ×3 ──► tmds_b/g/r ──► serializer ×3 ──► OBUFDS/TLVDS
rgb    ──►   │   ▲                                 (clk_pix)        (clk_pix, 5× / 5/4×)
             ▼   │
        hdmi_audio_src ──► hdmi_packet
```

The board's scanout presents a raster position `cx`, `cy` and, one pixel
clock later, that position's pixel `rgb_r/g/b`. The encoder turns the
position into a period (video, video guard, preamble, island guard, island
or control) and the lanes turn the period and its data into 10-bit symbols.
Everything runs on the pixel clock; the serializers are the only blocks with
a faster clock.

### 2.1 Latency

`tmds_*` shows the symbol for raster position `cx` four pixel clocks after
`cx` is presented with `DI_PIPE = 1` (period flags, `DI_PIPE` alignment,
lane select, lane register), three with `DI_PIPE = 0`. The sink locks to the
symbols, so the latency matters only to a design that compares the output
with its own raster.

## 3. `hdmi_encoder`

### 3.1 Timing inputs

The geometry is a set of inputs rather than parameters, so one instance
drives any mode a mode table selects; tied to constants, synthesis folds it
to a fixed-mode encoder.

| Input | Meaning |
|---|---|
| `h_active`, `v_active` | visible columns and rows |
| `h_total`, `v_total` | the full line and frame, blanking included |
| `h_sync_off`, `h_sync_wid` | HSYNC starts `h_sync_off` pixels after the active area and lasts `h_sync_wid` |
| `v_sync_off`, `v_sync_wid` | VSYNC starts on line `v_active + v_sync_off`, at the HSYNC edge of the line before (CEA-861), and lasts `v_sync_wid` lines |
| `h_pol`, `v_pol` | 1 = the sync is high while asserted |
| `di_npackets` | data-island packets per line, 1 to 18 |
| `vic` | the AVI InfoFrame's video identification code (0 = none) |
| `aud_div_max`, `aud_div_frac` | pixel clocks per audio sample, `max + frac/256` |
| `aud_rate`, `aud_depth` | 48, 44.1 or 32 kHz; 16, 20 or 24 bits declared |

The sums the comparators need (`h_active + h_sync_off`, the island bounds,
`h_total - 10` and the rest) are registered from the inputs every clock, so
the comparisons run against registers. The inputs are quasi-static: change
them only with `rst_n` low and hold it low for at least two clocks after the
change.

### 3.2 The line

With `di_start = h_active + 14` and `di_end = di_start + 32 * di_npackets`:

| Columns | Period | Lanes 1 and 2 | Lane 0 |
|---|---|---|---|
| `[0, h_active)` on rows `< v_active` | video | 8b/10b of G and R | 8b/10b of B |
| `[di_start - 10, di_start - 2)` | island preamble | control, CTL0 = CTL2 = 1 | control `{VSYNC, HSYNC}` |
| `[di_start - 2, di_start)`, `[di_end, di_end + 2)` | island guard | `0100110011` | TERC4 `{1, 1, VSYNC, HSYNC}` |
| `[di_start, di_end)` | data island | TERC4 of the packet's subpacket bits | TERC4 `{D3, header bit, VSYNC, HSYNC}` |
| `[h_total - 10, h_total - 2)` before an active line | video preamble | control, CTL0 = 1 | control `{VSYNC, HSYNC}` |
| `[h_total - 2, h_total)` before an active line | video guard | `0100110011` (lane 1), `1011001100` (lane 2) | `1011001100` |
| anything else | control | control, CTL = 0 | control `{VSYNC, HSYNC}` |

A line is "before an active line" when it is `v_total - 1` or below
`v_active - 1`. The island must end before the video preamble, so a mode
needs `h_active + 26 + 32 * di_npackets <= h_total`; 640x480 fits four
packets, 720p ten, 1080p seven. `D3` is 0 on the island's first pixel and 1
on every other (HDMI 1.4 Figure 5-3). Lane 0 is blue, lane 1 green, lane 2
red. CTL1 and CTL3 are always 0 and are tied at the lane ports.

### 3.3 Packet timing

`packet_enable` pulses on the first pixel of each 32-pixel packet window,
which starts at `di_start + 32k`. It is registered from `cx + 1` so the
registered pulse lands on the same pixel an unregistered compare would, and
the window match uses `di_start[4:0]`, not a constant, so a mode whose
`h_active` is not a multiple of 32 (1680x1050) still switches packets on
window boundaries. `video_field_end` pulses two pixels before the end of the
last active line and resets the once-per-field InfoFrame flags.

### 3.4 `DI_PIPE`

`DI_PIPE = 1` (the default) registers the packet content at
`hdmi_packet`'s input, so the per-pixel BCH accumulate starts from a
register instead of the audio parity and packet-type mux cone; that is the
path that otherwise limits the pixel clock, and with it the encoder closes
about 150 MHz. The encoder delays the period flags, the pixel and the syncs
by the same pixel, so the output is bit-identical to `DI_PIPE = 0` one pixel
later.

### 3.5 DVI-only build

Defining `HDMI_DVI_ONLY` reduces the lane select to video or control: no
guard bands, preambles or islands, and no audio. It exists to tell a TMDS
lock failure from a data-island or InfoFrame rejection on a strict sink.

## 4. `hdmi_channel`

`mode` selects the symbol: 0 control, 1 video, 2 video guard, 3 TERC4,
4 island guard; 5 to 7 emit the control symbol. Video uses the DVI 1.0
8b/10b code: transition minimization by XOR or XNOR, then DC balance by
optional inversion against a running disparity. The disparity register is
the running disparity of the emitted symbols, so it is always even and its
low bit is constant; it is cleared outside the video period. The control,
TERC4 and guard-band tables are the spec's; the lane number `CN` selects the
per-lane guard symbols. The output is registered.

## 5. `hdmi_packet`

A packet is 32 pixels. Each pixel carries one header bit on lane 0 and two
bits of each of the four 56-bit subpackets on lanes 1 and 2 (even bits on
lane 1, odd on lane 2). The module shifts the 24-bit header and the
subpackets out over `counter` 0 to 31 and appends each one's BCH(8) parity
byte, computed bit-serially with right-shift feedback mask `0x83`. With
the first transmitted bit treated as the highest polynomial coefficient,
the independent bench divides by `G(x) = x^8 + x^7 + x^6 + 1` (`0x1C1`).
Parity is sent at pixels 24-31 for the header and 28-31 for the subpackets. `counter` runs
during the island and tells `hdmi_audio_src` where in the packet it is.

## 6. `hdmi_audio_src`

### 6.1 Schedule

At each packet slot the source sends the first of these that is due:

1. **ACR** when a new CTS measurement is ready (every N/128 samples).
2. **Audio sample** when a group of four samples is waiting.
3. **GCP**, **AVI**, **Audio** and **SPD InfoFrames**, each once per video
   field.
4. **Null** otherwise.

### 6.2 Audio

The sample clock is a clock enable from a fractional divider: the period
alternates between `aud_div_max` and `aud_div_max + 1` under an 8-bit phase
accumulator of `aud_div_frac`, so the mean is exact. 74.25 MHz at 48 kHz is
1546.875 clocks; truncating it leaves the delivered rate hundreds of ppm off
the declared one, which a sink that slaves to the declared rate hears as a
periodic slip. Samples come in on `audio_l`/`audio_r` in the pixel domain.

Four samples make a group; groups go into an eight-group FIFO, and the
scheduler copies the head group into per-packet registers when it schedules
an audio packet, so a packet's 32 pixels always read a frozen snapshot. A
group that arrives with the FIFO full is dropped. Each subpacket is one
IEC 60958 frame pair: the 16-bit samples in the top of the 24-bit sample
fields, the channel-status bit for that frame, valid and user 0, and even
parity. The channel status declares consumer L-PCM, the sample rate from
`aud_rate` and the word length from `aud_depth`. The packet header's B
nibble (HB2[7:4]) marks the subpacket that starts each 192-frame block.

<a id="63-audio-clock-regeneration"></a>
### 6.3 Audio clock regeneration

N is the standard clock-independent value for the rate (6144, 6272 or 4096).
CTS is measured: the pixel clocks counted across N/128 samples of the
source's own divider, so the regenerated clock tracks the pixel clock and
the divider exactly. `CLK_PIX_HZ` only seeds CTS before the first
measurement. Every subpacket of the ACR packet carries the same N and CTS.

### 6.4 InfoFrames and control packets

- **AVI** (type 0x82, version 2): RGB, full range, IT content, the `vic`
  input, and a picture aspect derived from the VIC (4:3, 16:9, or no data
  for VIC 0 and the 64:27 and 256:135 formats). `AVI_AFD_VALID` and
  `AVI_AFD` add an Active Format Description.
- **Audio** (0x84): two-channel L-PCM, the sample rate and size.
- **SPD** (0x83): `SPD_VENDOR` and `SPD_PRODUCT`, left-aligned and
  zero-padded, and `SPD_SDI`.
- **GCP** (0x03): sent every field because some sinks want one before they
  lock, with neither AV-Mute flag set and the color depth not indicated.
  Neither flag is asserted continuously, to avoid sink-specific mute behavior.

Each InfoFrame's checksum makes its header and body sum to 0 mod 256.

## 7. Serializers

### 7.1 `hdmi_serializer`

A 10:1 DDR serializer clocked by the pixel clock and a phase-related 5×
clock, LSB first. The arm is chosen at compile time: the Gowin `OSER10` by
default, the Xilinx 7-series `OSERDESE2` master/slave pair under
`VENDOR_XILINX`, or, under `PLL_SIM_FREE_RUN`, a generic model for a
simulation with no vendor library: a 5×-clocked shift register that loads
each symbol once per pixel and sends two bits per 5× cycle, the even bit in
the clock's high half and the odd bit in the low half.

On a GW2A, take the 5× clock from the rPLL's `CLKOUT` and derive the pixel
clock with `CLKDIV` `/5`; the rPLL's `CLKOUTD` divider is even-only and
cannot make it.

### 7.2 `hdmi_serializer_us`

UltraScale's `OSERDESE3` has no cascade and serializes at most 8:1, so this
module puts a 10:8 gearbox in front of it. Three clocks come from one MMCM:
pixel (F), word (F × 5/4) and bit (F × 5). The pixel side packs four symbols
into a 40-bit group and flips a toggle; the word side copies the group and
toggle every word clock and, on a toggle change, sends the group as five
bytes. Groups arrive exactly every five word clocks; `aligned` reports the
lock and the sticky `slip` a cadence fault. The pixel-to-word copy is timed
as an ordinary related-clock path, whose tightest edge pair is 1/(5F):
2.694 ns at 74.25 MHz, too tight at 148.5 MHz. Those paths must not be cut.

### 7.3 `hdmi_gearbox_10to8`

The same 10:8 conversion for any number of lanes, for a serializer that
takes bytes (an UltraScale+ native-mode `TX_BITSLICE`), built to close at
1080p. The pixel side writes each group into one of two buffers alternately,
so a buffer holds still for ten word clocks; the word side brings the toggle
through a two-flop synchronizer and loads the buffer every fifth word clock
by its own count. The buffer-to-word paths are then a 2-cycle multicycle
crossing and the toggle an asynchronous one; the header gives the
constraints. Until aligned the bytes are zero, and a missing or mistimed
toggle clears `aligned_o` and sets `slip_o`. A stopped word clock cannot report a fault, and lost whole
toggle periods can be unobservable. Reset both domains after PLL/clock changes
before qualifying output.

## 8. `edid_i2c`

An open-loop I2C master: it drives SCL itself from a quarter-bit divider of
`CLK_HZ / I2C_HZ` and never waits on the bus, so a stuck sink cannot hang
it. A read starts after reset, on a rising edge of `hpd` (synchronized), and
on `start`; a trigger while `busy` is ignored. The completion cycle has
`busy` low and accepts a new trigger, including a one-clock `start` pulse.

```text
segment 0:  START  A0  00  RSTART  A1  read 256 (NAK the last)  STOP
segment 1:  START  60  01  RSTART  A0  00  RSTART  A1  read 256  STOP
```

Segment 1 (blocks 2 and 3, through the E-DDC segment pointer) is read only
when block 0's byte 126, the extension count, is 2 or more. Bytes land in a
512-byte block RAM; `cpu_addr`/`cpu_data` read it with one clock of latency.
The store is not cleared between reads, so after a one-segment read bytes
256-511 still hold the last segment-1 read; firmware reads the extension
count first.

Every written byte's ACK is checked. A NAK in segment 0 means no sink: the
read stops with `err` set and `valid` clear, and the store keeps its old
contents. A NAK in segment 1 means no E-DDC: the read stops, keeping
`valid` for blocks 0 and 1, without `err`. `valid` therefore means "the last
read completed without a base-EDID NAK"; checking the header and block
checksums is the CPU's job. A state register corrupted to a code outside the
enum releases both lines and finishes without `done`, so the next trigger
starts clean.

The asynchronous `sda_in` pad passes through two `ASYNC_REG` flip-flops before
ACK and data sampling in phase 2. The quarter-bit divider must be at least four
core clocks (`CLK_HZ >= 16 * I2C_HZ`); invalid configurations fail elaboration.
The minimum quarter provides time for both stages and the sampling edge after
SDA changes during SCL low. Board timing must also include slave data-valid
latency, level shifters, pull-ups and rise time. This open-loop master does not
support clock stretching. A synchronizer does not replace those timing checks.

Consumers must validate each advertised EDID block's checksum before using it.
The [Console 60K probe](../hw/console60k/README.md) records the qualification
procedure and its single-sink scope. Behavioral tests include delayed SDA at
the minimum divider, ACK/NAK handling, no sink and reset during a read.

## 9. `hdmi_cec`

### 9.1 Receiver

CEC is one open-drain wire. Its asynchronous input passes through two
`ASYNC_REG` flip-flops before edge detection. The receiver measures the low time of each bit
from the falling edge and classifies it on the rising edge: longer than the
midpoint of a '0' and a start bit's low time is a start bit, shorter than
the midpoint of a '1' and a '0' is a '1', anything between is a '0'. A
shorter pulse on an idle line is ignored. Each block is eight data bits,
EOM and ACK. A frame is at most 16 blocks; the low-time counter saturates,
so an idle line of any length is harmless.

The follower drives the ACK slot low for blocks whose destination (block 0's
low nibble) is `OUR_ADDR`. It leaves the slot of a broadcast frame
(destination F) high: on a broadcast a low ACK slot means rejection.

### 9.2 Messages

| Received | Action |
|---|---|
| `<User Control Pressed>` (0x44) to us | drop every held key, raise the keys whose `KEY_UI` code matches the operand, clear standby, arm the `HOLD_CYC` one-shot |
| `<User Control Released>` (0x45) to us | drop every held key |
| `<Give OSD Name>` (0x46) to us | queue `<Set OSD Name>` with `OSD_NAME` |
| `<Standby>` (0x36) to us or broadcast | set `cec_standby` |
| anything else | nothing (it is still dumped) |

Header-only polling frames are acknowledged when directed to us and dumped,
but do not dispatch an opcode. Messages without their required operands are
also ignored; retained bytes from an earlier frame never supply missing data.
A frame without EOM in its first 16 blocks is discarded. The receiver waits
for another START and does not interpret the oversized frame's tail as a command.

A key with `KEY_PULSE` set is a one-clock pulse per Pressed instead of a
held level. The hold one-shot drops held keys if the TV's auto-repeat stops
without a Released.

### 9.3 Transmitter

Three messages go out: `<Set OSD Name>` to the TV, and the One Touch Play
pair `<Image View On>` (to the TV) and `<Active Source>` (broadcast, with
`PHYS_ADDR`), due `BOOT_CYC` clocks after reset. Each is a pending request of
its own, and one arbiter starts the next frame when the transmitter is idle
and no frame is being received: the OSD reply first, then Image View On,
then Active Source. OSD requests share one pending bit and coalesce while
waiting; the boot sequence retains its own progress. The transmitter does not
check the ACK of its own frames.

### 9.4 Debug dump

Completed frames are formatted on `uart_data`/`uart_we` as hex bytes separated
by spaces and ended by a newline, paced by `uart_ready`. This diagnostic reads
the shared receive array. A following frame can overwrite bytes before a
stalled dump finishes, and its completion restarts the dump. Drain the UART
promptly; the output is a best-effort view of recent traffic.

### 9.5 Parameters

The bit timings (`START_LOW`, `START_PER`, `ZERO_LOW`, `ONE_LOW`,
`BIT_PER`), `HOLD_CYC` and `BOOT_CYC` are in clocks; the defaults are the
spec values at 75 MHz. `OSD_NAME` is 1 to 14 characters; the module
left-aligns it and counts them at elaboration.

## 10. Building a source

A 720p source on a GW2A: an rPLL whose `CLKOUT` is 371.25 MHz, a `CLKDIV /5`
for the 74.25 MHz pixel clock, a raster counter for `cx`/`cy`, one
`hdmi_encoder` with the timing inputs tied to the 720p constants
(1280/1650, 720/750, sync offsets 110/5, widths 40/5, positive syncs, ten
packets, VIC 4, `aud_div_max` 1546 and `aud_div_frac` 224 for 48 kHz), three
`hdmi_serializer` instances and a fourth for the clock lane (a constant
`10'b0000011111`), and four `TLVDS_OBUF`. An `edid_i2c` and an `hdmi_cec` on
the board's free-running clock, with their open-drain pads at the top,
complete it. A multi-mode design drives the timing inputs from a mode table
and holds the encoder's reset across each switch (section 3.1).

On the GW5A Tang Console boards, `pll/pll_video_60k.v` (two `PLLA`) or
`pll/pll_video_138k.v` (two generic `PLL`, since the GW5AST-138 has no `PLLA`)
supplies both clocks from the 50 MHz oscillator: 50 MHz to 27 MHz, then 27 MHz
to 371.25 MHz, and a `CLKDIV /5` with `CALIB=1` for the pixel clock. One PLL
hop cannot reach 74.25 MHz from 50 MHz inside the PFD range, and the nearest
single-hop clocks (73.333 and 75.0 MHz) fall outside CEA-861's ±0.5% VIC
tolerance. Both files define `pll_video` with ports `clkin`, `clkout` (pixel),
`clkoutd` (5x) and `lock` (both PLLs locked), so a board top builds against
either; under `PLL_SIM_FREE_RUN` both clocks free-run for simulation.

### 10.1 Integration rules

* **The serializer instance and the differential buffers.** `TLVDS_OBUF` or
  `ELVDS_OBUF` on Gowin (a board with 100 Ω across the pads and AC coupling
  is a true-LVDS load and takes `TLVDS_OBUF` with
  `IO_TYPE=LVDS25 DRIVE=3.5 BANK_VCCIO=3.3`; an emulated-differential network
  takes `ELVDS_OBUF`), `OBUFDS` with `IOSTANDARD TMDS_33` on 7-series,
  `OBUFDS` with a 1.2 V standard such as `DIFF_SSTL12` on an UltraScale+ HP
  bank. `OSER10` is the same primitive on GW2A and GW5A, so no RTL here is
  per-family.

This RTL carries no `unique`, `unique0` or `priority` case qualifiers. Gowin
V1.9.12.03 treats them as a hard don't-care license rather than an assertion
and can build a functionally wrong netlist while every simulator says the
source is fine: measured on a GW5A design where a `unique`-qualified case
took the wrong arm of a compiled if/else chain, with the failure changing as
the placement changed and timing signing off with margin. Verilator and
Vivado build such source correctly, so no simulation gate can catch it.
Every case statement that needs one has an explicit `default:` arm instead,
which is already unambiguous. Keep it that way when adding RTL. (Icarus also
warns `Case unique/unique0 qualities are ignored`.)

## 11. Verification

<a id="111-the-benches"></a>
### 11.1 Simulation

`ninja` in `sim/` runs Verible lint and the format check; `ninja sim` runs
`gate.sh`, every self-checking iverilog bench below. Each prints `PASS`,
exits non-zero on a failure, and the script ends with `ALL BENCHES PASS`.

| Bench | What it proves |
|---|---|
| `tb_di_equiv` | `DI_PIPE` 0 and 1 produce bit-identical lanes one pixel apart |
| `tb_di_bch` | islands decoded as a sink does: BCH, island length, IEC parity, sample pairing, ACR N, AVI checksum, the audio header and D3, at aligned and unaligned `h_active` |
| `tb_sync_timing` | HSYNC and VSYNC land exactly where CEA-861 puts them, positive and negative, `DI_PIPE` 0 and 1 |
| `tb_encoder_modes` | one encoder switched at run time through five real and five synthetic modes that together set and clear every bit of every timing, VIC and audio input; every pixel of every lane against the period, sync and video model; BCH on every packet |
| `tb_encoder_modes` with `HDMI_DVI_ONLY` | the same raster carries only video and control |
| `tb_channel` | three lanes against a DVI 1.0 encoder model, symbol for symbol: all 256 bytes, runs that drive the disparity to both extremes, random runs; the sink's decode, the disparity bound, control, guard, TERC4 and modes 5-7 |
| `tb_packet` | `DI_PIPE` 0 and 1 side by side, every pixel of random, all-zero and all-one packets against a model whose ECC is polynomial division by G(x) = 1 + x^6 + x^7 + x^8, not the RTL's shift register; the pipelined build one pixel later; a one-clock reset mid-packet |
| `tb_audio_src` | the source against a scoreboard: every audio packet's samples in order (drops only on overflow), channel status, parity and B flag; ACR N, and CTS out to the longest period (44.1 kHz at the widest divider); AVI for all 256 VICs; AIF, SPD, GCP and Null; seven rate/depth/divider configurations, an overflow, a mid-stream reset |
| `tb_spd`, `tb_avi` | the SPD and AVI InfoFrames from their parameters |
| `tb_edid_i2c` | reads against a behavioral EEPROM, the whole 512-byte store compared after each: auto, hot-plug with triggers while busy, start with 255 extensions, no sink, reset mid-read, a forced illegal state, and a start pulse in the non-busy completion cycle |
| `tb_edid_delayed` | the complete EDID bench with 90 ns slave delay and the minimum four-clock quarter-bit divider |
| `tb_edid_i2c_err` | a base NAK aborts with `err`; an E-DDC NAK keeps blocks 0-1 |
| `tb_cec` | a behavioral TV: input synchronizer staging, One Touch Play (and deferred behind a frame), ACK, every key, a hold of exactly `HOLD_CYC` clocks, pulse, the OSD reply at the 16-block maximum, other-address and broadcast frames, standby, a glitch, a 16-block dump paced by `uart_ready`, the saturated low-time counter, and short frames that must not reuse stale opcodes or operands |
| `tb_serializer` | the generic `hdmi_serializer` model puts every symbol on the wire in order, LSB first, across reset phases and a mid-stream reset |
| `tb_serializer_us`, `tb_gearbox` | bit-exact from reset at every phase and reset order; a stopped pixel side sets `slip` and re-aligns; a word-side reset clears both flags |
| `tb_pll_video` | each `pll_video` wrapper's `PLL_SIM_FREE_RUN` clocks: `lock` high, the pixel clock at 74.25 MHz and the 5x clock at 371.25 MHz to 0.1%; primitive behavior requires vendor timing analysis and board qualification |

Every check added to a bench was mutation-tested: the RTL was broken in the
way the check guards against and the bench failed.

### 11.2 Coverage

`sim/vl/cov.ps1` re-elaborates the same benches under Verilator with line,
branch and toggle instrumentation and merges the results;
`tools/cov_summary.py` renders [`coverage.md`](coverage.md), the committed
baseline, whose triage names the reason behind every remaining uncovered
point.

The baseline owns all coverage figures. The constant functions that run only at
elaboration (`width_of`, `osd_align` and `osd_count` in `hdmi_cec`;
`left_align`, `byte_sum` and `spd_body` in `hdmi_audio_src`) sit between
`// verilator coverage_off` and `coverage_on` comments, because their bodies
never execute in simulation. Other constant fields include packet header
and subpacket bits, the even running disparity's low bit, InfoFrame and
channel-status bytes, and the CEC transmit buffer selected by `OSD_NAME`.
The baseline's triage explains their effect on the measured toggle coverage.

### 11.3 Formal verification

The optional `ninja formal` target checks channel coding/disparity for all three
lanes, packet/BCH and `DI_PIPE` latency, audio FIFO preservation and packet
snapshots, combined arbitrary-payload gearbox ordering/ownership across the
phase/reset matrix, and pixel-clock stall/recovery contracts. `ninja formal-negative` also checks
intentional false properties. The [formal coverage map](formal-coverage.md)
owns the exact matrix, reset/clock assumptions, retained-cell census and limits.
All listed safety jobs are unbounded proofs; the matrix states the exact
4:5 clock relation, reset-release cases and clock-fault recovery envelope.
Vendor PLL/SERDES behavior, routed multicycle timing and analog metastability
remain board obligations.
