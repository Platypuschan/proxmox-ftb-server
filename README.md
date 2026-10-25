# proxmox-ftb-server

Erstellt auf einem Proxmox-VE-Host einen LXC-Container mit einem
Minecraft-Server für ein beliebiges [Feed-The-Beast-Modpack](https://www.feed-the-beast.com/modpacks/server-files/linux).
Der Server wird mit dem offiziellen FTB-Server-Installer eingerichtet und über
eine Web-Oberfläche bedient.

Das Script läuft **eigenständig**. Es nutzt nur die Werkzeuge, die jeder
Proxmox-VE-Host mitbringt (`pct`, `pvesm`, `pveam`, `pvesh`, `whiptail`,
`perl`, `curl`). Ein fremdes Framework wird nicht geladen, und es gibt weder
Telemetrie noch Statusabfragen an Dritte.

## Ablauf

1. **Prüfen:** root, Proxmox VE 8 oder neuer, amd64, alle Werkzeuge vorhanden.
   Die Dateien für den Container (`install/`, `files/`) kommen aus dem
   Checkout, in dem das Script liegt. Läuft es ohne Checkout (Einzeiler unten),
   lädt es sie als Archiv desselben Branches von GitHub.
2. **Modpack wählen:** Die Liste kommt von der FTB-API, danach folgt die
   Version (Vorauswahl: neueste Release). Die Minecraft-EULA wird automatisch
   akzeptiert (https://www.minecraft.net/eula).
3. **Container dimensionieren** aus der Empfehlung des Packs:
   - **Arbeitsspeicher (RAM)** = empfohlener Java-Heap + 1536 MiB für die JVM
     außerhalb des Heaps, aufgerundet auf 512 MiB. Beispiel FTB Evolution 2:
     8192 + 1536 → 9728 MiB.
   - **Speicherplatz (Root-Disk)** = 2 × Downloadgröße der Server-Dateien +
     10 GB für Welt, Backups, Java und Modloader, mindestens 16 GB.
   - **Hostname** `ftb-<pack>`, 4 CPU-Kerne, nächste freie Container-ID, DHCP
     auf `vmbr0`.
4. **Einstellungen:** Mit „Standard“ werden die Werte übernommen. „Erweitert“
   fragt jeden Wert einzeln ab: ID, Hostname, CPU, RAM, Disk, Storage, Bridge,
   IPv4 statisch oder DHCP, Gateway, VLAN, Root-Passwort, SSH-Schlüssel und
   Autostart. Danach folgt eine Bestätigung.
5. **Template:** Das neueste `debian-13-standard` wird genommen, wenn es auf
   dem Template-Storage liegt. Sonst lädt `pveam` es herunter.
6. **Container anlegen:** mit `pct create` (unprivilegiert, `nesting=1`,
   Zeitzone des Hosts, Tags `gaming;minecraft`), dann starten und auf das
   Netzwerk warten.
7. **Installieren:** `install/` und `files/` gehen per `pct push` als Tarball
   in den Container. `install/ftb-minecraft-install.sh` läuft per `pct exec`:
   - OS-Update
   - Benutzer `minecraft`
   - FTB-Installer (`-pack -version -auto -force -accept-eula`), der Java
     8–25 und den Modloader (Forge, NeoForge, Fabric) selbst mitbringt
   - systemd-Dienst mit Konsole als FIFO
   - Web-Oberfläche
   - ohne Root-Passwort: automatischer root-Login auf der Proxmox-Konsole
8. **Proxmox-Notizen** (Adressen, Pack, Version) setzen und die Adressen
   ausgeben.

Bricht etwas nach dem Anlegen ab, fragt das Script, ob der halbfertige
Container entfernt werden soll. Ohne Terminal bleibt er zur Fehlersuche
erhalten. Das vollständige Protokoll liegt unter
`/var/log/ftb-minecraft/create-<datum>.log`.

## Benutzung

Auf dem Proxmox-Host als root, direkt aus der Raw-Ansicht:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Platypuschan/proxmox-ftb-server/main/ct/ftb-minecraft.sh)"
```

Wichtig ist die Form `bash -c "$(curl …)"`. Bei `curl … | bash` ist die
Eingabe die Pipe statt des Terminals; dann gibt es keine Dialoge, und das
Script verlangt `FTB_PACK_ID`.

Alternativ aus einem Checkout:

```bash
apt install -y git    # falls git fehlt
git clone https://github.com/Platypuschan/proxmox-ftb-server.git
cd proxmox-ftb-server
bash ct/ftb-minecraft.sh
```

Ohne Dialoge, z. B. für mehrere Server oder per Automatisierung:

```bash
FTB_PACK_ID=128 FTB_UNATTENDED=1 bash -c "$(curl -fsSL https://raw.githubusercontent.com/Platypuschan/proxmox-ftb-server/main/ct/ftb-minecraft.sh)"
FTB_PACK_ID=134 FTB_UNATTENDED=1 var_ram=12288 var_disk=40 var_net=192.0.2.50/24 var_gateway=192.0.2.1 bash ct/ftb-minecraft.sh
```

## Einstellungen

| Variable | Bedeutung | Standard |
| --- | --- | --- |
| `FTB_PACK_ID` | Pack-ID (Spalte „#“ auf der FTB-Server-Files-Seite) | Auswahlmenü |
| `FTB_VERSION_ID` | Versions-ID | neueste Release |
| `FTB_UNATTENDED=1` | keine Dialoge (ohne Terminal automatisch) | – |
| `var_ctid` | Container-ID | nächste freie |
| `var_hostname` | Hostname | `ftb-<pack>` |
| `var_cpu` | CPU-Kerne | 4 |
| `var_ram` | RAM in MiB | aus der Pack-Empfehlung |
| `var_disk` | Root-Disk in GB | aus der Downloadgröße |
| `var_container_storage` | Storage für die Root-Disk | `local-lvm`, `local-zfs` oder `local` |
| `var_template_storage` | Storage für das Template | `local` |
| `var_brg` | Bridge | `vmbr0` |
| `var_net` | `dhcp` oder IPv4/Präfix | `dhcp` |
| `var_gateway` | Gateway bei statischer IP | – |
| `var_vlan` | VLAN-Tag | – |
| `var_pw` | Root-Passwort (sonst automatischer Konsolen-Login) | – |
| `var_ssh_authorized_key` | öffentlicher SSH-Schlüssel für root | – |
| `var_onboot` | Autostart mit dem Host (`1`/`0`) | `1` |
| `FTB_RAM_RESERVE` | RAM außerhalb des Java-Heaps in MiB | 1536 |
| `FTB_WEB_PORT` | Port der Web-Oberfläche | 8080 |
| `FTB_VERBOSE=1` | Ausgabe aller Schritte im Terminal statt nur im Log | – |
| `FTB_LOG_DIR` | Verzeichnis für das Protokoll | `/var/log/ftb-minecraft` |
| `FTB_REPO`, `FTB_REF` | Repository und Branch/Tag, aus dem ohne Checkout `install/` und `files/` geladen werden | `Platypuschan/proxmox-ftb-server`, `main` |
| `FTB_SOURCE_URL` | vollständige Archiv-URL statt `FTB_REPO`/`FTB_REF` (z. B. ein Fork oder ein Spiegel) | `https://codeload.github.com/<FTB_REPO>/tar.gz/<FTB_REF>` |

## Externe Verbindungen

- **Host:**
  - `api.feed-the-beast.com` für Pack-Liste und Versionen
  - der Proxmox-Template-Spiegel über `pveam`, nur wenn das Template fehlt
  - GitHub (`raw.githubusercontent.com`, `codeload.github.com`), nur beim
    Start ohne Checkout
- **Container:**
  - Debian-Spiegel
  - FTB-API und FTB-Download-Server
  - die Server von Mojang und vom Modloader (beim Installieren und bei
    Updates)
  - die FTB-API aus der Web-Oberfläche für den Modpack-Tab

## Web-Oberfläche

`http://<container-ip>:8080`, ohne Anmeldung. Gedacht ist sie für das lokale
Netz, deshalb gibt es keine Zugangskontrolle: Jeder, der den Port erreicht,
kann den Server steuern.

- **Status**: Zustand, Laufzeit, Minecraft-Version, MOTD, Antwortzeit,
  eingeloggte Spieler (online/max mit Namen) sowie CPU, RAM und Speicher. Die
  Spielerdaten kommen per Server List Ping, also über dieselbe Abfrage wie die
  Serverliste im Client. Sind mehr als 12 Spieler online, ermittelt der
  Konsolenbefehl `list` die vollständige Liste.
- **Starten, Stoppen, Neustart**, jeweils mit Rückfrage. Stoppen speichert die
  Welt.
- **Backups** erstellen, einspielen, herunterladen, hochladen und löschen,
  kompatibel mit FTB Backups (siehe unten).
- **Modpack**: zeigt installierte Version und neueste Release (FTB-API).
  - Das Update startet per Knopfdruck. Dabei wird der Server gestoppt, die
    Welt gesichert (`pre-update`), der FTB-Installer ausgeführt und der Server
    wieder gestartet.
  - Auch eine bestimmte Version lässt sich installieren, ebenso Beta- und
    Alpha-Versionen oder ein Downgrade, dann mit Warnung.
  - Die Minecraft-Version gibt das Modpack vor.
- **Konsole**: Live-Log (letzte 300 Zeilen) und Eingabe von Befehlen.

Länger laufende Aktionen laufen als Hintergrund-Job, die Ausgabe ist live zu
sehen. Es läuft immer nur ein Job gleichzeitig.

## Backups (kompatibel mit FTB Backups)

FTB-Modpacks bringen ihren eigenen Backup-Mod mit. Je nach Pack ist das ein
anderer:

| Mod | Packs (jeweils neueste Version, Stand 2026-10) | Ordner, Index |
| --- | --- | --- |
| FTB Backups 3 | 6 Packs, die neuesten (Evolution 1+2, Skies 2, StoneBlock 4, Unstable 6, Skies 2 Aero) | `ftbbackups3/`, `backups.json` (MC 1.21) bzw. `backups.json5` (ab MC 26.1) |
| FTB Backups 2 | 19 Packs, MC 1.18–1.21 | `backups/`, `backups.json` |
| FTB Backups 2.1 / 1, AromaBackup, keiner | 70 ältere Packs | – |

`ftb-backup`, und damit auch die Web-Oberfläche, erkennt den Mod des Packs und
arbeitet direkt mit dessen Backups:

- **Ein Ordner, ein Index, ein Format.** Backups aus der Web-Oberfläche liegen
  im Ordner des Mods und stehen in seinem Index. Die automatischen Backups des
  Mods erscheinen in der Web-Oberfläche. Das Format ist immer ein ZIP der Welt
  mit Einträgen `world/…`, genau wie beim Mod.
- **Erstellen bei laufendem Server:** über den Befehl des Mods,
  `ftbbackups3 start <datum>_<bezeichnung>` bzw. `backup snapshot <bezeichnung>`.
  Bei FTB Backups 2 sind Snapshots geschützt, die Rotation des Mods löscht sie
  nicht.
- **Erstellen bei gestopptem Server** (oder bei FTB Backups 2 mit
  `enabled: false`): `ftb-backup` schreibt ZIP und Index-Eintrag selbst im
  Format des Mods. Der Mod lädt den Index beim Start und übernimmt den Eintrag.
- **Packs ohne FTB Backups 2/3:** Backups im Format von FTB Backups 3 unter
  `ftbbackups3/`. Bekommt das Pack bei einem Update FTB Backups 3, findet der
  Mod sie vor. Die Ordner älterer Mods (`backups/` von FTB Backups 1) bleiben
  unberührt, deren Backups erscheinen aber nicht in der Web-Oberfläche.
- **Einspielen:**
  1. Server stoppen.
  2. Automatisches `pre-restore`-Backup der aktuellen Welt anlegen.
  3. Den Weltordner durch den Inhalt des ZIPs ersetzen.
  4. Server starten.

  Wie bei FTB Backups wird **nur die Welt** zurückgesetzt. Mods und
  Konfiguration gehören zur Modpack-Version. Um auf eine ältere Version
  zurückzugehen, gibt es `ftb-update <versions-id>`.
- **Hochladen:** Akzeptiert werden ZIPs mit einer Welt (`level.dat`). Archive
  mit `../`-Pfaden werden abgelehnt, damit ein kaputtes Archiv nichts außerhalb
  der Welt überschreibt.
- **Aufräumen:** Die Rotation macht der Mod (FTB Backups 3: 12 Backups bzw.
  50 GB, FTB Backups 2: 5 ungeschützte). `ftb-backup` begrenzt nur die eigenen
  automatischen Backups (`pre-update`, `pre-restore`) auf die letzten 3.
- FTB Backups 2 im Format `ZSTD` wird gelistet, kann aber nicht eingespielt
  werden. `DIRECTORY` und `ZIP` funktionieren.

## Im Container

| Befehl | Zweck |
| --- | --- |
| `journalctl -fu minecraft` | Server-Log live |
| `mc-cmd <befehl>` | Konsolenbefehl senden, z. B. `mc-cmd op Spieler`, `mc-cmd say Neustart` |
| `systemctl restart minecraft` | Neustart. `stop` speichert die Welt über den Konsolenbefehl `stop`. |
| `ftb-update [versions-id]` | Update auf die neueste Release oder die angegebene Version. Davor entsteht ein `pre-update`-Backup. |
| `ftb-backup info \| list \| create [label] \| restore <name> \| delete <name>` | Backups auf der Kommandozeile, dieselbe Logik wie in der Web-Oberfläche |

Der Java-Heap wird bei jedem Start aus dem Container-RAM berechnet
(RAM − `FTB_RAM_RESERVE`). Eine RAM-Änderung in Proxmox wirkt deshalb nach
einem Neustart des Dienstes. Port: 25565/TCP.

## Recherche: Möglichkeiten

Die erste Version baute auf dem Framework der [community-scripts](https://community-scripts.org/) auf. Seit dem Umbau läuft das Script eigenständig, weil das Framework zur Laufzeit von GitHub nachgeladen wurde, nicht festgelegt war und eine Statusabfrage an community-scripts.org schickte.

| Ansatz | Bewertung |
| --- | --- |
| **FTB-Server-Installer im LXC (gewählt)** | Offiziell von FTB, ein statisches Go-Binary. Die Flags (`-pack`, `-version`, `-auto`, `-force`, `-accept-eula`, `-dir`) erlauben vollautomatische Installation und Updates. Java und Modloader bringt er selbst mit. Läuft direkt im LXC, ohne Docker-Schicht. |
| FTB-API direkt (eigener Downloader) | Möglich (Dateiliste mit Hashes unter `/modpack/<id>/<version>`). Der Modloader-Install (Forge-/NeoForge-Prozessoren) müsste aber nachgebaut werden, und genau das übernimmt der Installer. |
| [itzg/minecraft-server](https://docker-minecraft-server.readthedocs.io/en/latest/types-and-platforms/mod-platforms/ftb/) mit `TYPE=FTBA` | Gut, braucht aber Docker im LXC (nesting) oder eine VM, also eine zusätzliche Schicht. Das Ziel ist ein Server nativ im LXC. |
| Crafty Controller / Pterodactyl | Web-Panels für viele Server. Das FTB-Pack muss dort trotzdem von Hand eingerichtet werden (Pterodactyl über das FTB-Egg). Lohnt sich bei vielen Servern mit Weboberfläche, ist aber kein „ein Pack = ein Container“-Automatismus. |
| Alpine statt Debian als Container-OS | Verworfen. Das Java, das der FTB-Installer mitbringt (Java 8 bis 25), ist gegen glibc gelinkt (`/lib64/ld-linux-x86-64.so.2`), Alpine nutzt musl. Es liefe nur mit `gcompat` oder einem Alpine-eigenen JDK, das die Pfade in `run.sh`/`start.sh` umgeht. Native Bibliotheken mancher Mods setzen ebenfalls glibc voraus. Dienst, Konsole und Log hängen an systemd und journald und müssten für OpenRC neu gebaut werden. Ersparnis: gut 100 MB Disk und einige Dutzend MB RAM, bei 6 bis 10 GB Java-Heap vernachlässigbar. |

## Getestet

- `tests/lint.sh`:
  - `bash -n` und shellcheck für alle Shell-Scripts und Test-Stubs
  - Syntax von Python und JavaScript, Prüfungen für Index-Parser und
    Job-Filter
  - Prüfung, dass `ct/`, `install/` und `files/` keine community-scripts
    mehr referenzieren
- `tests/host-select.sh`: Pack- und Versionsauswahl und Dimensionierung gegen
  die echte FTB-API. Geprüft wurden NeoForge (MC 26.1.2), Forge 1.12.2
  (Java 8), Fabric und vier Fehlerfälle.
- `tests/host-e2e.sh`: Das echte `ct/ftb-minecraft.sh` läuft gegen Stubs der
  Proxmox-Werkzeuge in `tests/pve-stub`. Container sind dabei podman-Container
  mit Debian 13 und systemd.
  - **A, ohne Dialoge:**
    1. Template laden.
    2. `pct create`-Argumente prüfen.
    3. Installieren.
    4. Den API-Test der Web-Oberfläche laufen lassen (`tests/web-api-check.sh`):
       - Status und Konsole
       - Backups über den FTB-Backups-Mod, Einspielen, Hochladen
       - Modpack-Update über die Oberfläche
    5. Sauber stoppen.
  - **B, alle Dialoge durchgespielt:** „Erweitert“ mit statischer IP,
    Gateway, VLAN, Passwort, SSH-Schlüssel, zweitem Storage und ohne
    Autostart, danach eine vollständige Installation.
  - **C, Fehler vor dem Anlegen:** ungültige ID, zu wenig RAM, inaktiver
    Storage. Es entsteht kein Container.
  - **D, Fehler nach dem Anlegen:** Der Container bleibt mit Hinweis und
    Log-Pfad erhalten.
  - **E, Einzeiler ohne Checkout:** Start per `bash -c` aus einem leeren
    Verzeichnis. Die Dateien kommen aus einem Repository-Archiv; GitHub ist
    dabei durch `file://` ersetzt. Ergebnis ist eine vollständige
    Installation. Eine nicht erreichbare Quelle wird vor dem Anlegen
    abgelehnt.

  Aufruf: `tests/host-e2e.sh <pack-id> <v2|v3|own> [pack-id-für-B]`.

Manuell geprüft wurden außerdem die Startlayouts des Installers: `run.sh` mit
`user_jvm_args.txt` (Forge/NeoForge ab 1.17) sowie `start.sh` mit
eingebettetem `-Xmx` (altes Forge, Fabric).

## Einschränkungen

- **Noch nicht auf einem echten Proxmox-Host gelaufen.**
  - In den Tests sind `pct`, `pvesm`, `pveam`, `pvesh` und `whiptail`
    nachgebildet, und podman ersetzt LXC.
  - Echte Proxmox-Eigenheiten sind deshalb ungetestet: unprivilegiertes
    LXC, AppArmor, die Storage-Typen, die Konsole und das Autologin.
- Nur amd64-Hosts. Proxmox liefert die Debian-Templates nur für amd64.
- Es gibt keinen `update`-Befehl im Container. Das Modpack wird in der
  Web-Oberfläche (Tab „Modpack“) oder mit `ftb-update` aktualisiert. Neue
  Versionen der Helfer und der Web-Oberfläche selbst kommen nur mit einem neu
  erstellten Container.
- Die Spielernamen in der Statusanzeige sind nur ohne verbundene Spieler
  getestet (0/20). Der Fallback über `list` bei mehr als 12 Spielern ist
  ebenfalls ungetestet.
- Die Web-Oberfläche hat keine Anmeldung und läuft als root. Sie gehört nur
  ins lokale Netz, also den Port nicht nach außen freigeben.
- Nur öffentliche FTB-Packs. Für private Packs bräuchte der Installer
  `-apikey`.
