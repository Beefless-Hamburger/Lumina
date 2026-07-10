#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

TMP_BIN="$(mktemp "${TMPDIR:-/tmp}/LuminaBackendTests.XXXXXX")"
trap 'rm -f "$TMP_BIN"' EXIT

swiftc -DLUMINA_BACKEND_TESTS \
    DisplayBackend.swift \
    BetterDisplayTransport.swift \
    AsyncProcessRunner.swift \
    DisplaySleeper.swift \
    ShutdownHeartbeatController.swift \
    BetterDisplayOutputParser.swift \
    DisplayLogic.swift \
    BetterDisplayService.swift \
    LuminaBackendTests.swift \
    SystemBetterDisplayTransport.swift \
    -o "$TMP_BIN" \
    -framework AppKit \
    -framework Foundation \
    -swift-version 5 \
    -warn-concurrency \
    -strict-concurrency=complete \
    -O

"$TMP_BIN"
