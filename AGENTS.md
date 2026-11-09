<!-- SPDX-License-Identifier: MIT OR Apache-2.0 -->
<!-- SPDX-FileCopyrightText: 2026 Howard M. Harte -->
# hh-hdmi: agent and contributor guide

Setup and gate commands live in
[README.md](README.md); how each block works, and how it is verified, is in
[doc/hh-hdmi-design.md](doc/hh-hdmi-design.md). Humans and agents use the
same documents; read them before making changes. Every module, port and
parameter name in `rtl/` is public API that downstream designs instantiate
directly: never rename one for style. Keep the RTL free of
`unique`/`priority` case qualifiers (the design document explains why).
