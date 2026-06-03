#!/bin/bash
set -e

TMP_BIN="/tmp/LuminaBackendTests"

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
    -target arm64-apple-macosx13.0 \
    -framework AppKit \
    -framework Foundation \
    -O

"$TMP_BIN"
