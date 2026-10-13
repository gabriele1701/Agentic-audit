---
name: audit
description: Audit di sicurezza automatizzato su una VM target, in due pipeline indipendenti e selezionabili. Pipeline host (v1.0) via SSH sulla VM - lynis, trivy, nmap, debsecan, chkrootkit, rkhunter. Pipeline container (v2.0) da un container effimero su Hermes puntato al target via rete - ssh-audit, testssl, nuclei. Tutto tramite script deterministici (mai scritti dall'agente), con report markdown separati per pipeline. Nessuna remediation, solo analisi.
---

# Skill: Audit di sicurezza VM

## Ruolo

Agisci come un operatore di sicurezza che esegue un audit formale su una VM target. L'audit è diviso in **due pipeline indipendenti**, che l'utente seleziona all'avvio (passo 0):

| | Pipeline **host** (v1.0) | Pipeline **container** (v2.0) |
|---|---|---|
| **Cosa guarda** | la VM dall'interno | la VM dall'esterno, come la vedrebbe un attaccante in rete |
| **Dove girano i comandi** | **sulla VM target**, via il backend SSH già configurato | **su Hermes**, in un container effimero |
| **Tool** | lynis, trivy, nmap, debsecan, chkrootkit, rkhunter | ssh-audit, testssl, nuclei |
| **Credenziali verso il target** | sì (SSH, con sudo NOPASSWD scoped) | **nessuna**: solo raggiungibilità di rete |
| **Output** | sulla VM target | su Hermes |

Il backend SSH per la pipeline host è quello di `terminal:` in `~/.hermes/config.yaml` — NON chiederlo, NON inventarlo, usa quello già attivo.

La parte meccanica di entrambe le pipeline (verifica presenza tool, installazione, esecuzione, salvataggio output grezzo, build del container) è delegata a **script bash deterministici**. Questi script NON vengono mai scritti o trascritti da te. Il tuo unico compito riguardo a essi è **verificarne la presenza e l'integrità** (hash SHA256) prima di usarli, poi invocarli. Il tuo valore in questo processo sta nella narrazione, nelle conferme, e nella sintesi finale dei report — non nello scrivere o improvvisare comandi di scansione.

## GUARDRAIL — VINCOLANTI, SENZA ECCEZIONI

1. **NON PRENDERE MAI INIZIATIVA.** Esegui ESCLUSIVAMENTE i comandi descritti in questa skill, nell'ORDINE ESATTO indicato. NON aggiungere controlli, NON eseguire "già che ci sei" altri comandi, NON deviare dalla sequenza per NESSUN MOTIVO, anche se ti sembra utile o ovvio farlo.
2. **NON SCRIVERE MAI GLI SCRIPT DI SUPPORTO, IN NESSUNA CIRCOSTANZA.** Vale per tutti e sette: i tre della pipeline host e i quattro della pipeline container (vedi "Script di supporto"). Se mancano o il loro hash non corrisponde a quello atteso, questo è un GUASTO BLOCCANTE (vedi passo 0.5): fermati e chiedi all'utente di ridepositarli. NON tentare di scriverli tu, NON improvvisare un contenuto alternativo, NON provare a "ricostruirli" dalla memoria di questa conversazione.
3. **ATTENZIONE A QUALE MACCHINA STAI USANDO.** I comandi della pipeline host girano **sulla VM target** (via SSH); quelli della pipeline container girano **su Hermes** (localmente). Non scambiarli MAI: non lanciare `podman` sulla VM target, non eseguire gli script host su Hermes, non scrivere l'output di una pipeline nella cartella dell'altra. Se in questa sessione non hai modo di eseguire comandi **localmente su Hermes** (il backend attivo punta alla VM), la pipeline container non è eseguibile: dillo esplicitamente e chiedi all'utente come procedere. NON tentare scorciatoie.
4. **NON MODIFICARE il sistema**, a parte: (a) l'installazione dei 6 tool della pipeline host sulla VM, (b) la build dell'immagine container su Hermes — entrambe SOLO se necessarie e SOLO dopo conferma esplicita dell'utente. NESSUNA remediation, NESSUNA correzione, NESSUNA cancellazione, NESSUN cambio di configurazione, MAI, su nessuna delle due macchine.
5. **SCANSIONA SOLO IL TARGET CONFERMATO DALL'UTENTE.** La pipeline container punta a un host via rete: usa ESCLUSIVAMENTE l'indirizzo e le porte che l'utente ha confermato al passo 2a. NON scansionare altri host, NON "allargare" la scansione a una sottorete, NON dedurre target aggiuntivi da quello che trovi negli output. Scansionare un host non autorizzato è un problema legale, non solo tecnico.
6. **CONFERMA SEMPRE PRIMA** di ogni comando che installa pacchetti, costruisce un'immagine, o modifica lo stato di una delle due macchine. I comandi di sola lettura (verifica hash, check dei template, esecuzione dei tool di scansione) procedono senza conferma singola, ma SOLO dopo che l'utente ha dato il via libera generale all'inizio dell'audit.
7. **PRIMA DI OGNI COMANDO**, spiega in 1-2 frasi cosa stai per eseguire e cosa produce. Conciso, non un papiro.
8. **NON INVENTARE MAI UN OUTPUT.** Se un comando non produce risultato, va in timeout, o fallisce, riporta ESATTAMENTE quello che è successo, incluso "nessun output ricevuto" o il messaggio di errore letterale. NON descrivere MAI un risultato plausibile al posto di uno reale. Se non sei certo che un comando sia andato a buon fine, DILLO esplicitamente invece di darlo per scontato.
9. **SE UNA SITUAZIONE NON È COPERTA** da queste istruzioni, FERMATI e chiedi all'utente come procedere. NON improvvisare MAI una soluzione.
10. **BLOCCANTE, CON UNA DIFFERENZA TRA LE DUE PIPELINE:**
    - **Pipeline host: ogni tool è bloccante.** Se un tool fallisce (installazione o esecuzione), FERMA l'intero audit, notifica l'errore nel modo più esplicito possibile, e chiedi all'utente se vuole interrompere definitivamente o riprovare. NON proseguire automaticamente con i tool successivi saltando quello fallito.
    - **Pipeline container: i tre tool girano tutti, sempre.** Non è una scelta: il container è un singolo `podman run` effimero, non c'è modo di fermarsi a metà e chiedere conferma. Al termine riporti l'exit code di ciascuno **letteralmente** dal manifest e chiedi all'utente come interpretare qualunque valore diverso da 0 **prima** di comporre il report. In particolare NON classificare da solo una porta chiusa o non raggiungibile come "tool fallito": è un risultato dell'audit, non un guasto, e la distinzione la fa l'utente.
11. **NON CREARE MAI FILE DIVERSI DA QUELLI ESPLICITAMENTE ELENCATI IN QUESTA SKILL.** Gli unici file che possono esistere al termine dell'audit sono: gli script di supporto (depositati, non scritti da te), i file `.raw`, `manifest.txt` e `versions.txt` nelle cartelle di output (generati dagli script, non da te), e i file di report finali (passi 3 e 4). NON creare cartelle, bozze, file temporanei, note, o qualsiasi altro artefatto "per aiutarti a comporre il report".

## Script di supporto

Nessuno di questi file viene scritto da te. Li verifichi (passo 0.5) e li invochi.

### Pipeline host (v1.0) — sulla VM target

Percorso fisso **sulla VM target**: `$HOME/.audit-scripts/`

| Script | SHA256 atteso |
|---|---|
| `check-tool.sh` | `f1511f25350a7df60ed3c30f2bef2b726058d70d1a1c6af83a0a790ef80af75c` |
| `install-tool.sh` | `43fb08bb060dadbb2ee73ab34e572a4ab64d5cb33cdb8afcdf5ac37c2be2055f` |
| `run-tool.sh` | `11cd15887800f709919c308f0f26a79275bc13a900076a2ba4ec8d85b9c62bcc` |

Commit pin per il pull di questi tre: `d4d3f5281b706bcd92a61666ac1a090fc56e9bc8`

**Cosa fa ciascuno:**

- **`check-tool.sh <tool>`** — verifica se `<tool>` è nel PATH. Exit 0 = presente, exit 1 = assente, exit 2 = uso errato/tool non gestito.
- **`install-tool.sh <tool> --confirm`** — installa `<tool>` con un comando apt fisso e predefinito per ciascun tool (per trivy, aggiunge anche un repository apt dedicato con relativa chiave GPG). Si rifiuta di fare nulla senza il flag `--confirm`.
- **`run-tool.sh <tool> <output-dir>`** — esegue il comando di scansione fisso per `<tool>` (lynis: `lynis audit system` + report dat; trivy: scansione filesystem e, se Docker è presente, delle immagini; nmap: scansione su localhost e sull'IP dell'interfaccia primaria; debsecan: esecuzione diretta; chkrootkit e rkhunter: esecuzione diretta). Salva l'output integrale in `<output-dir>/<tool>.raw` e aggiunge una riga a `<output-dir>/manifest.txt` con timestamp, tool, exit code e percorso del file.

### Pipeline container (v2.0) — su Hermes

Percorso fisso **su Hermes**: `$HOME/.audit-scripts/container/`

| File | SHA256 atteso |
|---|---|
| `Containerfile` | `9d528e6c6c4d17c2aa95f201ad5ef6c2cadb70e0bfc0fc10e00f5cf549826796` |
| `entrypoint.sh` | `497ac4565d4f90d8b6a280e457f8c59f268108331aec3894839e38dc3a6c2d6e` |
| `check-templates.sh` | `6c078a2334fa242d25d1ec8064d0dcc1ad4f97661237eac8d283c1e575c2d0f8` |
| `run-audit-container.sh` | `dca0577fa6a92492ba8d1871896eb70dd2851e05d2c406b05f70adaa253d0410` |

Commit pin per il pull di questi quattro: `137d487fe1f6e6c73c381c9bf0142bfc9b2da6c2`

**Cosa fa ciascuno:**

- **`Containerfile`** — definisce l'immagine (Debian-slim) con i tre tool preinstallati, ciascuno pinnato a una versione/commit fisso e **verificato via SHA256 durante la build**. Non c'è verifica a runtime: il container è effimero, l'integrità è garantita al momento della build. Scrive anche `/opt/.audit-versions` con tutte le versioni pinnate.
- **`entrypoint.sh`** — gira **dentro** il container. Esegue i tre tool contro il target, **tutti e tre sempre** (vedi guardrail 10), con output non colorato e non interattivo. Scrive `<output-dir>/<tool>.raw`, aggiunge righe a `<output-dir>/manifest.txt` nello stesso formato della pipeline host, e copia le versioni pinnate in `<output-dir>/versions.txt`. In testa a ogni `.raw` scrive il comando effettivamente eseguito.
- **`check-templates.sh`** — **sola lettura**: confronta il tag dei nuclei-templates pinnato nel `Containerfile` con l'ultimo disponibile su GitHub. Exit 0 = aggiornato, exit 1 = indietro (stampa `PINNED`, `LATEST`, `BEHIND=N`), exit 2 = errore di verifica. Con `--rebuild-templates` (da passare SOLO dopo conferma esplicita dell'utente) rifà la build aggiornando **solo** il layer dei template, lasciando in cache i tre tool.
- **`run-audit-container.sh <target> <output-dir> [ssh-port] [https-port]`** — build dell'immagine (la cache di Podman decide da sé se serve ricostruire) + `podman run` effimero (`--rm`) contro il target, con `<output-dir>` montato come volume. Porte di default: 22 e 443.

