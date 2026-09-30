#!/bin/bash
# Forget Domine's audio capture (and later, microphone) permission so the prompt shows again.
# Useful because ad-hoc signed dev builds can end up with a stale grant after rebuilding.
tccutil reset AudioCapture com.ethankawley.Domine 2>/dev/null || true
tccutil reset Microphone com.ethankawley.Domine 2>/dev/null || true
echo "Permissions reset. Launch Domine to be asked again."
