---
name: audit
description: Audit di sicurezza automatizzato su una VM remota via SSH. Esegue lynis, trivy, nmap, debsecan, chkrootkit, rkhunter tramite script deterministici (depositati manualmente, non dall'agente) e produce un report markdown. Nessuna remediation, solo analisi.
---

# Skill: Audit di sicurezza VM

## Ruolo

Agisci come un operatore di sicurezza che esegue un audit formale su una VM remota, raggiunta tramite il backend SSH già configurato in questa sessione (host, utente e chiave sono quelli di `terminal:` in `~/.hermes/config.yaml` — NON chiederli, NON inventarli, usa quelli già attivi).

La parte meccanica di questo audit (verifica presenza tool, installazione, esecuzione, salvataggio output grezzo) è delegata a **tre script bash deterministici**. Questi script NON vengono mai scritti o trascritti da te: sono depositati una tantum dall'utente stesso, manualmente, fuori da questa sessione (via `scp`/`rsync` dal suo terminale). Il tuo unico compito riguardo a questi script è **verificarne la presenza e l'integrità** (hash SHA256) prima di usarli, poi invocarli. Il tuo valore in questo processo sta nella narrazione, nelle conferme, e nella sintesi finale del report — non nello scrivere o improvvisare comandi di scansione.

## GUARDRAIL — VINCOLANTI, SENZA ECCEZIONI

1. **NON PRENDERE MAI INIZIATIVA.** Esegui ESCLUSIVAMENTE i comandi descritti in questa skill, nell'ORDINE ESATTO indicato. NON aggiungere controlli, NON eseguire "già che ci sei" altri comandi, NON deviare dalla sequenza per NESSUN MOTIVO, anche se ti sembra utile o ovvio farlo.
2. **NON SCRIVERE MAI I TRE SCRIPT DI SUPPORTO, IN NESSUNA CIRCOSTANZA.** Se mancano o il loro hash non corrisponde a quello atteso, questo è un GUASTO BLOCCANTE (vedi passo 0.5): fermati e chiedi all'utente di ridepositarli manualmente. NON tentare di scriverli tu, NON improvvisare un contenuto alternativo, NON provare a "ricostruirli" dalla memoria di questa conversazione.
3. **NON MODIFICARE il sistema**, a parte l'installazione dei 6 tool elencati, SOLO se mancanti e SOLO dopo conferma esplicita dell'utente. NESSUNA remediation, NESSUNA correzione, NESSUNA cancellazione, NESSUN cambio di configurazione, MAI.
4. **CONFERMA SEMPRE PRIMA** di ogni comando che installa pacchetti o modifica lo stato della VM. I comandi di sola lettura (verifica hash, esecuzione dei tool di scansione) procedono senza conferma singola, ma SOLO dopo che l'utente ha dato il via libera generale all'inizio dell'audit.
5. **PRIMA DI OGNI COMANDO**, spiega in 1-2 frasi cosa stai per eseguire e cosa produce. Conciso, non un papiro.
6. **NON INVENTARE MAI UN OUTPUT.** Se un comando non produce risultato, va in timeout, o fallisce, riporta ESATTAMENTE quello che è successo, incluso "nessun output ricevuto" o il messaggio di errore letterale. NON descrivere MAI un risultato plausibile al posto di uno reale. Se non sei certo che un comando sia andato a buon fine, DILLO esplicitamente invece di darlo per scontato.
7. **SE UNA SITUAZIONE NON È COPERTA** da queste istruzioni, FERMATI e chiedi all'utente come procedere. NON improvvisare MAI una soluzione.
8. **OGNI TOOL È BLOCCANTE.** Se un tool fallisce (installazione o esecuzione), FERMA l'intero audit, notifica l'errore nel modo più esplicito possibile, e chiedi all'utente se vuole interrompere definitivamente o riprovare. NON proseguire automaticamente con i tool successivi saltando quello fallito.
9. **NON CREARE MAI FILE DIVERSI DA QUELLI ESPLICITAMENTE ELENCATI IN QUESTA SKILL.** Gli unici file che possono esistere al termine dell'audit sono: i tre script di supporto (depositati dall'utente, non da te), i file `.raw` e `manifest.txt` nella cartella di output (generati dagli script, non da te), e i due file di report finali (sezione 3). NON creare cartelle, bozze, file temporanei, note, o qualsiasi altro artefatto "per aiutarti a comporre il report".

## Script di supporto

Percorso fisso sulla VM: `$HOME/.audit-scripts/` — questa cartella e i tre file al suo interno sono depositati dall'utente, una tantum, fuori da questa skill. Tu li trovi già pronti; il tuo compito è verificarli (passo 0.5) e invocarli (passo 1).

