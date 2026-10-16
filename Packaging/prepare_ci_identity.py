#!/usr/bin/env python3
"""Load GitHub signing secrets into private temporary files, without logging them."""
import base64
import os
from pathlib import Path
import re
import shutil
import sys

if os.environ.get("GITHUB_ACTIONS") != "true":
    raise RuntimeError("This helper is restricted to CI")
directory = Path(os.environ["RUNNER_TEMP"]) / "controlflip-signing"
if "--cleanup" in sys.argv:
    if directory.exists():
        shutil.rmtree(directory)
    sys.exit(0)
os.umask(0o077)
encoded = os.environ["SIGNING_P12_BASE64"]
password = os.environ["SIGNING_P12_PASSWORD"]
fingerprint = os.environ["SIGNING_CERT_SHA1"].upper()
if not encoded or not password or not re.fullmatch(r"[A-F0-9]{40}", fingerprint):
    raise ValueError("Configure all three SIGNING_* secrets")
directory.mkdir(mode=0o700, exist_ok=True)
p12 = directory / "author.p12"
password_file = directory / "password.txt"
p12.write_bytes(base64.b64decode(encoded, validate=True))
password_file.write_text(password + "\n")
with open(os.environ["GITHUB_ENV"], "a") as stream:
    stream.write(f"SIGNING_P12_FILE={p12}\nSIGNING_PASSWORD_FILE={password_file}\n")
print("Persistent author identity prepared. Private material was not logged.")
