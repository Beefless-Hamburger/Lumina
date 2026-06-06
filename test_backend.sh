#!/bin/bash
set -euo pipefail

TMP_BIN="$(mktemp -t LuminaBackendTests.XXXXXX)"
trap 'rm -f "$TMP_BIN"' EXIT

swiftc -DLUMINA_BACKEND_TESTS \
    DisplayBackend.swift \
    BetterDisplayTransport.swift \
    DisplaySleeper.swift \
    BetterDisplayOutputParser.swift \
    DisplayLogic.swift \
    BetterDisplayService.swift \
    LuminaBackendTests.swift \
    SystemBetterDisplayTransport.swift \
    -o "$TMP_BIN" \
    -framework AppKit \
    -framework Foundation \
    -O

"$TMP_BIN"
