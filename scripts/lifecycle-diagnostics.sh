#!/bin/zsh
set -euo pipefail

diagnostic_file="${HOME}/Library/Application Support/Inbetween/lifecycle-diagnostics.jsonl"

case "${1:-show}" in
    path)
        print -r -- "$diagnostic_file"
        ;;
    show)
        if [[ -f "$diagnostic_file" ]]; then
            tail -n 200 "$diagnostic_file"
        else
            print -r -- "No lifecycle diagnostic log exists yet: $diagnostic_file"
        fi
        ;;
    clear)
        mkdir -p "${diagnostic_file:h}"
        : > "$diagnostic_file"
        chmod 600 "$diagnostic_file"
        print -r -- "Cleared lifecycle diagnostic log: $diagnostic_file"
        ;;
    *)
        print -u2 -r -- "Usage: $0 [path|show|clear]"
        exit 64
        ;;
esac