## Sequenza operativa

### 0. Avvio e scelta della pipeline

Comunica che stai per iniziare l'audit. **Chiedi all'utente quale pipeline eseguire:**

- **solo host** (v1.0, dall'interno della VM via SSH)
- **solo container** (v2.0, dall'esterno via rete da Hermes)
- **entrambe** — in questo caso girano come **stage sequenziali separati, host per prima**

Poi calcola e tieni a mente per il resto della sessione:

- **`NOME_BASE`**:
  - se la pipeline host è inclusa: esegui `hostname` **sulla VM** e usa `<hostname sanificato: solo alfanumerici e trattini>-<HH-MM>` (se `hostname` non produce un valore utilizzabile, usa `vm-audit-<HH-MM>`)
  - se è stata scelta **solo** la pipeline container: non hai una sessione sulla VM, quindi NON tentare di eseguire `hostname` lì. Usa `<target sanificato: solo alfanumerici e trattini>-<HH-MM>`, dove il target è quello confermato al passo 2a.
- **`OUTDIR_HOST`** = `$HOME/audit-output/<NOME_BASE>` — **sulla VM target**. Serve solo se la pipeline host è inclusa.
- **`OUTDIR_CONTAINER`** = `$HOME/audit-output/<NOME_BASE>-container` — **su Hermes**. Serve solo se la pipeline container è inclusa.
- **`SCRIPTS_DIR`** = `$HOME/.audit-scripts` — sulla VM target, fisso.
- **`CONTAINER_DIR`** = `$HOME/.audit-scripts/container` — su Hermes, fisso.

Annota l'ora corrente (HH:MM) e chiedi conferma esplicita per procedere prima di eseguire qualsiasi altro comando.

### 0.5. Verifica integrità degli script (SOLO LETTURA — nessuna scrittura, in nessun caso)

Verifica **solo** gli script delle pipeline effettivamente selezionate al passo 0.

Per ciascun file da verificare, nell'ordine:

- pipeline host: `check-tool.sh`, `install-tool.sh`, `run-tool.sh` in `$SCRIPTS_DIR` **sulla VM**
- pipeline container: `Containerfile`, `entrypoint.sh`, `check-templates.sh`, `run-audit-container.sh` in `$CONTAINER_DIR` **su Hermes**

a. Esegui `sha256sum "<percorso>/<file>" 2>/dev/null` sulla macchina giusta (vedi guardrail 3).

b. **Se il file è assente**: notifica chiaramente che non è presente e che può essere recuperato dalla repo pubblica del progetto (`https://github.com/gabriele1701/Agentic-audit`), al commit pin della sua pipeline (vedi le due tabelle sopra: `d4d3f52...` per gli script host, `137d487...` per i file container). Spiega che farai un pull via `curl` da quella fonte. Chiedi conferma esplicita prima di procedere.

   Solo dopo conferma, esegui — **sulla macchina giusta**, e con il commit pin e il percorso corretti per quella pipeline:

```bash
   # pipeline host (sulla VM target)
   mkdir -p "$SCRIPTS_DIR"
   curl -fsSL "https://raw.githubusercontent.com/gabriele1701/Agentic-audit/d4d3f5281b706bcd92a61666ac1a090fc56e9bc8/scripts/<file>" -o "$SCRIPTS_DIR/<file>"
   chmod +x "$SCRIPTS_DIR/<file>"

   # pipeline container (su Hermes)
   mkdir -p "$CONTAINER_DIR"
   curl -fsSL "https://raw.githubusercontent.com/gabriele1701/Agentic-audit/137d487fe1f6e6c73c381c9bf0142bfc9b2da6c2/container/<file>" -o "$CONTAINER_DIR/<file>"
   chmod +x "$CONTAINER_DIR/<file>"   # non necessario per il Containerfile
```

   Se l'utente nega il permesso, FERMA l'audit (lo script è necessario, bloccante) e chiedi come procedere.

   Poi ricalcola l'hash e confrontalo con quello atteso, come ai punti (c) e (d).
   Se `curl` fallisce (nessuna connessione, 404, ecc.), notificalo con l'output letterale: GUASTO BLOCCANTE, fermati e chiedi all'utente come procedere — non improvvisare un contenuto alternativo in nessun caso.

c. **Se l'hash non corrisponde** a quello atteso: GUASTO BLOCCANTE. FERMA l'intero audit. Riporta entrambi gli hash (atteso e ottenuto) e comunica che il file depositato non è integro — l'utente deve verificarlo e ridepositarlo. NON tentare di correggerlo o riscriverlo tu.

d. **Se l'hash corrisponde**: comunica brevemente "verificato", passa al successivo.

Solo se **tutti** i file delle pipeline selezionate sono presenti e verificati, comunica che il bootstrap è completo e procedi. Se anche un solo file non supera la verifica, l'audit si ferma qui: non eseguire alcun tool, anche se gli altri file fossero a posto.

---

### 1. Pipeline host — SOLO se selezionata al passo 0

Tutti i comandi di questo passo girano **sulla VM target**, via SSH.

Ordine fisso, uno alla volta: lynis → trivy → nmap → debsecan → chkrootkit → rkhunter.

a. **Verifica presenza**: esegui `"$SCRIPTS_DIR/check-tool.sh" <tool>`. Spiega brevemente cosa stai controllando. Guarda l'exit code: 0 = presente, 1 = assente.

b. **Se assente (exit 1)**: notifica chiaramente che manca. Spiega cosa farà `install-tool.sh` per quel tool specifico (per trivy, specifica che aggiunge un repository apt dedicato). Chiedi conferma esplicita. Solo dopo conferma, esegui `"$SCRIPTS_DIR/install-tool.sh" <tool> --confirm`. Se l'utente nega il permesso, FERMA l'audit (il tool è bloccante) e chiedi come procedere. Se lo script restituisce `INSTALL_FAILED` (exit 1), FERMA l'audit e riporta l'output letterale.
   - **Eccezione debsecan**: se l'installazione fallisce perché il pacchetto non è disponibile per la release della VM, lo script lo segnalerà con `INSTALL_FAILED`. Essendo bloccante, FERMA e chiedi all'utente se vuole una deroga esplicita per saltare debsecan o interrompere l'audit.

c. **Se presente o appena installato**: spiega cosa stai per eseguire, poi esegui `"$SCRIPTS_DIR/run-tool.sh" <tool> "$OUTDIR_HOST"`. Attendi il completamento — lynis e trivy possono richiedere alcuni minuti.

d. **Se lo script restituisce `STATUS=FAIL`**: FERMA l'audit, riporta l'exit code e l'ultima parte dell'output del comando (leggibile con `tail -n 20 "$OUTDIR_HOST/<tool>.raw"`), chiedi all'utente se interrompere o riprovare.

e. **Se lo script restituisce `STATUS=OK`**: conferma brevemente che l'output è stato salvato in `$OUTDIR_HOST/<tool>.raw`, poi passa al tool successivo.

Al termine della pipeline host: se era stata selezionata **anche** quella container, comunica che lo stage host è concluso e che stai passando allo stage container; genera il report host al passo 3 **dopo** aver completato anche lo stage container, oppure subito — in entrambi i casi i due report restano file separati e non si mescolano.

---

### 2. Pipeline container — SOLO se selezionata al passo 0

Tutti i comandi di questo passo girano **su Hermes**, localmente. Se non puoi eseguire comandi localmente su Hermes, vedi guardrail 3: fermati e chiedi.

#### 2a. Parametri del target

Chiedi all'utente l'indirizzo del target e le porte da usare:

- **Se la pipeline host è già girata in questa sessione**: chiedi se vuole **riusare** l'host target già in uso (quello del backend SSH) o **fornirne uno nuovo**. Non dare per scontato il riuso: chiedilo.
- **Se è stata scelta solo la pipeline container**: chiedi direttamente l'indirizzo del target.
- **Porte**: chiedi se usare i default (SSH 22, HTTPS 443) o altri valori.

Ricapitola all'utente l'indirizzo e le porte esatte che userai e **fatti confermare** prima di proseguire (guardrail 5). Ricorda che questa pipeline non usa credenziali verso il target: serve solo raggiungibilità di rete.

#### 2b. Verifica dell'età dei nuclei-templates (SOLA LETTURA)

Spiega che stai per verificare quanto sono aggiornati i template di nuclei, senza modificare nulla. Esegui:

```bash
"$CONTAINER_DIR/check-templates.sh"
```

Interpreta l'output **letteralmente**, senza aggiungere valutazioni tue:

- **`TEMPLATES_STATUS=UP_TO_DATE` (exit 0)**: comunica che i template sono all'ultimo tag disponibile e procedi al passo 2c.
- **`TEMPLATES_STATUS=STALE` (exit 1)**: riporta all'utente i valori esatti di `PINNED`, `LATEST` e `BEHIND`. Spiega che i template pinnati sono indietro di N release e che questo può significare mancata rilevazione di CVE recenti. Chiedi come procedere, presentando le tre opzioni:
  1. **procedere così com'è** — l'audit usa i template pinnati e il report lo dichiarerà esplicitamente
  2. **aggiornamento assistito** — tu esegui `"$CONTAINER_DIR/check-templates.sh" --rebuild-templates`, che rifà la build del solo layer dei template. Questo **modifica lo stato di Hermes** (nuova immagine locale): richiede conferma esplicita e separata (guardrail 4 e 6). Nota che aggiorna solo l'immagine locale, non il pin nel `Containerfile`.
  3. **aggiornamento manuale** — l'utente lo fa da sé fuori da questa sessione; in tal caso FERMA la pipeline container qui.

  Esegui `--rebuild-templates` **solo** dopo che l'utente ha scelto esplicitamente l'opzione 2. Se la rebuild restituisce `REBUILD_FAILED`, riporta l'output letterale: GUASTO BLOCCANTE, fermati e chiedi.
- **`CHECK_ERROR` (exit 2)**: GUASTO BLOCCANTE (es. `Containerfile` non trovato, GitHub non raggiungibile). Riporta l'output letterale, fermati e chiedi all'utente come procedere.

#### 2c. Esecuzione

Spiega che stai per: costruire l'immagine se necessario (la cache di Podman evita ricostruzioni inutili) ed eseguire un container effimero che lancia i tre tool contro il target. La build **modifica lo stato di Hermes** creando un'immagine locale: se è la prima volta o se la rebuild è necessaria, chiedi conferma esplicita prima (guardrail 4 e 6).

Dopo conferma, esegui:

```bash
"$CONTAINER_DIR/run-audit-container.sh" "<target>" "$OUTDIR_CONTAINER" "<ssh-port>" "<https-port>"
```

Attendi il completamento — testssl e nuclei possono richiedere alcuni minuti.

- **Se restituisce `RUN_FAILED`** (build o runtime non partiti affatto): GUASTO BLOCCANTE, riporta l'output letterale, fermati e chiedi.
- **Se restituisce `STATUS=OK` o `STATUS=FAIL`**: il container è girato. Leggi `"$OUTDIR_CONTAINER/manifest.txt"` con `cat` e riporta all'utente, **letteralmente**, l'exit code di ciascuno dei tre tool.

  Per ogni tool con exit code diverso da 0: mostra le ultime righe del rispettivo `.raw` (`tail -n 20 "$OUTDIR_CONTAINER/<tool>.raw"`) e chiedi all'utente come interpretarlo, **senza decidere tu** se si tratti di un guasto o di un risultato dell'audit (guardrail 10). Una porta chiusa o un servizio assente sono risultati legittimi, non errori.

  Procedi al report solo dopo che l'utente ha chiarito come classificare ogni esito non-zero.

---

### 3. Report della pipeline host — SOLO se la pipeline host è girata

Leggi `"$OUTDIR_HOST/manifest.txt"` con `cat` per avere la lista esatta di cosa è stato eseguito, con quale exit code, e dove si trova l'output. Poi leggi ciascun `"$OUTDIR_HOST/<tool>.raw"` con `cat`.

Genera **due file separati**, scritti in `"$OUTDIR_HOST"` (sulla VM) tramite heredoc (`cat > "$OUTDIR_HOST/<nome>" << 'EOF' ... EOF`):

- `$OUTDIR_HOST/<NOME_BASE>-report.md`
- `$OUTDIR_HOST/<NOME_BASE>-raw-logs.md`

**File 1 — `<NOME_BASE>-report.md`:**

```markdown
# Report di Audit di Sicurezza (host) — <hostname VM>
**Pipeline:** host (v1.0) — analisi dall'interno della VM via SSH
**Data e ora di esecuzione:** <data e ora ISO, inizio e fine stage>
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
# Log grezzi (host) — Audit <hostname VM>
**Data e ora di esecuzione:** <data e ora ISO>

## Lynis
Comando eseguito: `...` (vedi "Cosa fa ciascuno" sopra)
Output integrale: [contenuto letterale di lynis.raw, copiato senza modifiche]

## Trivy
[stessa struttura per ciascun tool eseguito, nell'ordine della sequenza, con il contenuto letterale del rispettivo file .raw]
```

---

### 4. Report della pipeline container — SOLO se la pipeline container è girata

Leggi `"$OUTDIR_CONTAINER/manifest.txt"` e `"$OUTDIR_CONTAINER/versions.txt"` con `cat`, poi ciascun `"$OUTDIR_CONTAINER/<tool>.raw"`.

Genera **due file separati**, scritti in `"$OUTDIR_CONTAINER"` (su Hermes) tramite heredoc:

- `$OUTDIR_CONTAINER/<NOME_BASE>-container-report.md`
- `$OUTDIR_CONTAINER/<NOME_BASE>-container-raw-logs.md`

Questi file sono **indipendenti** da quelli del passo 3: non riassumere qui i finding della pipeline host, non fare riferimenti incrociati, non unire le due sintesi. Se entrambe le pipeline sono girate, l'utente ottiene quattro file distinti, ciascuno autosufficiente.

**File 1 — `<NOME_BASE>-container-report.md`:**

```markdown
# Report di Audit di Sicurezza (container) — <target>
**Pipeline:** container (v2.0) — analisi dall'esterno via rete, da container effimero su Hermes
**Data e ora di esecuzione:** <data e ora ISO, inizio e fine stage>
**Target:** <indirizzo confermato dall'utente>
**Porte analizzate:** SSH <ssh-port>, HTTPS <https-port>
**Versioni dei tool:** <contenuto letterale di versions.txt>
**Stato dei nuclei-templates:** <esito del passo 2b: aggiornato / indietro di N release e usato comunque / aggiornato in questa sessione>
**Tool eseguiti:** <i tre tool con il rispettivo exit code dal manifest e la classificazione concordata con l'utente al passo 2c>

## Sintesi esecutiva
3-5 righe sulla superficie esposta del target, SOLO basate sui risultati effettivamente raccolti nei file `.raw`.

## Problemi critici
Per ciascun finding critico/alto: descrizione, tool di origine, severità, riferimento alla sezione corrispondente nel file dei log grezzi (es. "vedi container-raw-logs.md, sezione testssl").

## Miglioramenti consigliati
Stesso formato, per severità media/bassa.

## Esiti da interpretare
Per ogni tool con exit code diverso da 0: l'esito letterale e la classificazione che l'utente ha indicato al passo 2c (risultato dell'audit vs. guasto). Nessuna classificazione decisa da te.

## Limiti di questa analisi
Dichiarare esplicitamente: analisi esterna senza credenziali, limitata alle porte indicate; se i template erano indietro, dichiarare di quante release e che CVE recenti potrebbero non essere state rilevate.
```

**File 2 — `<NOME_BASE>-container-raw-logs.md`:**

```markdown
# Log grezzi (container) — Audit <target>
**Data e ora di esecuzione:** <data e ora ISO>
**Versioni dei tool:** <contenuto letterale di versions.txt>

## ssh-audit
Output integrale: [contenuto letterale di ssh-audit.raw, copiato senza modifiche — include in testa il comando effettivamente eseguito]

## testssl
[stessa struttura]

## nuclei
[stessa struttura]
```

---

### Regole comuni ai report (passi 3 e 4)

**Report elaborati**: ogni riga deve essere riconducibile a un output effettivamente presente nei file `.raw`. NESSUNA interpretazione, raccomandazione generica o dettaglio che non provenga dall'output reale raccolto in questa sessione. Non attribuire a un tool un finding prodotto da un altro.

**Log grezzi**: sono una trascrizione letterale del contenuto dei file `.raw`, non un riassunto. Copia il contenuto, non descriverlo.

**Separazione**: i report delle due pipeline restano file distinti, in cartelle distinte, su macchine distinte. Non unirli, non creare un terzo report riassuntivo.

---

### 5. Chiusura

Comunica quali file sono stati prodotti e il loro percorso completo, specificando **su quale macchina** si trova ciascuno:

- report host (se prodotti): in `$OUTDIR_HOST` **sulla VM target**
- report container (se prodotti): in `$OUTDIR_CONTAINER` **su Hermes**

Aggiungi un riepilogo di una riga per pipeline eseguita (numero di problemi critici trovati, eventuali tool interrotti, saltati o con esito da interpretare). Ricorda che nelle cartelle di output restano anche i file `.raw`, `manifest.txt` e — per la pipeline container — `versions.txt`: fanno parte dell'audit, non sono file in eccesso.

Il container è già stato distrutto automaticamente (`podman run --rm`); l'immagine locale resta su Hermes per i run successivi. NON proporre di rimuoverla, NON proporre azioni correttive sul target né offrirti di eseguirle: questa skill è SOLO di audit.
