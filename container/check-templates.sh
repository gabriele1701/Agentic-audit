#!/bin/bash
# check-templates.sh [--rebuild-templates]
#
# SOLO LETTURA per default: confronta il tag dei nuclei-templates pinnato nel
# Containerfile con l'ultimo tag disponibile sulla repo ufficiale (via
# `git ls-remote`, nessuna API key necessaria). Nessuna modifica al sistema
# o all'immagine in questa modalita'.
#
# L'interpretazione dell'esito (chiedere conferma all'utente, decidere se
# aggiornare) resta all'agente, non a questo script - stesso schema di
# check-tool.sh in v1.0.
#
# Con --rebuild-templates: rilancia la build dell'immagine con il layer dei
# nuclei-templates invalidato e puntato all'ultimo tag disponibile (rebuild
# mirato: i layer precedenti - ssh-audit/testssl/nuclei binario - restano in
# cache). Questo flag va passato SOLO dopo conferma esplicita dell'utente
# raccolta dall'agente: lo script stesso non chiede conferma.
#
# Importante: --rebuild-templates aggiorna solo l'immagine locale. Il pin di
# default nel Containerfile (NUCLEI_TEMPLATES_TAG/_COMMIT) NON viene
# modificato da questo script - se si vuole rendere l'aggiornamento
# permanente (sopravvivere a una build pulita da zero), va fatto a mano.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINERFILE="${SCRIPT_DIR}/Containerfile"
REPO_URL="https://github.com/projectdiscovery/nuclei-templates.git"
IMAGE_TAG="localhost/agentic-audit-container:v2.0"

MODE="${1:-}"
if [ -n "$MODE" ] && [ "$MODE" != "--rebuild-templates" ]; then
    echo "USAGE_ERROR: opzione non riconosciuta: $MODE" >&2
    exit 2
fi

if [ ! -f "$CONTAINERFILE" ]; then
    echo "CHECK_ERROR: Containerfile non trovato in $SCRIPT_DIR" >&2
    exit 2
fi

PINNED_TAG="$(grep -E '^ARG NUCLEI_TEMPLATES_TAG=' "$CONTAINERFILE" | cut -d= -f2)"
if [ -z "$PINNED_TAG" ]; then
    echo "CHECK_ERROR: impossibile leggere NUCLEI_TEMPLATES_TAG da $CONTAINERFILE" >&2
    exit 2
fi

ALL_TAGS="$(git ls-remote --tags --refs "$REPO_URL" 2>/dev/null | awk '{print $2}' | sed 's#refs/tags/##' | sort -V)"
if [ -z "$ALL_TAGS" ]; then
    echo "CHECK_ERROR: impossibile contattare GitHub per verificare i tag di nuclei-templates" >&2
    exit 2
fi

LATEST_TAG="$(echo "$ALL_TAGS" | tail -n1)"

# conteggio di quante release separano il tag pinnato dall'ultimo disponibile,
# basato sull'ordinamento semver di tutti i tag della repo
BEHIND="$(echo "$ALL_TAGS" | awk -v pinned="$PINNED_TAG" 'found{c++} $0==pinned{found=1} END{print c+0}')"

if [ "$PINNED_TAG" = "$LATEST_TAG" ]; then
    echo "TEMPLATES_STATUS=UP_TO_DATE PINNED=${PINNED_TAG}"
    if [ "$MODE" = "--rebuild-templates" ]; then
        echo "NOTHING_TO_REBUILD: il tag pinnato e' gia' l'ultimo disponibile"
    fi
    exit 0
fi

echo "TEMPLATES_STATUS=STALE PINNED=${PINNED_TAG} LATEST=${LATEST_TAG} BEHIND=${BEHIND}"

if [ "$MODE" != "--rebuild-templates" ]; then
    exit 1
fi

# --- rebuild mirato: solo da qui in poi si tocca il sistema ---------------

LATEST_COMMIT="$(git ls-remote "$REPO_URL" "refs/tags/${LATEST_TAG}" 2>/dev/null | awk '{print $1}')"
if [ -z "$LATEST_COMMIT" ]; then
    echo "REBUILD_FAILED: impossibile risolvere il commit per il tag ${LATEST_TAG}" >&2
    exit 1
fi

echo "Rebuild mirato in corso: nuclei-templates ${PINNED_TAG} -> ${LATEST_TAG} (layer precedenti in cache)..."

if ! command -v podman >/dev/null 2>&1; then
    echo "REBUILD_FAILED: comando 'podman' non trovato nel PATH" >&2
    exit 1
fi

if podman build \
    --build-arg "NUCLEI_TEMPLATES_TAG=${LATEST_TAG}" \
    --build-arg "NUCLEI_TEMPLATES_COMMIT=${LATEST_COMMIT}" \
    --build-arg "TEMPLATES_CACHE_BUST=$(date +%s)" \
    -t "$IMAGE_TAG" \
    -f "$CONTAINERFILE" \
    "$SCRIPT_DIR"
then
    echo "REBUILD_OK: immagine locale aggiornata a nuclei-templates ${LATEST_TAG} (commit ${LATEST_COMMIT})"
    echo "NOTE: il pin di default nel Containerfile resta ${PINNED_TAG} - aggiornarlo a mano se si vuole rendere permanente"
    exit 0
else
    echo "REBUILD_FAILED: 'podman build' terminato con errore (vedi output sopra)" >&2
    exit 1
fi
