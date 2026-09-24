#!/bin/bash
# Unit tests for the subagent transcript parser. Runs against fixtures in /tmp,
# so it needs no live Claude Code session and touches nothing under ~/.claude.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/testsrc
cp Tests/AgentParserTests.swift build/testsrc/main.swift
swiftc -o build/agenttest Sources/Agents.swift build/testsrc/main.swift
build/agenttest | tee /tmp/agenttest-out.txt
! grep -q FAIL /tmp/agenttest-out.txt
