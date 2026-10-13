#!/bin/bash
# entrypoint.sh <target-host> [ssh-port] [https-port]
#
# Esegue ssh-audit, testssl.sh e nuclei contro <target-host>, uno alla volta,
# nello stesso formato raw-file/manifest usato da scripts/run-tool.sh in
# v1.0 (timestamp|tool|EXIT=n|path), cosi' la skill puo' riusare la stessa
# logica di lettura per comporre il report. Nessuna interpretazione: comandi
# fissi, nessuna decisione presa a runtime oltre a target/porte ricevute
# come argomenti.
#
# Output atteso in /output (da montare come volume al `podman run`):
#   /output/ssh-audit.raw
#   /output/testssl.raw
#   /output/nuclei.raw
#   /output/manifest.txt
set -u

TARGET="${1:-}"
SSH_PORT="${2:-22}"
HTTPS_PORT="${3:-443}"
OUTDIR="/output"

if [ -z "$TARGET" ]; then
    echo "USAGE_ERROR: specificare il target host (ed eventualmente ssh-port, https-port)" >&2
    exit 2
fi

mkdir -p "$OUTDIR"
MANIFEST="$OUTDIR/manifest.txt"

run_tool() {
    local tool="$1"
    local rawfile="$OUTDIR/${tool}.raw"
    local timestamp
    timestamp="$(date -Iseconds)"
    shift

    "$@" > "$rawfile" 2>&1
    local exit_code=$?

    echo "${timestamp}|${tool}|EXIT=${exit_code}|${rawfile}" >> "$MANIFEST"

    if [ "$exit_code" -eq 0 ]; then
        echo "STATUS=OK EXIT=${exit_code} OUTFILE=${rawfile}"
    else
        echo "STATUS=FAIL EXIT=${exit_code} OUTFILE=${rawfile}"
    fi
}

echo "--- ssh-audit su ${TARGET}:${SSH_PORT} ---"
run_tool ssh-audit ssh-audit "${TARGET}:${SSH_PORT}"

echo "--- testssl su ${TARGET}:${HTTPS_PORT} ---"
run_tool testssl testssl --quiet "${TARGET}:${HTTPS_PORT}"

echo "--- nuclei su ${TARGET} ---"
run_tool nuclei nuclei -u "https://${TARGET}" -t /opt/nuclei-templates -silent

echo "Audit container completato. Manifest: ${MANIFEST}"
