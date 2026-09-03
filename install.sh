#!/bin/sh
# Merak for ComfyUI - one-line installer for macOS and Linux.
#
#   curl -fsSL https://raw.githubusercontent.com/snarkify/merak-comfyui-node/main/install.sh | sh
#
# Options (pass them after `| sh -s --`):
#   --key <API_KEY>   use this key instead of asking for one
#   --path <DIR>      your ComfyUI folder (or its custom_nodes folder)
#   --lang en|zh      message language; the default follows your system
#   --yes             never ask anything; stop with an error instead

set -eu

REPO="snarkify/merak-comfyui-node"
BRANCH="main"
NODE_DIR_NAME="merak-comfyui-node"
KEY_DIR="$HOME/.merak"
KEY_FILE="$KEY_DIR/api_key"

API_KEY=""
COMFY_ARG=""
ASSUME_YES=0

case "${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}" in
  zh*|*zh_CN*|*zh_TW*|*zh_HK*) UI_LANG=zh ;;
  *) UI_LANG=en ;;
esac

while [ $# -gt 0 ]; do
  case "$1" in
    --key) API_KEY="${2:-}"; shift 2 || true ;;
    --key=*) API_KEY="${1#--key=}"; shift ;;
    --path) COMFY_ARG="${2:-}"; shift 2 || true ;;
    --path=*) COMFY_ARG="${1#--path=}"; shift ;;
    --lang) UI_LANG="${2:-en}"; shift 2 || true ;;
    --lang=*) UI_LANG="${1#--lang=}"; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    *) shift ;;
  esac
done

t() {
  if [ "$UI_LANG" = zh ]; then printf '%s\n' "$2"; else printf '%s\n' "$1"; fi
}
die() {
  t "$1" "$2" >&2
  exit 1
}

TTY=""
if [ "$ASSUME_YES" -eq 0 ] && [ -r /dev/tty ] && [ -w /dev/tty ]; then
  TTY=/dev/tty
fi

ask() { # ask <prompt_en> <prompt_zh>; answer on stdout, non-zero when there is no terminal
  if [ -z "$TTY" ]; then return 1; fi
  if [ "$UI_LANG" = zh ]; then printf '%s' "$2" >"$TTY"; else printf '%s' "$1" >"$TTY"; fi
  if IFS= read -r _reply <"$TTY"; then printf '%s' "$_reply"; else return 1; fi
}

WORK=$(mktemp -d 2>/dev/null || mktemp -d -t merak)
CANDIDATES="$WORK/candidates"
: >"$CANDIDATES"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

t "" ""
t "  Merak for ComfyUI - installer" "  Merak for ComfyUI 安装程序"
t "  ------------------------------" "  ------------------------------"

# ---------------------------------------------------------------- find ComfyUI

note() { # remember <dir> as a custom_nodes folder, if it exists
  _dir=${1%/}
  case "$_dir" in
    */custom_nodes) ;;
    *) _dir="$_dir/custom_nodes" ;;
  esac
  if [ ! -d "$_dir" ]; then return 0; fi
  if grep -qxF "$_dir" "$CANDIDATES" 2>/dev/null; then return 0; fi
  printf '%s\n' "$_dir" >>"$CANDIDATES"
}

if [ -n "$COMFY_ARG" ]; then
  note "$COMFY_ARG"
  if [ ! -s "$CANDIDATES" ]; then
    die "No custom_nodes folder under: $COMFY_ARG" "在该路径下找不到 custom_nodes 文件夹：$COMFY_ARG"
  fi
else
  if [ -n "${COMFYUI_PATH:-}" ]; then note "$COMFYUI_PATH"; fi
  # The places ComfyUI Desktop, the portable build and a git clone normally land.
  note "$HOME/Documents/ComfyUI"
  note "$HOME/ComfyUI"
  note "$HOME/Desktop/ComfyUI"
  note "$HOME/Downloads/ComfyUI"
  note "$HOME/comfy/ComfyUI"
  note "$HOME/Library/Application Support/ComfyUI"
  note "/opt/ComfyUI"
  note "/workspace/ComfyUI"

  if [ ! -s "$CANDIDATES" ]; then
    t "Looking for ComfyUI on this computer..." "正在查找本机上的 ComfyUI……"
    for root in "$HOME" "$HOME/Documents" "$HOME/Desktop" "$HOME/Downloads" \
                "$HOME/Applications" /Applications /opt /srv /workspace; do
      if [ ! -d "$root" ]; then continue; fi
      find "$root" -maxdepth 3 -type d -name custom_nodes 2>/dev/null |
        while IFS= read -r found; do note "$found"; done
    done
  fi
fi

COUNT=$(wc -l <"$CANDIDATES" | tr -d ' ')

