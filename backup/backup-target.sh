#!/bin/bash
# backup-target.sh <ssh-target> <identity-file|-> <ssh-port|-> <repo-path> <mode> [extra-path ...]
#
# Backup di sicurezza PRE-AUDIT della macchina target, da eseguire SU HERMES
# (non sulla VM: a differenza dei tre script in scripts/, questo gira in
# locale sulla macchina dove gira l'agente).
#
# Scopo: rete di sicurezza temporanea nel caso l'audit combini danni sul
# target. NON e', e non deve diventare, il backup ufficiale della macchina.
#
# Meccanismo: Hermes tira i dati dalla VM via SSH (stesse credenziali gia'
# usate dal resto della pipeline host, nessuna nuova fiducia di rete da
# configurare), li deposita in una staging area locale, esegue `restic
# backup` su un repository anch'esso locale a Hermes, e poi cancella SEMPRE
# la staging area - anche in caso di errore.
#
# I dati vengono tirati come tar NON compresso: preserva permessi e
# proprietario dei file (che una copia scp perderebbe) e resta stabile a
# livello di byte tra run successivi, cosi' la deduplicazione di restic
# funziona davvero invece di ri-salvare tutto ogni volta.
#
# Argomenti:
#   <ssh-target>      utente@host della VM (gli stessi di `terminal:` in
#                     ~/.hermes/config.yaml)
#   <identity-file>   chiave SSH da usare, oppure "-" per lasciare che sia
#                     ~/.ssh/config a deciderlo
#   <ssh-port>        porta SSH della VM, oppure "-" per il default di ssh
#                     (22). Stesso valore di ssh_port in config.yaml.
#   <repo-path>       percorso del repository restic, locale a Hermes
#   <mode>            default | full
#   [extra-path ...]  solo in mode=default: path aggiuntivi da includere,
#                     passati verbatim. Ignorati in mode=full (che prende
#                     gia' tutto).
#
# La password del repository NON si passa come argomento (finirebbe nella
# process list): lo script si aspetta che sia gia' nell'ambiente, in una
# delle variabili che restic legge nativamente - RESTIC_PASSWORD,
# RESTIC_PASSWORD_FILE o RESTIC_PASSWORD_COMMAND.
#
# Exit code:
#   0 = backup completato      1 = backup fallito (vedi STAGE=)
#   2 = uso errato             3 = restic non installato su Hermes
#   4 = password non configurata
set -u

# --- parametri fissi, non decisi a runtime --------------------------------

# Esattamente i path che install-tool.sh (e il setup sudoers documentato nel
# README) modificano sulla VM. La chiave trivy puo' non esistere ancora:
# --ignore-failed-read la salta con un warning invece di far fallire tar.
DEFAULT_PATHS=(/etc/apt/sources.list.d /etc/sudoers.d /usr/share/keyrings/trivy.gpg)

# mode=full: tutta la VM, escluso cio' che non ha senso backuppare.
# L'ordine degli argomenti e' fisso di proposito: la riga sudoers che
# autorizza questo comando deve poterlo matchare esattamente.
FULL_EXCLUDES=(--exclude=/proc --exclude=/sys --exclude=/dev --exclude=/run --exclude=/tmp --exclude=/mnt --exclude=/media --exclude=/lost+found --exclude=/var/cache/apt/archives)

# --- validazione argomenti ------------------------------------------------

if [ "$#" -lt 5 ]; then
    echo "USAGE_ERROR: backup-target.sh <ssh-target> <identity-file|-> <ssh-port|-> <repo-path> <mode:default|full> [extra-path ...]" >&2
    exit 2
fi

SSH_TARGET="$1"
IDENTITY="$2"
SSH_PORT="$3"
REPO="$4"
MODE="$5"
shift 5
EXTRA_PATHS=("$@")

case "$MODE" in
    default|full) ;;
    *)
        echo "USAGE_ERROR: mode non riconosciuto: '$MODE' (ammessi: default, full)" >&2
        exit 2
        ;;
esac

if [ "$MODE" = "full" ] && [ "${#EXTRA_PATHS[@]}" -gt 0 ]; then
    echo "WARN: mode=full include gia' tutta la VM, i path aggiuntivi vengono ignorati" >&2
    EXTRA_PATHS=()
fi

# --- prerequisiti ---------------------------------------------------------

