#!/usr/bin/env bash

# Copyright (c) 2026 proxmox-ftb-minecraft contributors
# Built on the community-scripts ORG framework (MIT) | https://github.com/community-scripts/core
# License: MIT
# Source: https://www.feed-the-beast.com/modpacks/server-files/linux

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

if [[ ! "${FTB_PACK_ID:-}" =~ ^[0-9]+$ || ! "${FTB_VERSION_ID:-}" =~ ^[0-9]+$ ]]; then
  msg_error "FTB_PACK_ID/FTB_VERSION_ID missing - run ct/ftb-minecraft.sh on the Proxmox host"
  exit 1
fi
FTB_WEB_PORT="${FTB_WEB_PORT:-8080}"

msg_info "Installing dependencies"
$STD apt install -y ca-certificates curl jq python3
msg_ok "Installed dependencies"

msg_info "Creating minecraft user"
useradd --system --home-dir /opt/minecraft --shell /usr/sbin/nologin minecraft
install -d -o minecraft -g minecraft /opt/minecraft /opt/minecraft/server
install -d /opt/minecraft/.upload
{
  printf 'FTB_PACK_ID=%q\n' "$FTB_PACK_ID"
  printf 'FTB_VERSION_ID=%q\n' "$FTB_VERSION_ID"
  printf 'FTB_PACK_NAME=%q\n' "${FTB_PACK_NAME:-FTB modpack $FTB_PACK_ID}"
  printf 'FTB_RAM_RESERVE=%q\n' "${FTB_RAM_RESERVE:-1536}"
  printf 'FTB_ACCEPT_EULA=%q\n' "${FTB_ACCEPT_EULA:-yes}"
} >/opt/minecraft/ftb-pack.env
msg_ok "Created minecraft user"

msg_info "Installing FTB helper tools and web GUI"
stage="$(mktemp -d)"
if [[ -n "${FTB_FILES_BUNDLE:-}" ]]; then
  # Passed in by ct/ftb-minecraft.sh from a local checkout.
  base64 -d <<<"$FTB_FILES_BUNDLE" | tar -xzf - -C "$stage"
else
  files_url="${COMMUNITY_SCRIPTS_URL:?}/files"
  curl -fsSL --retry 3 "${files_url}/MANIFEST" -o "$stage/MANIFEST"
  while read -r file; do
    [[ -z "$file" || "$file" == \#* ]] && continue
    if [[ ! "$file" =~ ^[A-Za-z0-9._/-]+$ || "$file" == *..* ]]; then
      msg_error "Invalid path in MANIFEST: ${file}"
      exit 1
    fi
    mkdir -p "$stage/files/$(dirname "$file")"
    curl -fsSL --retry 3 "${files_url}/${file}" -o "$stage/files/${file}"
  done <"$stage/MANIFEST"
fi
install -m 755 "$stage"/files/bin/* /usr/local/bin/
rm -rf /usr/local/lib/ftb-minecraft
install -d /usr/local/lib/ftb-minecraft
cp -r "$stage/files/web" /usr/local/lib/ftb-minecraft/web
install -m 644 "$stage"/files/lib/*.py /usr/local/lib/ftb-minecraft/
chown -R root:root /usr/local/lib/ftb-minecraft
chmod -R u=rwX,go=rX /usr/local/lib/ftb-minecraft
rm -rf "$stage"
msg_ok "Installed FTB helper tools and web GUI"

msg_info "Installing ${FTB_PACK_NAME:-FTB modpack} (Patience)"
$STD /usr/local/bin/ftb-install-pack "$FTB_VERSION_ID"
if [[ ! -f /opt/minecraft/server/run.sh && ! -f /opt/minecraft/server/start.sh ]]; then
  msg_error "The FTB installer finished without creating run.sh or start.sh"
  exit 1
fi
if [[ ! -f /opt/minecraft/server/server.properties ]]; then
  # Minecraft fills in every missing property on the first start.
  printf 'motd=%s\n' "${FTB_PACK_NAME:-FTB modpack}" >/opt/minecraft/server/server.properties
  chown minecraft:minecraft /opt/minecraft/server/server.properties
fi
msg_ok "Installed ${FTB_PACK_NAME:-FTB modpack}"

msg_info "Creating Minecraft service"
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
systemctl daemon-reload
systemctl enable -q --now minecraft
msg_ok "Created Minecraft service"

msg_info "Setting up web GUI"
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
systemctl daemon-reload
systemctl enable -q --now ftb-web
msg_ok "Web GUI running on http port ${FTB_WEB_PORT}"

motd_ssh
customize
# customize writes the framework's /usr/bin/update; this app has no in-container
# update path, modpack updates run from the web GUI.
rm -f /usr/bin/update
cleanup_lxc
