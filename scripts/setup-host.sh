#!/usr/bin/env bash
#
# setup-host.sh — prepare an Ubuntu/Debian laptop to run the agent stack 24x7.
#
# Applies only host-level fixes that preflight.sh flags on a low-RAM laptop:
#   1. swapfile            — survive build-time memory spikes instead of OOM
#   2. zram                — compressed RAM, worth ~1.5-2 GB on an 8 GB box
#   3. vm tunables         — swappiness/cache pressure suited to zram
#   4. lid behaviour       — closing the laptop must not suspend the server
#   5. battery charge cap  — permanent AC at 100% destroys the battery
#   6. cloudflared         — inbound webhooks without a public IP (optional)
#
# Every step is idempotent and skipped if already satisfied.
# Nothing here installs or configures Hermes itself.
#
# Usage:
#   sudo bash scripts/setup-host.sh --dry-run     # show the plan, change nothing
#   sudo bash scripts/setup-host.sh               # apply, with a confirmation
#   sudo bash scripts/setup-host.sh --yes         # apply without prompting
#
# Options:
#   --swap-size N   swapfile size in GiB (default 4)
#   --battery N     charge limit percent (default 60; 0 disables this step)
#   --no-cloudflared
#   --dry-run, --yes, --help

set -euo pipefail

SWAP_GB=4
BATTERY_PCT=60
WANT_CLOUDFLARED=1
DRY_RUN=0
ASSUME_YES=0

SWAPFILE=/swapfile
LOGIND_DROPIN=/etc/systemd/logind.conf.d/99-agent-host.conf
SYSCTL_FILE=/etc/sysctl.d/99-agent-host.conf
ZRAM_CONF=/etc/systemd/zram-generator.conf
BATTERY_UNIT=/etc/systemd/system/battery-charge-limit.service

if [ -t 1 ]; then G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[1m'; N=$'\e[0m'; else G=""; Y=""; B=""; N=""; fi
say()  { printf '%s==>%s %s\n' "$B" "$N" "$1"; }
ok()   { printf '    %sok%s   %s\n' "$G" "$N" "$1"; }
skip() { printf '    %sskip%s %s\n' "$Y" "$N" "$1"; }

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
  case "$1" in
    --swap-size)      SWAP_GB="${2:?--swap-size needs a value}"; shift 2 ;;
    --battery)        BATTERY_PCT="${2:?--battery needs a value}"; shift 2 ;;
    --no-cloudflared) WANT_CLOUDFLARED=0; shift ;;
    --dry-run)        DRY_RUN=1; shift ;;
    --yes|-y)         ASSUME_YES=1; shift ;;
    --help|-h)        usage ;;
    *) printf 'unknown option: %s (try --help)\n' "$1" >&2; exit 2 ;;
  esac
done

case "$SWAP_GB" in ''|*[!0-9]*) echo "--swap-size must be an integer" >&2; exit 2 ;; esac
case "$BATTERY_PCT" in ''|*[!0-9]*) echo "--battery must be an integer" >&2; exit 2 ;; esac
if [ "$BATTERY_PCT" -gt 100 ]; then echo "--battery must be 0-100" >&2; exit 2; fi

if [ "$DRY_RUN" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
  echo "Needs root. Re-run with: sudo bash $0 $*" >&2
  exit 1
fi

# run <description> <command...> — honours --dry-run.
run() {
  local desc="$1"; shift
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '    would: %s\n' "$desc"
    return 0
  fi
  "$@"
}

# write_file <path> <description> — content on stdin, honours --dry-run.
write_file() {
  local path="$1" desc="$2" content
  content=$(cat)
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '    would write %s (%s)\n' "$path" "$desc"
    return 0
  fi
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$content" > "$path"
}

mem_total_mib() { awk '/^MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo; }
swap_total_mib() { awk '/^SwapTotal:/ {printf "%d", $2/1024}' /proc/meminfo; }

printf '%s=== agent host setup ===%s\n' "$B" "$N"
printf 'RAM %s MiB · swap now %s MiB · plan: %s GiB swapfile, zram, battery %s%%\n\n' \
  "$(mem_total_mib)" "$(swap_total_mib)" "$SWAP_GB" "$BATTERY_PCT"

if [ "$DRY_RUN" -eq 0 ] && [ "$ASSUME_YES" -eq 0 ]; then
  printf 'This modifies swap, sysctl, logind and systemd units. Continue? [y/N] '
  read -r reply
  case "$reply" in [yY]*) ;; *) echo "Aborted."; exit 0 ;; esac
  echo
fi

# ------------------------------------------------------------------ 1. swap
say "Swapfile (${SWAP_GB} GiB)"
if [ "$(swap_total_mib)" -ge $((SWAP_GB * 1024 - 64)) ]; then
  skip "already $(swap_total_mib) MiB of swap"
elif [ -e "$SWAPFILE" ]; then
  skip "$SWAPFILE exists; leaving it alone (remove it manually to resize)"
else
  # fallocate on some filesystems produces a file swapon refuses; dd is slower
  # but always valid. btrfs needs a no-COW, no-compress file.
  if [ "$(findmnt -no FSTYPE / 2>/dev/null)" = "btrfs" ]; then
    run "create btrfs swapfile" btrfs filesystem mkswapfile --size "${SWAP_GB}g" "$SWAPFILE"
  else
    run "allocate $SWAPFILE" dd if=/dev/zero of="$SWAPFILE" bs=1M count=$((SWAP_GB * 1024)) status=none
    run "chmod 600 $SWAPFILE" chmod 600 "$SWAPFILE"
    run "mkswap $SWAPFILE" mkswap "$SWAPFILE" >/dev/null
  fi
  run "swapon $SWAPFILE" swapon "$SWAPFILE"
  if [ "$DRY_RUN" -eq 0 ]; then
    grep -qs "^$SWAPFILE " /etc/fstab || printf '%s none swap sw 0 0\n' "$SWAPFILE" >> /etc/fstab
    ok "swap active and persisted in /etc/fstab"
  else
    printf '    would: append %s to /etc/fstab\n' "$SWAPFILE"
  fi
