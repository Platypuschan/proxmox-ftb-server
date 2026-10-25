#!/usr/bin/env bash
# Creates a Proxmox VE LXC container with a Minecraft server for an FTB modpack.
# Standalone: needs only the tools of a PVE host (pct, pvesm, pveam, pvesh,
# whiptail, perl, curl). External contacts: the FTB API for the pack list,
# the Proxmox template mirror (pveam) when the Debian template is missing,
# and GitHub when run without a checkout.
#
# Usage (as root on the PVE host):
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/Platypuschan/proxmox-ftb-server/main/ct/ftb-minecraft.sh)"
#                                                  without a checkout (loads install/ and files/ from GitHub)
#   bash ct/ftb-minecraft.sh                       interactive
#   FTB_PACK_ID=128 bash ct/ftb-minecraft.sh       pack preset; settings dialog still offered
#   FTB_PACK_ID=128 FTB_UNATTENDED=1 bash ct/ftb-minecraft.sh   no dialogs at all
# Settings via environment: see README ("Einstellungen").
#
# License: MIT
# Source: https://www.feed-the-beast.com/modpacks/server-files/linux

set -Eeuo pipefail

APP="FTB-Minecraft"
# install/ and files/ come from the checkout this script sits in; when it runs
# without one (bash -c "$(curl …/ct/ftb-minecraft.sh)"), from the repository
# tarball of the same branch.
FTB_REPO="${FTB_REPO:-Platypuschan/proxmox-ftb-server}"
FTB_REF="${FTB_REF:-main}"
FTB_SOURCE_URL="${FTB_SOURCE_URL:-https://codeload.github.com/${FTB_REPO}/tar.gz/${FTB_REF}}"
REPO_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
  _checkout="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  if [[ -f "$_checkout/install/ftb-minecraft-install.sh" && -d "$_checkout/files" ]]; then
    REPO_DIR="$_checkout"
  fi
  unset _checkout
fi
FTB_API="https://api.feed-the-beast.com/v1/modpacks/public"
# The JVM needs memory beyond the heap (metaspace, threads, direct buffers).
FTB_RAM_RESERVE="${FTB_RAM_RESERVE:-1536}"
FTB_WEB_PORT="${FTB_WEB_PORT:-8080}"
BACKTITLE="FTB-Minecraft für Proxmox VE"
TEMPLATE_SERIES="debian-13-standard"

LOG_DIR="${FTB_LOG_DIR:-/var/log/ftb-minecraft}"
LOG_FILE=""
CT_CREATED=""
WORK_DIR=""

# ------------------------------------------------------------------------------
# Output and error handling
# ------------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_OK=$'\e[32m' C_ERR=$'\e[31m' C_WARN=$'\e[33m' C_DIM=$'\e[2m' C_BOLD=$'\e[1m' C_OFF=$'\e[0m'
else
  C_OK="" C_ERR="" C_WARN="" C_DIM="" C_BOLD="" C_OFF=""
fi
msg_info() { printf '%s  … %s%s\n' "$C_DIM" "$*" "$C_OFF"; }
msg_ok() { printf '%s  ✓%s %s\n' "$C_OK" "$C_OFF" "$*"; }
msg_warn() { printf '%s  !%s %s\n' "$C_WARN" "$C_OFF" "$*"; }
msg_error() { printf '%s  ✗ %s%s\n' "$C_ERR" "$*" "$C_OFF" >&2; }

# Exit codes: 3 = expected failure with a message (die), 130 = cancelled by the
# user. Both also reach the caller through $(...) subshells; the ERR handler
# stays quiet for them and only explains unexpected failures.
die() {
  msg_error "$*"
  exit 3
}

# Runs a command with its output in the log file (on screen too with FTB_VERBOSE=1).
run() {
  if [[ "${FTB_VERBOSE:-0}" == "1" ]]; then
    "$@" 2>&1 | tee -a "$LOG_FILE"
  else
    "$@" >>"$LOG_FILE" 2>&1
  fi
}

