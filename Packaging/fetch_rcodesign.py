#!/usr/bin/env python3
"""Download a fixed upstream signing tool and verify the pinned release checksum."""
import hashlib
from pathlib import Path
import tarfile
import urllib.request

VERSION = "0.29.0"
ARCHIVE = f"apple-codesign-{VERSION}-macos-universal.tar.gz"
SHA256 = "d98372d5524226ccf9dc0eda03d4e4f5826182dabb2fc3f2bd303ed9113a748d"
URL = f"https://github.com/indygreg/apple-platform-rs/releases/download/apple-codesign%2F{VERSION}/{ARCHIVE}"


def fetch():
    cache = Path(__file__).resolve().parents[1] / ".build/tools"
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / ARCHIVE
    if not archive.exists() or hashlib.sha256(archive.read_bytes()).hexdigest() != SHA256:
        print("Загрузка rcodesign для локальной подписи…", flush=True)
        with urllib.request.urlopen(URL, timeout=60) as response:
            data = response.read()
        if hashlib.sha256(data).hexdigest() != SHA256:
            raise ValueError("Upstream rcodesign checksum mismatch")
        archive.write_bytes(data)
    target = cache / "rcodesign"
    with tarfile.open(archive) as source:
        member = next(m for m in source.getmembers() if Path(m.name).name == "rcodesign" and m.isfile())
        target.write_bytes(source.extractfile(member).read())
    target.chmod(0o755)
    return target


if __name__ == "__main__":
    print(fetch())
