#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

TMP_BIN="$(mktemp "${TMPDIR:-/tmp}/LuminaLogicTests.XXXXXX")"
trap 'rm -f "$TMP_BIN"' EXIT

swiftc -DLUMINA_LOGIC_TESTS \
    DisplayLogic.swift \
    BetterDisplayOutputParser.swift \
    LuminaLogicTests.swift \
    -o "$TMP_BIN" \
    -swift-version 5 \
    -warn-concurrency \
    -strict-concurrency=complete \
    -O

"$TMP_BIN"
