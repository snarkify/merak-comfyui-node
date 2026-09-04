#!/bin/sh

set -eu

REPO=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d 2>/dev/null || mktemp -d -t merak-test)
trap 'rm -rf "$WORK"' EXIT INT TERM

SOURCE="$WORK/source/merak-comfyui-node-main"
ARCHIVE="$WORK/node.tar.gz"
mkdir -p "$SOURCE"
cp "$REPO/merak_nodes.py" "$REPO/__init__.py" "$SOURCE/"
tar -czf "$ARCHIVE" -C "$WORK/source" merak-comfyui-node-main

checks=0
failures=0

pass() {
  checks=$((checks + 1))
  printf 'ok - %s\n' "$1"
}

fail() {
  checks=$((checks + 1))
  failures=$((failures + 1))
  printf 'FAIL - %s\n' "$1"
}

comfy() {
  mkdir -p "$1/custom_nodes"
  : >"$1/main.py"
}

run_installer() {
  home=$1
  shift
  HOME="$home" MERAK_ARCHIVE="$ARCHIVE" sh "$REPO/install.sh" "$@" >"$WORK/output" 2>&1
}

HOME_DIR="$WORK/explicit-home"
ROOT="$WORK/explicit/ComfyUI"
mkdir -p "$HOME_DIR"
comfy "$ROOT"
if run_installer "$HOME_DIR" --path "$ROOT" --key test-key --yes &&
   [ -f "$ROOT/custom_nodes/merak-comfyui-node/merak_nodes.py" ] &&
   [ "$(cat "$HOME_DIR/.merak/api_key")" = test-key ]; then
  pass "explicit path installs the node and key"
else
  fail "explicit path installs the node and key"
fi

HOME_DIR="$WORK/default-home"
ROOT="$HOME_DIR/ComfyUI"
comfy "$ROOT"
if run_installer "$HOME_DIR" --yes &&
   [ -f "$ROOT/custom_nodes/merak-comfyui-node/merak_nodes.py" ] &&
   [ ! -e "$HOME_DIR/.merak/api_key" ]; then
  pass "common location installs without inventing a key"
else
  fail "common location installs without inventing a key"
fi

: >"$ROOT/custom_nodes/merak-comfyui-node/old-version"
if run_installer "$HOME_DIR" --yes &&
   [ -f "$ROOT/custom_nodes/merak-comfyui-node.previous/old-version" ]; then
  pass "an update keeps the previous version"
else
  fail "an update keeps the previous version"
fi

HOME_DIR="$WORK/multiple-home"
comfy "$HOME_DIR/ComfyUI"
comfy "$HOME_DIR/Documents/ComfyUI"
if run_installer "$HOME_DIR" --yes; then
  fail "multiple installs require an explicit choice"
elif grep -qF -- "--path" "$WORK/output" &&
     [ ! -d "$HOME_DIR/ComfyUI/custom_nodes/merak-comfyui-node" ] &&
     [ ! -d "$HOME_DIR/Documents/ComfyUI/custom_nodes/merak-comfyui-node" ]; then
  pass "multiple installs require an explicit choice"
else
  fail "multiple installs require an explicit choice"
fi

HOME_DIR="$WORK/invalid-home"
mkdir -p "$HOME_DIR"
if run_installer "$HOME_DIR" --path "$HOME_DIR/missing" --yes; then
  fail "invalid path is rejected"
else
  pass "invalid path is rejected"
fi

if HOME="$HOME_DIR" sh "$REPO/install.sh" --path >"$WORK/output" 2>&1; then
  fail "missing option value is rejected"
else
  pass "missing option value is rejected"
fi

if HOME="$HOME_DIR" sh "$REPO/install.sh" --bogus >"$WORK/output" 2>&1; then
  fail "unknown option is rejected"
else
  pass "unknown option is rejected"
fi

if [ "$failures" -gt 0 ]; then
  printf '%s of %s checks failed\n' "$failures" "$checks"
  exit 1
fi
printf '%s checks passed\n' "$checks"
