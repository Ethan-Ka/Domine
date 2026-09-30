#!/bin/bash
# Stream Domine's log messages (all levels). Ctrl-C to stop.
exec log stream --level debug --style compact --predicate 'subsystem == "com.ethankawley.Domine"'