on_error() {
  local rc=$? line=$1 cmd=$2
  trap - ERR
  if ((rc != 3 && rc != 130)); then
    msg_error "Fehler in Zeile ${line} (Exit-Code ${rc}): ${cmd}"
    if [[ -n "$LOG_FILE" && -s "$LOG_FILE" ]]; then
      printf '%s--- letzte Zeilen aus %s ---%s\n' "$C_DIM" "$LOG_FILE" "$C_OFF" >&2
      tail -n 25 "$LOG_FILE" >&2
    fi
  fi
  exit "$rc"
}

# Any abort after `pct create` offers to remove the half-built container.
on_exit() {
  local rc=$?
  [[ -n "$WORK_DIR" ]] && rm -rf "$WORK_DIR"
  if ((rc != 0)) && [[ -n "$CT_CREATED" ]]; then
    if interactive && whiptail --backtitle "$BACKTITLE" --title "ABGEBROCHEN" --defaultno --yesno \
      "Die Installation ist nicht fertig geworden.\n\nContainer ${CTID} wieder entfernen?\n(Nein: zur Fehlersuche behalten)" 12 60; then
      pct stop "$CTID" >/dev/null 2>&1 || true
      pct destroy "$CTID" --purge >/dev/null 2>&1 || true
      msg_warn "Container ${CTID} entfernt"
    else
      msg_warn "Container ${CTID} bleibt zur Fehlersuche bestehen (entfernen: pct destroy ${CTID} --purge)"
    fi
    [[ -n "$LOG_FILE" ]] && msg_warn "Vollständiges Log: ${LOG_FILE}"
  fi
}
trap 'on_error $LINENO "$BASH_COMMAND"' ERR
trap on_exit EXIT

interactive() {
  [[ "${FTB_UNATTENDED:-0}" != "1" && -t 0 ]]
}

# whiptail writes the answer to stderr; swap it onto stdout. Cancel aborts.
ask() {
  local answer
  answer=$(whiptail --backtitle "$BACKTITLE" "$@" 3>&1 1>&2 2>&3) || {
    printf '\n'
    msg_warn "Abgebrochen"
    exit 130
  }
  printf '%s' "$answer"
}

# ------------------------------------------------------------------------------
# Host checks
# ------------------------------------------------------------------------------
check_host() {
  [[ "$(id -u)" == "0" ]] || die "Bitte als root auf dem Proxmox-VE-Host ausführen"
  command -v pveversion >/dev/null 2>&1 || die "Kein Proxmox-VE-Host (pveversion fehlt)"
  local tool
  for tool in pct pvesm pveam pvesh perl curl tar; do
    command -v "$tool" >/dev/null 2>&1 || die "Werkzeug fehlt: ${tool}"
  done
  if interactive; then
    command -v whiptail >/dev/null 2>&1 || die "whiptail fehlt (apt install whiptail) oder FTB_UNATTENDED=1 setzen"
  fi
  perl -MJSON::PP -e 1 2>/dev/null || die "Perl-Modul JSON::PP fehlt"
  [[ "$(dpkg --print-architecture 2>/dev/null)" == "amd64" ]] ||
    die "Nur amd64-Hosts werden unterstützt (Proxmox-Templates gibt es nur für amd64)"
  local pve_version
  pve_version="$(pveversion | sed -n 's#^pve-manager/\([0-9]*\).*#\1#p')"
  [[ -n "$pve_version" && "$pve_version" -ge 8 ]] ||
    die "Proxmox VE 8 oder neuer nötig (gefunden: $(pveversion | head -n1))"
  mkdir -p "$LOG_DIR"
  LOG_FILE="$LOG_DIR/create-$(date +%Y%m%d-%H%M%S).log"
  WORK_DIR="$(mktemp -d)"
  msg_ok "Proxmox VE $(pveversion | sed -n 's#^pve-manager/\([^/ ]*\).*#\1#p'), Log: ${LOG_FILE}"
}