if ! command -v restic >/dev/null 2>&1; then
    echo "RESTIC_MISSING: 'restic' non trovato nel PATH su questa macchina (Hermes)" >&2
    exit 3
fi

if [ -z "${RESTIC_PASSWORD:-}" ] \
   && [ -z "${RESTIC_PASSWORD_FILE:-}" ] \
   && [ -z "${RESTIC_PASSWORD_COMMAND:-}" ]; then
    echo "PASSWORD_NOT_SET: serve RESTIC_PASSWORD, RESTIC_PASSWORD_FILE o RESTIC_PASSWORD_COMMAND nell'ambiente" >&2
    exit 4
fi

# --- preparazione ---------------------------------------------------------

# Etichetta derivata dal target, usata per lo snapshot e per la staging area.
TARGET_LABEL="$(echo "$SSH_TARGET" | tr -c 'a-zA-Z0-9.-' '-' | sed 's/-\+/-/g; s/^-//; s/-$//')"
[ -n "$TARGET_LABEL" ] || TARGET_LABEL="target"

# Staging area con percorso STABILE tra i run (non mktemp): path costanti
# permettono a restic di trovare lo snapshot padre e quindi di leggere solo
# cio' che e' cambiato, invece di ri-processare tutto ogni volta.
# Contiene temporaneamente dati sensibili della VM in chiaro (es. sudoers),
# quindi permessi 700 e cancellazione garantita in uscita.
STAGING_BASE="${HOME}/.audit-backup-staging"
STAGING="${STAGING_BASE}/${TARGET_LABEL}"

cleanup() {
    rm -rf "$STAGING"
}
trap cleanup EXIT

rm -rf "$STAGING"
if ! mkdir -p "$STAGING"; then
    echo "STATUS=FAIL STAGE=staging-setup EXIT=1" >&2
    echo "Impossibile creare la staging area in $STAGING" >&2
    exit 1
fi
chmod 700 "$STAGING_BASE" "$STAGING"

SSH_OPTS=(-o BatchMode=yes)
if [ "$IDENTITY" != "-" ]; then
    if [ ! -f "$IDENTITY" ]; then
        echo "USAGE_ERROR: chiave SSH non trovata: $IDENTITY" >&2
        exit 2
    fi
    SSH_OPTS+=(-i "$IDENTITY")
fi
if [ "$SSH_PORT" != "-" ]; then
    case "$SSH_PORT" in
        ''|*[!0-9]*)
            echo "USAGE_ERROR: porta SSH non valida: '$SSH_PORT' (attesa una porta numerica o '-')" >&2
            exit 2
            ;;
    esac
    SSH_OPTS+=(-p "$SSH_PORT")
fi
# La verifica della host key resta ai default di SSH, di proposito: se l'host
# non e' ancora in known_hosts il comando fallisce in modo esplicito invece
# di accettare in silenzio una chiave nuova.

# --- 1. snapshot dei pacchetti installati --------------------------------
# Non richiede sudo. Serve a ricostruire cosa era installato prima
# dell'audit, che e' esattamente cio' che install-tool.sh cambia.

echo "--- raccolta elenco pacchetti installati da ${SSH_TARGET} ---"
if ! ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "dpkg --get-selections" > "$STAGING/dpkg-selections.txt" 2>"$STAGING/.dpkg-stderr"; then
    echo "STATUS=FAIL STAGE=pull-packages EXIT=1" >&2
    echo "--- stderr ---" >&2
    cat "$STAGING/.dpkg-stderr" >&2
    exit 1
fi
rm -f "$STAGING/.dpkg-stderr"

# --- 2. pull dei file via tar --------------------------------------------
# tar gira con sudo sulla VM perche' i path di default includono
# /etc/sudoers.d, illeggibile da un utente non privilegiato. Il comando e'
# fisso per ogni mode, cosi' puo' essere autorizzato da una riga sudoers
# vincolata agli argomenti esatti (vedi README) invece di un NOPASSWD ampio.

build_remote_tar_cmd() {
    local quoted=""
    local p
    if [ "$MODE" = "full" ]; then
        local ex
        for ex in "${FULL_EXCLUDES[@]}"; do
            quoted="$quoted $(printf '%q' "$ex")"
        done
        echo "sudo tar -cf - --absolute-names --ignore-failed-read --one-file-system${quoted} /"
        return
    fi
    for p in "${DEFAULT_PATHS[@]}" ${EXTRA_PATHS[@]+"${EXTRA_PATHS[@]}"}; do
        quoted="$quoted $(printf '%q' "$p")"
    done
    echo "sudo tar -cf - --absolute-names --ignore-failed-read${quoted}"
}

