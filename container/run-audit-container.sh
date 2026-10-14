#!/bin/bash
# run-audit-container.sh <target-host> <output-dir> [ssh-port] [https-port]
#
# Script unico per il ciclo di vita del container dello stage v2.0:
#   1. build dell'immagine (il caching dei layer di Podman decide da solo
#      se serve ricostruire qualcosa - nessuno step esplicito di "verifica
#      se l'immagine esiste gia'")
#   2. run del container contro il target, con /output montato su
#      <output-dir>
#   3. nessuna elaborazione dell'output: resta in <output-dir>/*.raw e
#      <output-dir>/manifest.txt, nello stesso formato di v1.0, pronti per
#      la lettura da parte della skill
#
# La verifica dell'eta' dei nuclei-templates (check-templates.sh) e' uno
# step SEPARATO, da eseguire PRIMA di questo script e con conferma
# dell'utente raccolta dall'agente - non e' incluso qui.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINERFILE="${SCRIPT_DIR}/Containerfile"
IMAGE_TAG="localhost/agentic-audit-container:v2.0"

TARGET="${1:-}"
OUTDIR="${2:-}"
SSH_PORT="${3:-22}"
HTTPS_PORT="${4:-443}"

if [ -z "$TARGET" ] || [ -z "$OUTDIR" ]; then
    echo "USAGE_ERROR: specificare target-host e output-dir" >&2
    exit 2
fi

if ! command -v podman >/dev/null 2>&1; then
    echo "RUN_FAILED: comando 'podman' non trovato nel PATH" >&2
    exit 1
fi

mkdir -p "$OUTDIR"

# --isolation chroot: su Podman rootless in WSL (nessuna sessione systemd
# utente "vera" per logind, anche con linger abilitato) crun puo' fallire
# gli step RUN con "sd-bus call: Permission denied" durante la creazione
# del cgroup - il fallback automatico di Podman a --cgroup-manager=cgroupfs
# (solo un warning) non basta a evitarlo in fase di build. L'isolamento
# chroot esegue gli step RUN senza passare da crun/cgroup, quindi elimina
# il problema. Non serve per `podman run` qui sotto: quello e' un path
# diverso in crun e in questo ambiente funziona gia' senza modifiche.
echo "--- build immagine (cache Podman attiva, nessuna ricostruzione se nulla e' cambiato) ---"
if ! podman build --isolation chroot -t "$IMAGE_TAG" -f "$CONTAINERFILE" "$SCRIPT_DIR"; then
    echo "RUN_FAILED: 'podman build' terminato con errore (vedi output sopra)" >&2
    exit 1
fi

echo "--- run container contro ${TARGET} (ssh:${SSH_PORT} https:${HTTPS_PORT}) ---"
if podman run --rm \
    --network slirp4netns \
    -v "${OUTDIR}:/output:Z" \
    "$IMAGE_TAG" \
    "$TARGET" "$SSH_PORT" "$HTTPS_PORT"
then
    echo "STATUS=OK OUTDIR=${OUTDIR}"
    exit 0
else
    RUN_EXIT=$?
    echo "STATUS=FAIL EXIT=${RUN_EXIT} OUTDIR=${OUTDIR}"
    exit 1
fi
