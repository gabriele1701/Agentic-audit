#!/bin/bash
# check-tool.sh <toolname>
# Verifica se un tool è presente nel PATH.
# Exit 0 = presente, Exit 1 = assente, Exit 2 = uso errato / tool non gestito.
set -u

TOOL="${1:-}"

if [ -z "$TOOL" ]; then
    echo "USAGE_ERROR: specificare il nome del tool" >&2
    exit 2
fi

case "$TOOL" in
    lynis|trivy|nmap|debsecan|chkrootkit|rkhunter)
        ;;
    *)
        echo "UNKNOWN_TOOL: $TOOL non è tra i tool gestiti da questo audit" >&2
        exit 2
        ;;
esac

if command -v "$TOOL" >/dev/null 2>&1; then
    echo "PRESENT: $TOOL trovato in $(command -v "$TOOL")"
    exit 0
else
    echo "MISSING: $TOOL non trovato nel PATH"
    exit 1
fi
