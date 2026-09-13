#!/usr/bin/env python3
"""Reject developer-machine dylib dependencies in a built RoamShot.app."""
import argparse
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("app", type=Path)
args = parser.parse_args()
checked = 0
errors = []
for binary in args.app.rglob("*"):
    if not binary.is_file():
        continue
    kind = subprocess.check_output(["file", "-b", str(binary)], text=True)
    if "Mach-O" not in kind:
        continue
    checked += 1
    output = subprocess.check_output(["xcrun", "otool", "-L", str(binary)], text=True)
    for line in output.splitlines()[1:]:
        dependency = line.strip().split(" (compatibility version", 1)[0]
        if (dependency.startswith("/") and not dependency.startswith(("/System/Library/", "/usr/lib/"))) or "libroamshot_gyroflow.dylib" in dependency:
            errors.append(f"{binary.name}: {dependency}")
if errors or not checked:
    raise SystemExit("Invalid app linkage:\n" + "\n".join(errors or ["No Mach-O binaries found"]))
print(f"Checked {checked} Mach-O binaries: no external Gyroflow dylib or developer-machine dependencies")
