#!/usr/bin/env python3
"""Removes build-machine details from the app's executables, before they're signed.

Compilers leave text behind: absolute paths from __FILE__, #filePath and generated bundle accessors, and Module/File.swift
names used in `try!` failure messages. Each match is overwritten in place, keeping the file's layout: only the text of
those failure messages changes. Usage: scrub-binaries.py <file>...
"""
import re
import sys
from pathlib import Path

HOME = str(Path.home()).encode()
PATTERNS = [
    re.compile(re.escape(HOME) + rb"/[^\0]*"),
    re.compile(rb"(?<=\0)[A-Za-z_][\w-]*/[\w+\-]+\.swift(?=\0)"),
]
# Rust panic locations in a prebuilt dependency: not NUL-terminated, so each is blanked with same-length filler.
RUST = re.compile(rb"/Users/runner/[\x21-\x7e]*?\.rs")


def blank(match):
    return b"?" + b"\0" * (len(match.group(0)) - 1)


for name in sys.argv[1:]:
    data = Path(name).read_bytes()
    total = 0
    for pattern in PATTERNS:
        data, count = pattern.subn(blank, data)
        total += count
    data, count = RUST.subn(lambda m: b"?" * len(m.group(0)), data)
    total += count
    Path(name).write_bytes(data)
    print(f"{Path(name).name}: {total} strings blanked")
