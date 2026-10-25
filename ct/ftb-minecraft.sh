#!/usr/bin/env bash
_CS_DEFAULT_URL="${_CS_DEFAULT_URL:-https://raw.githubusercontent.com/Platypuschan/proxmox-ftb-minecraft/main}"
_cs_boot="${COMMUNITY_SCRIPTS_CORE_DIR:-$(dirname "${BASH_SOURCE[0]}")/../../core}/core/build.func"
source "$_cs_boot" 2>/dev/null || source <(curl -fsSL "${COMMUNITY_SCRIPTS_CORE_URL:-https://raw.githubusercontent.com/community-scripts/core/main}/core/build.func")
# Copyright (c) 2026 proxmox-ftb-minecraft contributors
# Built on the community-scripts ORG framework (MIT) | https://github.com/community-scripts/core
# License: MIT
# Source: https://www.feed-the-beast.com/modpacks/server-files/linux

APP="FTB-Minecraft"
var_tags="${var_tags:-gaming;minecraft}"
var_cpu="${var_cpu:-4}"
var_ram="${var_ram:-}"
var_disk="${var_disk:-}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_unprivileged="${var_unprivileged:-1}"

FTB_API="https://api.feed-the-beast.com/v1/modpacks/public"
# The JVM needs memory beyond the heap (metaspace, threads, direct buffers).
FTB_RAM_RESERVE="${FTB_RAM_RESERVE:-1536}"

header_info "$APP"
variables
color
catch_errors

# No telemetry to the community-scripts API from this script. Overriding
# diagnostics_check keeps the question away and leaves the host-wide opt-in
# file (/usr/local/community-scripts/diagnostics) of other scripts untouched;
# every reporting function returns early on DIAGNOSTICS=no, inside the
# container too (the value is passed in).
DIAGNOSTICS="no"
diagnostics_check() { DIAGNOSTICS="no"; }

