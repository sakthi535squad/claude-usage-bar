#!/bin/bash
# Unit tests for the transcript reader, session model, pace forecast and theme
# formatting. Runs against fixtures in /tmp, so it needs no live Claude Code
# session and touches nothing under ~/.claude.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/testsrc build/themetestsrc
cp Tests/AgentParserTests.swift build/testsrc/main.swift
swiftc -lsqlite3 -o build/agenttest Sources/Agents.swift Sources/Titles.swift Sources/Transcripts.swift Sources/Pace.swift Sources/KeepWarm.swift build/testsrc/main.swift
build/agenttest
cp Tests/ThemeTests.swift build/themetestsrc/main.swift
swiftc -o build/themetest Sources/Format.swift Sources/Grid.swift build/themetestsrc/main.swift
build/themetest
