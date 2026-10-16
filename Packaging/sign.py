#!/usr/bin/env python3
"""Sign with an author-owned P12 locally; no Keychain or remote signing service."""
import os
from pathlib import Path
import re
import subprocess
import sys
from fetch_rcodesign import fetch


def run(*args, input_data=None):
    return subprocess.run(args, input=input_data, check=True, capture_output=True).stdout


def main():
    target = Path(sys.argv[1]).resolve()
    root = Path(__file__).resolve().parents[1]
    p12 = Path(os.environ["SIGNING_P12_FILE"]).expanduser().resolve()
    password_file = Path(os.environ["SIGNING_PASSWORD_FILE"]).expanduser().resolve()
    expected = os.environ.get("SIGNING_IDENTITY", "").upper()
    if not re.fullmatch(r"[A-F0-9]{40}", expected):
        raise ValueError("A permanent certificate fingerprint is required")
    if os.environ.get("SIGNING_STYLE", "self-signed") != "self-signed":
        raise ValueError("This P12 workflow currently supports self-signed releases")
    cert = run("openssl", "pkcs12", "-in", str(p12), "-clcerts", "-nokeys",
               "-passin", f"file:{password_file}")
    fingerprint = run("openssl", "x509", "-noout", "-fingerprint", "-sha1", input_data=cert)
    actual = fingerprint.decode().strip().split("=", 1)[1].replace(":", "").upper()
    if actual != expected:
        raise ValueError("The P12 certificate differs from SIGNING_IDENTITY")
    tool = fetch()
    args = [str(tool), "--config-file", "/dev/null", "sign", "--p12-file", str(p12),
            "--p12-password-file", str(password_file), "--timestamp-url", "none"]
    if target.suffix == ".app":
        identifier = "local.controlflip.mac"
        requirement = f'=identifier "{identifier}" and certificate leaf = H"{expected}"'
        compiled = root / ".build/author-requirements.bin"
        run("csreq", "-r", requirement, "-b", str(compiled))
        args += ["--code-requirements-file", str(compiled)]
    elif target.suffix == ".dmg":
        args += ["--binary-identifier", "local.controlflip.diskimage"]
    else:
        raise ValueError("Only the app and its DMG may be signed by this helper")
    # Explicit local P12 source and timestamp=none: signing never sends the key anywhere.
    subprocess.run(args + [str(target)], check=True)
    subprocess.run(["codesign", "--verify", "--strict", str(target)], check=True)


if __name__ == "__main__":
    main()
