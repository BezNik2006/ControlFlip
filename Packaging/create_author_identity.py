#!/usr/bin/env python3
"""Create one permanent author identity, outside the repository. Never run per release."""
import os
from pathlib import Path
import secrets
import subprocess
import sys

CONFIG = """[req]
prompt = no
distinguished_name = identity
x509_extensions = code_signing
[identity]
CN = ControlFlip Author Code Signing
O = ControlFlip
[code_signing]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
"""


def run(*args):
    result = subprocess.run(args, capture_output=True)
    if result.returncode:
        # Never log arguments to commands that handle private key material.
        raise RuntimeError(f"{args[0]} {args[1]} failed (exit {result.returncode})")
    return result.stdout


def main():
    if len(sys.argv) != 2:
        raise ValueError("Usage: python3 Packaging/create_author_identity.py /private/backup/location")
    directory = Path(sys.argv[1]).expanduser().resolve()
    repo = Path(__file__).resolve().parents[1]
    if directory == repo or repo in directory.parents:
        raise ValueError("Signing keys must be stored outside the public project")
    os.umask(0o077)
    # Refuse to replace an existing identity, even after a partially failed setup.
    directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    (directory / ".gitignore").write_text("*\n")
    config = directory / "openssl.cnf"
    config.write_text(CONFIG)
    password = secrets.token_urlsafe(40)
    os.environ["CONTROLFLIP_SIGNING_PASSWORD"] = password
    password_file = directory / "password.txt"
    password_file.write_text(password + "\n")
    private_key = directory / "author.key"
    certificate = directory / "author.pem"
    p12 = directory / "author.p12"
    run("openssl", "req", "-x509", "-newkey", "rsa:3072", "-sha256", "-days", "7300",
        "-config", str(config), "-passout", f"file:{password_file}",
        "-keyout", str(private_key), "-out", str(certificate))
    run("openssl", "pkcs12", "-export", "-inkey", str(private_key), "-in", str(certificate),
        "-name", "ControlFlip Author Code Signing", "-out", str(p12),
        "-passin", "env:CONTROLFLIP_SIGNING_PASSWORD", "-passout", f"file:{password_file}",
        "-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES", "-macalg", "sha1")
    fingerprint = run("openssl", "x509", "-in", str(certificate), "-noout", "-fingerprint", "-sha1")
    fingerprint = fingerprint.decode().strip().split("=", 1)[1].replace(":", "").upper()
    (directory / "fingerprint.txt").write_text(fingerprint + "\n")
    (directory / "README-private.txt").write_text(
        "Постоянная подпись автора ControlFlip. Не загружайте эту папку в GitHub или чат.\n"
        "author.p12 — сертификат и закрытый ключ, password.txt — пароль, fingerprint.txt — открытый идентификатор.\n"
        "Сохраните защищённую резервную копию этой папки. Не создавайте новый ключ при каждом выпуске.\n")
    print("Next: prepare_local_release.py to build a signed installer.")
    print("Author identity created. SHA-1: " + fingerprint)
    print("Private material is stored outside the public project.")


if __name__ == "__main__":
    main()
