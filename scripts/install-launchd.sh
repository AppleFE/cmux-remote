#!/usr/bin/env bash
# Install cmux-relay as a root launchd daemon bound to port 80.
#
# Port 80 is privileged (<1024), so the relay must run as a system-domain
# daemon (root), not a per-user agent. This script builds the release binary,
# installs it under a root-owned prefix (/usr/local/lib/cmux-remote) so a
# non-root account cannot swap the binary the daemon execs, renders
# /Library/LaunchDaemons/com.genie.cmuxremote.plist with HOME pinned to the
# owner's home (so root still resolves the cmux socket + relay.json under the
# owner's account), then bootstraps and kickstarts the daemon.
#
# Run with sudo: `sudo ./scripts/install-launchd.sh`. The owner is taken from
# SUDO_USER (override with CMUX_REMOTE_USER). Use --dry-run to validate/render
# without building, copying, writing, or invoking launchctl.

set -euo pipefail

LABEL="com.genie.cmuxremote"
DRY_RUN=0

usage() {
  cat <<USAGE
Usage: sudo scripts/install-launchd.sh [--dry-run]

Installs cmux-relay as a root launchd daemon bound to port 80.

Options:
  --dry-run   Print resolved paths and rendered plist without building,
              copying, writing the daemon, or invoking launchctl.

Environment:
  CMUX_REMOTE_USER     Owner whose ~/.cmuxremote + cmux identity to adopt
                       (default: SUDO_USER).
  CMUX_SOCKET_PATH     Pin the cmux socket instead of auto-discovering it.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="$ROOT/scripts/relay.plist.tmpl"
BIN_SRC="$ROOT/.build/release/cmux-relay"
SOCKET="${CMUX_SOCKET_PATH:-}"
DEV_ALLOW_LOCALHOST="${CMUX_DEV_ALLOW_LOCALHOST:-0}"
# launchd starts daemons with a stripped PATH; tailscale CLI on macOS lives in
# /usr/local/bin (pkg install) or /opt/homebrew/bin (brew), so prepend both
# before the system defaults so AuthService's whois fallback can find it.
RELAY_PATH="${CMUX_RELAY_PATH:-/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin}"
LAUNCH_DAEMONS_DIR="/Library/LaunchDaemons"
PLIST="$LAUNCH_DAEMONS_DIR/$LABEL.plist"
TARGET="system"
SERVICE="$TARGET/$LABEL"

note() { printf '[install-launchd] %s\n' "$*"; }
fail() { printf '[install-launchd] ERROR: %s\n' "$*" >&2; exit 1; }

sed_escape() {
  # Escape replacement text for sed's s||| delimiter.
  printf '%s' "$1" | sed 's/[\\&|]/\\&/g'
}

xml_escape() {
  # Escape token values before placing them inside plist XML text nodes.
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

render_token() {
  sed_escape "$(xml_escape "$1")"
}

# Resolve the owner whose cmux identity / config / socket the daemon should
# adopt. Under sudo this is SUDO_USER; allow an explicit override. The relay
# runs as root but the plist pins HOME to the owner's home, so cmux socket
# discovery and ~/.cmuxremote resolve under the owner's account.
OWNER_USER="${CMUX_REMOTE_USER:-${SUDO_USER:-}}"
if [ -z "$OWNER_USER" ]; then
  if [ "$DRY_RUN" -eq 1 ]; then
    OWNER_USER="${USER:-unknown}"
    note "dry-run without sudo; previewing owner as '$OWNER_USER'"
  else
    fail "could not determine owner user; run under sudo or set CMUX_REMOTE_USER"
  fi
fi

real_home() {
  dscl . -read "/Users/$1" NFSHomeDirectory 2>/dev/null | awk '{print $2}'
}
OWNER_HOME="$(real_home "$OWNER_USER")"
[ -n "$OWNER_HOME" ] || fail "could not resolve home for user '$OWNER_USER' (dscl lookup failed)"

DEST="${CMUX_REMOTE_HOME:-$OWNER_HOME/.cmuxremote}"
# The daemon execs this binary as root, so it must live under a root-owned
# prefix OUTSIDE the owner's home — otherwise a process running as the owner
# could swap the executable and gain root (privilege escalation).
PREFIX="${CMUX_PREFIX:-/usr/local/lib/cmux-remote}"
BIN_DEST="$PREFIX/bin/cmux-relay"
CONFIG="${CMUX_RELAY_CONFIG:-$DEST/relay.json}"
LOGDIR="${CMUX_RELAY_LOGDIR:-$DEST/log}"
# Leave SOCKET empty by default so cmux-relay discovers the live cmux socket at
# runtime: it follows cmux's last-socket-path markers (the fixed
# /tmp/cmux-last-socket-path, then ~/.local/state/cmux, then the legacy
# ~/Library/Application Support/cmux) and falls back to ~/.local/state/cmux/cmux.sock.
# With HOME pinned to the owner's home in the daemon plist, the user-relative
# markers resolve correctly even though the process runs as root.

render_plist() {
  sed \
    -e "s|__BIN__|$(render_token "$BIN_DEST")|g" \
    -e "s|__CONFIG__|$(render_token "$CONFIG")|g" \
    -e "s|__HOME__|$(render_token "$OWNER_HOME")|g" \
    -e "s|__SOCKET__|$(render_token "$SOCKET")|g" \
    -e "s|__LOGDIR__|$(render_token "$LOGDIR")|g" \
    -e "s|__DEV_ALLOW_LOCALHOST__|$(render_token "$DEV_ALLOW_LOCALHOST")|g" \
    -e "s|__RELAY_PATH__|$(render_token "$RELAY_PATH")|g" \
    "$TEMPLATE"
}

validate_rendered_plist() {
  local tmp rc
  tmp="$(mktemp)"
  render_plist > "$tmp"
  if command -v plutil >/dev/null 2>&1; then
    if plutil -lint "$tmp" >/dev/null; then
      rc=0
    else
      rc=$?
    fi
  else
    rc=0
  fi
  rm -f "$tmp"
  return "$rc"
}

[ -f "$TEMPLATE" ] || fail "missing plist template: $TEMPLATE"

if [ "$DRY_RUN" -eq 1 ]; then
  note "dry-run; no build, copy, writes, or launchctl calls"
  note "label: $LABEL (system daemon)"
  note "owner: $OWNER_USER (home: $OWNER_HOME)"
  note "binary: $BIN_DEST"
  if [ -f "$CONFIG" ]; then
    note "config: $CONFIG (exists)"
  else
    note "config: $CONFIG (would write default relay.json)"
  fi
  if [ -n "$SOCKET" ]; then
    note "socket override: $SOCKET"
  else
    note "socket override: <dynamic via cmux last-socket-path>"
  fi
  note "logdir: $LOGDIR"
  note "plist: $PLIST"
  note "domain: $TARGET (daemon runs as root to bind port 80)"
  note "would run: swift build -c release"
  note "would copy: $BIN_SRC -> $BIN_DEST"
  note "would run: launchctl bootstrap $TARGET $PLIST"
  note "would run: launchctl kickstart -k $SERVICE"
  printf '%s\n' '--- rendered plist ---'
  render_plist
  validate_rendered_plist
  exit 0
fi

command -v swift >/dev/null 2>&1 || fail "missing required tool: swift"
command -v launchctl >/dev/null 2>&1 || fail "missing required tool: launchctl"
[ "$(id -u)" -eq 0 ] || fail "port 80 is privileged; rerun under sudo: sudo $0 $*"

# First-run convenience: if there is no config yet, write a sane default so a
# brand-new user does not have to hand-author relay.json before the first
# install. Existing configs are never touched.
if [ ! -f "$CONFIG" ]; then
  note "no config at $CONFIG; writing default relay.json"
  mkdir -p "$(dirname "$CONFIG")"
  cat > "$CONFIG" <<'JSON'
{
  "listen":      "0.0.0.0:80",
  "default_fps": 15,
  "idle_fps":    5
}
JSON
  note "this Mac's own tailnet login is auto-authorised, so a phone on the"
  note "  same Tailscale account pairs out of the box. For other accounts, add"
  note "  the login to \"allow_login\" in $CONFIG (CMUX_NO_SELF_LOGIN=1 to opt out)."
fi

note "building release binary"
(cd "$ROOT" && swift build -c release)
[ -x "$BIN_SRC" ] || fail "release binary not found after build: $BIN_SRC"

note "installing binary under $PREFIX (root-owned); config/logs under $DEST"
mkdir -p "$PREFIX/bin" "$DEST" "$LOGDIR" "$LAUNCH_DAEMONS_DIR"
cp "$BIN_SRC" "$BIN_DEST"
chmod 755 "$BIN_DEST"

# Copy the SwiftPM resource bundle (WebResources) next to the binary so
# Bundle.module can locate web assets (index.html, app.js, style.css) at
# runtime. Without this, / and /app.js silently 404 after install.
BUNDLE_SRC=$(find "$ROOT/.build" -type d -name "CmuxRemote_RelayServer.bundle" -path "*release*" 2>/dev/null | head -1)
if [ -n "$BUNDLE_SRC" ]; then
    rm -rf "$PREFIX/bin/CmuxRemote_RelayServer.bundle"
    cp -R "$BUNDLE_SRC" "$PREFIX/bin/"
else
    fail "WebResources bundle not found — run 'swift build -c release' first"
fi

# Ownership: the daemon execs the binary as root, so the whole PREFIX tree
# must be root-owned — a non-root account must not be able to swap the
# executable or tamper with served web assets (privilege-escalation vector).
# relay.json / devices / logs stay owner-owned so the operator can hand-edit
# config. The pinned HOME in the daemon plist keeps ~/.cmuxremote resolving to
# the owner's home even though the binary lives under /usr/local.
chown -R root:admin "$PREFIX"
chmod 755 "$PREFIX" "$PREFIX/bin"
chown -R "$OWNER_USER" "$DEST" 2>/dev/null || true

note "rendering $PLIST"
render_plist > "$PLIST"
validate_rendered_plist

# Migration from the pre-80 per-user agent: if a legacy gui-domain agent is
# still registered, boot it out and drop its plist. Otherwise KeepAlive would
# restart it forever, crash-looping against the singleton flock (and holding
# the old port). Best-effort — silently skipped if none was ever installed.
LEGACY_UID="$(id -u "$OWNER_USER" 2>/dev/null || true)"
LEGACY_PLIST="$OWNER_HOME/Library/LaunchAgents/$LABEL.plist"
if [ -n "$LEGACY_UID" ]; then
  if launchctl bootout "gui/$LEGACY_UID/$LABEL" >/dev/null 2>&1 \
     || launchctl bootout "gui/$LEGACY_UID" "$LEGACY_PLIST" >/dev/null 2>&1; then
    note "removed legacy per-user agent (gui/$LEGACY_UID)"
    sleep 1
  fi
fi
[ -f "$LEGACY_PLIST" ] && rm -f "$LEGACY_PLIST"

note "bootstrapping $LABEL (system domain)"
# bootout any prior instance; if one was actually running, give it a moment
# to release the listening port + the singleton flock before we
# re-bootstrap. The relay also enforces single-instance via flock on
# ~/.cmuxremote/relay.lock, so even if a race slips through here the loser
# exits cleanly instead of two daemons fighting over the same port.
if launchctl bootout "$TARGET" "$PLIST" >/dev/null 2>&1; then
    sleep 1
fi
launchctl bootstrap "$TARGET" "$PLIST"
launchctl kickstart -k "$SERVICE"

note "installed; logs at $LOGDIR"
note "inspect with: launchctl print $SERVICE"
