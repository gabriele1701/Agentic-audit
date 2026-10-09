#!/bin/bash
# install-tool.sh <toolname> --confirm
# Installa un tool con un comando fisso e predefinito per ciascun tool.
# Si rifiuta di agire senza il flag --confirm: la conferma resta una decisione
# presa in chat tra utente e agente, non uno stato interno dello script.
set -u

TOOL="${1:-}"
CONFIRM_FLAG="${2:-}"

if [ -z "$TOOL" ]; then
    echo "USAGE_ERROR: specificare il nome del tool" >&2
    exit 2
fi

if [ "$CONFIRM_FLAG" != "--confirm" ]; then
    echo "REFUSED: installazione non confermata (serve il flag --confirm)" >&2
    exit 3
fi

install_lynis() {
    sudo apt-get update && sudo apt-get install -y lynis
}

install_trivy() {
    local keyring="/usr/share/keyrings/trivy.gpg"
    if [ ! -f "$keyring" ]; then
        curl -fsSL https://aquasecurity.github.io/trivy-repo/deb/public.key | sudo gpg --dearmor -o "$keyring" || return 1
        echo "deb [signed-by=$keyring] https://aquasecurity.github.io/trivy-repo/deb generic main" | sudo tee /etc/apt/sources.list.d/trivy.list > /dev/null || return 1
    fi
    sudo apt-get update && sudo apt-get install -y trivy
}

install_nmap() {
    sudo apt-get update && sudo apt-get install -y nmap
}

install_debsecan() {
    sudo apt-get update && sudo apt-get install -y debsecan
}

install_chkrootkit() {
    sudo apt-get update && sudo apt-get install -y chkrootkit
}

install_rkhunter() {
    sudo apt-get update && sudo apt-get install -y rkhunter
}

case "$TOOL" in
    lynis) install_lynis ;;
    trivy) install_trivy ;;
    nmap) install_nmap ;;
    debsecan) install_debsecan ;;
    chkrootkit) install_chkrootkit ;;
    rkhunter) install_rkhunter ;;
    *)
        echo "UNKNOWN_TOOL: $TOOL non è tra i tool gestiti da questo audit" >&2
        exit 2
        ;;
esac
INSTALL_EXIT=$?

if [ "$INSTALL_EXIT" -eq 0 ] && command -v "$TOOL" >/dev/null 2>&1; then
    echo "INSTALLED: $TOOL installato con successo"
    exit 0
else
    echo "INSTALL_FAILED: installazione di $TOOL fallita (exit $INSTALL_EXIT)" >&2
    exit 1
fi
