#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
CPU_ARCH=$(uname -m)
mkdir -p .build
xcrun swiftc -swift-version 5 -j 1 -whole-module-optimization -target "$CPU_ARCH-apple-macosx13.0" \
  -module-cache-path "$PWD/.build/ModuleCache" Source/Core.swift Tests/main.swift -o .build/CoreTests
codesign --force --sign - .build/CoreTests
.build/CoreTests
