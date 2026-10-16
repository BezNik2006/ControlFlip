#!/usr/bin/env python3
"""Build a signed installer using the existing author key, without Keychain access."""
import os
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
directory = Path(sys.argv[1]).expanduser().resolve()
env = dict(os.environ,
    SIGNING_IDENTITY=(directory / "fingerprint.txt").read_text().strip(),
    SIGNING_P12_FILE=str(directory / "author.p12"),
    SIGNING_PASSWORD_FILE=str(directory / "password.txt"),
    SIGNING_STYLE="self-signed")
subprocess.run([str(root / "release.command")], cwd=root, env=env, check=True)
