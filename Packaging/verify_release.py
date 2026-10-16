#!/usr/bin/env python3
"""Refuse ad-hoc or unexpected identities in a public release."""
import os
import plistlib
import re
import subprocess
import sys
from pathlib import Path


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True)


def main():
    app = Path(sys.argv[1]).resolve()
    expected = os.environ.get("SIGNING_IDENTITY", "").upper()
    if not re.fullmatch(r"[A-F0-9]{40}", expected):
        raise ValueError("SIGNING_IDENTITY must be the SHA-1 of the permanent certificate")
    run("codesign", "--verify", "--strict", "--all-architectures", str(app))
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if info["CFBundleIdentifier"] != "local.controlflip.mac":
        raise ValueError("Bundle identifier changed; permissions may no longer match")
    run("lipo", str(app / "Contents/MacOS/ControlFlip"), "-verify_arch", "arm64", "x86_64")
    requirements = []
    for arch in ("arm64", "x86_64"):
        display = run("codesign", "-d", "--arch", arch, "-r-", str(app))
        requirement = next(line for line in (display.stdout + display.stderr).splitlines()
                           if "designated =>" in line)
        if "cdhash" in requirement or ("certificate" not in requirement and "anchor" not in requirement):
            raise ValueError("A permanent certificate-based requirement is required")
        run("codesign", "--verify", "--strict", "--arch", arch, "-R",
            f'=certificate leaf = H"{expected}"', str(app))
        requirements.append(requirement)
    if requirements[0] != requirements[1]:
        raise ValueError("The architectures have different designated requirements")
    print("Release identity verified for arm64 and x86_64.")


if __name__ == "__main__":
    main()
