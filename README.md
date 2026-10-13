# Agentic Audit — skill `/audit` per Hermes Agent

Skill custom per [Hermes Agent](https://github.com/NousResearch) che esegue un audit di sicurezza automatizzato su una macchina remota, combinando script bash deterministici con un agente IA per la narrazione, le conferme e la sintesi finale. Due pipeline indipendenti e selezionabili: una **dall'interno** della macchina via SSH, una **dall'esterno** via rete da un container effimero — più un backup di sicurezza prima di toccare il target.
L’agente monitora l’esecuzione e, se il processo si blocca, riporta in chat il motivo con l’output letterale ricevuto. È possibile discutere con l’agente per approfondire o localizzare la causa del problema, senza perdere il progresso dell’audit — ma l’agente non intraprende mai un’azione di propria iniziativa: ogni comando resta soggetto a conferma esplicita dell’utente.

## A cosa serve

Questa skill automatizza un audit di sicurezza difensivo di base su un sistema Linux, in **due pipeline indipendenti** che scegli all'avvio: una sola, o entrambe.

### Pipeline host — la VM vista dall'interno

Gira **sulla VM target**, raggiunta via SSH da Hermes, ed esegue in sequenza sei tool consolidati:

- **lynis** — hardening e configurazione generale del sistema
- **trivy** — vulnerabilità note su filesystem e, se presente, immagini Docker
- **nmap** — porte e servizi esposti (su localhost e sull'interfaccia di rete primaria)
- **debsecan** — vulnerabilità note nei pacchetti Debian/Ubuntu installati
- **chkrootkit** — ricerca di rootkit
- **rkhunter** — ricerca di rootkit ed exploit noti

Prima di installare qualunque cosa, questa pipeline esegue un **backup di sicurezza** della VM con [restic](https://github.com/restic/restic) — vedi sotto.

### Pipeline container — la VM vista dall'esterno

Gira **su Hermes**, dentro un container effimero che punta al target via rete, come farebbe qualcuno che osserva la macchina da fuori. Non richiede **nessuna credenziale** verso il target, solo raggiungibilità di rete:

- **ssh-audit** — algoritmi, cifrari e configurazione del server SSH
- **testssl.sh** — configurazione TLS/SSL, certificati, vulnerabilità note del canale cifrato
- **nuclei** — scansione basata su template per vulnerabilità ed esposizioni note

Il container viene costruito da un `Containerfile` con i tre tool pinnati a versioni fisse e verificati via SHA256 **durante la build**, eseguito con Podman, e distrutto a fine audit.

### Output

Ogni pipeline produce **due file markdown indipendenti**: un report elaborato (sintesi, problemi critici, raccomandazioni) e un file con i log grezzi integrali di ogni tool, così ogni affermazione nel report è sempre verificabile contro l'output originale. Scegliendo una sola pipeline ottieni solo i suoi due file; scegliendo entrambe ne ottieni quattro, ciascuno autosufficiente — i report non vengono mescolati.

**Ambienti supportati**: qualsiasi macchina target Linux basata su **Debian/Ubuntu** (gli script di installazione usano `apt-get`), raggiungibile via SSH da Hermes. La pipeline container richiede **Podman** su Hermes; il backup richiede **restic** su Hermes.

## Come avviene l'audit

L'audit non è lasciato all'improvvisazione del modello: la parte meccanica (verifica presenza tool, installazione, esecuzione, salvataggio output, backup, build del container) è delegata a **script bash deterministici**, sempre gli stessi comandi fissi. L'agente si occupa di spiegare ogni passaggio, chiedere conferma prima di qualsiasi installazione o modifica del sistema, fermarsi sugli errori, e scrivere la sintesi finale basandosi solo sui dati effettivamente raccolti — mai inventati.

L'agente non scrive né modifica mai questi script: ne verifica l'hash SHA256 prima di usarli, e si ferma se non corrisponde.

## Come Hermes raggiunge le due macchine

Questa skill ha bisogno di lavorare su **due macchine diverse**: la VM target (pipeline host) e Hermes stesso (pipeline container e backup). Il backend terminal di Hermes è però un'impostazione **globale e unica**: o punta tutto alla VM via SSH, o esegue tutto in locale. Non esiste un modo nativo per usarne due insieme, o per scegliere il backend comando per comando.

La soluzione adottata è: **backend `local`, SSH esplicito dove serve.**

```
                       Hermes (backend: local)
                       ├── podman build/run ────────────► container effimero ──┐
                       ├── restic backup                                       │ rete
                       │      └── ssh ──────────────────────────────► VM target ◄┘
                       └── vm-exec.sh ──── ssh ─────────────────────► VM target
                                                                      ├── check-tool.sh
                                                                      ├── install-tool.sh
                                                                      └── run-tool.sh
```

Tutto ciò che l'agente esegue parte da Hermes. I tre script della pipeline host continuano a **risiedere ed eseguire sulla VM**, esattamente come in v1.0: vengono raggiunti tramite `helper/vm-exec.sh`, che legge host, utente, porta e chiave dal blocco `terminal:` di `config.yaml` — gli stessi valori che il backend `ssh` usava prima. Quei valori restano quindi in `config.yaml` anche se il backend non li usa più: sono l'unica fonte di verità per la connessione.

Il vantaggio non è solo pratico. Con il backend `ssh` un comando destinato a Hermes finiva silenziosamente sulla VM; ora è il contrario, ma con una differenza importante: i tre script host **non esistono su Hermes**, quindi un'invocazione a cui sfugga il wrapper fallisce con "No such file or directory" invece di eseguire `apt-get install` sulla macchina sbagliata.

### Se preferisci tenere il backend su `ssh`

Puoi farlo, ma funzionerà **solo la pipeline host**: backup e pipeline container richiedono `podman` e `restic` su Hermes, e con il backend `ssh` quei comandi finiscono sulla VM, dove non sono installati. La skill lo rileva e lo dichiara invece di tentare scorciatoie.

## Il backup di sicurezza (pipeline host)

La pipeline host installa pacchetti e aggiunge repository apt sulla VM. Prima di farlo, esegue un backup con restic come **rete di sicurezza temporanea**, nel caso l'audit causi problemi.

> **Questo non è, e non deve diventare, il backup ufficiale della tua VM.** È uno snapshot di emergenza, pensato per il caso specifico in cui l'audit combini danni. Tienine uno tuo, vero, separato.

Come funziona:

- Gira **su Hermes**, non sulla VM: Hermes tira i dati via SSH con le stesse credenziali già usate dal resto della pipeline host, quindi **non serve configurare nessun nuovo accesso**.
- I dati arrivano come **tar non compresso**, che preserva proprietario e permessi dei file — importante perché `/etc/sudoers.d` deve tornare `root:root 0440` o `sudo` lo rifiuta. Un semplice `scp` questa fedeltà la perderebbe.
- Il repository restic è **locale a Hermes**, uno per target, riusato tra audit successivi: restic accumula uno snapshot per esecuzione e deduplica, quindi lo spazio cresce molto più lentamente di quanto si aspetterebbe.
- La **password te la chiede l'agente a ogni audit** e non viene salvata da nessuna parte. Se è il primo backup per quel target, quella password è l'unica via d'accesso agli snapshot: perderla significa perderli.
- Se il backup fallisce, l'audit **non si ferma da solo** ma non prosegue di sua iniziativa: l'agente ti dice cosa è andato storto e ti chiede il permesso esplicito di continuare senza rete di sicurezza, o di fermarsi.

### Modi di backup

| Modo | Cosa include | Quando usarlo |
|---|---|---|
| `default` | Solo ciò che l'audit modifica: `/etc/apt/sources.list.d`, `/etc/sudoers.d`, la chiave apt di trivy, più l'elenco dei pacchetti installati | Default consigliato. Pochi KB, pochi secondi. |
| `default` + path extra | Come sopra, più i path che indichi tu | Quando hai sulla VM qualcosa che vuoi proteggere in più |
| `full` | Tutta la VM (esclusi `/proc`, `/sys`, `/dev`, `/run`, `/tmp`, `/mnt`, `/media`, cache apt) | Quando vuoi copertura totale e hai tempo e spazio su Hermes |

### Ripristino e pulizia: restano a te

La skill **crea** snapshot e non li ripristina mai, nemmeno se glielo chiedi durante l'audit: un ripristino è una modifica del target, e questa skill è dichiaratamente solo di analisi. Allo stesso modo non cancella e non fa `prune` di nulla.

Per ripristinare, da Hermes:

```bash
# vedi gli snapshot disponibili per un target
restic -r ~/.audit-backups/<target> snapshots

# ripristina in una cartella di appoggio
restic -r ~/.audit-backups/<target> restore latest --target /tmp/ripristino

# dentro c'è target-files.tar (con permessi e proprietari originali)
# e target-files.index.txt, che elenca cosa contiene
find /tmp/ripristino -name 'target-files*'

# estrai solo ciò che ti serve, come root per riottenere i permessi corretti
sudo tar -xvf "$(find /tmp/ripristino -name target-files.tar)" -C / <path-da-ripristinare>
```

Per liberare spazio, `restic forget` e `restic prune` sono comandi tuoi da dare quando vuoi: la skill non li esegue mai.

## Prerequisiti

### Per tutte le pipeline

1. **Hermes Agent con backend terminal in locale.** In `~/.hermes/config.yaml`:

   ```yaml
   terminal:
     backend: local
     ssh_host: <IP della VM>
     ssh_user: <utente SSH sulla VM>
     ssh_port: 22
     ssh_key: '/home/<utente-hermes>/.ssh/<chiave>'
     cwd: /home/<utente-hermes>
   ```

   Oppure `hermes config set terminal.backend local`. Il perché è spiegato in "Come Hermes raggiunge le due macchine": è il presupposto su cui si regge tutto il resto.

   Due dettagli che è facile sbagliare:
   - **`cwd` deve essere una directory esistente su Hermes.** Se resta puntato alla home della VM (tipico se arrivi da un setup con backend `ssh`), *ogni* comando fallisce la `cd` iniziale, anche quelli che non c'entrano nulla con la VM.
   - **Le chiavi `ssh_*` vanno lasciate dov'erano**, anche se il backend non le usa più: `vm-exec.sh` le legge da lì.

2. **Chiave SSH verso la VM funzionante come file su Hermes**, con la pubblica corrispondente in `~/.ssh/authorized_keys` sulla VM. Deve essere **senza passphrase** o già sbloccata in un agent: le connessioni avvengono in modalità non interattiva (`BatchMode=yes`), quindi un prompt non verrebbe mostrato a nessuno e il comando fallirebbe. Verifica con:

   ```bash
   ~/.audit-scripts/helper/vm-exec.sh --show-target   # quale macchina verrà raggiunta
   ~/.audit-scripts/helper/vm-exec.sh 'whoami'        # deve rispondere l'utente della VM
   ```

   Se il secondo comando risponde con l'utente di *Hermes* invece che con quello della VM, `ssh_host` sta puntando a Hermes stesso: correggilo prima di lanciare un audit, altrimenti la pipeline host analizzerebbe la macchina sbagliata.

### Per la pipeline host

3. **Macchina target Debian/Ubuntu**, con accesso internet in uscita (per installare i tool mancanti e per il pull automatico degli script, se necessario).
4. **restic su Hermes**, per il backup di sicurezza. Se manca, la skill te lo segnala e ti chiede se installarlo o procedere senza backup — non lo installa da sola. Per installarlo con verifica dell'hash:

   ```bash
   VER=0.19.1
   curl -fsSLO "https://github.com/restic/restic/releases/download/v${VER}/restic_${VER}_linux_amd64.bz2"
   curl -fsSLO "https://github.com/restic/restic/releases/download/v${VER}/SHA256SUMS"
   grep "restic_${VER}_linux_amd64.bz2" SHA256SUMS | sha256sum -c -
   bunzip2 "restic_${VER}_linux_amd64.bz2"
   sudo install -m 755 "restic_${VER}_linux_amd64" /usr/local/bin/restic
   restic version
   ```

   Va anche bene `apt install restic`, tenendo presente che la versione nei repository è spesso più vecchia.

5. **Regole sudo senza password sulla VM target**, scoped esclusivamente ai comandi usati da questa skill. Senza questo passaggio, l'audit si ferma al primo comando che richiede `sudo`, perché l'esecuzione non interattiva non fornisce un terminale a cui `sudo` possa chiedere la password.

   > Il file va creato **sulla VM target**, non su Hermes, e l'`<utente>` è quello SSH della VM (`ssh_user` in `config.yaml`). Su Hermes questa skill non ha bisogno di nessuna regola `sudo`.

   Prima verifica i percorsi reali sulla macchina target:

   ```bash
   which lynis nmap chkrootkit rkhunter apt-get gpg tee cat
   ```

   Poi crea il file (sostituendo ogni percorso con quello ottenuto sopra, ed `<utente>` con l'utente SSH usato):

   ```bash
   sudo visudo -f /etc/sudoers.d/audit-scripts
   ```

   Contenuto:

   ```
   <utente> ALL=(root) NOPASSWD: <path-lynis> audit system --quiet
   <utente> ALL=(root) NOPASSWD: <path-cat> /var/log/lynis-report.dat
   <utente> ALL=(root) NOPASSWD: <path-nmap> -sV -p- 127.0.0.1
   <utente> ALL=(root) NOPASSWD: <path-nmap> -sV -p- *
   <utente> ALL=(root) NOPASSWD: <path-chkrootkit>
   <utente> ALL=(root) NOPASSWD: <path-rkhunter> --check --sk --rwo
   <utente> ALL=(root) NOPASSWD: <path-apt-get> update
   <utente> ALL=(root) NOPASSWD: <path-apt-get> install -y lynis
   <utente> ALL=(root) NOPASSWD: <path-apt-get> install -y trivy
   <utente> ALL=(root) NOPASSWD: <path-apt-get> install -y nmap
   <utente> ALL=(root) NOPASSWD: <path-apt-get> install -y debsecan
   <utente> ALL=(root) NOPASSWD: <path-apt-get> install -y chkrootkit
   <utente> ALL=(root) NOPASSWD: <path-apt-get> install -y rkhunter
   <utente> ALL=(root) NOPASSWD: <path-gpg> --dearmor -o /usr/share/keyrings/trivy.gpg
   <utente> ALL=(root) NOPASSWD: <path-tee> /etc/apt/sources.list.d/trivy.list
   ```

   Salva (`visudo` valida la sintassi da solo), poi:

   ```bash
   sudo chmod 440 /etc/sudoers.d/audit-scripts
   ```

   Ogni riga è vincolata al comando esatto, incluso gli argomenti — non è un `NOPASSWD: ALL`. Resta scoped solo a ciò che questa skill usa.

   Verifica che sudo le abbia accettate prima di lanciare un audit:

   ```bash
   sudo -l -U <utente>
   ```

6. **Regola sudo per il backup**, sempre sulla VM target. Il backup legge `/etc/sudoers.d`, che un utente non privilegiato non può leggere, quindi serve una riga dedicata. Verifica prima il percorso reale di `tar` sulla VM (`which tar`), poi aggiungi al file `/etc/sudoers.d/audit-scripts`:

   ```
   <utente> ALL=(root) NOPASSWD: <path-tar> -cf - --absolute-names --ignore-failed-read /etc/apt/sources.list.d /etc/sudoers.d /usr/share/keyrings/trivy.gpg
   ```

   Questa riga autorizza **esattamente** il comando del modo `default`, argomenti inclusi: non concede `tar` generico.

   Se vuoi usare il modo `full`, serve anche questa riga:

   ```
   <utente> ALL=(root) NOPASSWD: <path-tar> -cf - --absolute-names --ignore-failed-read --one-file-system --exclude=/proc --exclude=/sys --exclude=/dev --exclude=/run --exclude=/tmp --exclude=/mnt --exclude=/media --exclude=/lost+found --exclude=/var/cache/apt/archives /
   ```

   Le due righe devono combaciare **carattere per carattere** con il comando che `backup-target.sh` costruisce: stesso ordine dei flag e stesso ordine dei path. Conviene copiare i path direttamente dall'array `DEFAULT_PATHS` dello script ([`backup/backup-target.sh`](./backup/backup-target.sh)) invece di ritrascriverli: se divergono anche di un solo carattere, `sudo` rifiuta la riga e il backup fallisce con `STATUS=FAIL STAGE=pull-files`.

   > **Attenzione se aggiungi path extra al backup.** Ogni combinazione di path produce un comando `tar` diverso, che le righe sopra non matchano. Puoi aggiungere una riga per la combinazione esatta che ti serve, oppure usare una wildcard — ma sappi cosa stai concedendo: `NOPASSWD` su `tar` con argomenti liberi equivale, in pratica, a **lettura come root di tutto il filesystem** (e `tar` sa anche scrivere file). Preferisci righe esatte per i path che ti servono davvero.

### Per la pipeline container

7. **Podman su Hermes**. La pipeline container costruisce ed esegue l'immagine con Podman (non Docker). In WSL serve WSL2: su WSL1 Podman non funziona. Verifica con `podman info`.

   Su WSL, Podman rootless segnala di solito che non c'è una sessione systemd utente e ripiega su `cgroupfs`: sono warning innocui e la build funziona comunque. Se però vuoi che l'audit possa partire anche da un contesto non interattivo (cron, gateway) senza che i processi vengano terminati alla chiusura della sessione di login, abilita il lingering una volta per sempre:

   ```bash
   loginctl enable-linger "$(id -u)"
   ```

8. **Raggiungibilità di rete da Hermes al target**, sulle porte che vuoi analizzare (di default 22 e 443). Nessuna credenziale verso il target è necessaria.

## Installazione

Dall'ambiente dove usi Hermes (es. la tua WSL):

```bash
mkdir -p ~/.hermes/skills/audit
curl -fsSL "https://raw.githubusercontent.com/gabriele1701/Agentic-audit/v2.2/SKILL.md" -o ~/.hermes/skills/audit/SKILL.md
```

Non serve copiare nessuno script: la skill si occupa lei stessa di depositarli al primo utilizzo, sulla macchina giusta per ciascuno (vedi sotto).

Se aggiorni da una versione precedente, sostituisci il file `SKILL.md` e nient'altro: gli script già depositati vengono ri-verificati per hash al primo audit, e quelli nuovi scaricati su conferma.

## Utilizzo

Una volta installata, basta invocare:

```
/audit
```

dentro Hermes. L'agente ti chiederà **quale pipeline eseguire** (host, container, o entrambe), comunicherà host e utente target, chiederà conferma per iniziare, poi procederà con la sequenza descritta sopra.

Alla fine troverai i report nella cartella di output della rispettiva pipeline, il cui percorso completo ti verrà comunicato: quelli della pipeline host **sulla macchina target**, quelli della pipeline container **su Hermes**.

## Cosa fa effettivamente la skill

`SKILL.md` contiene l'intera logica operativa: i guardrail che vincolano il comportamento dell'agente, la sequenza fissa di entrambe le pipeline, e le istruzioni per generare i file finali. È consultabile direttamente in questa repo.

**Avviso 1 — pull automatico degli script**: se gli script di supporto non sono presenti, la skill — dopo aver chiesto conferma — esegue un pull da questa stessa repo (commit fisso) per recuperarli, poi ne verifica l'integrità con SHA256 prima di usarli. Questo comportamento è scritto per intero dentro `SKILL.md`, consultabile lì.

**Avviso 2 — script di supporto**: tutti gli script sono in questa repo, leggibili e verificabili da chiunque prima di fidarsene:

| Cartella | Contenuto | Dove viene eseguito |
|---|---|---|
| [`helper/`](./helper) | `vm-exec.sh` | su Hermes (apre SSH verso la VM) |
| [`scripts/`](./scripts) | `check-tool.sh`, `install-tool.sh`, `run-tool.sh` | sulla macchina target |
| [`backup/`](./backup) | `backup-target.sh` | su Hermes (legge la VM via SSH) |
| [`container/`](./container) | `Containerfile`, `entrypoint.sh`, `check-templates.sh`, `run-audit-container.sh` | su Hermes |

## Aggiornamento dei template di nuclei

I template di nuclei sono pinnati a un tag fisso nel `Containerfile`, per coerenza con l'approccio di integrità del resto del progetto. Il rovescio della medaglia è che invecchiano: nuovi CVE non vengono rilevati.

Per questo, prima di ogni audit container, la skill esegue un controllo in sola lettura che confronta il tag pinnato con l'ultimo disponibile su GitHub, e ti dice di quante release sei indietro. Puoi scegliere di procedere comunque (il report lo dichiarerà), di farli aggiornare all'agente — che rifà la build del solo layer dei template, lasciando in cache i tre tool — oppure di aggiornarli tu.

L'aggiornamento assistito tocca solo l'immagine locale: il pin nel `Containerfile` resta quello, così una build pulita da zero resta riproducibile. Se vuoi rendere permanente l'aggiornamento, modifica a mano `NUCLEI_TEMPLATES_TAG` e `NUCLEI_TEMPLATES_COMMIT` nel `Containerfile` (e aggiorna il suo hash in `SKILL.md`).

## Personalizzazione

Sia `SKILL.md` sia gli script sono pensati per essere adattati: puoi modificare guardrail, sequenza dei tool, comandi di scansione, versioni pinnate o criteri del report secondo le tue necessità. Se personalizzi uno script o il `Containerfile`, ricorda di aggiornare anche il relativo hash SHA256 dentro `SKILL.md`, altrimenti la verifica di integrità lo rifiuterà.

## Limiti noti

### Architettura di esecuzione

- Il backend terminal di Hermes è **un'impostazione unica e globale**: non si possono usare due backend insieme, né scegliere il backend comando per comando. Da qui la scelta di `local` + SSH esplicito. Se cambi quell'impostazione, cambia il comportamento di *tutte* le skill su quella istanza di Hermes, non solo di questa.
- Il wrapper `vm-exec.sh` apre **una connessione SSH per comando**: nessuna shell remota persistente tra un comando e l'altro. In pratica non è un problema (gli script sono autonomi e i percorsi sono assoluti), ma significa che un `export` o un `cd` non sopravvivono all'invocazione successiva.
- `vm-exec.sh` legge `config.yaml` con un parser minimale che riconosce le quattro chiavi `ssh_*` dentro il blocco `terminal:`. Se la tua versione di Hermes tiene quei valori altrove (per esempio come variabili `TERMINAL_SSH_*` in `.env`), passali con `AUDIT_VM_HOST`, `AUDIT_VM_USER`, `AUDIT_VM_PORT`, `AUDIT_VM_KEY`.

### Pipeline host

- **debsecan** potrebbe non essere disponibile nei repository apt per alcune release non più supportate: in quel caso la skill lo segnala e chiede una deroga esplicita per saltarlo, senza bloccare necessariamente il resto dell'audit.
- La scansione **Docker** con trivy viene eseguita solo se Docker è installato sulla macchina target; altrimenti viene annotata come omessa, non come errore.
- Pensata e testata solo su target **Debian/Ubuntu**; altre distribuzioni richiederebbero adattare i comandi di installazione negli script.

### Pipeline container

- A differenza di quella host, nella pipeline container **i tre tool girano sempre tutti**, anche se uno fallisce: è un singolo `podman run`, non c'è modo di fermarsi a metà e chiedere conferma. L'agente riporta gli exit code letteralmente e ti chiede come classificarli prima di scrivere il report.
- Una **porta chiusa o non raggiungibile** è un risultato dell'audit, non un guasto. Se sul target 443 è chiusa, testssl e nuclei lo segnaleranno come errore di connessione: è corretto, e la skill è scritta perché l'agente non lo spacci da solo per un malfunzionamento.
- I **template di nuclei** sono pinnati, quindi possono essere indietro rispetto agli ultimi CVE. Vedi la sezione sull'aggiornamento sopra.

### Backup

- Il backup **non sostituisce un backup vero** della VM: è una rete di sicurezza di emergenza per il caso specifico in cui l'audit combini danni.
- La **password non è recuperabile**. Se la perdi, gli snapshot di quel repository sono inaccessibili: è restic che funziona così, non un limite della skill.
- La skill **non ripristina e non fa pulizia** degli snapshot, in nessun caso: entrambe sono azioni tue, con `restic` direttamente.
- Lo spazio su Hermes cresce nel tempo, soprattutto usando il modo `full`. La deduplicazione di restic aiuta molto, ma non è magia: controlla periodicamente con `restic stats`.
- Non sono supportate **esecuzioni concorrenti** sullo stesso target: la staging area ha un percorso stabile per target (serve alla deduplicazione), quindi due audit in parallelo sulla stessa VM si pesterebbero i piedi.

## Ambiente di test

- **Macchina target**: Ubuntu/Debian (VM su VMware Workstation)
- **Ambiente agente**: Hermes Agent (terminale), su WSL2, con `terminal.backend: local`
- **Runtime container**: Podman (rootless)
- **Modello**: DeepSeek V4 Flash 0731 (1m token di contesto)

I requisiti di contesto e i tempi misurati sulla v1.0 erano: minimo 90k token, raccomandato 130k, 15-20 minuti per un audit completo. La v2.x ha una `SKILL.md` più grande e due pipeline, quindi queste cifre vanno rimisurate: usale come limite inferiore, non come stima.

## Versionamento

- Il pull di `SKILL.md` (sezione Installazione) punta a un **tag di release**.
- Il pull interno degli script (dentro `SKILL.md`) punta a **commit SHA fissi**, non al tag — per garanzia di integrità massima anche in caso di modifiche future ai tag. Ogni gruppo di script ha il suo pin, quindi aggiornare un gruppo non invalida gli altri.

| Riferimento | Punta a |
|---|---|
| `SKILL.md` | tag `v2.2` |
| `helper/` (accesso alla VM) | commit `5d54bfb` |
| `scripts/` (pipeline host) | commit `d4d3f52` |
| `backup/` | commit `5d54bfb` |
| `container/` | commit `137d487` |

Se aggiorni il progetto, aggiorna questi riferimenti e i corrispondenti hash SHA256 dentro `SKILL.md`.

## Disclaimer

Per quanto questa skill sia stata progettata per essere il più deterministica possibile, coinvolge comunque un agente IA per narrazione, conferme e sintesi del report. I risultati possono variare in base alle capacità del modello usato, e non è da escludersi un comportamento inatteso. Verifica sempre i risultati contro i log grezzi prima di trarre conclusioni operative.
Quando utilizzato su Hermes, di default il sistema chiederà ogni volta l'autorizzazione all'immissione di comandi; questo a prescindere dal tool. Per evitare ciò, digitare alla prima richiesta "2. allow for this session"

## Licenza

MIT — vedi [LICENSE](./LICENSE).

# Nota etica sull'utilizzo dell'IA
Questo progetto è stato ideato, strutturato e supervisionato dal sottoscritto. Il codice e i contenuti sono stati sviluppati in stretta collaborazione con Claude (Anthropic), che ha agito come assistente di programmazione per la scrittura e l'ottimizzazione del materiale, sotto la mia costante guida e validazione.
