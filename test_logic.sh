#!/bin/bash
set -euo pipefail

TMP_BIN="$(mktemp -t LuminaLogicTests.XXXXXX)"
trap 'rm -f "$TMP_BIN"' EXIT

swiftc -DLUMINA_LOGIC_TESTS \
    DisplayLogic.swift \
    BetterDisplayOutputParser.swift \
    LuminaLogicTests.swift \
    -o "$TMP_BIN" \
    -O

"$TMP_BIN"
