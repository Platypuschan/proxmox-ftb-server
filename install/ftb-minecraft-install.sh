#!/usr/bin/env bash
# Installs the FTB modpack server, helper tools and web GUI inside the
# container. Run by ct/ftb-minecraft.sh on the host via `pct exec`, with the
# repository's install/ and files/ unpacked to FTB_SETUP_DIR.
#
# License: MIT
# Source: https://www.feed-the-beast.com/modpacks/server-files/linux

set -Eeuo pipefail
trap 'echo "FEHLER in Zeile $LINENO (Exit-Code $?): $BASH_COMMAND" >&2' ERR

msg() { printf '\n==> %s\n' "$*"; }

export DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8 LANG=C.UTF-8

if [[ ! "${FTB_PACK_ID:-}" =~ ^[0-9]+$ || ! "${FTB_VERSION_ID:-}" =~ ^[0-9]+$ ]]; then
  echo "FTB_PACK_ID/FTB_VERSION_ID fehlen - ct/ftb-minecraft.sh auf dem Proxmox-Host ausführen" >&2
  exit 1
fi
FTB_SETUP_DIR="${FTB_SETUP_DIR:-/root/ftb-setup}"
FTB_WEB_PORT="${FTB_WEB_PORT:-8080}"
[[ -d "$FTB_SETUP_DIR/files/bin" ]] || {
  echo "Setup-Dateien fehlen unter ${FTB_SETUP_DIR}" >&2
  exit 1
}

msg "Aktualisiere das Container-Betriebssystem"
apt-get update
apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold dist-upgrade
apt-get install -y --no-install-recommends ca-certificates curl jq python3 tar gzip

msg "Lege den Benutzer minecraft an"
id minecraft >/dev/null 2>&1 || useradd --system --home-dir /opt/minecraft --shell /usr/sbin/nologin minecraft
install -d -o minecraft -g minecraft /opt/minecraft /opt/minecraft/server
install -d /opt/minecraft/.upload
{
  printf 'FTB_PACK_ID=%q\n' "$FTB_PACK_ID"
  printf 'FTB_VERSION_ID=%q\n' "$FTB_VERSION_ID"
  printf 'FTB_PACK_NAME=%q\n' "${FTB_PACK_NAME:-FTB modpack $FTB_PACK_ID}"
  printf 'FTB_RAM_RESERVE=%q\n' "${FTB_RAM_RESERVE:-1536}"
  printf 'FTB_ACCEPT_EULA=%q\n' "${FTB_ACCEPT_EULA:-yes}"
} >/opt/minecraft/ftb-pack.env

msg "Installiere Helfer und Web-Oberfläche"
install -m 755 "$FTB_SETUP_DIR"/files/bin/* /usr/local/bin/
rm -rf /usr/local/lib/ftb-minecraft
install -d /usr/local/lib/ftb-minecraft
cp -r "$FTB_SETUP_DIR/files/web" /usr/local/lib/ftb-minecraft/web
install -m 644 "$FTB_SETUP_DIR"/files/lib/*.py /usr/local/lib/ftb-minecraft/
chown -R root:root /usr/local/lib/ftb-minecraft
chmod -R u=rwX,go=rX /usr/local/lib/ftb-minecraft

msg "Installiere ${FTB_PACK_NAME:-das FTB-Modpack} mit dem FTB-Installer"
/usr/local/bin/ftb-install-pack "$FTB_VERSION_ID"
if [[ ! -f /opt/minecraft/server/run.sh && ! -f /opt/minecraft/server/start.sh ]]; then
  echo "Der FTB-Installer hat weder run.sh noch start.sh angelegt" >&2
  exit 1
fi
if [[ ! -f /opt/minecraft/server/server.properties ]]; then
  # Minecraft fills in every missing property on the first start.
  printf 'motd=%s\n' "${FTB_PACK_NAME:-FTB modpack}" >/opt/minecraft/server/server.properties
  chown minecraft:minecraft /opt/minecraft/server/server.properties
fi

msg "Richte den Minecraft-Dienst ein"
cat <<EOF >/etc/systemd/system/minecraft.socket
[Unit]
Description=Minecraft server console input
PartOf=minecraft.service

[Socket]
ListenFIFO=/run/minecraft.stdin
SocketUser=minecraft
SocketMode=0600
RemoveOnStop=true
EOF
cat <<EOF >/etc/systemd/system/minecraft.service
[Unit]
Description=${FTB_PACK_NAME:-FTB} Minecraft server
Wants=network-online.target
After=network-online.target minecraft.socket
Requires=minecraft.socket

[Service]
Type=simple
User=minecraft
Group=minecraft
WorkingDirectory=/opt/minecraft/server
Sockets=minecraft.socket
StandardInput=socket
StandardOutput=journal
StandardError=journal
ExecStartPre=/usr/local/bin/ftb-heap
ExecStart=/usr/local/bin/ftb-start
ExecStop=/bin/sh -c 'echo stop >/run/minecraft.stdin; while kill -0 "\$\$MAINPID" 2>/dev/null; do sleep 1; done'
TimeoutStartSec=600
TimeoutStopSec=180
Restart=on-failure
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF

msg "Richte die Web-Oberfläche ein (HTTP-Port ${FTB_WEB_PORT})"
cat <<EOF >/etc/systemd/system/ftb-web.service
[Unit]
Description=FTB Minecraft web GUI
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
Environment=FTB_WEB_PORT=${FTB_WEB_PORT}
ExecStart=/usr/bin/python3 /usr/local/lib/ftb-minecraft/web/ftb-web.py
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

if [[ "${FTB_ROOT_AUTOLOGIN:-no}" == "yes" ]]; then
  msg "Konsole: automatischer root-Login (kein Passwort gesetzt)"
  # pct console / the Proxmox console attach to tty1 (container-getty@1) or
  # /dev/console (console-getty), depending on the container's console mode.
  for unit in container-getty@1.service console-getty.service; do
    mkdir -p "/etc/systemd/system/${unit}.d"
    cat <<'EOF' >"/etc/systemd/system/${unit}.d/autologin.conf"
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear --keep-baud - 115200,38400,9600 $TERM
EOF
  done
fi

# Shown on every login: where to find the server and the web GUI.
{
  printf '_ftb_name=%q\n_ftb_port=%q\n' "${FTB_PACK_NAME:-FTB-Minecraft}" "$FTB_WEB_PORT"
  cat <<'EOF'
_ftb_ip="$(hostname -I | awk '{print $1}')"
printf '\n  %s\n  Minecraft:      %s:25565\n  Web-Oberfläche: http://%s:%s\n  Konsole:        mc-cmd <befehl>   Log: journalctl -fu minecraft\n\n' \
  "$_ftb_name" "$_ftb_ip" "$_ftb_ip" "$_ftb_port"
unset _ftb_name _ftb_port _ftb_ip
EOF
} >/etc/profile.d/ftb-minecraft.sh
: >/etc/motd

systemctl daemon-reload
systemctl enable -q --now minecraft ftb-web
if [[ "${FTB_ROOT_AUTOLOGIN:-no}" == "yes" ]]; then
  systemctl restart container-getty@1.service console-getty.service 2>/dev/null || true
fi

msg "Räume auf"
apt-get -y autoremove
apt-get clean
echo "Installation abgeschlossen"
