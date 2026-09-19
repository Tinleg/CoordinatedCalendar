#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPM_SCRATCH="${COORDINATEDCALENDAR_SCRATCH:-/private/tmp/CoordinatedCalendar-spm-build}"
cd "$ROOT_DIR"

if command -v xattr >/dev/null 2>&1; then
  xattr -cr "$SPM_SCRATCH" .build 2>/dev/null || true
fi

swift test --scratch-path "$SPM_SCRATCH"
swift build -c release --scratch-path "$SPM_SCRATCH"
COORDINATEDCALENDAR_SCRATCH="$SPM_SCRATCH" ./scripts/package-app.sh

echo "Built CoordinatedCalendar.app at $ROOT_DIR/.build/CoordinatedCalendar.app"
