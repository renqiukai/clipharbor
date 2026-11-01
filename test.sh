#!/bin/sh
set -eu
cd "$(dirname "$0")"
mkdir -p .build
swiftc -D CLIPBOARD_TEST Sources/ClipHarbor/History.swift Sources/ClipHarbor/ClipHarbor.swift Sources/ClipHarbor/WeChatExport.swift Tests/main.swift -o .build/history-check
.build/history-check
