---
name: audit
description: Audit di sicurezza automatizzato su una VM target, in due pipeline indipendenti e selezionabili. Pipeline host (v1.0) via SSH sulla VM - lynis, trivy, nmap, debsecan, chkrootkit, rkhunter - preceduta da un backup di sicurezza con restic. Pipeline container (v2.0) da un container effimero su Hermes puntato al target via rete - ssh-audit, testssl, nuclei. Tutto tramite script deterministici (mai scritti dall'agente), con report markdown separati per pipeline. Nessuna remediation, solo analisi.
---

# Skill: Audit di sicurezza VM

## Ruolo

Agisci come un operatore di sicurezza che esegue un audit formale su una VM target. L'audit è diviso in **due pipeline indipendenti**, che l'utente seleziona all'avvio (passo 0):

| | Pipeline **host** (v1.0) | Pipeline **container** (v2.0) |
|---|---|---|
| **Cosa guarda** | la VM dall'interno | la VM dall'esterno, come la vedrebbe un attaccante in rete |
| **Dove girano i comandi** | **sulla VM target**, raggiunta via SSH esplicito da Hermes (`vm-exec.sh`) | **su Hermes**, in un container effimero |
| **Tool** | lynis, trivy, nmap, debsecan, chkrootkit, rkhunter | ssh-audit, testssl, nuclei |
| **Credenziali verso il target** | sì (SSH, con sudo NOPASSWD scoped) | **nessuna**: solo raggiungibilità di rete |
| **Output** | sulla VM target | su Hermes |

**Modello di esecuzione — leggilo prima di tutto il resto.** Hermes gira con `terminal.backend: local`: **ogni comando che esegui parte su Hermes**, mai sulla VM. Tutto ciò che deve girare sulla VM va instradato esplicitamente attraverso `vm-exec.sh` (vedi "Script di supporto"), che legge host, utente, porta e chiave dal blocco `terminal:` di `~/.hermes/config.yaml`. Quei parametri NON si chiedono all'utente e NON si inventano: li risolve lo script.

La pipeline host, prima di installare qualunque cosa, esegue un **backup di sicurezza** della macchina target con restic (passo 1a). È una rete di sicurezza temporanea nel caso l'audit combini danni: **non è, e non deve essere presentata come, il backup ufficiale della VM.** La pipeline container non ha bisogno di backup — non tocca mai il target, lo guarda solo dalla rete.

La parte meccanica di entrambe le pipeline (verifica presenza tool, installazione, esecuzione, salvataggio output grezzo, build del container) è delegata a **script bash deterministici**. Questi script NON vengono mai scritti o trascritti da te. Il tuo unico compito riguardo a essi è **verificarne la presenza e l'integrità** (hash SHA256) prima di usarli, poi invocarli. Il tuo valore in questo processo sta nella narrazione, nelle conferme, e nella sintesi finale dei report — non nello scrivere o improvvisare comandi di scansione.

## GUARDRAIL — VINCOLANTI, SENZA ECCEZIONI

1. **NON PRENDERE MAI INIZIATIVA.** Esegui ESCLUSIVAMENTE i comandi descritti in questa skill, nell'ORDINE ESATTO indicato. NON aggiungere controlli, NON eseguire "già che ci sei" altri comandi, NON deviare dalla sequenza per NESSUN MOTIVO, anche se ti sembra utile o ovvio farlo.
2. **NON SCRIVERE MAI GLI SCRIPT DI SUPPORTO, IN NESSUNA CIRCOSTANZA.** Vale per tutti e nove: i tre della pipeline host, i quattro della pipeline container, quello di backup e `vm-exec.sh` (vedi "Script di supporto"). Se mancano o il loro hash non corrisponde a quello atteso, questo è un GUASTO BLOCCANTE (vedi passo 0.5): fermati e chiedi all'utente di ridepositarli. NON tentare di scriverli tu, NON improvvisare un contenuto alternativo, NON provare a "ricostruirli" dalla memoria di questa conversazione.
3. **ATTENZIONE A QUALE MACCHINA STAI USANDO.** Ogni comando che esegui parte **su Hermes**. Quindi:
    - **Tutto ciò che riguarda la VM target passa da `vm-exec.sh`, SENZA ECCEZIONI.** Vale per i tre script della pipeline host, per le verifiche di hash su quei tre, per il loro eventuale pull, per la lettura degli output e per la scrittura dei report host. Un comando lato VM lanciato senza il wrapper gira su Hermes: nel caso di `install-tool.sh` significherebbe eseguire `apt-get install` sulla macchina sbagliata.
    - **I tre script host NON esistono su Hermes e non devono mai esservi depositati.** Se un'invocazione senza wrapper ti restituisce "No such file or directory", quello è il sintomo di un wrapper dimenticato, non di uno script mancante: NON scaricarli su Hermes per "risolvere", torna a usare `vm-exec.sh`.
    - **Lo script di backup e quelli della pipeline container girano su Hermes, direttamente, senza wrapper.** Il backup legge la VM via SSH da sé: non gira sulla VM. Non lanciare MAI `podman` o `restic` sulla VM.
    - **QUOTING — il comando remoto va in APICI SINGOLI.** `$HOME` e le altre espansioni devono essere risolte dalla shell **remota**, non da quella locale su Hermes:
      `vm-exec.sh 'sha256sum "$HOME/.audit-scripts/check-tool.sh"'` è giusto;
      `vm-exec.sh "sha256sum \"$HOME/.audit-scripts/check-tool.sh\""` è SBAGLIATO e **non dà errore**: espande la home di Hermes e poi cerca quel percorso sulla VM, dove non esiste. È il fallimento più insidioso di questa skill — se un percorso lato VM contiene il nome utente di Hermes, hai sbagliato il quoting.
    - Non scrivere MAI l'output di una pipeline nella cartella dell'altra.
    - Se `vm-exec.sh` restituisce `CONFIG_ERROR` (exit 65) o un errore di connessione SSH (exit 255), la **pipeline host non è eseguibile**: dillo esplicitamente, riporta l'output letterale e chiedi all'utente come procedere. La pipeline container resta invece eseguibile, perché non usa la VM. NON tentare scorciatoie.
4. **NON MODIFICARE il sistema**, a parte: (a) l'installazione dei 6 tool della pipeline host sulla VM, (b) la build dell'immagine container su Hermes, (c) la creazione/scrittura del repository restic su Hermes — tutte SOLO se necessarie e SOLO dopo conferma esplicita dell'utente. Il backup **legge** dalla VM e **non la modifica in alcun modo**. NESSUNA remediation, NESSUNA correzione, NESSUNA cancellazione, NESSUN cambio di configurazione, MAI, su nessuna delle due macchine.
5. **SCANSIONA SOLO IL TARGET CONFERMATO DALL'UTENTE.** La pipeline container punta a un host via rete: usa ESCLUSIVAMENTE l'indirizzo e le porte che l'utente ha confermato al passo 2a. NON scansionare altri host, NON "allargare" la scansione a una sottorete, NON dedurre target aggiuntivi da quello che trovi negli output. Scansionare un host non autorizzato è un problema legale, non solo tecnico.
6. **CONFERMA SEMPRE PRIMA** di ogni comando che installa pacchetti, costruisce un'immagine, o modifica lo stato di una delle due macchine. I comandi di sola lettura (verifica hash, check dei template, esecuzione dei tool di scansione) procedono senza conferma singola, ma SOLO dopo che l'utente ha dato il via libera generale all'inizio dell'audit.
7. **PRIMA DI OGNI COMANDO**, spiega in 1-2 frasi cosa stai per eseguire e cosa produce. Conciso, non un papiro.
8. **NON INVENTARE MAI UN OUTPUT.** Se un comando non produce risultato, va in timeout, o fallisce, riporta ESATTAMENTE quello che è successo, incluso "nessun output ricevuto" o il messaggio di errore letterale. NON descrivere MAI un risultato plausibile al posto di uno reale. Se non sei certo che un comando sia andato a buon fine, DILLO esplicitamente invece di darlo per scontato.
9. **SE UNA SITUAZIONE NON È COPERTA** da queste istruzioni, FERMATI e chiedi all'utente come procedere. NON improvvisare MAI una soluzione.
10. **BLOCCANTE, CON UNA DIFFERENZA TRA LE DUE PIPELINE:**
    - **Pipeline host: ogni tool è bloccante.** Se un tool fallisce (installazione o esecuzione), FERMA l'intero audit, notifica l'errore nel modo più esplicito possibile, e chiedi all'utente se vuole interrompere definitivamente o riprovare. NON proseguire automaticamente con i tool successivi saltando quello fallito.
    - **Pipeline container: i tre tool girano tutti, sempre.** Non è una scelta: il container è un singolo `podman run` effimero, non c'è modo di fermarsi a metà e chiedere conferma. Al termine riporti l'exit code di ciascuno **letteralmente** dal manifest e chiedi all'utente come interpretare qualunque valore diverso da 0 **prima** di comporre il report. In particolare NON classificare da solo una porta chiusa o non raggiungibile come "tool fallito": è un risultato dell'audit, non un guasto, e la distinzione la fa l'utente.
11. **NON CREARE MAI FILE DIVERSI DA QUELLI ESPLICITAMENTE ELENCATI IN QUESTA SKILL.** Gli unici file che possono esistere al termine dell'audit sono: i nove script di supporto, `vm-exec.sh` incluso (depositati, non scritti da te), i file `.raw`, `manifest.txt` e `versions.txt` nelle cartelle di output (generati dagli script, non da te), il repository restic su Hermes (gestito da `backup-target.sh`, non da te), e i file di report finali (passi 3 e 4). NON creare cartelle, bozze, file temporanei, note, o qualsiasi altro artefatto "per aiutarti a comporre il report".
12. **LA PASSWORD DEL BACKUP NON SI SCRIVE E NON SI RIPETE.** La password del repository restic te la fornisce l'utente al passo 1a. Usala **solo** per quella singola invocazione dello script. NON ripeterla in chat, NON riportarla nel report, NON scriverla in un file, NON salvarla per riusarla in un passo successivo. Se serve di nuovo, richiedila.
13. **IL BACKUP NON RIPRISTINA NULLA, MAI.** Questa skill crea snapshot e non li ripristina in nessun caso, nemmeno se l'audit va male, nemmeno se l'utente lo chiede durante l'audit: un ripristino è una modifica del target, e questa skill è solo di analisi. Se l'utente chiede un ripristino, spiega che va fatto da lui con `restic` direttamente, fuori da questa skill. Allo stesso modo NON cancellare, NON fare `forget`, NON fare `prune` di snapshot esistenti: la pulizia del repository è una sua azione manuale.

## Script di supporto

Nessuno di questi file viene scritto da te. Li verifichi (passo 0.5) e li invochi.

### Accesso alla VM — su Hermes

Percorso fisso **su Hermes**: `$HOME/.audit-scripts/helper/`

| File | SHA256 atteso |
|---|---|
| `vm-exec.sh` | `ce94cfbecd1d95867f37ff498417fb9246383891a1fb7b4a2a9f412472e5f445` |

Commit pin per il pull di questo file: `5d54bfbe94e56e6c8b112101e9a54d2f95798f0b`

**Cosa fa:**

- **`vm-exec.sh '<comando remoto>'`** — gira **su Hermes** ed esegue `<comando remoto>` **sulla VM target** via SSH. Legge host, utente, porta e chiave dal blocco `terminal:` di `~/.hermes/config.yaml`. Propaga **verbatim** l'exit code del comando remoto (indispensabile: gli script della pipeline host comunicano tramite exit code) e inoltra **stdin** (serve a scrivere file sulla VM con un heredoc risolto in locale). Il comando va passato come **un solo argomento in apici singoli** (guardrail 3). Exit code propri: 64 = uso errato, 65 = `CONFIG_ERROR` (parametri non ricavabili, porta non valida, chiave dichiarata ma assente), 255 = connessione SSH non stabilita.
- **`vm-exec.sh --show-target`** — non apre nessuna connessione: stampa `VM_TARGET`, `VM_PORT`, `VM_KEY` e `CONFIG_SOURCE`, cioè esattamente quale macchina verrà raggiunta. Serve al passo 0 per mostrarlo all'utente prima di toccare qualunque cosa. Un valore `-` significa "non configurato, deciso dai default di ssh": va passato così com'è a `backup-target.sh`, che lo accetta.

Questo è l'**unico** modo in cui raggiungi la VM. Non comporre comandi `ssh` a mano, in nessun punto dell'audit.

### Pipeline host (v1.0) — sulla VM target

Questi tre script **risiedono ed eseguono sulla VM target**, e si invocano **sempre** tramite `vm-exec.sh` (guardrail 3).

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

### Backup pre-audit — su Hermes

Percorso fisso **su Hermes**: `$HOME/.audit-scripts/backup/`

| File | SHA256 atteso |
|---|---|
| `backup-target.sh` | `d276118fc08c4a248863d56aaa58ec534c62f4458f03dbbbd995667b9aa1cabe` |

Commit pin per il pull di questo file: `5d54bfbe94e56e6c8b112101e9a54d2f95798f0b`

**Cosa fa:**

- **`backup-target.sh <ssh-target> <identity-file|-> <ssh-port|-> <repo-path> <mode> [extra-path ...]`** — gira **su Hermes**. Tira i dati dalla VM via SSH (con le stesse credenziali della pipeline host) come tar non compresso, che preserva proprietario e permessi dei file; li deposita in una staging area locale con permessi 700; esegue `restic backup` su un repository locale a Hermes; poi **cancella sempre** la staging area, anche in caso di errore. Modi: `default` (solo i path che l'audit modifica) e `full` (tutta la VM). In `default` accetta path aggiuntivi, passati verbatim. Verifica che il tar scaricato non sia vuoto né corrotto prima di procedere. Chiave SSH e porta accettano `-` per lasciare il default (rispettivamente `~/.ssh/config` e la porta 22), ma in questa skill si passano sempre espliciti, ricavati da `vm-exec.sh --show-target`. Legge la password da `RESTIC_PASSWORD` (o `RESTIC_PASSWORD_FILE` / `RESTIC_PASSWORD_COMMAND`) nell'ambiente — mai da un argomento. Exit code: 0 = fatto, 1 = fallito (riporta `STAGE=`), 2 = uso errato, 3 = restic non installato su Hermes, 4 = password non configurata.

### Pipeline container (v2.0) — su Hermes

Percorso fisso **su Hermes**: `$HOME/.audit-scripts/container/`

| File | SHA256 atteso |
|---|---|
| `Containerfile` | `9d528e6c6c4d17c2aa95f201ad5ef6c2cadb70e0bfc0fc10e00f5cf549826796` |
| `entrypoint.sh` | `497ac4565d4f90d8b6a280e457f8c59f268108331aec3894839e38dc3a6c2d6e` |
| `check-templates.sh` | `6c078a2334fa242d25d1ec8064d0dcc1ad4f97661237eac8d283c1e575c2d0f8` |
| `run-audit-container.sh` | `5fd72a81b3a45aa58f1b317bc378408ee395d15b7cdbc72a2fe21b71c3a40177` |

Commit pin per il pull di questi quattro: `266072c08570127707fb468789549c11430d782d`

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

**Se la pipeline host è inclusa**, la prima cosa da verificare è `vm-exec.sh`: tutto ciò che riguarda la VM passa da lui, quindi il suo controllo di integrità va **anticipato qui** rispetto al passo 0.5, prima del suo primo utilizzo. Esegui su Hermes:

```bash
sha256sum "$HOME/.audit-scripts/helper/vm-exec.sh" 2>/dev/null
```

Confrontalo con l'hash atteso in "Accesso alla VM". Assente o non corrispondente: si applica il passo 0.5 (punti b e c) con il suo commit pin — è un guasto bloccante per la pipeline host.

Poi mostra all'utente quale macchina verrà raggiunta, prima di toccare qualunque cosa:

```bash
"$HELPER_DIR/vm-exec.sh" --show-target
```

Riporta all'utente i valori stampati (`VM_TARGET`, `VM_PORT`, `VM_KEY`) e **fatteli confermare**: è il target che la pipeline host analizzerà e da cui il backup leggerà. Se restituisce `CONFIG_ERROR` (exit 65), la pipeline host non è eseguibile: vedi guardrail 3.

Poi calcola e tieni a mente per il resto della sessione. **Attenzione a quale `$HOME` è quale**: nei percorsi marcati "sulla VM" il `$HOME` è quello della VM e va lasciato espandere alla shell remota (apici singoli, guardrail 3); in quelli marcati "su Hermes" è la home locale.

- **`HELPER_DIR`** = `$HOME/.audit-scripts/helper` — **su Hermes**, fisso. Contiene `vm-exec.sh`.
- **`NOME_BASE`**:
  - se la pipeline host è inclusa: esegui `"$HELPER_DIR/vm-exec.sh" 'hostname'` e usa `<hostname sanificato: solo alfanumerici e trattini>-<HH-MM>` (se non produce un valore utilizzabile, usa `vm-audit-<HH-MM>`). Questa è anche la prima verifica concreta che l'SSH verso la VM funzioni: se fallisce con exit 255, fermati e vedi guardrail 3.
  - se è stata scelta **solo** la pipeline container: la VM non va toccata affatto, quindi NON eseguire `hostname` lì né invocare `vm-exec.sh`. Usa `<target sanificato: solo alfanumerici e trattini>-<HH-MM>`, dove il target è quello confermato al passo 2a.
- **`OUTDIR_HOST`** = `$HOME/audit-output/<NOME_BASE>` — **sulla VM target**. Serve solo se la pipeline host è inclusa.
- **`OUTDIR_CONTAINER`** = `$HOME/audit-output/<NOME_BASE>-container` — **su Hermes**. Serve solo se la pipeline container è inclusa.
- **`SCRIPTS_DIR`** = `$HOME/.audit-scripts` — **sulla VM target**, fisso.
- **`CONTAINER_DIR`** = `$HOME/.audit-scripts/container` — **su Hermes**, fisso.
- **`BACKUP_DIR`** = `$HOME/.audit-scripts/backup` — **su Hermes**, fisso. Serve solo se la pipeline host è inclusa.
- **`BACKUP_REPO`** = `$HOME/.audit-backups/<target sanificato>` — **su Hermes**. Un repository per target, riusato tra audit successivi: restic accumula uno snapshot per esecuzione e deduplica, quindi NON creare un repository nuovo ogni volta.

Annota l'ora corrente (HH:MM) e chiedi conferma esplicita per procedere prima di eseguire qualsiasi altro comando.

### 0.5. Verifica integrità degli script (SOLO LETTURA — nessuna scrittura, in nessun caso)

Verifica **solo** gli script delle pipeline effettivamente selezionate al passo 0.

Per ciascun file da verificare, nell'ordine:

- pipeline host: `vm-exec.sh` in `$HELPER_DIR` **su Hermes** (già verificato al passo 0: non rifarlo), poi `check-tool.sh`, `install-tool.sh`, `run-tool.sh` in `$SCRIPTS_DIR` **sulla VM**, più `backup-target.sh` in `$BACKUP_DIR` **su Hermes**
- pipeline container: `Containerfile`, `entrypoint.sh`, `check-templates.sh`, `run-audit-container.sh` in `$CONTAINER_DIR` **su Hermes**

a. Calcola l'hash **sulla macchina giusta** (guardrail 3):

```bash
# file su Hermes (vm-exec.sh, backup-target.sh, file container)
sha256sum "<percorso>/<file>" 2>/dev/null

# file sulla VM (i tre della pipeline host) — apici singoli, $HOME è quello della VM
"$HELPER_DIR/vm-exec.sh" 'sha256sum "$HOME/.audit-scripts/<file>" 2>/dev/null'
```

b. **Se il file è assente**: notifica chiaramente che non è presente e che può essere recuperato dalla repo pubblica del progetto (`https://github.com/gabriele1701/Agentic-audit`), al commit pin che gli corrisponde (vedi le tabelle sopra: `5d54bfb...` per `vm-exec.sh` e per lo script di backup, `d4d3f52...` per gli script host, `266072c...` per i file container). Spiega che farai un pull via `curl` da quella fonte. Chiedi conferma esplicita prima di procedere.

   Solo dopo conferma, esegui — **sulla macchina giusta**, e con il commit pin e il percorso corretti per quella pipeline:

```bash
   # vm-exec.sh (su Hermes) — va depositato per primo: senza di lui non si
   # raggiunge la VM, quindi nemmeno si verificano i tre script host
   mkdir -p "$HELPER_DIR"
   curl -fsSL "https://raw.githubusercontent.com/gabriele1701/Agentic-audit/5d54bfbe94e56e6c8b112101e9a54d2f95798f0b/helper/vm-exec.sh" -o "$HELPER_DIR/vm-exec.sh" && chmod +x "$HELPER_DIR/vm-exec.sh"

   # pipeline host (SULLA VM TARGET) — un'unica invocazione remota, in apici
   # singoli: il curl deve girare sulla VM, non su Hermes
   "$HELPER_DIR/vm-exec.sh" 'mkdir -p "$HOME/.audit-scripts" && curl -fsSL "https://raw.githubusercontent.com/gabriele1701/Agentic-audit/d4d3f5281b706bcd92a61666ac1a090fc56e9bc8/scripts/<file>" -o "$HOME/.audit-scripts/<file>" && chmod +x "$HOME/.audit-scripts/<file>"'

   # script di backup (su Hermes)
   mkdir -p "$BACKUP_DIR"
   curl -fsSL "https://raw.githubusercontent.com/gabriele1701/Agentic-audit/5d54bfbe94e56e6c8b112101e9a54d2f95798f0b/backup/backup-target.sh" -o "$BACKUP_DIR/backup-target.sh" && chmod +x "$BACKUP_DIR/backup-target.sh"

   # pipeline container (su Hermes) — i TRE SCRIPT (entrypoint.sh,
   # check-templates.sh, run-audit-container.sh), una riga per ciascuno:
   # il chmod e' concatenato al curl e non va separato, altrimenti il file
   # resta a 644 e la pipeline fallisce con "Permission denied" (exit 126)
   mkdir -p "$CONTAINER_DIR"
   curl -fsSL "https://raw.githubusercontent.com/gabriele1701/Agentic-audit/266072c08570127707fb468789549c11430d782d/container/<script>" -o "$CONTAINER_DIR/<script>" && chmod +x "$CONTAINER_DIR/<script>"

   # il Containerfile a parte: non e' eseguibile, nessun chmod
   curl -fsSL "https://raw.githubusercontent.com/gabriele1701/Agentic-audit/266072c08570127707fb468789549c11430d782d/container/Containerfile" -o "$CONTAINER_DIR/Containerfile"
```

   Il `curl` degli script host gira **sulla VM**: serve quindi che la VM abbia accesso a internet. Se non ce l'ha, il pull fallisce e l'utente deve depositare i file a mano — NON ripiegare sul depositarli su Hermes (guardrail 3).

   Se l'utente nega il permesso, FERMA l'audit (lo script è necessario, bloccante) e chiedi come procedere.

   Poi ricalcola l'hash e confrontalo con quello atteso, come ai punti (c) e (d).
   Se `curl` fallisce (nessuna connessione, 404, ecc.), notificalo con l'output letterale: GUASTO BLOCCANTE, fermati e chiedi all'utente come procedere — non improvvisare un contenuto alternativo in nessun caso.

c. **Se l'hash non corrisponde** a quello atteso: GUASTO BLOCCANTE. FERMA l'intero audit. Riporta entrambi gli hash (atteso e ottenuto) e comunica che il file depositato non è integro — l'utente deve verificarlo e ridepositarlo. NON tentare di correggerlo o riscriverlo tu.

d. **Se l'hash corrisponde**: comunica brevemente "verificato", passa al successivo.

Solo se **tutti** i file delle pipeline selezionate sono presenti e verificati, comunica che il bootstrap è completo e procedi. Se anche un solo file non supera la verifica, l'audit si ferma qui: non eseguire alcun tool, anche se gli altri file fossero a posto.

---

### 1. Pipeline host — SOLO se selezionata al passo 0

#### 1a. Backup di sicurezza pre-audit

Questo passo gira **su Hermes** (vedi guardrail 3), ed è il primo della pipeline host: viene **prima** di qualunque verifica o installazione sulla VM, perché il suo scopo è proteggere lo stato del target da ciò che l'audit sta per fare.

Spiega all'utente cosa stai per fare: un backup con restic della macchina target, come rete di sicurezza temporanea nel caso l'audit causi problemi. Chiarisci che **non sostituisce un backup proprio** della VM.

**i. Scelta dello scope.** Chiedi all'utente quale modo usare:
- **`default`** (consigliato) — backuppa solo ciò che l'audit effettivamente modifica: `/etc/apt/sources.list.d`, `/etc/sudoers.d`, la chiave apt di trivy, più uno snapshot dell'elenco pacchetti installati. Veloce, pochi KB.
- **`default` con path aggiuntivi** — come sopra, più i path che l'utente indica. Passali allo script **verbatim**, come argomenti dopo il modo: non interpretarli, non espanderli, non aggiungerne di tua iniziativa.
- **`full`** — tutta la VM. Avvisa che può richiedere molto tempo e molto spazio su Hermes, proporzionali alla dimensione della VM.

Avvisa che i modi diversi da `default` richiedono una riga `sudoers` dedicata sulla VM (vedi README): se manca, il pull fallisce con un errore di `sudo`.

**ii. Password del repository.** Chiedi all'utente la password del repository restic. Se è il primo backup per questo target, il repository viene creato ora e quella password sarà **l'unica** via d'accesso agli snapshot: dillo esplicitamente, perché perderla significa perdere i backup. Vale il guardrail 12: usa la password solo per questa invocazione, non ripeterla, non salvarla.

**iii. Esecuzione.** Il repository viene creato se non esiste, quindi questo comando **modifica lo stato di Hermes**: chiedi conferma esplicita prima (guardrail 4 e 6). Poi esegui:

```bash
RESTIC_PASSWORD='<password fornita dall'utente>' "$BACKUP_DIR/backup-target.sh" \
    "<VM_TARGET>" "<VM_KEY>" "<VM_PORT>" "$BACKUP_REPO" "<modo>" [path aggiuntivi...]
```

`VM_TARGET`, `VM_KEY` e `VM_PORT` sono **esattamente** i valori stampati da `vm-exec.sh --show-target` al passo 0, passati verbatim (`-` compreso, se è quello il valore): non chiederli all'utente, non ricavarli altrove, non riscriverli a memoria.

Questo script gira **su Hermes** e fa SSH verso la VM da sé: NON va invocato tramite `vm-exec.sh` (guardrail 3).

**iv. Esiti.** Interpreta l'output **letteralmente**:

- **`STATUS=OK SNAPSHOT=<id>`** — backup completato. Riporta l'ID dello snapshot all'utente e **tienilo a mente**: va dichiarato nell'intestazione del report host (passo 3). Procedi al passo 1b.
- **`RESTIC_MISSING` (exit 3)** — restic non è installato su Hermes. NON tentare di installarlo tu. Riportalo, indica che il README documenta come installarlo con verifica dell'hash, e chiedi all'utente se vuole installarlo e riprovare, oppure procedere senza backup (vedi sotto).
- **`PASSWORD_NOT_SET` (exit 4)** o **`USAGE_ERROR` (exit 2)** — errore nell'invocazione. Correggi l'invocazione (password o argomenti) e riprova. Se non è chiaro cosa manca, fermati e chiedi.
- **`STATUS=FAIL STAGE=<fase>` (exit 1)** — il backup è fallito. Riporta la fase e l'output letterale. Le fasi dicono dove: `pull-packages` / `pull-files` (problema SSH o `sudo` sulla VM), `verify` (il pull non ha prodotto dati utilizzabili), `repo-init` / `backup` (problema restic su Hermes).

**In caso di fallimento, il backup NON blocca automaticamente l'audit, ma NON procedere di tua iniziativa.** Spiega all'utente che la rete di sicurezza non si è attivata e chiedi **permesso esplicito** per una delle due strade: procedere comunque con la pipeline host senza backup, oppure fermare qui l'audit. Se l'utente sceglie di procedere, annotalo: va dichiarato nel report host (passo 3). Se l'utente non si esprime chiaramente, fermati.

#### 1b. Sequenza dei tool

Tutti i comandi di questo passo girano **sulla VM target**, quindi **ognuno** passa da `vm-exec.sh`, in apici singoli (guardrail 3). Sostituisci `<NOME_BASE>` con il valore calcolato al passo 0: dentro gli apici singoli `$HOME` si espande sulla VM, `<NOME_BASE>` no — quello lo scrivi tu.

Ordine fisso, uno alla volta: lynis → trivy → nmap → debsecan → chkrootkit → rkhunter.

a. **Verifica presenza**: esegui

```bash
"$HELPER_DIR/vm-exec.sh" '"$HOME/.audit-scripts/check-tool.sh" <tool>'
```

   Spiega brevemente cosa stai controllando. Guarda l'exit code: 0 = presente, 1 = assente. Un exit 255 non è una risposta dello script: è la connessione SSH caduta (guardrail 3).

b. **Se assente (exit 1)**: notifica chiaramente che manca. Spiega cosa farà `install-tool.sh` per quel tool specifico (per trivy, specifica che aggiunge un repository apt dedicato). Chiedi conferma esplicita. Solo dopo conferma, esegui

```bash
"$HELPER_DIR/vm-exec.sh" '"$HOME/.audit-scripts/install-tool.sh" <tool> --confirm'
```

   Se l'utente nega il permesso, FERMA l'audit (il tool è bloccante) e chiedi come procedere. Se lo script restituisce `INSTALL_FAILED` (exit 1), FERMA l'audit e riporta l'output letterale.
   - **Eccezione debsecan**: se l'installazione fallisce perché il pacchetto non è disponibile per la release della VM, lo script lo segnalerà con `INSTALL_FAILED`. Essendo bloccante, FERMA e chiedi all'utente se vuole una deroga esplicita per saltare debsecan o interrompere l'audit.

c. **Se presente o appena installato**: spiega cosa stai per eseguire, poi esegui

```bash
"$HELPER_DIR/vm-exec.sh" '"$HOME/.audit-scripts/run-tool.sh" <tool> "$HOME/audit-output/<NOME_BASE>"'
```

   Attendi il completamento — lynis e trivy possono richiedere alcuni minuti.

d. **Se lo script restituisce `STATUS=FAIL`**: FERMA l'audit, riporta l'exit code e l'ultima parte dell'output del comando, leggibile con

```bash
"$HELPER_DIR/vm-exec.sh" 'tail -n 20 "$HOME/audit-output/<NOME_BASE>/<tool>.raw"'
```

   poi chiedi all'utente se interrompere o riprovare.

e. **Se lo script restituisce `STATUS=OK`**: conferma brevemente che l'output è stato salvato in `$OUTDIR_HOST/<tool>.raw`, poi passa al tool successivo.

Al termine della pipeline host (backup incluso): se era stata selezionata **anche** quella container, comunica che lo stage host è concluso e che stai passando allo stage container; genera il report host al passo 3 **dopo** aver completato anche lo stage container, oppure subito — in entrambi i casi i due report restano file separati e non si mescolano.

---

### 2. Pipeline container — SOLO se selezionata al passo 0

Tutti i comandi di questo passo girano **su Hermes**, localmente. Se non puoi eseguire comandi localmente su Hermes, vedi guardrail 3: fermati e chiedi.

#### 2a. Parametri del target

Chiedi all'utente l'indirizzo del target e le porte da usare:

- **Se la pipeline host è già girata in questa sessione**: chiedi se vuole **riusare** l'host target già analizzato (quello mostrato da `vm-exec.sh --show-target` al passo 0) o **fornirne uno nuovo**. Non dare per scontato il riuso: chiedilo.
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

Gli output sono **sulla VM**, quindi anche la lettura e la scrittura dei report passano da `vm-exec.sh`.

Leggi il manifest per avere la lista esatta di cosa è stato eseguito, con quale exit code, e dove si trova l'output, poi leggi ciascun `.raw`:

```bash
"$HELPER_DIR/vm-exec.sh" 'cat "$HOME/audit-output/<NOME_BASE>/manifest.txt"'
"$HELPER_DIR/vm-exec.sh" 'cat "$HOME/audit-output/<NOME_BASE>/<tool>.raw"'
```

Genera **due file separati**, scritti in `$OUTDIR_HOST` (sulla VM). L'heredoc viene risolto su Hermes e inviato via stdin al `cat` remoto, così il contenuto non deve attraversare nessun livello di quoting aggiuntivo:

```bash
"$HELPER_DIR/vm-exec.sh" 'cat > "$HOME/audit-output/<NOME_BASE>/<nome-file>"' << 'EOF'
<contenuto del report>
EOF
```

Il delimitatore va scritto `<< 'EOF'` con gli apici: senza, la shell di Hermes espanderebbe `$...` e i backtick dentro il contenuto del report, che include output grezzi dei tool.

I due file sono:

- `$OUTDIR_HOST/<NOME_BASE>-report.md`
- `$OUTDIR_HOST/<NOME_BASE>-raw-logs.md`

**File 1 — `<NOME_BASE>-report.md`:**

```markdown
# Report di Audit di Sicurezza (host) — <hostname VM>
**Pipeline:** host (v1.0) — analisi dall'interno della VM via SSH
**Data e ora di esecuzione:** <data e ora ISO, inizio e fine stage>
**Host target:** <IP/host SSH>
**Backup pre-audit:** <snapshot restic ID e modo usato, dal passo 1a — oppure "NON ESEGUITO" con il motivo esatto e la nota che l'utente ha dato permesso esplicito di procedere senza>
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

Se è stato fatto un backup, ricorda all'utente che lo snapshot resta nel repository restic su Hermes (`$BACKUP_REPO`), insieme a quelli degli audit precedenti, e che la sua pulizia è una sua azione manuale: tu non la fai mai (guardrail 13).

Il container è già stato distrutto automaticamente (`podman run --rm`); l'immagine locale resta su Hermes per i run successivi. NON proporre di rimuoverla, NON proporre azioni correttive sul target né offrirti di eseguirle, NON proporre di ripristinare il backup: questa skill è SOLO di audit.
