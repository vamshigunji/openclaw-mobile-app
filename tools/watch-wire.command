#!/bin/zsh
# OpenClaw Mobile — live WS payload tap (DEBUG builds only)
# → app → gateway     ← gateway → app
echo "Watching OpenClaw Mobile wire traffic (Ctrl-C to stop)…"
xcrun simctl spawn booted log stream \
  --predicate 'subsystem == "com.openclaw.mobile"' \
  --level info \
  --style compact
