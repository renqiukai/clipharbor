#!/bin/sh
set -eu
cd "$(dirname "$0")"
mkdir -p .build
swiftc Sources/ClipHarbor/History.swift Sources/ClipHarbor/HistoryFile.swift Sources/ClipHarbor/ClipHarbor.swift Sources/ClipHarbor/WeChatExport.swift Sources/ClipHarbor/WeChatExportSession.swift Tests/*.swift -o .build/history-check
.build/history-check
