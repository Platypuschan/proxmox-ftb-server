# proxmox-ftb-minecraft

Erstellt auf einem Proxmox-VE-Host einen LXC-Container mit einem
Minecraft-Server für ein beliebiges [Feed-The-Beast-Modpack](https://www.feed-the-beast.com/modpacks/server-files/linux).
Aufbau und Bedienung folgen den [community-scripts](https://community-scripts.org/):
gleiches Framework (`community-scripts/core`), gleiche Standard-/Erweitert-Dialoge,
gleiche `var_*`-Einstellungen. Installiert wird der Server mit dem offiziellen
FTB-Server-Installer.

## Ablauf

1. **Host (`ct/ftb-minecraft.sh`)**: lädt die Modpack-Liste über die FTB-API.
   Nach der Auswahl von Pack und Version (Standard: neueste Release) wird der
   Container passend zum Pack dimensioniert:
   - **Arbeitsspeicher (RAM) des Containers** = von FTB empfohlener Java-Heap +
     1536 MiB für die JVM außerhalb des Heaps, aufgerundet auf 512 MiB. Beispiel
     FTB Evolution 2: 8192 + 1536 → 9728 MiB.
   - **Speicherplatz (Root-Disk) des Containers** = 2 × Downloadgröße der
     Server-Dateien + 10 GB für Welt, Backups, Java und Modloader, mindestens
     16 GB.
   - **Hostname** `ftb-<pack>`. CPU-Kerne: 4.

   Alle Werte lassen sich im Erweitert-Dialog oder per `var_*` überschreiben.
   Die Minecraft-EULA wird dabei automatisch akzeptiert
   (https://www.minecraft.net/eula).
2. **Container (`install/ftb-minecraft-install.sh`)** auf Debian 13:
   - lädt den FTB-Installer für Pack und Version
     (`api.feed-the-beast.com/v1/modpacks/public/modpack/<pack>/<version>/server/linux`)
     und führt ihn unbeaufsichtigt als Benutzer `minecraft` aus:
     `-pack -version -dir /opt/minecraft/server -auto -force [-accept-eula]`
   - Der Installer bringt die passende Java-Version (8 bis 25) unter
     `server/jre/` und den Modloader (Forge, NeoForge, Fabric) selbst mit. Java
     aus apt wird nicht gebraucht.
   - legt `minecraft.service` und `minecraft.socket` an. Die Konsole ist eine
     FIFO, daher braucht es weder screen noch tmux.
   - richtet die Web-Oberfläche `ftb-web.service` ein (siehe unten).

Helfer-Scripts und Web-Oberfläche liegen unter `files/`. Läuft das Script aus
einem lokalen Checkout, gehen sie als base64-Tarball über die Umgebung in den
Container. Sonst lädt der Container sie anhand von `files/MANIFEST` von
`COMMUNITY_SCRIPTS_URL`.

## Benutzung

Auf dem Proxmox-Host als root:

```bash
git clone <repo-url> proxmox-ftb-minecraft
cd proxmox-ftb-minecraft
bash ct/ftb-minecraft.sh
```

Das Framework erkennt den lokalen Checkout und nimmt `install/` aus demselben
Verzeichnis. Den Kern (`community-scripts/core`) lädt es von GitHub.

Unbeaufsichtigt, z. B. für mehrere Server:

```bash
FTB_PACK_ID=128 bash ct/ftb-minecraft.sh                                   # neueste Release
FTB_PACK_ID=35 FTB_VERSION_ID=12180 var_ram=8192 bash ct/ftb-minecraft.sh
```

| Variable | Bedeutung |
| --- | --- |
| `FTB_PACK_ID` | Pack-ID (Spalte „#“ auf der FTB-Server-Files-Seite). Ohne Angabe erscheint ein Auswahlmenü. |
| `FTB_VERSION_ID` | Versions-ID. Ohne Angabe wird die neueste Release genommen. |
| `FTB_RAM_RESERVE` | RAM außerhalb des Java-Heaps in MiB (Standard 1536) |
| `FTB_WEB_PORT` | Port der Web-Oberfläche (Standard 8080) |
| `var_cpu`, `var_ram`, `var_disk`, `var_hostname`, … | die üblichen community-scripts-Einstellungen |

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

| Ansatz | Bewertung |
| --- | --- |
| **FTB-Server-Installer im LXC (gewählt)** | Offiziell von FTB, ein statisches Go-Binary. Die Flags (`-pack`, `-version`, `-auto`, `-force`, `-accept-eula`, `-dir`) erlauben vollautomatische Installation und Updates. Java und Modloader bringt er selbst mit. Läuft direkt im LXC, ohne Docker-Schicht. |
| FTB-API direkt (eigener Downloader) | Möglich (Dateiliste mit Hashes unter `/modpack/<id>/<version>`). Der Modloader-Install (Forge-/NeoForge-Prozessoren) müsste aber nachgebaut werden, und genau das übernimmt der Installer. |
| [itzg/minecraft-server](https://docker-minecraft-server.readthedocs.io/en/latest/types-and-platforms/mod-platforms/ftb/) mit `TYPE=FTBA` | Gut, braucht aber Docker im LXC (nesting) oder eine VM, also eine zusätzliche Schicht. Passt nicht zum community-scripts-Modell (nativ im LXC). |
| Crafty Controller / Pterodactyl (gibt es als community-scripts) | Web-Panels für viele Server. Das FTB-Pack muss dort trotzdem von Hand eingerichtet werden (Pterodactyl über das FTB-Egg). Lohnt sich bei vielen Servern mit Weboberfläche, ist aber kein „ein Pack = ein Container“-Automatismus. |
| Alpine statt Debian als Container-OS | Verworfen. Das Java, das der FTB-Installer mitbringt (Java 8 bis 25), ist gegen glibc gelinkt (`/lib64/ld-linux-x86-64.so.2`), Alpine nutzt musl. Es liefe nur mit `gcompat` oder einem Alpine-eigenen JDK, das die Pfade in `run.sh`/`start.sh` umgeht. Native Bibliotheken mancher Mods setzen ebenfalls glibc voraus. Dienst, Konsole und Log hängen an systemd und journald und müssten für OpenRC neu gebaut werden. Ersparnis: gut 100 MB Disk und einige Dutzend MB RAM, bei 6 bis 10 GB Java-Heap vernachlässigbar. |

## Getestet

- `tests/lint.sh`:
  - `bash -n` und shellcheck für alle Shell-Scripts
  - Syntaxprüfung für Python und JavaScript
  - Abgleich von `files/MANIFEST` mit den vorhandenen Dateien
- `tests/host-select.sh`: Pack- und Versionsauswahl und Dimensionierung gegen
  die echte FTB-API. Geprüft wurden NeoForge (MC 26.1.2), Forge 1.12.2 (Java 8)
  und Fabric sowie die Fehlerfälle (fremde Version, unbekanntes Pack,
  nicht-numerische ID).
- `tests/container-install.sh`: Install-Script in einem Debian-13-Container mit
  systemd (podman) als Ersatz für den LXC:
  1. ältere Version installieren
  2. Server-Start bis „Done“
  3. `mc-cmd`
  4. API-Test der Web-Oberfläche (`tests/web-api-check.sh`):
     - Status mit Server List Ping und Konsole
     - Erkennung des Backup-Mods
     - Backup im laufenden Betrieb über den Mod, mit Archiv im Ordner und
       Eintrag im Index des Mods
     - Backups des Mods erscheinen in der Oberfläche
     - Herunterladen, Löschen (auch aus dem Index) und Hochladen
     - Archive mit `../` oder ohne Welt werden abgelehnt
     - Einspielen mit `pre-restore`-Backup
     - Backup bei gestopptem Server: Der Mod behält den Eintrag nach seinem
       nächsten eigenen Backup
     - Stopp und Start
  5. Modpack-Update über die Web-Oberfläche auf die neueste Release, mit
     `pre-update`-Backup
  6. sauberer Stopp

  Aufruf: `tests/container-install.sh <pack-id> <v2|v3|own>`. Mit `KEEP=1`
  bleibt der Container danach laufen, die Web-Oberfläche ist dann unter
  `http://localhost:18080` erreichbar.

Manuell geprüft wurden außerdem die Startlayouts des Installers: `run.sh` mit
`user_jvm_args.txt` (Forge/NeoForge ab 1.17) sowie `start.sh` mit
eingebettetem `-Xmx` (altes Forge, Fabric).

## Einschränkungen

- **Noch nicht auf einem echten Proxmox-Host gelaufen.** Der Host-Teil
  (`build_container` des Frameworks) ist ungetestet, getestet sind nur die
  Auswahllogik und der Container-Teil.
- Es gibt keinen `update`-Befehl im Container. Das Modpack wird in der
  Web-Oberfläche (Tab „Modpack“) oder mit `ftb-update` aktualisiert. Neue
  Versionen der Helfer und der Web-Oberfläche selbst kommen nur mit einem neu
  erstellten Container.
- Telemetrie an die community-scripts ist abgeschaltet (`DIAGNOSTICS=no`). Die
  Diagnose-Frage des Frameworks wird übersprungen, die hostweite Einstellung
  für andere community-scripts (`/usr/local/community-scripts/diagnostics`)
  bleibt unverändert.
- Die Spielernamen in der Statusanzeige sind nur ohne verbundene Spieler
  getestet (0/20). Ein Client-Login auf einen Modpack-Server ließ sich im Test
  nicht nachstellen. Der Fallback über `list` bei mehr als 12 Spielern ist
  ebenfalls ungetestet.
- Die Web-Oberfläche hat keine Anmeldung und läuft als root. Sie gehört nur
  ins lokale Netz, also den Port nicht nach außen freigeben.
- Nur öffentliche FTB-Packs. Für private Packs bräuchte der Installer
  `-apikey`.
- arm64 nutzt den ARM-Build des Installers (`server/arm/linux`). Das ist
  ungetestet.