REMOTE_TAR_CMD="$(build_remote_tar_cmd)"
TARFILE="$STAGING/target-files.tar"

echo "--- pull dei file da ${SSH_TARGET} (mode=${MODE}) ---"
echo "comando remoto: ${REMOTE_TAR_CMD}"

ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "$REMOTE_TAR_CMD" > "$TARFILE" 2>"$STAGING/.tar-stderr"
TAR_EXIT=$?

# I warning di tar sui path mancanti (es. chiave trivy non ancora presente)
# sono attesi e non fatali: vengono mostrati ma non fermano il backup.
if [ -s "$STAGING/.tar-stderr" ]; then
    echo "--- avvisi da tar sulla VM ---"
    cat "$STAGING/.tar-stderr"
fi
rm -f "$STAGING/.tar-stderr"

if [ "$TAR_EXIT" -ne 0 ]; then
    echo "STATUS=FAIL STAGE=pull-files EXIT=${TAR_EXIT}" >&2
    exit 1
fi

# --- 3. verifica che il pull abbia prodotto qualcosa di valido -----------
# Senza questo controllo un tar vuoto (es. sudo negato) produrrebbe uno
# snapshot apparentemente riuscito ma inutile.

if [ ! -s "$TARFILE" ]; then
    echo "STATUS=FAIL STAGE=verify EXIT=1" >&2
    echo "Il tar scaricato e' vuoto: il pull non ha prodotto dati" >&2
    exit 1
fi

if ! tar -tf "$TARFILE" >/dev/null 2>&1; then
    echo "STATUS=FAIL STAGE=verify EXIT=1" >&2
    echo "Il tar scaricato non e' leggibile: pull incompleto o corrotto" >&2
    exit 1
fi

TAR_ENTRIES="$(tar -tf "$TARFILE" 2>/dev/null | wc -l)"
echo "tar verificato: ${TAR_ENTRIES} voci, $(du -h "$TARFILE" | cut -f1)"

# Indice leggibile di cosa contiene il tar, con permessi e proprietario come
# erano sulla VM. Costa pochi KB e rende lo snapshot autodescrittivo: senza
# questo, `restic ls` mostrerebbe solo un .tar opaco.
tar -tvf "$TARFILE" > "$STAGING/target-files.index.txt" 2>/dev/null

# --- 4. repository restic ------------------------------------------------

if ! restic -r "$REPO" cat config >/dev/null 2>&1; then
    echo "--- repository non inizializzato, inizializzazione in ${REPO} ---"
    if ! restic -r "$REPO" init; then
        echo "STATUS=FAIL STAGE=repo-init EXIT=1" >&2
        exit 1
    fi
fi

# --- 5. backup -----------------------------------------------------------

echo "--- restic backup verso ${REPO} ---"
BACKUP_LOG="$(mktemp)"
restic -r "$REPO" backup \
    --host "$TARGET_LABEL" \
    --tag agentic-audit \
    --tag "mode=${MODE}" \
    "$STAGING" 2>&1 | tee "$BACKUP_LOG"
BACKUP_EXIT="${PIPESTATUS[0]}"

if [ "$BACKUP_EXIT" -ne 0 ]; then
    rm -f "$BACKUP_LOG"
    echo "STATUS=FAIL STAGE=backup EXIT=${BACKUP_EXIT}" >&2
    exit 1
fi

SNAPSHOT_ID="$(grep -oE 'snapshot [0-9a-f]+ saved' "$BACKUP_LOG" | tail -n1 | awk '{print $2}')"
rm -f "$BACKUP_LOG"

if [ -z "$SNAPSHOT_ID" ]; then
    # Il backup e' uscito 0 ma l'ID non e' stato trovato nell'output: non
    # inventarlo, dichiararlo.
    echo "STATUS=OK SNAPSHOT=unknown REPO=${REPO} HOST=${TARGET_LABEL} MODE=${MODE}"
    echo "NOTA: backup riuscito ma ID snapshot non individuato nell'output di restic" >&2
    exit 0
fi

echo "STATUS=OK SNAPSHOT=${SNAPSHOT_ID} REPO=${REPO} HOST=${TARGET_LABEL} MODE=${MODE}"
exit 0