# install/ and files/ for the container: from the checkout, or downloaded.
fetch_sources() {
  if [[ -n "$REPO_DIR" ]]; then
    msg_ok "Dateien aus dem lokalen Checkout ${REPO_DIR}"
    return
  fi
  msg_info "Lade die Script-Dateien (${FTB_SOURCE_URL})"
  mkdir "$WORK_DIR/src"
  if ! curl -fsSL --retry 3 --connect-timeout 10 "$FTB_SOURCE_URL" | tar -xzf - -C "$WORK_DIR/src" --strip-components=1 2>>"$LOG_FILE"; then
    die "Script-Dateien nicht ladbar: ${FTB_SOURCE_URL}"
  fi
  [[ -f "$WORK_DIR/src/install/ftb-minecraft-install.sh" && -d "$WORK_DIR/src/files" ]] ||
    die "Im Archiv fehlen install/ oder files/: ${FTB_SOURCE_URL}"
  REPO_DIR="$WORK_DIR/src"
  msg_ok "Script-Dateien geladen (${FTB_REPO}@${FTB_REF})"
}

# ------------------------------------------------------------------------------
# FTB modpack selection
# ------------------------------------------------------------------------------
# JSON is parsed with Perl's core JSON::PP: a bare PVE host has no jq, but
# Perl is always there because PVE itself is written in it.
ftb_json() {
  perl -MJSON::PP -e '
    my ($mode, $file) = @ARGV;
    local $/; open(my $fh, "<", $file) or exit 1;
    my $d = eval { JSON::PP->new->decode(<$fh>) } or exit 1;
    sub targets {
      my %t = map { $_->{type} => $_ } @{ $_[0]{targets} || [] };
      my $g = $t{game}{version} // "?";
      my $l = $t{modloader} ? "$t{modloader}{name} $t{modloader}{version}" : "?";
      return ($g, $l);
    }
    my @v = sort { $b->{id} <=> $a->{id} } @{ $d->{versions} || [] };
    if ($mode eq "ids") { print join(" ", @{ $d->{packs} || [] }), "\n" }
    elsif ($mode eq "pack-line") {
      exit 0 unless ($d->{status} // "") eq "success" && @v;
      my ($g, $l) = targets($v[0]); (my $n = $d->{name}) =~ s/\s+/ /g;
      printf "%d\t%s (MC %s, %s)\n", $d->{id}, $n, $g, $l;
    }
    elsif ($mode eq "name") { print "$d->{name}\n" if defined $d->{name} }
    elsif ($mode eq "slug") { print "$d->{slug}\n" if defined $d->{slug} }
    elsif ($mode eq "versions") {
      for my $v (@v) { my ($g, $l) = targets($v); printf "%d\t%s [%s] MC %s, %s\n", $v->{id}, $v->{name}, $v->{type}, $g, $l }
    }
    elsif ($mode eq "latest-release") {
      my ($r) = grep { $_->{type} eq "release" } @v; $r //= $v[0]; print "$r->{id}\n" if $r;
    }
    elsif ($mode eq "has-version") { exit((grep { $_->{id} == $ENV{FTB_VERSION_ID} } @v) ? 0 : 1) }
    elsif ($mode eq "version-info") {
      # recommended heap MiB, server-side download size MiB, version name, game, loader
      my $bytes = 0; $bytes += $_->{size} for grep { !$_->{clientonly} } @{ $d->{files} || [] };
      my ($g, $l) = targets($d);
      printf "%d\t%d\t%s\t%s\t%s\n", $d->{specs}{recommended} || 4096, $bytes / 1048576, $d->{name}, $g, $l;
    }
  ' "$1" "$2"
}

ftb_fetch() {
  curl -fsSL --retry 3 --connect-timeout 10 --max-time 60 "$1" -o "$2"
}

ftb_select_pack() {
  local tmp="$WORK_DIR/ftb" ids id label lines choice
  local -a menu=()
  mkdir -p "$tmp"

  if [[ -z "${FTB_PACK_ID:-}" ]]; then
    interactive || die "FTB_PACK_ID fehlt (ohne Terminal gibt es keine Pack-Auswahl)"
    msg_info "Lade die FTB-Modpack-Liste"
    ftb_fetch "${FTB_API}/modpack/all" "$tmp/all.json" || die "FTB-API nicht erreichbar (${FTB_API})"
    ids="$(ftb_json ids "$tmp/all.json")"
    if curl --help all 2>/dev/null | grep -q -- '--parallel'; then
      for id in $ids; do
        printf 'url = "%s/modpack/%s"\noutput = "%s/%s.json"\n' "$FTB_API" "$id" "$tmp" "$id"
      done >"$tmp/list.cfg"
      curl -fsSL --retry 3 --parallel --parallel-max 16 -K "$tmp/list.cfg" 2>/dev/null || true
    else
      for id in $ids; do ftb_fetch "${FTB_API}/modpack/${id}" "$tmp/${id}.json" || true; done
    fi
    lines="$(for id in $ids; do if [[ -s "$tmp/${id}.json" ]]; then ftb_json pack-line "$tmp/${id}.json" || true; fi; done)"
    while IFS=$'\t' read -r id label; do
      [[ -n "$id" ]] && menu+=("$id" "$label")
    done <<<"$lines"
    ((${#menu[@]} > 0)) || die "Die FTB-API hat keine installierbaren Modpacks geliefert"
    msg_ok "$((${#menu[@]} / 2)) FTB-Modpacks geladen"
    FTB_PACK_ID="$(ask --title "FTB-MODPACK" --menu "Welches Modpack soll der Server bekommen?" 22 90 14 "${menu[@]}")"
    FTB_PACK_INTERACTIVE=1
  fi
  [[ "$FTB_PACK_ID" =~ ^[0-9]+$ ]] || die "FTB_PACK_ID muss eine Zahl sein, nicht '${FTB_PACK_ID}'"

  if [[ ! -s "$tmp/${FTB_PACK_ID}.json" ]] && ! ftb_fetch "${FTB_API}/modpack/${FTB_PACK_ID}" "$tmp/${FTB_PACK_ID}.json"; then
    die "FTB-Modpack ${FTB_PACK_ID} nicht gefunden"
  fi
  FTB_PACK_NAME="$(ftb_json name "$tmp/${FTB_PACK_ID}.json" || true)"
  [[ -n "$FTB_PACK_NAME" ]] || die "FTB-Modpack ${FTB_PACK_ID} nicht gefunden"

  if [[ -z "${FTB_VERSION_ID:-}" ]]; then
    FTB_VERSION_ID="$(ftb_json latest-release "$tmp/${FTB_PACK_ID}.json" || true)"
    # Only an interactive pack choice asks for the version; Enter keeps the latest release.
    if [[ -n "${FTB_PACK_INTERACTIVE:-}" ]]; then
      menu=()
      while IFS=$'\t' read -r id label; do menu+=("$id" "$label"); done < <(ftb_json versions "$tmp/${FTB_PACK_ID}.json")
      choice="$(ask --title "${FTB_PACK_NAME} – VERSION" --default-item "$FTB_VERSION_ID" \
        --menu "Welche Version? (Vorauswahl: neueste Release)" 22 90 14 "${menu[@]}")"
      FTB_VERSION_ID="$choice"
    fi
  fi
  if [[ ! "$FTB_VERSION_ID" =~ ^[0-9]+$ ]] || ! FTB_VERSION_ID="$FTB_VERSION_ID" ftb_json has-version "$tmp/${FTB_PACK_ID}.json"; then
    die "Version '${FTB_VERSION_ID}' gehört nicht zu FTB-Modpack ${FTB_PACK_ID}"
  fi

  ftb_fetch "${FTB_API}/modpack/${FTB_PACK_ID}/${FTB_VERSION_ID}" "$tmp/version.json" ||
    die "FTB-Modpack-Version ${FTB_VERSION_ID} nicht ladbar"
  IFS=$'\t' read -r PACK_HEAP PACK_SIZE_MB PACK_VERSION_NAME PACK_GAME PACK_LOADER < <(ftb_json version-info "$tmp/version.json")
  PACK_SLUG="$(ftb_json slug "$tmp/${FTB_PACK_ID}.json" || true)"
  msg_ok "Modpack: ${FTB_PACK_NAME} ${PACK_VERSION_NAME} (Minecraft ${PACK_GAME}, ${PACK_LOADER})"
  # Running this script accepts the Minecraft EULA (https://www.minecraft.net/eula).
  FTB_ACCEPT_EULA="yes"
  msg_ok "Minecraft-EULA akzeptiert (https://www.minecraft.net/eula)"
}

# ------------------------------------------------------------------------------
# Container settings
# ------------------------------------------------------------------------------
# Storages with the given content type: "name<TAB>free GiB", active ones only.
storages() {
  pvesm status -content "$1" 2>/dev/null | awk 'NR > 1 && $3 == "active" { printf "%s\t%d\n", $1, $6 / 1048576 }'
}

pick_storage() {
  local content="$1" title="$2" current="$3" name free
  local -a menu=()
  while IFS=$'\t' read -r name free; do
    [[ -n "$name" ]] && menu+=("$name" "${free} GiB frei")
  done < <(storages "$content")
  ((${#menu[@]} > 0)) || die "Kein aktiver Storage für '${content}' gefunden"
  if [[ -n "$current" ]]; then
    printf '%s' "$current"
  elif ((${#menu[@]} == 2)) || ! interactive; then
    # Only one storage, or no dialog: prefer the PVE defaults.
    for name in local-lvm local-zfs local; do
      if printf '%s\n' "${menu[@]}" | grep -qx "$name"; then
        printf '%s' "$name"
        return
      fi
    done
    printf '%s' "${menu[0]}"
  else
    ask --title "$title" --menu "Storage wählen:" 16 60 6 "${menu[@]}"
  fi
}

default_settings() {
  CTID="${var_ctid:-$(pvesh get /cluster/nextid)}"
  local slug
  slug="$(tr -c 'a-z0-9-' '-' <<<"${PACK_SLUG,,}" | cut -c1-55)"
  slug="${slug%-}"
  CT_HOSTNAME="${var_hostname:-ftb-${slug#ftb-}}"
  CT_CORES="${var_cpu:-4}"
  # Size the container from the pack's own recommendation unless set.
  CT_RAM="${var_ram:-$(((PACK_HEAP + FTB_RAM_RESERVE + 511) / 512 * 512))}"
  # Pack files, modloader libraries and JRE, plus room for the world and backups.
  local disk=$(((PACK_SIZE_MB * 2 + 1023) / 1024 + 10))
  ((disk < 16)) && disk=16
  CT_DISK="${var_disk:-$disk}"
  CT_BRIDGE="${var_brg:-vmbr0}"
  CT_NET="${var_net:-dhcp}"
  CT_GATEWAY="${var_gateway:-}"
  CT_VLAN="${var_vlan:-}"
  CT_PASSWORD="${var_pw:-}"
  CT_SSH_KEY="${var_ssh_authorized_key:-}"
  CT_ONBOOT="${var_onboot:-1}"
  CT_STORAGE="${var_container_storage:-}"
  TEMPLATE_STORAGE="${var_template_storage:-}"
}

advanced_settings() {
  CTID="$(ask --title "CONTAINER-ID" --inputbox "Container-ID:" 9 60 "$CTID")"
  CT_HOSTNAME="$(ask --title "HOSTNAME" --inputbox "Hostname:" 9 60 "$CT_HOSTNAME")"
  CT_CORES="$(ask --title "CPU" --inputbox "CPU-Kerne:" 9 60 "$CT_CORES")"
  CT_RAM="$(ask --title "RAM" --inputbox "Arbeitsspeicher in MiB (Empfehlung des Packs: ${PACK_HEAP} MiB Heap + ${FTB_RAM_RESERVE}):" 10 70 "$CT_RAM")"
  CT_DISK="$(ask --title "DISK" --inputbox "Root-Disk in GB:" 9 60 "$CT_DISK")"
  CT_STORAGE="$(pick_storage rootdir "CONTAINER-STORAGE" "")"
  CT_BRIDGE="$(ask --title "NETZWERK" --inputbox "Bridge:" 9 60 "$CT_BRIDGE")"
  CT_NET="$(ask --title "NETZWERK" --inputbox "IPv4: dhcp oder Adresse mit Präfix (z. B. 192.0.2.50/24):" 10 70 "$CT_NET")"
  if [[ "$CT_NET" != "dhcp" ]]; then
    CT_GATEWAY="$(ask --title "NETZWERK" --inputbox "Gateway:" 9 60 "$CT_GATEWAY")"
  fi
  CT_VLAN="$(ask --title "NETZWERK" --inputbox "VLAN-Tag (leer = keiner):" 9 60 "$CT_VLAN")"
  CT_PASSWORD="$(ask --title "ROOT-PASSWORT" --passwordbox "Root-Passwort (leer = Konsole loggt automatisch als root ein):" 10 70 "")"
  CT_SSH_KEY="$(ask --title "SSH" --inputbox "Öffentlicher SSH-Schlüssel für root (leer = keiner):" 10 70 "$CT_SSH_KEY")"
  if whiptail --backtitle "$BACKTITLE" --title "AUTOSTART" --yesno "Container beim Booten des Hosts starten?" 9 60; then
    CT_ONBOOT=1
  else
    CT_ONBOOT=0
  fi
}

validate_settings() {
  [[ "$CTID" =~ ^[0-9]+$ && "$CTID" -ge 100 ]] || die "Ungültige Container-ID: ${CTID}"
  pvesh get /cluster/nextid --vmid "$CTID" >/dev/null 2>&1 || die "Container-ID ${CTID} ist schon vergeben"
  [[ "$CT_HOSTNAME" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || die "Ungültiger Hostname: ${CT_HOSTNAME}"
  [[ "$CT_CORES" =~ ^[0-9]+$ && "$CT_CORES" -ge 1 ]] || die "Ungültige CPU-Anzahl: ${CT_CORES}"
  [[ "$CT_RAM" =~ ^[0-9]+$ && "$CT_RAM" -ge 2048 ]] || die "RAM muss mindestens 2048 MiB sein: ${CT_RAM}"
  [[ "$CT_DISK" =~ ^[0-9]+$ && "$CT_DISK" -ge 8 ]] || die "Disk muss mindestens 8 GB sein: ${CT_DISK}"
  [[ "$CT_BRIDGE" =~ ^[A-Za-z0-9._-]+$ ]] || die "Ungültige Bridge: ${CT_BRIDGE}"
  if [[ "$CT_NET" != "dhcp" ]]; then
    [[ "$CT_NET" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || die "IPv4 muss 'dhcp' oder Adresse/Präfix sein: ${CT_NET}"
    [[ -z "$CT_GATEWAY" || "$CT_GATEWAY" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "Ungültiges Gateway: ${CT_GATEWAY}"
  fi
  [[ -z "$CT_VLAN" || "$CT_VLAN" =~ ^[0-9]+$ ]] || die "Ungültiger VLAN-Tag: ${CT_VLAN}"
  [[ "$CT_ONBOOT" =~ ^[01]$ ]] || die "var_onboot muss 0 oder 1 sein"
  [[ "$FTB_WEB_PORT" =~ ^[0-9]+$ ]] || die "FTB_WEB_PORT muss eine Zahl sein"
  [[ -z "$CT_SSH_KEY" || "$CT_SSH_KEY" =~ ^(ssh-|ecdsa-|sk-) ]] || die "Kein gültiger öffentlicher SSH-Schlüssel"

  CT_STORAGE="$(pick_storage rootdir "CONTAINER-STORAGE" "$CT_STORAGE")"
  TEMPLATE_STORAGE="$(pick_storage vztmpl "TEMPLATE-STORAGE" "$TEMPLATE_STORAGE")"
  local free
  free="$(storages rootdir | awk -F'\t' -v s="$CT_STORAGE" '$1 == s { print $2 }')"
  [[ -n "$free" ]] || die "Storage ${CT_STORAGE} ist nicht aktiv oder kann keine Container aufnehmen"
  ((free >= CT_DISK)) || die "Auf ${CT_STORAGE} sind nur ${free} GiB frei, gebraucht werden ${CT_DISK} GB"
}

choose_settings() {
  default_settings
  if interactive; then
    local mode
    mode="$(ask --title "EINSTELLUNGEN" --menu \
      "Container für ${FTB_PACK_NAME}:\n\nID ${CTID}, ${CT_HOSTNAME}, ${CT_CORES} CPU, ${CT_RAM} MiB RAM, ${CT_DISK} GB Disk, ${CT_NET}" \
      16 76 3 standard "Mit diesen Werten anlegen" advanced "Werte anpassen (Netzwerk, Storage, Passwort …)")"
    [[ "$mode" == "advanced" ]] && advanced_settings
  fi
  validate_settings
  local net="$CT_NET"
  [[ "$CT_NET" != "dhcp" && -n "$CT_GATEWAY" ]] && net+=" via ${CT_GATEWAY}"
  [[ -n "$CT_VLAN" ]] && net+=", VLAN ${CT_VLAN}"
  msg_ok "Container ${CTID} (${CT_HOSTNAME}): ${CT_CORES} CPU, ${CT_RAM} MiB RAM, ${CT_DISK} GB auf ${CT_STORAGE}, ${CT_BRIDGE} ${net}"
  if interactive && ! whiptail --backtitle "$BACKTITLE" --title "ANLEGEN?" --yesno \
    "Container ${CTID} (${CT_HOSTNAME}) mit ${FTB_PACK_NAME} ${PACK_VERSION_NAME} jetzt anlegen?" 9 70; then
    msg_warn "Abgebrochen"
    exit 130
  fi
}

# ------------------------------------------------------------------------------
# Template, container, installation
# ------------------------------------------------------------------------------
ensure_template() {
  local pattern="^${TEMPLATE_SERIES}_.*_amd64\.tar\.(zst|gz|xz)$"
  TEMPLATE="$(pveam list "$TEMPLATE_STORAGE" 2>/dev/null | awk '{ sub(/^.*\//, "", $1); print $1 }' |
    grep -E "$pattern" | sort -V | tail -n 1 || true)"
  if [[ -n "$TEMPLATE" ]]; then
    msg_ok "Template ${TEMPLATE} liegt auf ${TEMPLATE_STORAGE}"
    return
  fi
  msg_info "Lade das Template ${TEMPLATE_SERIES} herunter"
  run pveam update
  TEMPLATE="$(pveam available -section system | awk '{ print $2 }' | grep -E "$pattern" | sort -V | tail -n 1 || true)"
  [[ -n "$TEMPLATE" ]] || die "Kein ${TEMPLATE_SERIES}-Template im Proxmox-Katalog gefunden"
  run pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
  msg_ok "Template ${TEMPLATE} heruntergeladen"
}

create_container() {
  local net0="name=eth0,bridge=${CT_BRIDGE},ip=${CT_NET}"
  [[ "$CT_NET" != "dhcp" && -n "$CT_GATEWAY" ]] && net0+=",gw=${CT_GATEWAY}"
  [[ -n "$CT_VLAN" ]] && net0+=",tag=${CT_VLAN}"
  local -a args=(
    "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}"
    --hostname "$CT_HOSTNAME" --cores "$CT_CORES" --memory "$CT_RAM" --swap 512
    --rootfs "${CT_STORAGE}:${CT_DISK}" --net0 "$net0"
    --unprivileged 1 --features nesting=1 --onboot "$CT_ONBOOT"
    --ostype debian --timezone host --tags "gaming;minecraft"
  )
  [[ -n "$CT_PASSWORD" ]] && args+=(--password "$CT_PASSWORD")
  if [[ -n "$CT_SSH_KEY" ]]; then
    printf '%s\n' "$CT_SSH_KEY" >"$WORK_DIR/authorized_keys"
    args+=(--ssh-public-keys "$WORK_DIR/authorized_keys")
  fi
  msg_info "Lege Container ${CTID} an"
  run pct create "${args[@]}"
  CT_CREATED=1
  msg_ok "Container ${CTID} angelegt"

  msg_info "Starte Container und warte auf Netzwerk"
  run pct start "$CTID"
  local i
  for ((i = 0; i < 60; i++)); do
    if pct exec "$CTID" -- sh -c 'ip -4 -o addr show scope global | grep -q inet && getent hosts deb.debian.org >/dev/null' \
      >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done
  ((i < 60)) || die "Container ${CTID} hat nach 2 Minuten kein Netzwerk (Bridge/VLAN/DHCP prüfen)"
  CT_IP="$(pct exec "$CTID" -- hostname -I | awk '{ print $1 }')"
  msg_ok "Netzwerk bereit: ${CT_IP}"
}

install_server() {
  local bundle="$WORK_DIR/ftb-minecraft-setup.tar.gz"
  tar -C "$REPO_DIR" --exclude=__pycache__ -czf "$bundle" install files
  run pct push "$CTID" "$bundle" /root/ftb-minecraft-setup.tar.gz
  run pct exec "$CTID" -- sh -c 'rm -rf /root/ftb-setup && mkdir /root/ftb-setup && tar -xzf /root/ftb-minecraft-setup.tar.gz -C /root/ftb-setup && rm /root/ftb-minecraft-setup.tar.gz'

  local autologin="no"
  [[ -z "$CT_PASSWORD" ]] && autologin="yes"
  msg_info "Installiere ${FTB_PACK_NAME} im Container (dauert einige Minuten, Fortschritt im Log)"
  run pct exec "$CTID" -- env \
    FTB_PACK_ID="$FTB_PACK_ID" FTB_VERSION_ID="$FTB_VERSION_ID" FTB_PACK_NAME="$FTB_PACK_NAME" \
    FTB_ACCEPT_EULA="$FTB_ACCEPT_EULA" FTB_RAM_RESERVE="$FTB_RAM_RESERVE" FTB_WEB_PORT="$FTB_WEB_PORT" \
    FTB_SETUP_DIR=/root/ftb-setup FTB_ROOT_AUTOLOGIN="$autologin" \
    bash /root/ftb-setup/install/ftb-minecraft-install.sh
  run pct exec "$CTID" -- rm -rf /root/ftb-setup
  msg_ok "${FTB_PACK_NAME} installiert"
}

write_notes() {
  local notes
  notes="$(
    cat <<EOF
# ${FTB_PACK_NAME}

FTB-Modpack ${FTB_PACK_ID}, Version ${PACK_VERSION_NAME} (${FTB_VERSION_ID}), Minecraft ${PACK_GAME}, ${PACK_LOADER}

- Minecraft: \`${CT_IP}:25565\`
- Web-Oberfläche: [http://${CT_IP}:${FTB_WEB_PORT}](http://${CT_IP}:${FTB_WEB_PORT})
- Konsole im Container: \`mc-cmd <befehl>\`, Log: \`journalctl -fu minecraft\`

Angelegt am $(date '+%Y-%m-%d %H:%M') mit proxmox-ftb-minecraft.
EOF
  )"
  run pct set "$CTID" --description "$notes"
}

main() {
  printf '\n%s%s%s – Minecraft-Server für FTB-Modpacks\n\n' "$C_BOLD" "$APP" "$C_OFF"
  check_host
  fetch_sources
  ftb_select_pack
  choose_settings
  ensure_template
  create_container
  install_server
  write_notes
  CT_CREATED=""
  printf '\n'
  msg_ok "Fertig."
  printf '  Minecraft-Server:  %s%s:25565%s\n' "$C_BOLD" "$CT_IP" "$C_OFF"
  printf '  Web-Oberfläche:    %shttp://%s:%s%s\n' "$C_BOLD" "$CT_IP" "$FTB_WEB_PORT" "$C_OFF"
  printf '  Der erste Start erzeugt die Welt und kann einige Minuten dauern.\n\n'
}

main "$@"
