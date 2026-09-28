#!/bin/zsh
set -euo pipefail

project_root=${0:A:h:h}
cd "$project_root"

print -r -- "== Headless scenarios =="
swift run inbetween-scenario-runner --all --summary

print -r -- "== Swift tests =="
swift test

print -r -- "== Python tests =="
python3 -m unittest discover -s tools -p 'test_*.py' -v

print -r -- "FAST VERIFICATION PASSED"