if [ "$COUNT" -eq 0 ]; then
  t "ComfyUI was not found on this computer." "在本机上没有找到 ComfyUI。"
  answer=$(ask "Type the full path to your ComfyUI folder (or press Enter to stop): " \
               "请输入 ComfyUI 文件夹的完整路径（直接回车则退出）：") || answer=""
  if [ -n "$answer" ]; then note "$answer"; fi
  COUNT=$(wc -l <"$CANDIDATES" | tr -d ' ')
fi

if [ "$COUNT" -eq 0 ]; then
  t "Install ComfyUI first - see https://github.com/$REPO#install-comfyui - then run this again." \
    "请先安装 ComfyUI（见 https://github.com/$REPO/blob/main/README.zh-CN.md#安装-comfyui），然后重新运行本脚本。"
  exit 1
fi

if [ "$COUNT" -eq 1 ]; then
  TARGET=$(cat "$CANDIDATES")
else
  t "Several ComfyUI installs were found:" "找到多个 ComfyUI 安装位置："
  i=0
  while IFS= read -r line; do
    i=$((i + 1))
    printf '  %s) %s\n' "$i" "$line"
  done <"$CANDIDATES"
  choice=$(ask "Which one? [1] " "选择哪一个？[1] ") || choice=1
  case "${choice:-1}" in
    ''|*[!0-9]*) choice=1 ;;
  esac
  if [ "$choice" -lt 1 ] || [ "$choice" -gt "$COUNT" ]; then choice=1; fi
  TARGET=$(sed -n "${choice}p" "$CANDIDATES")
fi

t "ComfyUI: ${TARGET%/custom_nodes}" "ComfyUI 位置：${TARGET%/custom_nodes}"

if [ ! -w "$TARGET" ]; then
  die "No permission to write to $TARGET - run this again with sudo, or fix the folder's permissions." \
      "没有写入权限：$TARGET —— 请用 sudo 重新运行，或修改该文件夹的权限。"
fi

# ------------------------------------------------------------------ the files

DEST="$TARGET/$NODE_DIR_NAME"

t "Downloading the node..." "正在下载节点……"
if ! command -v curl >/dev/null 2>&1; then
  die "curl is not installed." "未安装 curl。"
fi
curl -fsSL "https://codeload.github.com/$REPO/tar.gz/refs/heads/$BRANCH" | tar -xzf - -C "$WORK" ||
  die "Download failed - check your internet connection and try again." \
      "下载失败 —— 请检查网络连接后重试。"

SRC="$WORK/$NODE_DIR_NAME-$BRANCH"
if [ ! -d "$SRC" ]; then
  SRC=$(find "$WORK" -maxdepth 1 -type d -name "*-$BRANCH" | head -n 1)
fi
if [ ! -f "$SRC/merak_nodes.py" ]; then
  die "The download looks incomplete." "下载的文件不完整。"
fi

if [ -d "$DEST" ]; then
  rm -rf "$DEST.previous"
  mv "$DEST" "$DEST.previous"
  t "Replacing the previous version (kept as $NODE_DIR_NAME.previous)." \
    "已替换旧版本（旧版本保留为 $NODE_DIR_NAME.previous）。"
fi
mv "$SRC" "$DEST"
t "Installed to $DEST" "已安装到 $DEST"

# -------------------------------------------------------------------- the key

if [ -z "$API_KEY" ] && [ -s "$KEY_FILE" ]; then
  t "An API key is already saved in $KEY_FILE - keeping it." \
    "$KEY_FILE 中已保存 API key —— 保持不变。"
else
  if [ -z "$API_KEY" ]; then
    API_KEY=$(ask "Paste your merak API key (from https://merakcompute.ai): " \
                  "请粘贴你的 merak API key（在 https://merakcompute.ai 获取）：") || API_KEY=""
  fi
  API_KEY=$(printf '%s' "$API_KEY" | tr -d '[:space:]')
  if [ -n "$API_KEY" ]; then
    mkdir -p "$KEY_DIR"
    umask 077
    printf '%s\n' "$API_KEY" >"$KEY_FILE"
    chmod 600 "$KEY_FILE" 2>/dev/null || true
    t "Key saved to $KEY_FILE" "Key 已保存到 $KEY_FILE"
  else
    t "No key saved. Save one later with:" "未保存 key。之后可以这样保存："
    printf '  mkdir -p %s && printf %%s\\\\n "YOUR_KEY" > %s\n' "$KEY_DIR" "$KEY_FILE"
  fi
fi

# ------------------------------------------------------------------- finished

t "" ""
t "Done. Restart ComfyUI, double-click the canvas and search for \"Merak\"." \
  "完成。请重启 ComfyUI，然后双击画布并搜索 “Merak”。"
t "You should see: Merak Generate Video, Merak Fetch Video (by id)." \
  "你应该能看到：Merak Generate Video、Merak Fetch Video (by id)。"
t "" ""
