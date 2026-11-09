#!/usr/bin/env python3
# SPDX-License-Identifier: MIT OR Apache-2.0
# SPDX-FileCopyrightText: 2026 Howard M. Harte
"""Validate repeated binary EDID responses from edid_probe (115200 8N1)."""
import argparse
import hashlib
import json
from pathlib import Path
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "retrosim-build/tools"))
from bridgeport import open_port


def response(port, timeout):
    """Find the packet prefix, then read its fixed-length status and byte window."""
    deadline = time.monotonic() + timeout
    data = bytearray()
    while time.monotonic() < deadline:
        data.extend(port.read(517))
        start = data.find(b"EDID")
        if start >= 0 and len(data) >= start + 517:
            return bytes(data[start + 4:start + 517])
    raise TimeoutError("incomplete EDID response")


def validate(packet):
    status, edid = packet[0], packet[1:]
    if status != 1 or edid[:8] != b"\0\xff\xff\xff\xff\xff\xff\0":
        raise ValueError(f"invalid EDID status/header: {status:#x}")
    blocks = min(4, 1 + edid[126])
    sums = [sum(edid[i*128:(i+1)*128]) & 255 for i in range(blocks)]
    if any(sums):
        raise ValueError(f"EDID checksum failures: {sums}")
    return edid[:blocks*128], sums


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("port")
    parser.add_argument("--reads", type=int, default=20)
    parser.add_argument("--timeout", type=float, default=5)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.reads < 1 or args.timeout <= 0:
        parser.error("reads and timeout must be positive")
    args.output.mkdir(parents=True, exist_ok=True)
    reference = None
    with open_port(args.port, 115200, timeout=0.05, dtr=False, rts=False,
                   xonxoff=False, rtscts=False, dsrdtr=False) as port:
        port.reset_input_buffer()
        for i in range(args.reads):
            port.write(b"r")
            packet = response(port, args.timeout)
            edid, sums = validate(packet)
            (args.output / f"read-{i:03d}.bin").write_bytes(packet)
            if reference is not None and edid != reference:
                raise ValueError(f"EDID changed on read {i}")
            reference = edid
    result = dict(reads=args.reads, blocks=len(reference)//128, checksums=sums,
                  sha256=hashlib.sha256(reference).hexdigest(), identical=True)
    (args.output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result))


if __name__ == "__main__":
    main()
