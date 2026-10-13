#!/bin/bash
# vm-exec.sh '<comando remoto>'
# vm-exec.sh --show-target
#
# Esegue <comando remoto> SULLA VM TARGET via SSH, partendo DA HERMES.
#
# Perche' esiste: la skill gira con `terminal.backend: local`, quindi tutti i
# comandi dell'agente vengono eseguiti su Hermes. Tutto cio' che deve girare
# sulla VM va quindi instradato esplicitamente via SSH. Questo script e'
# l'UNICO punto in cui vivono i parametri di connessione: l'agente non li
# ricompone a mano a ogni invocazione, cosi' non possono divergere.
#
# I parametri vengono letti dal blocco `terminal:` di ~/.hermes/config.yaml
# (chiavi ssh_host, ssh_user, ssh_port, ssh_key), gli stessi che il backend
# `ssh` di Hermes usava prima del passaggio a `local`. Restano quindi
# un'unica fonte di verita', anche se il backend non li usa piu'.
#
# Override via ambiente, per installazioni in cui il config ha un'altra
# forma: AUDIT_VM_HOST, AUDIT_VM_USER, AUDIT_VM_PORT, AUDIT_VM_KEY,
# HERMES_CONFIG (percorso del config.yaml).
#
# QUOTING - la regola piu' importante di questo script:
# il comando remoto va passato come UN SOLO argomento, in APICI SINGOLI, in
# modo che `$HOME`, `$(...)` e simili vengano espansi DALLA SHELL REMOTA e
# non da quella locale su Hermes.
#
#   vm-exec.sh 'sha256sum "$HOME/.audit-scripts/check-tool.sh"'   # giusto
#   vm-exec.sh "sha256sum \"$HOME/.audit-scripts/check-tool.sh\"" # SBAGLIATO
#
# La versione sbagliata non da' errore: espande $HOME su Hermes
# (/home/<utente-hermes>) e poi cerca quel percorso sulla VM, dove non
# esiste. Fallimento silenzioso con un percorso plausibile ma errato.
#
# stdin viene inoltrato al comando remoto, cosi' si possono scrivere file
# sulla VM con un heredoc risolto in locale:
#   vm-exec.sh 'cat > "$HOME/audit-output/report.md"' << 'EOF'
#   ...
#   EOF
#
# Exit code: quello del comando remoto, propagato verbatim (serve: gli script
# della pipeline host comunicano tramite exit code 0/1/2/3). In aggiunta:
#   64  = uso errato di questo script
#   65  = parametri di connessione non ricavabili
#   255 = (da ssh) connessione non stabilita
# 64 e 65 sono volutamente alti per non collidere con i codici degli script
# della pipeline host.
set -u

CONFIG="${HERMES_CONFIG:-$HOME/.hermes/config.yaml}"

if [ "$#" -ne 1 ] || [ -z "${1:-}" ]; then
    echo "USAGE_ERROR: vm-exec.sh '<comando remoto>' | vm-exec.sh --show-target" >&2
    echo "Il comando remoto va passato come un solo argomento, in apici singoli." >&2
    exit 64
fi

ARG="$1"

# --- lettura dei parametri dal blocco terminal: di config.yaml ------------
# Parsing deliberatamente minimale e in puro bash: legge solo le quattro
# chiavi che servono, solo dentro il blocco `terminal:`, ignorando commenti e
# apici. Non e' un parser YAML generico e non pretende di esserlo: se il
# config ha una forma diversa, si usano gli override via ambiente.

CFG_HOST=""
CFG_USER=""
CFG_PORT=""
CFG_KEY=""

if [ -f "$CONFIG" ]; then
    in_block=0
    while IFS= read -r line || [ -n "$line" ]; do
        stripped="${line%%#*}"
        [ -n "${stripped//[[:space:]]/}" ] || continue

        first="${stripped:0:1}"
        if [ "$first" != " " ] && [ "$first" != "	" ]; then
            case "$stripped" in
                terminal:*) in_block=1 ;;
                *)          in_block=0 ;;
            esac
            continue
        fi

        [ "$in_block" -eq 1 ] || continue

        kv="${stripped#"${stripped%%[![:space:]]*}"}"
        key="${kv%%:*}"
        [ "$key" != "$kv" ] || continue
        value="${kv#*:}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        value="${value#\'}"; value="${value%\'}"
        value="${value#\"}"; value="${value%\"}"

        case "$key" in
            ssh_host) CFG_HOST="$value" ;;
            ssh_user) CFG_USER="$value" ;;
            ssh_port) CFG_PORT="$value" ;;
            ssh_key)  CFG_KEY="$value" ;;
        esac
    done < "$CONFIG"
fi

VM_HOST="${AUDIT_VM_HOST:-$CFG_HOST}"
VM_USER="${AUDIT_VM_USER:-$CFG_USER}"
VM_PORT="${AUDIT_VM_PORT:-$CFG_PORT}"
VM_KEY="${AUDIT_VM_KEY:-$CFG_KEY}"

if [ -z "$VM_HOST" ] || [ -z "$VM_USER" ]; then
    echo "CONFIG_ERROR: host o utente della VM non ricavabili" >&2
    echo "Cercati in: ${CONFIG} (blocco 'terminal:', chiavi ssh_host/ssh_user)" >&2
    echo "Override disponibili: AUDIT_VM_HOST, AUDIT_VM_USER" >&2
    exit 65
fi

if [ -n "$VM_PORT" ]; then
    case "$VM_PORT" in
        ''|*[!0-9]*)
            echo "CONFIG_ERROR: porta SSH non valida: '${VM_PORT}'" >&2
            exit 65
            ;;
    esac
fi

if [ -n "$VM_KEY" ] && [ ! -f "$VM_KEY" ]; then
    echo "CONFIG_ERROR: chiave SSH dichiarata ma non trovata: ${VM_KEY}" >&2
    exit 65
fi

# --- modo diagnostico ------------------------------------------------------
# Serve alla skill per mostrare all'utente, prima di toccare qualunque cosa,
# esattamente quale macchina verra' raggiunta dalla pipeline host. Non apre
# nessuna connessione.
#
# I valori sono stampati in forma direttamente riutilizzabile come argomenti
# di backup-target.sh, che accetta "-" per "lascia decidere a ssh": quindi un
# parametro non configurato esce come "-" e non come testo descrittivo.

if [ "$ARG" = "--show-target" ]; then
    echo "VM_TARGET=${VM_USER}@${VM_HOST}"
    echo "VM_PORT=${VM_PORT:--}"
    echo "VM_KEY=${VM_KEY:--}"
    echo "CONFIG_SOURCE=${CONFIG}"
    echo "NOTA: '-' significa non configurato, deciso dai default di ssh (porta 22) o da ~/.ssh/config (chiave)."
    exit 0
fi

# --- esecuzione remota -----------------------------------------------------
# BatchMode=yes: se l'autenticazione non e' possibile senza interazione, il
# comando fallisce subito invece di restare appeso su un prompt che in una
# sessione non interattiva nessuno vedrebbe.
# La verifica della host key resta ai default di SSH, di proposito: un host
# non ancora in known_hosts fa fallire il comando invece di accettare in
# silenzio una chiave nuova.

SSH_OPTS=(-o BatchMode=yes)
[ -n "$VM_PORT" ] && SSH_OPTS+=(-p "$VM_PORT")
[ -n "$VM_KEY" ] && SSH_OPTS+=(-i "$VM_KEY")

exec ssh "${SSH_OPTS[@]}" "${VM_USER}@${VM_HOST}" "$ARG"
