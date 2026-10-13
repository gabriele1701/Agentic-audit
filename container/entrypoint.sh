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
# I tre tool vengono eseguiti TUTTI, sempre, indipendentemente dall'esito dei
# precedenti: il container e' un singolo `podman run` effimero, non c'e' modo
# di fermarsi a meta' e chiedere conferma. L'exit code di ciascuno finisce nel
# manifest; l'interpretazione resta all'agente e all'utente.
#
# Output in /output (da montare come volume al `podman run`):
#   /output/ssh-audit.raw
#   /output/testssl.raw
#   /output/nuclei.raw
#   /output/manifest.txt
#   /output/versions.txt   (versioni pinnate, copiate dall'immagine)
#
# Tutti e tre i tool sono invocati con l'output colorato disabilitato
# (ssh-audit -n, testssl --color 0, nuclei -nc): i file .raw vengono
# trascritti letteralmente nel report dei log grezzi, e i codici ANSI li
# renderebbero illeggibili.
set -u

TARGET="${1:-}"
SSH_PORT="${2:-22}"
HTTPS_PORT="${3:-443}"
OUTDIR="/output"
VERSIONS_FILE="/opt/.audit-versions"

if [ -z "$TARGET" ]; then
    echo "USAGE_ERROR: specificare il target host (ed eventualmente ssh-port, https-port)" >&2
    exit 2
fi

mkdir -p "$OUTDIR"
MANIFEST="$OUTDIR/manifest.txt"

# Provenienza: le versioni sono quelle pinnate e verificate in build-time,
# scritte nell'immagine dal Containerfile. Non vengono interrogate a runtime
# (ssh-audit non ha un flag --version) ne' ricostruite dall'agente.
if [ -f "$VERSIONS_FILE" ]; then
    cp "$VERSIONS_FILE" "$OUTDIR/versions.txt"
else
    echo "VERSIONS_UNAVAILABLE: ${VERSIONS_FILE} non presente nell'immagine" > "$OUTDIR/versions.txt"
fi

run_tool() {
    local tool="$1"
    shift
    local rawfile="$OUTDIR/${tool}.raw"
    local timestamp
    timestamp="$(date -Iseconds)"

    # Il comando effettivo viene scritto in testa al file .raw: cosi' il
    # report puo' citarlo come dato verificabile invece di farselo
    # raccontare dall'agente.
    {
        echo "--- tool: ${tool} ---"
        echo "--- comando: $* ---"
        echo "--- avvio: ${timestamp} ---"
        echo "---"
    } > "$rawfile"

    "$@" >> "$rawfile" 2>&1
    local exit_code=$?

    echo "${timestamp}|${tool}|EXIT=${exit_code}|${rawfile}" >> "$MANIFEST"

    if [ "$exit_code" -eq 0 ]; then
        echo "STATUS=OK EXIT=${exit_code} OUTFILE=${rawfile}"
    else
        echo "STATUS=FAIL EXIT=${exit_code} OUTFILE=${rawfile}"
    fi
}

echo "--- ssh-audit su ${TARGET}:${SSH_PORT} ---"
run_tool ssh-audit ssh-audit -n "${TARGET}:${SSH_PORT}"

# --warnings batch: testssl senza questo flag fa `read` da stdin su ogni
# warning di test (bloccante in un container non interattivo). "batch" lo
# rende non interattivo e si ferma sull'errore invece di proseguire a
# tentoni - coerente con il resto del progetto, che preferisce fallire in
# modo esplicito piuttosto che produrre dati parziali silenziosamente.
echo "--- testssl su ${TARGET}:${HTTPS_PORT} ---"
run_tool testssl testssl --quiet --color 0 --warnings batch "${TARGET}:${HTTPS_PORT}"

echo "--- nuclei su ${TARGET} ---"
run_tool nuclei nuclei -u "https://${TARGET}" -t /opt/nuclei-templates -silent -nc

echo "Audit container completato. Manifest: ${MANIFEST}"
