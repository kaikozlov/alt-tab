#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DD="$ROOT/build/DerivedData"
xcodebuild -project "$ROOT/AltTab.xcodeproj" -scheme AltTabTests -configuration Debug -derivedDataPath "$DD" build ONLY_ACTIVE_ARCH=YES
exec "$DD/Build/Products/Debug/AltTabTests"
