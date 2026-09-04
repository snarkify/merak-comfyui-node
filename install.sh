#!/bin/sh
# Merak for ComfyUI installer for macOS and Linux.
#
#   curl -fsSL https://raw.githubusercontent.com/snarkify/merak-comfyui-node/main/install.sh | sh

set -eu

REPO="snarkify/merak-comfyui-node"
BRANCH="main"
NODE_NAME="merak-comfyui-node"
KEY_DIR="$HOME/.merak"
KEY_FILE="$KEY_DIR/api_key"

API_KEY=""
COMFY_PATH=""
ASSUME_YES=0

say() { printf '%s\n' "$1"; }
fail() { say "$1" >&2; exit 1; }

usage() {
  cat <<'EOF'
Merak for ComfyUI installer

  --path <DIR>  ComfyUI folder (or its custom_nodes folder)
  --key <KEY>   merak API key
  --yes         do not prompt
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --path)
      [ "$#" -ge 2 ] || fail "--path needs a value."
      [ -n "$2" ] || fail "--path needs a value."
      COMFY_PATH=$2
      shift 2
      ;;
    --path=*)
      COMFY_PATH=${1#--path=}
      [ -n "$COMFY_PATH" ] || fail "--path needs a value."
      shift
      ;;
    --key)
      [ "$#" -ge 2 ] || fail "--key needs a value."
      API_KEY=$2
      shift 2
      ;;
    --key=*) API_KEY=${1#--key=}; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Unknown option: $1" ;;
  esac
done

ask() {
  [ "$ASSUME_YES" -eq 0 ] || return 1
  [ -r /dev/tty ] && [ -w /dev/tty ] || return 1
  printf '%s' "$1" >/dev/tty
  IFS= read -r answer </dev/tty || return 1
  printf '%s' "$answer"
}

WORK=$(mktemp -d 2>/dev/null || mktemp -d -t merak)
CANDIDATES="$WORK/candidates"
: >"$CANDIDATES"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

add_candidate() {
  path=${1%/}
  [ -n "$path" ] || return 0
  case "$path" in
    */custom_nodes) root=${path%/custom_nodes} ;;
    *) root=$path ;;
  esac
  [ -d "$root/custom_nodes" ] || return 0
  if [ ! -f "$root/main.py" ] && [ ! -f "$root/comfyui_version.py" ] && [ ! -d "$root/comfy" ]; then
    return 0
  fi
  root=$(cd "$root" 2>/dev/null && pwd -P) || return 0
  grep -qxF "$root" "$CANDIDATES" 2>/dev/null || printf '%s\n' "$root" >>"$CANDIDATES"
}

if [ -n "$COMFY_PATH" ]; then
  add_candidate "$COMFY_PATH"
  [ -s "$CANDIDATES" ] || fail "That does not look like a ComfyUI folder: $COMFY_PATH"
elif [ -n "${COMFYUI_PATH:-}" ]; then
  add_candidate "$COMFYUI_PATH"
  [ -s "$CANDIDATES" ] || fail "COMFYUI_PATH is not a ComfyUI folder: $COMFYUI_PATH"
else
  for path in \
    "$HOME/ComfyUI" \
    "$HOME/Documents/ComfyUI" \
    "$HOME/Desktop/ComfyUI" \
    "$HOME/Downloads/ComfyUI" \
    "$HOME/comfy/ComfyUI" \
    "/opt/ComfyUI" \
    "/workspace/ComfyUI"
  do
    add_candidate "$path"
  done
  for path in "$HOME"/ComfyUI-Installs/*/ComfyUI; do
    [ -d "$path" ] && add_candidate "$path"
  done
fi

COUNT=$(wc -l <"$CANDIDATES" | tr -d ' ')
if [ "$COUNT" -eq 0 ]; then
  COMFY_PATH=$(ask "Full path to your ComfyUI folder: ") ||
    fail "ComfyUI was not found. Run again with --path /path/to/ComfyUI."
  add_candidate "$COMFY_PATH"
  [ -s "$CANDIDATES" ] || fail "That does not look like a ComfyUI folder: $COMFY_PATH"
  TARGET=$(sed -n '1p' "$CANDIDATES")
elif [ "$COUNT" -gt 1 ]; then
  say "Several ComfyUI folders were found:"
  number=0
  while IFS= read -r path; do
    number=$((number + 1))
    printf '  %s) %s\n' "$number" "$path"
  done <"$CANDIDATES"
  choice=$(ask "Which one? [1] ") ||
    fail "Run again with --path to choose a ComfyUI folder."
  choice=${choice:-1}
  case "$choice" in *[!0-9]*) fail "Not a number: $choice" ;; esac
  [ "$choice" -ge 1 ] && [ "$choice" -le "$COUNT" ] || fail "Invalid choice: $choice"
  TARGET=$(sed -n "${choice}p" "$CANDIDATES")
else
  TARGET=$(sed -n '1p' "$CANDIDATES")
fi

CUSTOM_NODES="$TARGET/custom_nodes"
[ -w "$CUSTOM_NODES" ] || fail "Cannot write to $CUSTOM_NODES."

say "Installing Merak into $TARGET"
if [ -n "${MERAK_ARCHIVE:-}" ]; then
  tar -xzf "$MERAK_ARCHIVE" -C "$WORK" || fail "Could not unpack $MERAK_ARCHIVE."
else
  command -v curl >/dev/null 2>&1 || fail "curl is not installed."
  curl -fsSL "https://codeload.github.com/$REPO/tar.gz/refs/heads/$BRANCH" |
    tar -xzf - -C "$WORK" || fail "Download failed."
fi

SOURCE="$WORK/$NODE_NAME-$BRANCH"
[ -f "$SOURCE/merak_nodes.py" ] || fail "The downloaded archive is incomplete."

DEST="$CUSTOM_NODES/$NODE_NAME"
BACKUP="$CUSTOM_NODES/$NODE_NAME.previous"
if [ -e "$DEST" ]; then
  rm -rf "$BACKUP"
  mv "$DEST" "$BACKUP"
fi
if ! mv "$SOURCE" "$DEST"; then
  [ ! -e "$BACKUP" ] || mv "$BACKUP" "$DEST"
  fail "Install failed."
fi
say "Installed to $DEST"

EXISTING_KEY=""
if [ -r "$KEY_FILE" ]; then
  EXISTING_KEY=$(tr -d '[:space:]' <"$KEY_FILE" 2>/dev/null) || EXISTING_KEY=""
fi
if [ -z "$API_KEY" ] && [ -z "$EXISTING_KEY" ]; then
  API_KEY=$(ask "Paste your merak API key: ") || API_KEY=""
fi
API_KEY=$(printf '%s' "$API_KEY" | tr -d '[:space:]')
if [ -n "$API_KEY" ]; then
  umask 077
  mkdir -p "$KEY_DIR"
  printf '%s\n' "$API_KEY" >"$KEY_FILE"
  chmod 600 "$KEY_FILE" 2>/dev/null || true
  say "Key saved to $KEY_FILE"
elif [ -n "$EXISTING_KEY" ]; then
  say "Keeping the existing key in $KEY_FILE"
else
  say "No key saved. Put it in $KEY_FILE before using the node."
fi

say "Done. Restart ComfyUI and search for Merak."
