#!/usr/bin/env bash
#
# preflight.sh — check whether this machine can host the Hermes agent stack.
#
# Tuned for the low-RAM case (8 GB laptop acting as a 24x7 server). Reports
# PASS / WARN / FAIL per check and exits non-zero if anything is FAIL.
#
# Safe to run repeatedly. Reads only; changes nothing.
#
# Usage:  bash scripts/preflight.sh

set -uo pipefail

PASS=0; WARN=0; FAIL=0

if [ -t 1 ] && [ "${NO_COLOR:-}" = "" ]; then
  G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; B=$'\e[1m'; N=$'\e[0m'
else
  G=""; Y=""; R=""; B=""; N=""
fi

pass() { printf '  %sPASS%s  %s\n' "$G" "$N" "$1"; PASS=$((PASS+1)); }
warn() { printf '  %sWARN%s  %s\n' "$Y" "$N" "$1"; [ $# -gt 1 ] && printf '        ↳ %s\n' "$2"; WARN=$((WARN+1)); }
fail() { printf '  %sFAIL%s  %s\n' "$R" "$N" "$1"; [ $# -gt 1 ] && printf '        ↳ %s\n' "$2"; FAIL=$((FAIL+1)); }
head2() { printf '\n%s%s%s\n' "$B" "$1" "$N"; }

# Total RAM in MiB. /proc/meminfo is kB.
mem_total_mib() { awk '/^MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo; }
mem_avail_mib() { awk '/^MemAvailable:/ {printf "%d", $2/1024}' /proc/meminfo; }
swap_total_mib() { awk '/^SwapTotal:/ {printf "%d", $2/1024}' /proc/meminfo; }

printf '%s=== Hermes host preflight ===%s\n' "$B" "$N"
printf 'host: %s   date: %s\n' "$(hostname 2>/dev/null || echo '?')" "$(date -Is 2>/dev/null || date)"

# ---------------------------------------------------------------- platform
head2 'Platform'

if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  pass "OS: ${PRETTY_NAME:-$NAME}"
else
  warn "Cannot read /etc/os-release" "Non-standard distro; the install scripts assume Debian/Ubuntu."
fi

if grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
  fail "Running under WSL2" \
    "On 8 GB, Windows + WSL2 leaves too little for the stack and WSL does not survive lid-close reliably. Install Ubuntu Server bare-metal for a 24x7 host."
else
  pass "Bare-metal / VM kernel (not WSL)"
fi

cores=$(nproc 2>/dev/null || echo 0)
if [ "$cores" -ge 4 ]; then
  pass "CPU cores: $cores"
elif [ "$cores" -ge 2 ]; then
  warn "CPU cores: $cores" "Workable but browser automation will be slow."
else
  fail "CPU cores: $cores" "Need at least 2."
fi

# A running graphical session costs 0.7-1.5 GB that the stack needs.
if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || pgrep -x gnome-shell >/dev/null 2>&1 || pgrep -x plasmashell >/dev/null 2>&1; then
  warn "A desktop environment appears to be running" \
    "Costs ~1 GB. On 8 GB prefer Ubuntu Server (no GUI), or boot to multi-user.target: sudo systemctl set-default multi-user.target"
else
  pass "No desktop environment detected"
fi

# ---------------------------------------------------------------- memory
head2 'Memory'

total=$(mem_total_mib); avail=$(mem_avail_mib); swap=$(swap_total_mib)
printf '  total=%s MiB  available=%s MiB  swap=%s MiB\n' "$total" "$avail" "$swap"

# Stack budget, SQLite-only (no Postgres): ~1.5 GB idle, ~2.5 GB active,
# ~5-6 GB peak while a build agent runs.
if   [ "$total" -ge 15000 ]; then pass "RAM: ample (>=16 GB)"
elif [ "$total" -ge 7000 ]; then
  warn "RAM: 8 GB — workable, but only with the low-memory profile" \
    "Use SQLite (no Postgres), cap concurrent browsers at 1, and keep swap + zram configured. Adding one 16 GB SODIMM removes every constraint here."
elif [ "$total" -ge 3500 ]; then
  warn "RAM: 4 GB — gateway only" "Run the agent's heavy work on another host via the SSH backend."
else
  fail "RAM: under 4 GB" "Not enough for this stack."
fi

if [ "$avail" -lt 1500 ]; then
  warn "Only ${avail} MiB available right now" "Close other workloads before starting the stack."
fi

# On 8 GB, swap is the difference between 'slow' and 'OOM-killed mid-build'.
want_swap=4096
if [ "$swap" -ge "$want_swap" ]; then
  pass "Swap: ${swap} MiB"
elif [ "$swap" -gt 0 ]; then
  warn "Swap: ${swap} MiB (want >= ${want_swap} MiB on 8 GB)" "Run: sudo bash scripts/setup-host.sh"
else
  if [ "$total" -lt 15000 ]; then
    fail "No swap configured" "An 8 GB host will be OOM-killed during build bursts. Run: sudo bash scripts/setup-host.sh"
  else
    warn "No swap configured" "Recommended even with 16 GB."
  fi
fi

if [ -e /sys/block/zram0 ] || lsmod 2>/dev/null | grep -q '^zram'; then
  pass "zram active (compressed RAM)"
else
  [ "$total" -lt 15000 ] && warn "zram not active" "Buys ~1.5-2 GB effective on an 8 GB box. Run: sudo bash scripts/setup-host.sh"
fi

sw=$(cat /proc/sys/vm/swappiness 2>/dev/null || echo "?")
if [ "$sw" != "?" ] && [ "$sw" -ge 60 ] 2>/dev/null && [ "$total" -lt 15000 ]; then
  warn "vm.swappiness=$sw" "With zram, 100 performs better than the default 60. setup-host.sh sets this."
fi

# ---------------------------------------------------------------- disk
head2 'Disk'

root_avail_gb=$(df -BG --output=avail / 2>/dev/null | tail -1 | tr -dc '0-9')
root_avail_gb=${root_avail_gb:-0}
if   [ "$root_avail_gb" -ge 40 ]; then pass "Free space on /: ${root_avail_gb} GB"
elif [ "$root_avail_gb" -ge 20 ]; then warn "Free space on /: ${root_avail_gb} GB" "Container images for this stack run 15-25 GB."
else fail "Free space on /: ${root_avail_gb} GB" "Need 20 GB minimum."
fi

if command -v lsblk >/dev/null 2>&1; then
  rootdev=$(findmnt -no SOURCE / 2>/dev/null | sed 's/\[.*//')
  # Virtio/loop devices report ROTA=1 regardless of the backing store, so the
  # answer is meaningless there.
  case "$rootdev" in
    /dev/vd*|/dev/loop*|/dev/mapper/*|overlay) ;;
    *)
      rot=$(lsblk -no ROTA "$rootdev" 2>/dev/null | head -1 | tr -d ' ')
      case "$rot" in
        0) pass "Root filesystem is on an SSD" ;;
        1) warn "Root filesystem is on a spinning disk" "Swap thrash will be painful. Move the stack to an SSD." ;;
      esac
      ;;
  esac
fi

# ---------------------------------------------------------------- runtime
head2 'Runtime dependencies'

if command -v docker >/dev/null 2>&1; then
  pass "docker: $(docker --version 2>/dev/null | head -1)"
  if timeout 10 docker info >/dev/null 2>&1; then
    pass "docker daemon reachable"
  else
    warn "docker installed but daemon not reachable" "sudo systemctl enable --now docker && sudo usermod -aG docker \"\$USER\" (then log out and back in)"
  fi
  if docker compose version >/dev/null 2>&1; then
    pass "docker compose plugin present"
  else
    warn "docker compose plugin missing" "sudo apt-get install -y docker-compose-plugin"
  fi
else
  warn "docker not installed" "Only needed for the containerised backend. Native install works without it."
fi

if command -v node >/dev/null 2>&1; then
  nmaj=$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
  if [ "${nmaj:-0}" -ge 22 ]; then pass "node: $(node --version)"
  else warn "node $(node --version) is old" "Hermes expects Node 22+."; fi
else
  warn "node not installed" "The Hermes installer can provide it; or: https://github.com/nvm-sh/nvm"
fi

command -v git  >/dev/null 2>&1 && pass "git present"  || fail "git missing"  "sudo apt-get install -y git"
command -v curl >/dev/null 2>&1 && pass "curl present" || fail "curl missing" "sudo apt-get install -y curl"

# ---------------------------------------------------------------- 24x7
head2 'Always-on behaviour'

have_battery=0
for b in /sys/class/power_supply/BAT*; do [ -d "$b" ] && have_battery=1 && break; done
if [ "$have_battery" -eq 1 ]; then
  pass "Battery present — acts as a built-in UPS"
  thr=$(cat /sys/class/power_supply/BAT*/charge_control_end_threshold 2>/dev/null | head -1)
  if [ -n "$thr" ]; then
    if [ "$thr" -le 80 ] 2>/dev/null; then
      pass "Charge limit set to ${thr}%"
    else
      warn "Charge limit is ${thr}%" "Holding 100% on permanent AC swells the battery. setup-host.sh sets 60%."
    fi
  else
    warn "Kernel charge-limit control not exposed" "Set the limit in MyASUS or the BIOS instead. Important for 24x7 on AC."
  fi
else
  pass "No battery (desktop/VM) — nothing to limit"
fi

# Only meaningful on a machine that actually has a lid.
if [ -d /proc/acpi/button/lid ] && [ -n "$(ls -A /proc/acpi/button/lid 2>/dev/null)" ]; then
  if grep -rqsE '^[[:space:]]*HandleLidSwitch[[:space:]]*=[[:space:]]*ignore' /etc/systemd/logind.conf /etc/systemd/logind.conf.d/ 2>/dev/null; then
    pass "Lid close will not suspend the host"
  else
    warn "Closing the lid will suspend this host" "Kills the agent every time you shut the laptop. setup-host.sh fixes this."
  fi
fi

# ---------------------------------------------------------------- network
head2 'Network'

if getent hosts github.com >/dev/null 2>&1; then
  pass "DNS resolves"
else
  fail "DNS resolution failed" "No outbound name resolution; nothing will work."
fi

if command -v curl >/dev/null 2>&1; then
  # A proxy that retries emits one code per attempt; keep the last.
  code=$(curl -sS -o /dev/null -w '%{http_code}' -m 15 https://openrouter.ai/api/v1/models 2>/dev/null | tail -c 3)
  code=${code:-000}
  case "$code" in
    200|401|403) pass "Reached openrouter.ai (HTTP $code)" ;;
    000)         warn "Could not reach openrouter.ai" "Check egress/firewall/proxy." ;;
    *)           warn "openrouter.ai returned HTTP $code" ;;
  esac
fi

if command -v cloudflared >/dev/null 2>&1; then
  pass "cloudflared present (inbound webhooks without port-forwarding)"
else
  warn "cloudflared not installed" "Needed to receive webhooks behind CGNAT/dynamic IP. setup-host.sh can install it."
fi

# ---------------------------------------------------------------- existing
head2 'Existing install'

if [ -d "$HOME/.hermes" ]; then
  pass "Found $HOME/.hermes"
  [ -f "$HOME/.hermes/config.yaml" ] && pass "  config.yaml present" || warn "  config.yaml missing" "Run: hermes setup"
  if [ -d "$HOME/.hermes/vault" ]; then
    perms=$(stat -c '%a' "$HOME/.hermes/vault" 2>/dev/null || echo '?')
    [ "$perms" = "700" ] && pass "  vault/ permissions $perms" || warn "  vault/ permissions $perms" "Expected 700. chmod 700 ~/.hermes/vault"
  fi
  if [ -f "$HOME/.hermes/.env" ]; then
    perms=$(stat -c '%a' "$HOME/.hermes/.env" 2>/dev/null || echo '?')
    [ "$perms" = "600" ] && pass "  .env permissions $perms" || fail "  .env permissions $perms" "Holds API keys. chmod 600 ~/.hermes/.env"
  fi
else
  warn "No $HOME/.hermes yet" "Expected before first install."
fi

# ---------------------------------------------------------------- verdict
printf '\n%s=== %d pass / %d warn / %d fail ===%s\n' "$B" "$PASS" "$WARN" "$FAIL" "$N"
if [ "$FAIL" -gt 0 ]; then
  printf '%sBlocked.%s Resolve the FAIL items above, then re-run.\n' "$R" "$N"
  exit 1
fi
if [ "$WARN" -gt 0 ]; then
  printf '%sUsable, with caveats.%s Review WARN items — on 8 GB the swap/zram ones matter most.\n' "$Y" "$N"
  exit 0
fi
printf '%sReady.%s\n' "$G" "$N"