# Helper tools and web GUI travel into the container as one base64 tarball
# when the script runs from a checkout; otherwise the container downloads
# them from COMMUNITY_SCRIPTS_URL.
ftb_bundle_files() {
  local root="${COMMUNITY_SCRIPTS_ROOT:-}"
  [[ -n "$root" && -f "$root/files/MANIFEST" ]] || return 0
  FTB_FILES_BUNDLE="$(tar -C "$root" --exclude=__pycache__ -czf - files | base64 -w0)"
  # The environment passed to lxc-attach allows 128 KiB per variable.
  if ((${#FTB_FILES_BUNDLE} > 120000)); then
    msg_error "files/ bundle is too large for the container environment (${#FTB_FILES_BUNDLE} bytes)"
    exit 1
  fi
  export FTB_FILES_BUNDLE
}

# ------------------------------------------------------------------------------
# FTB modpack selection (PVE host only, before the container exists)
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
  local tmp ids id label lines choice heap size_mb vname game loader slug
  local -a menu=()
  tmp="$(mktemp -d)"

  if [[ -z "${FTB_PACK_ID:-}" ]]; then
    msg_info "Loading FTB modpack list"
    if ! ftb_fetch "${FTB_API}/modpack/all" "$tmp/all.json"; then
      msg_error "Could not reach the FTB API (${FTB_API})"
      exit 1
    fi
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
    if ((${#menu[@]} == 0)); then
      msg_error "The FTB API returned no installable modpacks"
      exit 1
    fi
    msg_ok "Loaded $((${#menu[@]} / 2)) FTB modpacks"
    choice=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "FTB MODPACK" \
      --menu "Choose the FTB modpack for this server:" 22 90 14 "${menu[@]}" 3>&1 1>&2 2>&3) || exit_script
    FTB_PACK_ID="$choice"
    FTB_PACK_INTERACTIVE=1
  fi
  if [[ ! "$FTB_PACK_ID" =~ ^[0-9]+$ ]]; then
    msg_error "FTB_PACK_ID must be numeric, got '${FTB_PACK_ID}'"
    exit 1
  fi

  if [[ ! -s "$tmp/${FTB_PACK_ID}.json" ]] && ! ftb_fetch "${FTB_API}/modpack/${FTB_PACK_ID}" "$tmp/${FTB_PACK_ID}.json"; then
    msg_error "Could not load FTB modpack ${FTB_PACK_ID}"
    exit 1
  fi
  FTB_PACK_NAME="$(ftb_json name "$tmp/${FTB_PACK_ID}.json" || true)"
  if [[ -z "$FTB_PACK_NAME" ]]; then
    msg_error "FTB modpack ${FTB_PACK_ID} not found"
    exit 1
  fi

  if [[ -z "${FTB_VERSION_ID:-}" ]]; then
    FTB_VERSION_ID="$(ftb_json latest-release "$tmp/${FTB_PACK_ID}.json" || true)"
    # Only an interactive pack choice asks for the version; Enter keeps the
    # latest release, so unattended runs (FTB_PACK_ID set) never block here.
    if [[ -n "${FTB_PACK_INTERACTIVE:-}" ]]; then
      menu=()
      while IFS=$'\t' read -r id label; do menu+=("$id" "$label"); done < <(ftb_json versions "$tmp/${FTB_PACK_ID}.json")
      choice=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "${FTB_PACK_NAME} VERSION" \
        --default-item "$FTB_VERSION_ID" \
        --menu "Choose the modpack version (default: latest release):" 22 90 14 "${menu[@]}" 3>&1 1>&2 2>&3) || exit_script
      FTB_VERSION_ID="$choice"
    fi
  fi
  if [[ ! "$FTB_VERSION_ID" =~ ^[0-9]+$ ]] || ! FTB_VERSION_ID="$FTB_VERSION_ID" ftb_json has-version "$tmp/${FTB_PACK_ID}.json"; then
    msg_error "Version '${FTB_VERSION_ID}' does not belong to FTB modpack ${FTB_PACK_ID}"
    exit 1
  fi

  if ! ftb_fetch "${FTB_API}/modpack/${FTB_PACK_ID}/${FTB_VERSION_ID}" "$tmp/version.json"; then
    msg_error "Could not load FTB modpack version ${FTB_VERSION_ID}"
    exit 1
  fi
  IFS=$'\t' read -r heap size_mb vname game loader < <(ftb_json version-info "$tmp/version.json")

  # Size the container from the pack's own recommendation unless the user set it.
  if [[ -z "$var_ram" ]]; then
    var_ram=$(((heap + FTB_RAM_RESERVE + 511) / 512 * 512))
  fi
  if [[ -z "$var_disk" ]]; then
    # Pack files, modloader libraries and JRE, plus room for the world and backups.
    var_disk=$(((size_mb * 2 + 1023) / 1024 + 10))
    if ((var_disk < 16)); then var_disk=16; fi
  fi
  slug="$(ftb_json slug "$tmp/${FTB_PACK_ID}.json" || true)"
  slug="$(tr -c 'a-z0-9-' '-' <<<"${slug,,}" | cut -c1-55)"
  slug="${slug%-}"
  var_hostname="${var_hostname:-ftb-${slug#ftb-}}"

  rm -rf "$tmp"
  msg_ok "Selected ${FTB_PACK_NAME} ${vname} (MC ${game}, ${loader})"
  msg_ok "Sizing: ${var_ram} MiB RAM (pack recommends ${heap} MiB heap), ${var_disk} GB disk"
  # Running this script accepts the Minecraft EULA (https://www.minecraft.net/eula).
  FTB_ACCEPT_EULA="yes"
  msg_ok "Minecraft EULA accepted (https://www.minecraft.net/eula)"
  export FTB_PACK_ID FTB_VERSION_ID FTB_PACK_NAME FTB_ACCEPT_EULA FTB_RAM_RESERVE
}

# Creating containers only: there is no in-container `update` for this app,
# modpack updates run from the web GUI.
if ! command -v pveversion >/dev/null 2>&1; then
  msg_error "Run this script on the Proxmox VE host. Modpack updates are done in the web GUI."
  exit 1
fi
ftb_select_pack
ftb_bundle_files
if [[ -n "${FTB_WEB_PORT:-}" && ! "$FTB_WEB_PORT" =~ ^[0-9]+$ ]]; then
  msg_error "FTB_WEB_PORT must be numeric"
  exit 1
fi
export FTB_WEB_PORT

start
build_container
description

msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW}${FTB_PACK_NAME:-The FTB} server is reachable at:${CL}"
echo -e "${GATEWAY}${BGN}${IP}:25565${CL}"
echo -e "${INFO}${YW}Web GUI:${CL}"
echo -e "${GATEWAY}${BGN}http://${IP}:${FTB_WEB_PORT:-8080}${CL}"
echo -e "${INFO}${YW}The first start generates the world and can take several minutes.${CL}"
