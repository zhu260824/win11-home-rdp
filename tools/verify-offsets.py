#!/usr/bin/env python3
"""Verify that an rdpwrap.ini offset fragment plausibly applies to a given termsrv.dll.

Why this exists
---------------
A wrong offset does not fail loudly: rdpwrap.dll happily writes bytes at the wrong
address inside the TermService process, which can crash svchost or silently corrupt
policy state. Offset tables copied from a neighbouring build are the usual cause.

What this checks (no disassembler required)
-------------------------------------------
1. every code patch offset lands inside the .text section
2. the SLInit hook offset lands inside .text as well
3. each SLInit global (bServerSku, bRemoteConnAllowed, ...) is referenced from
   .text through a RIP-relative operand -- if a claimed global is never touched by
   any code, it is almost certainly the wrong address

Usage
-----
    python tools/verify-offsets.py --dll C:\\Windows\\System32\\termsrv.dll
    python tools/verify-offsets.py --dll termsrv.dll --ini offsets/10.0.26100.9949.ini
    python tools/verify-offsets.py --dll termsrv.dll --section 10.0.26100.9949
"""

from __future__ import annotations

import argparse
import re
import struct
import sys

CODE_KEYS = ("SingleUserOffset", "DefPolicyOffset", "LocalOnlyOffset", "SLInitOffset")
SLINIT_NAMES = (
    "bInitialized", "bServerSku", "lMaxUserSessions", "bAppServerAllowed",
    "bRemoteConnAllowed", "bMultimonAllowed", "ulMaxDebugSessions", "bFUSEnabled",
)


class PE:
    def __init__(self, data: bytes) -> None:
        self.data = data
        if data[:2] != b"MZ":
            raise ValueError("not a PE file")
        e = struct.unpack_from("<I", data, 0x3C)[0]
        if data[e:e + 4] != b"PE\0\0":
            raise ValueError("missing PE signature")
        coff = e + 4
        nsec = struct.unpack_from("<H", data, coff + 2)[0]
        optsz = struct.unpack_from("<H", data, coff + 16)[0]
        sec0 = coff + 20 + optsz
        self.sections = []
        for i in range(nsec):
            o = sec0 + i * 40
            name = data[o:o + 8].rstrip(b"\0").decode("latin-1")
            vsize, vaddr, rsize, raddr = struct.unpack_from("<IIII", data, o + 8)
            self.sections.append(
                dict(name=name, va=vaddr, vsize=vsize, raw=raddr, rawsize=rsize)
            )

    def section_of(self, rva: int):
        for s in self.sections:
            if s["va"] <= rva < s["va"] + s["vsize"]:
                return s
        return None

    def in_text(self, rva: int) -> bool:
        s = self.section_of(rva)
        return bool(s and s["name"] == ".text")

    def read(self, rva: int, n: int) -> bytes:
        off = rva  # sections here are mapped with raw == va; fall back below
        s = self.section_of(rva)
        if s is not None and s["rawsize"]:
            off = s["raw"] + (rva - s["va"])
        return self.data[off:off + n]


def parse_ini(path: str) -> dict[str, dict[str, str]]:
    sections: dict[str, dict[str, str]] = {}
    cur = None
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith(";"):
                continue
            if line.startswith("[") and line.endswith("]"):
                cur = line[1:-1]
                sections.setdefault(cur, {})
            elif "=" in line and cur is not None:
                k, v = line.split("=", 1)
                sections[cur][k.strip()] = v.strip()
    return sections


def pick_section(sections, wanted: str | None) -> tuple[str, str]:
    """Return (main_section, slinit_section)."""
    if wanted:
        main = wanted if wanted in sections else None
    else:
        main = next((s for s in sections if re.fullmatch(r"10\.\d+\.\d+\.\d+", s)), None)
    if main is None:
        raise SystemExit("no suitable version section found in the ini")
    slinit = f"{main}-SLInit"
    return main, slinit if slinit in sections else ""


def count_rip_refs(pe: PE, target_rva: int, limit: int = 20) -> int:
    """Count RIP-relative operands in .text that resolve to target_rva."""
    hits = 0
    for s in pe.sections:
        if s["name"] != ".text" or not s["rawsize"]:
            continue
        start, end, raw = s["va"], s["va"] + s["vsize"], s["raw"]
        blob = pe.data[raw:raw + s["rawsize"]]
        for i in range(0, min(len(blob) - 6, end - start - 6)):
            # any modrm byte with mod=00 and rm=101 selects a RIP-relative disp32
            if (blob[i] & 0xC7) != 0x05:
                continue
            disp = struct.unpack_from("<i", blob, i + 1)[0]
            if (start + i) + 5 + disp == target_rva:
                hits += 1
                if hits >= limit:
                    return hits
    return hits


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dll", default=r"C:\Windows\System32\termsrv.dll")
    ap.add_argument("--ini", required=True)
    ap.add_argument("--section", default=None)
    args = ap.parse_args()

    pe = PE(open(args.dll, "rb").read())
    sections = parse_ini(args.ini)
    main_sec, slinit_sec = pick_section(sections, args.section)
    main = sections[main_sec]
    slinit = sections.get(slinit_sec, {})

    print(f"dll      : {args.dll}")
    print(f"section  : [{main_sec}]" + (f" + [{slinit_sec}]" if slinit_sec else ""))
    print(f"file size: {len(pe.data)} bytes, {len(pe.sections)} sections")
    print()

    failures = 0

    print("code patch sites")
    for key in CODE_KEYS:
        val = main.get(f"{key}.x64") or main.get(f"{key}.x86")
        if not val:
            continue
        off = int(val, 16)
        sec = pe.section_of(off)
        ok = pe.in_text(off)
        failures += 0 if ok else 1
        print(f"  {key:18s} {off:>#8x}  in .text={str(ok):5s}  "
              f"section={sec['name'] if sec else 'none':8s}  bytes={pe.read(off, 10).hex(' ')}")

    print()
    print("SLInit globals (must be referenced from .text)")
    for name in SLINIT_NAMES:
        val = slinit.get(f"{name}.x64") or slinit.get(f"{name}.x86")
        if not val:
            print(f"  {name:20s} not declared")
            failures += 1
            continue
        rva = int(val, 16)
        sec = pe.section_of(rva)
        refs = count_rip_refs(pe, rva)
        ok = refs > 0 and sec is not None
        failures += 0 if ok else 1
        print(f"  {name:20s} {rva:>#8x}  section={sec['name'] if sec else 'none':8s}  "
              f"refs={refs:<3d} {'OK' if ok else 'SUSPECT'}")

    print()
    if failures:
        print(f"RESULT: {failures} check(s) failed - do not use this offset set")
        return 1
    print("RESULT: all checks passed - offsets are structurally consistent with this binary")
    return 0


if __name__ == "__main__":
    sys.exit(main())