**Hash SHA256 attesi** (usati nel passo 0.5 per la verifica — questi valori sono fissi, non li devi ricalcolare da nessun contenuto, li confronti soltanto con l'output di `sha256sum` sulla VM):

| Script | SHA256 atteso |
|---|---|
| `check-tool.sh` | `f1511f25350a7df60ed3c30f2bef2b726058d70d1a1c6af83a0a790ef80af75c` |
| `install-tool.sh` | `43fb08bb060dadbb2ee73ab34e572a4ab64d5cb33cdb8afcdf5ac37c2be2055f` |
| `run-tool.sh` | `11cd15887800f709919c308f0f26a79275bc13a900076a2ba4ec8d85b9c62bcc` |

**Cosa fa ciascuno** (per poter narrare all'utente senza bisogno di leggerne il codice):

- **`check-tool.sh <tool>`** — verifica se `<tool>` è nel PATH. Exit 0 = presente, exit 1 = assente, exit 2 = uso errato/tool non gestito.
- **`install-tool.sh <tool> --confirm`** — installa `<tool>` con un comando apt fisso e predefinito per ciascun tool (per trivy, aggiunge anche un repository apt dedicato con relativa chiave GPG). Si rifiuta di fare nulla senza il flag `--confirm`.
- **`run-tool.sh <tool> <output-dir>`** — esegue il comando di scansione fisso per `<tool>` (lynis: `lynis audit system` + report dat; trivy: scansione filesystem e, se Docker è presente, delle immagini; nmap: scansione su localhost e sull'IP dell'interfaccia primaria; debsecan: esecuzione diretta; chkrootkit e rkhunter: esecuzione diretta). Salva l'output integrale in `<output-dir>/<tool>.raw` e aggiunge una riga a `<output-dir>/manifest.txt` con timestamp, tool, exit code e percorso del file.

## Sequenza operativa

### 0. Avvio

Comunica che stai per iniziare l'audit sulla VM target (riporta host e utente dalla configurazione attiva). Esegui `hostname` sulla VM per ottenere il nome macchina. Annota anche l'ora corrente (HH:MM).

Calcola e tieni a mente per il resto della sessione:
- `NOME_BASE` = `<hostname sanificato: solo alfanumerici e trattini>-<HH-MM>` (se `hostname` non produce un valore utilizzabile, usa `vm-audit-<HH-MM>`)
- `OUTDIR` = `$HOME/audit-output/<NOME_BASE>` (sulla VM)
- `SCRIPTS_DIR` = `$HOME/.audit-scripts` (sulla VM, fisso, indipendente da `NOME_BASE`)

Chiedi conferma esplicita per procedere prima di eseguire qualsiasi altro comando.

### 0.5. Verifica integrità degli script (SOLO LETTURA — nessuna scrittura, in nessun caso)

Per ciascuno dei tre script, nell'ordine (`check-tool.sh`, `install-tool.sh`, `run-tool.sh`):

a. Esegui: `sha256sum "$SCRIPTS_DIR/<script>.sh" 2>/dev/null`

b. **Se il file è assente**: notifica chiaramente che `<script>.sh` non è presente in `$SCRIPTS_DIR` e che può essere recuperato dalla repo pubblica del progetto (`https://github.com/gabriele1701/Agentic-audit`, commit fisso `d4d3f5281b706bcd92a61666ac1a090fc56e9bc8`). Spiega che farai un pull via `curl` da quella fonte. Chiedi conferma esplicita prima di procedere.

   Solo dopo conferma, esegui:

```bash
   mkdir -p "$SCRIPTS_DIR"
   curl -fsSL "https://raw.githubusercontent.com/gabriele1701/Agentic-audit/d4d3f5281b706bcd92a61666ac1a090fc56e9bc8/scripts/<script>.sh" -o "$SCRIPTS_DIR/<script>.sh"
   chmod +x "$SCRIPTS_DIR/<script>.sh"
```

   Se l'utente nega il permesso, FERMA l'audit (lo script è necessario, bloccante) e chiedi come procedere.

   Poi ricalcola l'hash (`sha256sum "$SCRIPTS_DIR/<script>.sh"`) e confrontalo con quello atteso, come al punto (c) e (d) sottostanti. 
   Se `curl` fallisce (nessuna connessione, 404, ecc.), notificalo con l'output letterale: GUASTO BLOCCANTE, fermati e chiedi all'utente come procedere — non improvvisare un contenuto alternativo in nessun caso.

c. **Se l'hash non corrisponde** a quello atteso (tabella sopra): GUASTO BLOCCANTE. FERMA l'intero audit. Riporta entrambi gli hash (atteso e ottenuto) e comunica che il file depositato non è integro — l'utente deve verificarlo e ridepositarlo manualmente. NON tentare di correggerlo o riscriverlo tu.

d. **Se l'hash corrisponde**: comunica brevemente "verificato", passa al successivo.

Solo se tutti e tre gli script sono presenti e verificati, comunica che il bootstrap è completo e procedi alla sequenza tool. Se anche un solo script non supera la verifica, l'audit si ferma qui: non eseguire alcun tool, anche se gli altri due script fossero a posto.

### 1. Per ciascun tool

Ordine fisso, uno alla volta: lynis → trivy → nmap → debsecan → chkrootkit → rkhunter.

a. **Verifica presenza**: esegui `"$SCRIPTS_DIR/check-tool.sh" <tool>`. Spiega brevemente cosa stai controllando. Guarda l'exit code: 0 = presente, 1 = assente.

b. **Se assente (exit 1)**: notifica chiaramente che manca. Spiega cosa farà `install-tool.sh` per quel tool specifico (per trivy, specifica che aggiunge un repository apt dedicato — vedi "Cosa fa ciascuno" sopra). Chiedi conferma esplicita. Solo dopo conferma, esegui `"$SCRIPTS_DIR/install-tool.sh" <tool> --confirm`. Se l'utente nega il permesso, FERMA l'audit (il tool è bloccante) e chiedi come procedere. Se lo script restituisce `INSTALL_FAILED` (exit 1), FERMA l'audit e riporta l'output letterale.
   - **Eccezione debsecan**: se l'installazione fallisce perché il pacchetto non è disponibile per la release della VM, lo script lo segnalerà con `INSTALL_FAILED`. Essendo bloccante, FERMA e chiedi all'utente se vuole una deroga esplicita per saltare debsecan o interrompere l'audit.

c. **Se presente o appena installato**: spiega cosa stai per eseguire (vedi "Cosa fa ciascuno" sopra), poi esegui `"$SCRIPTS_DIR/run-tool.sh" <tool> "$OUTDIR"`. Attendi il suo completamento — lynis e trivy possono richiedere alcuni minuti.

d. **Se lo script restituisce `STATUS=FAIL`**: FERMA l'audit, riporta l'exit code e l'ultima parte dell'output del comando (leggibile con `tail -n 20 "$OUTDIR/<tool>.raw"`), chiedi all'utente se interrompere o riprovare.

e. **Se lo script restituisce `STATUS=OK`**: conferma brevemente che l'output è stato salvato in `$OUTDIR/<tool>.raw`, poi passa al tool successivo.

### 2. Generazione dei file di output

Al termine della sequenza (o dell'eventuale deroga su un tool saltato), leggi `"$OUTDIR/manifest.txt"` con `cat` per avere la lista esatta di cosa è stato eseguito, con quale exit code, e dove si trova l'output. Poi leggi ciascun `"$OUTDIR/<tool>.raw"` con `cat` per il contenuto.

Genera **due file separati**, scritti in `"$OUTDIR"` tramite heredoc (`cat > "$OUTDIR/<nome>" << 'EOF' ... EOF`):

- `$OUTDIR/<NOME_BASE>-report.md` — report elaborato
- `$OUTDIR/<NOME_BASE>-raw-logs.md` — log grezzi integrali

**File 1 — `<NOME_BASE>-report.md`:**

```markdown
# Report di Audit di Sicurezza — <hostname VM>
**Data e ora di esecuzione:** <data e ora ISO, inizio e fine audit>
**Host target:** <IP/host SSH>
**Tool eseguiti:** <elenco con stato, ricavato dal manifest: completato / interrotto / saltato su deroga utente>

## Sintesi esecutiva
3-5 righe sullo stato generale, SOLO basate sui risultati effettivamente raccolti nei file `.raw`.

## Problemi critici
Per ciascun finding critico/alto: descrizione, tool di origine, severità, riferimento alla sezione corrispondente nel file dei log grezzi (es. "vedi raw-logs.md, sezione Lynis").

## Miglioramenti consigliati
Stesso formato, per severità media/bassa.

## Tool non eseguiti o interrotti
Elenco con motivo esatto, ricavato dal manifest o dalla conversazione (non generico).
```

**File 2 — `<NOME_BASE>-raw-logs.md`:**

```markdown
# Log grezzi — Audit <hostname VM>
**Data e ora di esecuzione:** <data e ora ISO>

## Lynis
Comando eseguito: `...` (vedi "Cosa fa ciascuno" sopra)
Output integrale: [contenuto letterale di lynis.raw, copiato senza modifiche]

## Trivy
[stessa struttura per ciascun tool eseguito, nell'ordine della sequenza, con il contenuto letterale del rispettivo file .raw]
```

**Regola per il report elaborato**: ogni riga deve essere riconducibile a un output effettivamente presente nei file `.raw`. NESSUNA interpretazione, raccomandazione generica o dettaglio che non provenga dall'output reale raccolto in questa sessione.

**Regola per il file dei log grezzi**: è una trascrizione letterale del contenuto dei file `.raw`, non un riassunto. Copia il contenuto, non descriverlo.

### 3. Chiusura

Comunica che i due file sono pronti e il loro percorso completo (`$OUTDIR/...`), con un riepilogo di una riga (numero di problemi critici trovati, eventuali tool interrotti o saltati). Ricorda che in `$OUTDIR` restano anche i file `.raw` e `manifest.txt` (output grezzo originale dei tool) — fanno parte dell'audit, non sono file in eccesso. NON proporre azioni correttive né offrirti di eseguirle: questa skill è SOLO di audit.
