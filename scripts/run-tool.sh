#!/bin/bash
# run-tool.sh <toolname> <output-dir>
# Esegue il comando fisso per il tool, scrive l'output grezzo in <output-dir>/<tool>.raw
# e aggiunge una riga al manifest. Nessuna interpretazione: comando e nome file
# sono fissi per ciascun tool, non decisi a runtime.
set -u

TOOL="${1:-}"
OUTDIR="${2:-}"

if [ -z "$TOOL" ] || [ -z "$OUTDIR" ]; then
    echo "USAGE_ERROR: specificare tool e output-dir" >&2
    exit 2
fi

mkdir -p "$OUTDIR"
RAWFILE="$OUTDIR/${TOOL}.raw"
MANIFEST="$OUTDIR/manifest.txt"
TIMESTAMP="$(date -Iseconds)"

run_lynis() {
    sudo lynis audit system --quiet > "$RAWFILE" 2>&1
    echo "---LYNIS-REPORT-DAT---" >> "$RAWFILE"
    sudo cat /var/log/lynis-report.dat >> "$RAWFILE" 2>&1
}

run_trivy() {
    {
        echo "---TRIVY-FS---"
        trivy fs --scanners vuln --severity HIGH,CRITICAL,MEDIUM /
        echo "---TRIVY-IMAGE---"
        if command -v docker >/dev/null 2>&1; then
            IMAGES="$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null)"
            if [ -n "$IMAGES" ]; then
                for IMG in $IMAGES; do
                    echo "--- image: $IMG ---"
                    trivy image --severity HIGH,CRITICAL,MEDIUM "$IMG"
                done
            else
                echo "NO_IMAGES: nessuna immagine Docker presente"
            fi
        else
            echo "NO_DOCKER: Docker non installato sulla VM"
        fi
    } > "$RAWFILE" 2>&1
}

run_nmap() {
    local iface_ip
    iface_ip="$(ip -br a | awk '$1 !~ /^lo$/ {print $3}' | cut -d/ -f1 | head -n1)"
    {
        echo "---NMAP-LOCALHOST---"
        sudo nmap -sV -p- 127.0.0.1
        echo "---NMAP-INTERFACE (${iface_ip})---"
        if [ -n "$iface_ip" ]; then
            sudo nmap -sV -p- "$iface_ip"
        else
            echo "NO_INTERFACE_IP: impossibile determinare l'IP dell'interfaccia primaria"
        fi
    } > "$RAWFILE" 2>&1
}

run_debsecan() {
    debsecan > "$RAWFILE" 2>&1
}

run_chkrootkit() {
    sudo chkrootkit > "$RAWFILE" 2>&1
}

run_rkhunter() {
    sudo rkhunter --check --sk --rwo > "$RAWFILE" 2>&1
}

case "$TOOL" in
    lynis) run_lynis ;;
    trivy) run_trivy ;;
    nmap) run_nmap ;;
    debsecan) run_debsecan ;;
    chkrootkit) run_chkrootkit ;;
    rkhunter) run_rkhunter ;;
    *)
        echo "UNKNOWN_TOOL: $TOOL non è tra i tool gestiti da questo audit" >&2
        exit 2
        ;;
esac
RUN_EXIT=$?

echo "${TIMESTAMP}|${TOOL}|EXIT=${RUN_EXIT}|${RAWFILE}" >> "$MANIFEST"

# rkhunter termina con exit 1 quando trova warning (non è un errore di scansione)
if [ "$RUN_EXIT" -eq 0 ] || { [ "$TOOL" = "rkhunter" ] && [ "$RUN_EXIT" -eq 1 ]; }; then
    echo "STATUS=OK EXIT=${RUN_EXIT} OUTFILE=${RAWFILE}"
    exit 0
else
    echo "STATUS=FAIL EXIT=${RUN_EXIT} OUTFILE=${RAWFILE}"
    exit 1
fi
