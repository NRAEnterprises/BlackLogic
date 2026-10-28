#!/bin/bash
set -Eeuo pipefail

echo "=== 1. Updating Package Lists ==="
pacman -Sy --noconfirm

echo "=== 2. Installing Core Environment Packages ==="
pacman -S --needed --noconfirm zsh git jq curl fastfetch iproute2 procps-ng figlet

echo "=== 3. Creating Directory Structure ==="
mkdir -p ~/bin
mkdir -p ~/.cache/zsh-extras
mkdir -p ~/.local/share/fastfetch/presets
mkdir -p ~/.oh-my-zsh/custom/plugins

sleep 2

echo "=== 4. Backing up existing .zshrc ==="
if [ -f ~/.zshrc ]; then
    cp ~/.zshrc ~/.zshrc.bak.$(date +%s)
    echo "backed up existing .zshrc"
fi

echo "=== 5. Installing oh-my-zsh & Plugins ==="
if [ ! -f "$HOME/.oh-my-zsh/oh-my-zsh.sh" ]; then
    rm -rf ~/.oh-my-zsh
    git clone --depth=1 https://github.com/ohmyzsh/ohmyzsh.git ~/.oh-my-zsh
fi

if [ ! -d ~/.oh-my-zsh/custom/plugins/zsh-autosuggestions ]; then
    git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions.git ~/.oh-my-zsh/custom/plugins/zsh-autosuggestions
fi

if [ ! -d ~/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting ]; then
    git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting.git ~/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting
fi

sleep 1

echo "=== 6. Writing ~/.zshrc ==="
cat <<'ZSH_EOF' > ~/.zshrc
# ─── Shell behavior ────────────────────────────────────────────
HISTFILE=~/.histfile
HISTSIZE=30000
SAVEHIST=100000
setopt autocd beep extendedglob nomatch notify share_history hist_ignore_all_dups

# ─── PATH: user-local binaries first ───────────────────────────
export PATH="$HOME/.local/bin:$HOME/bin:$PATH"

# ─── oh-my-zsh ─────────────────────────────────────────────────
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="agnoster"
plugins=(git zsh-autosuggestions zsh-syntax-highlighting)
source "$ZSH/oh-my-zsh.sh"

# ─── Prompt: agnoster + bold + [ssh] + hostname ────────────────
_zsh_prompt_host="$(hostname -s 2>/dev/null)"
[[ -z "$_zsh_prompt_host" ]] && _zsh_prompt_host="localhost"

prompt_context() {
  prompt_segment black default "%B${_zsh_prompt_host}%b"
}

RPROMPT='%B⚊ %D{%H:%M:%S}  %D{%Y-%m-%d}%b'

_zsh_prompt_precmd() {
  if [[ -n "$SSH_CONNECTION" ]]; then
    PROMPT='%{%f%b%k%}%B%F{green}[ssh]%f %B$(build_prompt)%b '
  else
    PROMPT='%{%f%b%k%}%B$(build_prompt)%b '
  fi
}
typeset -ga precmd_functions
precmd_functions+=(_zsh_prompt_precmd)

# ─── Custom MOTD ───────────────────────────────────────────────
if [ -x "$HOME/bin/termux-header.sh" ]; then
  "$HOME/bin/termux-header.sh"
fi

# ─── health command ────────────────────────────────────────────
health() { "$HOME/bin/termux-header.sh"; }

# ─── Disable bracketed paste markers ───────────────────────────
unset zle_bracketed_paste
ZSH_EOF

sleep 1

echo "=== 7. Writing ~/bin/termux-header.sh ==="
cat <<'MOTD_EOF' > ~/bin/termux-header.sh
#!/usr/bin/env bash
# termux-header.sh — MOTD: hardware banner + system/network/security snapshot

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/zsh-extras"
mkdir -p "$CACHE_DIR"

B=$'\033[1m'; R=$'\033[0m'; D=$'\033[2m'
G=$'\033[1;32m'; Y=$'\033[1;33m'; RD=$'\033[1;31m'; C=$'\033[1;36m'

hdr() { printf '%s─── %s ───%s\n' "$C" "$1" "$R"; }

mtime() {
  local f="$1" v
  [[ -r "$f" ]] || { echo 0; return; }
  v=$(stat -c %Y "$f" 2>/dev/null) || v=0
  [[ "$v" =~ ^[0-9]+$ ]] || v=0
  echo "$v"
}

refresh_cache() {
  local f="$1" ttl="$2"; shift 2
  local now last
  now=$(date +%s); last=$(mtime "$f")
  (( now - last < ttl )) && return
  "$@" > "$f.tmp" 2>/dev/null && mv -f "$f.tmp" "$f" 2>/dev/null
}

get_cache() {
  local f="$1" d="${2:-warming up…}"
  [[ -r "$f" ]] && cat "$f" || printf '%s' "$d"
}

