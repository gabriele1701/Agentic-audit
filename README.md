# Agentic Audit — skill `/audit` per Hermes Agent

Skill custom per [Hermes Agent](https://github.com/NousResearch) che esegue un audit di sicurezza automatizzato su una macchina remota raggiunta via SSH, combinando script bash deterministici con un agente IA per la narrazione, le conferme e la sintesi finale.
L’agente monitora l’esecuzione e, se il processo si blocca, riporta in chat il motivo con l’output letterale ricevuto. È possibile discutere con l’agente per approfondire o localizzare la causa del problema, senza perdere il progresso dell’audit — ma l’agente non intraprende mai un’azione di propria iniziativa: ogni comando resta soggetto a conferma esplicita dell’utente.

## A cosa serve

Questa skill automatizza un audit di sicurezza difensivo di base su un sistema Linux, eseguendo in sequenza sei tool consolidati:

- **lynis** — hardening e configurazione generale del sistema
- **trivy** — vulnerabilità note su filesystem e, se presente, immagini Docker
- **nmap** — porte e servizi esposti (su localhost e sull'interfaccia di rete primaria)
- **debsecan** — vulnerabilità note nei pacchetti Debian/Ubuntu installati
- **chkrootkit** — ricerca di rootkit
- **rkhunter** — ricerca di rootkit ed exploit noti

Al termine produce due file markdown: un report elaborato (sintesi, problemi critici, raccomandazioni) e un file con i log grezzi integrali di ogni tool, così ogni affermazione nel report è sempre verificabile contro l'output originale.

**Ambienti supportati**: qualsiasi macchina target Linux basata su **Debian/Ubuntu** (gli script di installazione usano `apt-get`), raggiungibile via SSH dal backend configurato in Hermes. L'agente stesso può girare in qualsiasi ambiente in cui gira Hermes — è stata sviluppata e testata nel setup descritto più sotto.

## Come avviene l'audit

L'audit non è lasciato all'improvvisazione del modello: la parte meccanica (verifica presenza tool, installazione, esecuzione, salvataggio output) è delegata a tre script bash deterministici (`check-tool.sh`, `install-tool.sh`, `run-tool.sh`), sempre gli stessi comandi fissi per ogni tool. L'agente si occupa di spiegare ogni passaggio, chiedere conferma prima di qualsiasi installazione o modifica del sistema, fermare l'intero audit al primo errore (ogni tool è bloccante), e scrivere la sintesi finale basandosi solo sui dati effettivamente raccolti — mai inventati.

## Prerequisiti

1. **Hermes Agent configurato con backend SSH** verso la macchina target (`terminal: ssh` in `~/.hermes/config.yaml`, con host, utente e chiave già funzionanti).
2. **Macchina target Debian/Ubuntu**, con accesso internet in uscita (per installare i tool mancanti e per il pull automatico degli script, se necessario).
3. **Regole sudo senza password**, scoped esclusivamente ai comandi usati da questa skill. Senza questo passaggio, l'audit si ferma al primo comando che richiede `sudo`, perché l'esecuzione non interattiva via Hermes non fornisce un terminale a cui `sudo` possa chiedere la password.

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

## Installazione

Dall'ambiente dove usi Hermes (es. la tua WSL):

```bash
mkdir -p ~/.hermes/skills/audit
curl -fsSL "https://raw.githubusercontent.com/gabriele1701/Agentic-audit/v1.0/SKILL.md" -o ~/.hermes/skills/audit/SKILL.md
```

Non serve copiare né gli script né altro: la skill si occupa lei stessa di depositarli sulla macchina target al primo utilizzo (vedi sotto).

## Utilizzo

Una volta installata, basta invocare:

```
/audit
```

dentro Hermes. L'agente comunicherà host e utente target, chiederà conferma per iniziare, poi procederà con la sequenza di controllo e narrazione descritta sopra. Alla fine troverai i due file di report nella cartella di output sulla macchina target, il cui percorso ti verrà comunicato.

## Cosa fa effettivamente la skill

`SKILL.md` contiene l'intera logica operativa: i guardrail che vincolano il comportamento dell'agente, la sequenza fissa dei sei tool, e le istruzioni per generare i due file finali. È consultabile direttamente in questa repo.

**Avviso 1 — pull automatico degli script**: se gli script di supporto non sono presenti sulla macchina target, la skill — dopo aver chiesto conferma — esegue un pull da questa stessa repo (commit fisso) per recuperarli, poi ne verifica l'integrità con SHA256 prima di usarli. Questo comportamento è scritto per intero dentro `SKILL.md`, consultabile lì.

**Avviso 2 — script di supporto**: i tre script bash che eseguono effettivamente i comandi (`check-tool.sh`, `install-tool.sh`, `run-tool.sh`) sono nella cartella [`scripts/`](./scripts) di questa repo, leggibili e verificabili da chiunque prima di fidarsene.

## Personalizzazione

Sia `SKILL.md` sia gli script in `scripts/` sono pensati per essere adattati: puoi modificare guardrail, sequenza dei tool, comandi di scansione o criteri del report secondo le tue necessità. Se personalizzi gli script, ricorda di aggiornare anche gli hash SHA256 attesi dentro `SKILL.md`, altrimenti la verifica di integrità li rifiuterà.

## Limiti noti

- **debsecan** potrebbe non essere disponibile nei repository apt per alcune release non più supportate: in quel caso la skill lo segnala e chiede una deroga esplicita per saltarlo, senza bloccare necessariamente il resto dell'audit.
- La scansione **Docker** con trivy viene eseguita solo se Docker è installato sulla macchina target; altrimenti viene annotata come omessa, non come errore.
- Pensata e testata solo su target **Debian/Ubuntu**; altre distribuzioni richiederebbero adattare i comandi di installazione negli script.

## Ambiente di test

- **Macchina target**: Ubuntu/Debian
- **Ambiente agente**: Hermes Agent (terminale)
- **Modello**: DeepSeek V4 Flash 0731 (1m token di contesto)
- **Contesto**: minimo 75k token, raccomandato 100k token

## Versionamento

- Il pull di `SKILL.md` (sezione Installazione) punta al tag `v1.0`.
- Il pull interno degli script di supporto (dentro `SKILL.md`) punta a un commit SHA fisso, non al tag — per garanzia di integrità massima anche in caso di modifiche future ai tag.

Se aggiorni il progetto, aggiorna questi riferimenti di conseguenza.

## Disclaimer

Per quanto questa skill sia stata progettata per essere il più deterministica possibile, coinvolge comunque un agente IA per narrazione, conferme e sintesi del report. I risultati possono variare in base alle capacità del modello usato, e non è da escludersi un comportamento inatteso. Verifica sempre i risultati contro i log grezzi prima di trarre conclusioni operative.

## Licenza

MIT — vedi [LICENSE](./LICENSE).
