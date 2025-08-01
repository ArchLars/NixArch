#!/usr/bin/env bash
# FusionSync: Keep pacman and Nix environments synchronized

set -euo pipefail

usage() {
  cat <<USAGE
Usage: $(basename "$0") COMMAND

Commands:
  upgrade          Run pacman upgrade and rebuild Nix environment
  rebuild          Regenerate wrappers and run home-manager switch
  daemon           Start the FusionSync watcher daemon
  pacman-hook      Record updated packages from pacman hook
USAGE
}

log_dir="/var/lib/fusionsync"
log_file="$log_dir/pacman.log"

ensure_state() {
  sudo mkdir -p "$log_dir"
  sudo touch "$log_file"
}

record_update() {
  ensure_state
  local pkg=$1
  echo "$(date -u +%FT%T) $pkg" | sudo tee -a "$log_file" >/dev/null
}

regenerate_wrappers() {
  echo "[FusionSync] Regenerating nixGL and nix-ld wrappers" >&2
  # nixGL wrapper regeneration
  if command -v nixGL >/dev/null; then
    nixGL --auto --print-shell-hooks > "$log_dir/nixgl.sh"
  fi
  # nix-ld wrapper regeneration
  if command -v nix-ld >/dev/null; then
    sudo nix-ld --print-root | sudo tee "$log_dir/nix-ld-root" >/dev/null
  fi
}

run_home_manager() {
  if command -v home-manager >/dev/null; then
    home-manager switch
  fi
}

self_test() {
  echo "[FusionSync] Running GUI test" >&2
  if command -v systemd-run >/dev/null; then
    systemd-run --quiet --user --scope bash -c "${HOME}/.nix-profile/bin/xdg-open https://example.com" && return 0
  fi
  return 1
}

rebuild() {
  regenerate_wrappers
  if self_test; then
    run_home_manager
  else
    echo "[FusionSync] Self-test failed; aborting rebuild" >&2
    return 1
  fi
}

upgrade() {
  sudo pacman -Syu --noconfirm
  rebuild
}

daemon() {
  ensure_state
  echo "[FusionSync] Watching $log_file for changes" >&2
  tail -Fn0 "$log_file" | while read -r line; do
    pkg=$(echo "$line" | awk '{print $2}')
    echo "[FusionSync] Detected update for $pkg" >&2
    rebuild
  done
}

case "${1:-}" in
  upgrade) upgrade ;;
  rebuild) rebuild ;;
  daemon) daemon ;;
  pacman-hook) shift; record_update "$@" ;;
  *) usage ;;
esac