# ---------- HEADER ----------
if command -v figlet >/dev/null 2>&1; then
  printf '%s' "$C"
  figlet -f standard "BLACK TERMINAL"
  printf '%s' "$R"
fi

# ---------- fastfetch ----------
if command -v fastfetch >/dev/null 2>&1; then
  fastfetch --config termux 2>/dev/null || fastfetch 2>/dev/null
fi

# ---------- SYSTEM ----------
hdr SYSTEM
root_state=$( [[ "$(id -u)" = "0" ]] && echo yes || echo no )
fw_state="inactive"
if command -v nft >/dev/null 2>&1; then
  fw_state=$(nft list ruleset 2>/dev/null | grep -q . && echo "rules present" || echo "empty")
fi
vpn_state="none"
ip link show 2>/dev/null | grep -qE 'tun|wg|tap' && vpn_state="tun/wg present"

printf '  root: %s   firewall: %s   vpn: %s\n' "$root_state" "$fw_state" "$vpn_state"

host=$(hostname 2>/dev/null || echo unknown)
distro=$(grep '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d= -f2- | tr -d '"')
uptime_raw=$(awk '{print int($1)}' /proc/uptime 2>/dev/null)
if [[ -n "$uptime_raw" ]]; then
  if (( uptime_raw < 3600 )); then up=$(printf "%dm" $((uptime_raw/60)))
  elif (( uptime_raw < 86400 )); then up=$(printf "%dh %dm" $((uptime_raw/3600)) $(((uptime_raw%3600)/60)))
  else up=$(printf "%dd %dh" $((uptime_raw/86400)) $(((uptime_raw%86400)/3600)))
  fi
else up="unknown"; fi
printf '  device: %s (%s)   uptime: %s\n' "$host" "${distro:-Linux}" "$up"

# ---------- DISK ----------
_disk_lines=$(df -h -x tmpfs -x devtmpfs -x squashfs -x overlay -x ramfs 2>/dev/null | awk 'NR>1 && $1 !~ /^(shm|udev|tmpfs|none)$/ {
  gsub(/%/,"",$5);
  mounts[$1] = mounts[$1] " " $6;
  if (!($1 in size)) { size[$1]=$2; used[$1]=$3; avail[$1]=$4; pct[$1]=$5 }
}
END {
  for (dev in mounts) {
    print dev "|" size[dev] "|" used[dev] "|" avail[dev] "|" pct[dev] "|" mounts[dev]
  }
}')

if [[ -n "$_disk_lines" ]]; then
  while IFS='|' read -r dev size used avail pct mnts; do
    [[ -z "$pct" ]] && continue
    if   (( pct >= 90 )); then color="$RD"
    elif (( pct >= 70 )); then color="$Y"
    else                       color="$G"
    fi
    printf '  %s%-28s%s %s used / %s (%s%%)  %s free\n    mounts:%s\n' \
      "$color" "$dev" "$R" "$used" "$size" "$pct" "$avail" "$mnts"
  done <<< "$_disk_lines"
fi

# ---------- NETWORK ----------
hdr NETWORK
_net_lines=$(ip -o -4 addr show 2>/dev/null | awk '{gsub(/\/.*/,"",$4); if ($4 != "127.0.0.1") print "  " $2 "  " $4}')
if [[ -n "$_net_lines" ]]; then printf '%s\n' "$_net_lines"; else printf '  %s(no interface data)%s\n' "$D" "$R"; fi

# ---------- TAILSCALE (cached 30s) ----------
hdr TAILSCALE
TS_CACHE="$CACHE_DIR/tailscale.txt"
refresh_cache "$TS_CACHE" 30 bash -c '
  if ! command -v tailscale >/dev/null 2>&1; then echo "state: not installed"; exit 0; fi
  if ! command -v jq >/dev/null 2>&1; then echo "state: jq missing"; exit 0; fi
  j=$(timeout 3 tailscale status --json 2>/dev/null) || { echo "state: not running"; exit 0; }
  state=$(printf "%s" "$j" | jq -r ".BackendState // \"unknown\"")
  host=$(printf "%s" "$j" | jq -r ".Self.HostName // \"?\"")
  ips=$(printf "%s" "$j" | jq -r "(.Self.TailscaleIPs // []) | join(\" / \")")
  peers=$(printf "%s" "$j" | jq -r "(.Peer // {}) | length")
  online=$(printf "%s" "$j" | jq -r "[.Peer[]? | select(.Online==true)] | length")
  echo "state: $state   hostname: $host"
  echo "IPs: $ips"
  echo "peers: $peers ($online online)"
'
while IFS= read -r line; do printf '  %s\n' "$line"; done < <(get_cache "$TS_CACHE")

# ---------- PACKAGES (cached 1h) ----------
hdr PACKAGES
PKG_CACHE="$CACHE_DIR/pkg.txt"
refresh_cache "$PKG_CACHE" 3600 bash -c '
  n=$(pacman -Qu 2>/dev/null | wc -l | tr -d " ")
  if (( n > 0 )); then echo "pacman: $n upgrades available"; else echo "up to date"; fi
'
printf '  %s\n' "$(get_cache "$PKG_CACHE")"

# ---------- PORTS ----------
hdr PORTS
listen=$(ss -tlnH 2>/dev/null | wc -l | tr -d " ")
ext=$(ss -tlnH 2>/dev/null | awk '$4 !~ /^(127\.|\[::1\])/ && $4 ~ /(0\.0\.0\.0|\*|\[::\])/ {print $4}' | sort -u)
if [[ -z "$ext" ]]; then
  printf '  listening: %s total   external: %snone%s\n' "$listen" "$G" "$R"
else
  printf '  listening: %s total   external:\n' "$listen"
  while IFS= read -r p; do [[ -n "$p" ]] && printf '    %s%s%s\n' "$Y" "$p" "$R"; done <<< "$ext"
fi

# ---------- CONNECTIONS ----------
hdr CONNECTIONS
conns=$(ss -tnH state established 2>/dev/null | awk '$4 !~ /127\.0\.0\.1/ && $5 !~ /127\.0\.0\.1/ {print $5}' | head -10)
if [[ -z "$conns" ]]; then
  printf '  external: %snone%s\n' "$G" "$R"
else
  n=$(echo "$conns" | wc -l | tr -d " ")
  printf '  external: %s%s active%s\n' "$Y" "$n" "$R"
  while IFS= read -r c; do printf '    %s\n' "$c"; done <<< "$conns"
fi

# ---------- DEV ----------
hdr DEV
tools=()
add() { command -v "$1" >/dev/null 2>&1 && tools+=("$2"); }
add node     "node $(node -v 2>/dev/null | sed 's/^v//')"
add pnpm     "pnpm $(pnpm -v 2>/dev/null)"
add python   "python $(python --version 2>&1 | awk '{print $2}')"
add go       "go $(go version 2>/dev/null | awk '{print $3}' | sed 's/^go//')"
add cargo    "rust $(cargo --version 2>/dev/null | awk '{print $2}')"
add git      "git $(git --version 2>/dev/null | awk '{print $3}')"
add jq       "jq $(jq --version 2>/dev/null | sed 's/^jq-//')"
add rg       "rg $(rg --version 2>/dev/null | head -n1 | awk '{print $2}')"
add fzf      "fzf $(fzf --version 2>/dev/null | awk '{print $1}')"
printf '  %s\n' "${tools[*]:-none}"
printf '\n'
MOTD_EOF

chmod +x ~/bin/termux-header.sh
bash -n ~/bin/termux-header.sh && echo "─── wrote ~/bin/termux-header.sh ───"

sleep 1

echo "=== 8. Writing Fastfetch Preset ==="
cat <<'FF_EOF' > ~/.local/share/fastfetch/presets/termux.jsonc
{
    "$schema": "https://github.com/fastfetch-cli/fastfetch/raw/dev/doc/json_schema.json",
    "logo": null,
    "display": {
        "separator": " ›  "
    },
    "modules": [
        "break",
        { "type": "os",       "key": "OS  ", "keyColor": "31" },
        { "type": "kernel",   "key": "KER ", "keyColor": "32" },
        { "type": "cpu",      "key": "CPU ", "keyColor": "37" },
        { "type": "gpu",      "key": "GPU ", "keyColor": "38" },
        { "type": "packages", "format": "{} (pacman)", "key": "PKG ", "keyColor": "33" },
        { "type": "shell",    "key": "SH  ", "keyColor": "34" },
        { "type": "terminal", "key": "TER ", "keyColor": "35" },
        { "type": "wm",       "key": "WM  ", "keyColor": "36" },
        { "type": "disk",     "key": "DSK ", "keyColor": "37" },
        { "type": "memory",   "key": "MEM ", "keyColor": "44" },
        { "type": "swap",     "key": "SWP ", "keyColor": "43" },
        { "type": "vulkan",   "key": "VK  ", "keyColor": "40" },
        { "type": "opengl",   "key": "ES  ", "keyColor": "41" },
        { "type": "opencl",   "key": "CL  ", "keyColor": "42" },
        "break"
    ]
}
FF_EOF
echo "─── wrote fastfetch preset ───"

echo "=== 9. Final Environment Configuration ==="
if [ "$(id -u)" -eq 0 ]; then
    usermod -s /usr/bin/zsh root
else
    usermod -s /usr/bin/zsh "$USER"
fi

if command -v npm >/dev/null 2>&1; then
    npm config set prefix ~/.local
fi

grep -q 'HOME/.local/bin' ~/.zshrc || echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc

echo "─── Setup Complete ───"
echo "Log out and back in for chsh to take effect, or run: exec zsh"
