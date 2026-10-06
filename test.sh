#!/bin/bash
# Unit tests for the transcript reader, session model and pace forecast. Runs against fixtures in /tmp,
# so it needs no live Claude Code session and touches nothing under ~/.claude.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/testsrc
cp Tests/AgentParserTests.swift build/testsrc/main.swift
swiftc -target "$(uname -m)-apple-macos13.0" -lsqlite3 -o build/agenttest Sources/Agents.swift Sources/Titles.swift Sources/Transcripts.swift Sources/Pace.swift Sources/KeepWarm.swift build/testsrc/main.swift
build/agenttest