fi

# ------------------------------------------------------------------ 2. zram
say "zram (compressed RAM)"
if [ -e /sys/block/zram0 ]; then
  skip "zram0 already present"
else
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '    would: apt-get install systemd-zram-generator and write %s\n' "$ZRAM_CONF"
  else
    if ! dpkg -s systemd-zram-generator >/dev/null 2>&1; then
      DEBIAN_FRONTEND=noninteractive apt-get update -qq || true
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq systemd-zram-generator \
        || skip "could not install systemd-zram-generator; skipping zram"
    fi
    if dpkg -s systemd-zram-generator >/dev/null 2>&1; then
      write_file "$ZRAM_CONF" "zram sized to half of RAM, max 4G" <<'EOF'
# Managed by atlas setup-host.sh
[zram0]
zram-size = min(ram / 2, 4096)
compression-algorithm = zstd
EOF
      systemctl daemon-reload
      systemctl start /dev/zram0 2>/dev/null || true
      ok "zram configured (active after next boot if it did not start now)"
    fi
  fi
fi

# -------------------------------------------------------------- 3. tunables
say "Memory tunables"
# With zram, swapping to compressed RAM is cheap, so a high swappiness is
# correct — the kernel default of 60 is tuned for disk swap.
write_file "$SYSCTL_FILE" "swappiness + cache pressure for a zram host" <<'EOF'
# Managed by atlas setup-host.sh
vm.swappiness = 100
vm.vfs_cache_pressure = 50
vm.dirty_background_ratio = 5
vm.dirty_ratio = 10
EOF
run "apply sysctl" sysctl -q --system
ok "vm.swappiness=100, vfs_cache_pressure=50"

# -------------------------------------------------------------------- 4. lid
say "Lid behaviour"
if [ -d /proc/acpi/button/lid ] && [ -n "$(ls -A /proc/acpi/button/lid 2>/dev/null)" ]; then
  write_file "$LOGIND_DROPIN" "ignore lid events" <<'EOF'
# Managed by atlas setup-host.sh
# A laptop acting as a server must keep running with the lid shut.
[Login]
HandleLidSwitch=ignore
HandleLidSwitchDocked=ignore
HandleLidSwitchExternalPower=ignore
EOF
  run "reload logind" systemctl restart systemd-logind
  ok "closing the lid no longer suspends this host"
else
  skip "no lid detected"
fi

# ---------------------------------------------------------------- 5. battery
say "Battery charge limit"
if [ "$BATTERY_PCT" -eq 0 ]; then
  skip "disabled by --battery 0"
else
  bat_thr=""
  for f in /sys/class/power_supply/BAT*/charge_control_end_threshold; do
    [ -e "$f" ] && { bat_thr="$f"; break; }
  done
  if [ -z "$bat_thr" ]; then
    skip "kernel charge-limit control not exposed — set the limit in MyASUS or BIOS instead"
  else
    run "set charge limit to ${BATTERY_PCT}%" sh -c "echo $BATTERY_PCT > '$bat_thr'"
    # The sysfs value resets on reboot, so persist it as a unit.
    write_file "$BATTERY_UNIT" "re-apply charge limit at boot" <<EOF
# Managed by atlas setup-host.sh
[Unit]
Description=Cap battery charge at ${BATTERY_PCT}% for 24x7 AC operation
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'for f in /sys/class/power_supply/BAT*/charge_control_end_threshold; do [ -w "\$f" ] && echo ${BATTERY_PCT} > "\$f"; done; exit 0'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    run "enable battery unit" systemctl enable --now battery-charge-limit.service
    ok "charge capped at ${BATTERY_PCT}% and persisted across reboots"
  fi
fi

# ------------------------------------------------------------ 6. cloudflared
say "cloudflared (inbound webhooks without a public IP)"
if [ "$WANT_CLOUDFLARED" -eq 0 ]; then
  skip "disabled by --no-cloudflared"
elif command -v cloudflared >/dev/null 2>&1; then
  skip "already installed"
else
  arch=$(dpkg --print-architecture 2>/dev/null || echo amd64)
  url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}.deb"
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '    would: download and install %s\n' "$url"
  else
    tmp=$(mktemp -d)
    if curl -fsSL -o "$tmp/cloudflared.deb" "$url"; then
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$tmp/cloudflared.deb" \
        && ok "installed — authenticate later with: cloudflared tunnel login" \
        || skip "install failed; see https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/"
    else
      skip "download failed; install manually if you need inbound webhooks"
    fi
    rm -rf "$tmp"
  fi
fi

# ------------------------------------------------------------------- summary
printf '\n%s=== done ===%s\n' "$B" "$N"
if [ "$DRY_RUN" -eq 1 ]; then
  printf 'Dry run: nothing was changed. Re-run without --dry-run to apply.\n'
else
  printf 'RAM %s MiB · swap %s MiB\n' "$(mem_total_mib)" "$(swap_total_mib)"
  printf 'Re-run scripts/preflight.sh to confirm, then install Hermes.\n'
fi
