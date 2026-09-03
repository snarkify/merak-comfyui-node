#!/bin/sh
# Merak for ComfyUI - installer for macOS and Linux.
#
#   curl -fsSL https://raw.githubusercontent.com/snarkify/merak-comfyui-node/main/install.sh | sh
#
# Windows has the same installer as install.ps1 - the two are kept in step.
#
# Options (pass them after `| sh -s --`):
#   --key <API_KEY>   use this key instead of asking for one
#   --path <DIR>      your ComfyUI folder (or its custom_nodes folder)
#   --lang en|zh      message language; the default follows your system
#   --yes             never ask anything; stop with an error instead
#   --no-scan         skip the disk search, use only recorded and default paths
#   --detect-only     print every ComfyUI folder found, then stop

set -eu

REPO="snarkify/merak-comfyui-node"
BRANCH="main"
NODE_DIR_NAME="merak-comfyui-node"
KEY_DIR="$HOME/.merak"
KEY_FILE="$KEY_DIR/api_key"

API_KEY=""
COMFY_ARG=""
ASSUME_YES=0
NO_SCAN=0
DETECT_ONLY=0

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
    --no-scan) NO_SCAN=1; shift ;;
    --detect-only) DETECT_ONLY=1; shift ;;
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

OS=$(uname -s 2>/dev/null || echo unknown)

WORK=$(mktemp -d 2>/dev/null || mktemp -d -t merak)
SURE="$WORK/sure"      # folders confirmed to be a ComfyUI install
MAYBE="$WORK/maybe"    # folders that hold custom_nodes but look less certain
SEEN="$WORK/seen"      # device:inode of every folder already recorded
: >"$SURE"
: >"$MAYBE"
: >"$SEEN"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

t "" ""
t "  Merak for ComfyUI - installer" "  Merak for ComfyUI 安装程序"
t "  ------------------------------" "  ------------------------------"

# --------------------------------------------------------------- finding it
#
# ComfyUI does not live in one place across systems, but every install has the
# same shape inside: <base>/custom_nodes, next to main.py or comfyui_version.py.
# So the search is for that shape, cheapest source first - the desktop app and
# comfy-cli both write down where they put it, which beats searching a disk.

is_comfy_root() { # a folder that really is a ComfyUI install
  [ -f "$1/main.py" ] || [ -f "$1/comfyui_version.py" ] || [ -d "$1/comfy" ]
}

note() { # note <dir>: <dir> is a ComfyUI folder, or a custom_nodes folder itself
  _dir=${1%/}
  [ -n "$_dir" ] || return 0
  case "$_dir" in
    */custom_nodes) ;;
    *) _dir="$_dir/custom_nodes" ;;
  esac
  [ -d "$_dir" ] || return 0
  _root=${_dir%/custom_nodes}
  # Never offer our own folder, or a backup of it, as a place to install into.
  # Whole path segments only: a parent folder that merely contains the name in
  # the middle of its own is somebody else's business.
  case "/$_dir/" in
    */"$NODE_DIR_NAME"/*|*.previous/*) return 0 ;;
  esac
  _real=$(cd "$_dir" 2>/dev/null && pwd -P) || return 0
  # Identify a folder by device and inode, not by its name: a case-insensitive
  # disk answers to both ComfyUI and comfyui, and they are one folder.
  _key=$(stat -f '%d:%i' "$_real" 2>/dev/null || stat -c '%d:%i' "$_real" 2>/dev/null || printf '%s' "$_real")
  if grep -qxF "$_key" "$SEEN" 2>/dev/null; then return 0; fi
  printf '%s\n' "$_key" >>"$SEEN"
  if is_comfy_root "$_root"; then
    printf '%s\n' "$_real" >>"$SURE"
  else
    printf '%s\n' "$_real" >>"$MAYBE"
  fi
}

note_base() { # note <dir> and <dir>/ComfyUI - desktop records the parent of both
  note "$1"
  note "$1/ComfyUI"
}

found_any() { [ -s "$SURE" ] || [ -s "$MAYBE" ]; }

# 1. What the caller told us, or the environment.
if [ -n "$COMFY_ARG" ]; then
  note_base "$COMFY_ARG"
  if ! found_any; then
    die "No custom_nodes folder under: $COMFY_ARG" "在该路径下找不到 custom_nodes 文件夹：$COMFY_ARG"
  fi
else
  if [ -n "${COMFYUI_PATH:-}" ]; then note_base "$COMFYUI_PATH"; fi

  # 2. Paths the ComfyUI apps write down for themselves.
  if [ "$OS" = Darwin ]; then
    CONF_DIRS="$HOME/Library/Application Support/Comfy Desktop
$HOME/Library/Application Support/ComfyUI"
  else
    CONF_DIRS="${XDG_CONFIG_HOME:-$HOME/.config}/comfyui-desktop-2
${XDG_CONFIG_HOME:-$HOME/.config}/ComfyUI"
  fi

  printf '%s\n' "$CONF_DIRS" | while IFS= read -r conf; do
    [ -d "$conf" ] || continue
    # Desktop 2: every install it made, by path, plus the folder it keeps them in.
    if [ -f "$conf/installations.json" ]; then
      grep -o '"installPath"[[:space:]]*:[[:space:]]*"[^"]*"' "$conf/installations.json" 2>/dev/null |
        sed 's/.*"\(.*\)"$/\1/'
    fi
    if [ -f "$conf/settings.json" ]; then
      grep -o '"installDir"[[:space:]]*:[[:space:]]*"[^"]*"' "$conf/settings.json" 2>/dev/null |
        sed 's/.*"\(.*\)"$/\1/' |
        while IFS= read -r parent; do
          [ -d "$parent" ] && find "$parent" -maxdepth 1 -mindepth 1 -type d 2>/dev/null
        done
    fi
    # Desktop 1: one base path, in JSON and again in YAML.
    if [ -f "$conf/config.json" ]; then
      grep -o '"basePath"[[:space:]]*:[[:space:]]*"[^"]*"' "$conf/config.json" 2>/dev/null |
        sed 's/.*"\(.*\)"$/\1/'
    fi
    if [ -f "$conf/extra_models_config.yaml" ]; then
      sed -n 's/^[[:space:]]*base_path:[[:space:]]*//p' "$conf/extra_models_config.yaml" 2>/dev/null
    fi
  done >"$WORK/recorded" || true

  # 3. comfy-cli remembers the workspace it installed into.
  CLI_INI="${XDG_CONFIG_HOME:-$HOME/.config}/comfy-cli/config.ini"
  if [ -f "$CLI_INI" ]; then
    sed -n 's/^[[:space:]]*\(default_workspace\|recent_workspace\)[[:space:]]*=[[:space:]]*//p' \
      "$CLI_INI" 2>/dev/null >>"$WORK/recorded" || true
  fi

  # 4. A ComfyUI that is running right now says where it is.
  ps -eo args= 2>/dev/null |
    sed -n 's|.*[ "]\(/[^ ]*\)/main\.py.*|\1|p' >>"$WORK/recorded" || true

  if [ -f "$WORK/recorded" ]; then
    while IFS= read -r recorded; do
      [ -n "$recorded" ] && note_base "$recorded"
    done <"$WORK/recorded"
  fi

  # 5. Where the desktop app, the portable build and a plain clone land by default.
  for base in \
    "$HOME/ComfyUI-Installs" \
    "$HOME/Documents/ComfyUI" \
    "$HOME/ComfyUI" \
    "$HOME/Desktop/ComfyUI" \
    "$HOME/Downloads/ComfyUI" \
    "$HOME/comfy/ComfyUI" \
    "$HOME/comfyui" \
    "$HOME/src/ComfyUI" \
    "$HOME/git/ComfyUI" \
    "/opt/ComfyUI" \
    "/srv/ComfyUI" \
    "/workspace/ComfyUI" \
    "/ComfyUI"
  do
    note_base "$base"
    # ComfyUI-Installs holds one folder per install, each with ComfyUI inside.
    if [ -d "$base" ]; then
      find "$base" -maxdepth 1 -mindepth 1 -type d 2>/dev/null |
        while IFS= read -r child; do note_base "$child"; done
    fi
  done

  # 6. The file index, if this system keeps one. Spotlight answers in a moment;
  #    so does plocate. Neither walks the disk.
  if ! found_any && [ "$NO_SCAN" -eq 0 ]; then
    if [ "$OS" = Darwin ] && command -v mdfind >/dev/null 2>&1; then
      mdfind -name custom_nodes 2>/dev/null | grep '/custom_nodes$' |
        while IFS= read -r hit; do note "$hit"; done
    elif command -v plocate >/dev/null 2>&1; then
      plocate -l 200 '/custom_nodes' 2>/dev/null | grep '/custom_nodes$' |
        while IFS= read -r hit; do note "$hit"; done
    elif command -v locate >/dev/null 2>&1; then
      locate -l 200 '/custom_nodes' 2>/dev/null | grep '/custom_nodes$' |
        while IFS= read -r hit; do note "$hit"; done
    fi
  fi

  # 7. Last resort: walk the likely roots. Depth-limited and pruned, so it is
  #    seconds rather than minutes - a full-disk walk is not worth it.
  if ! found_any && [ "$NO_SCAN" -eq 0 ]; then
    t "Searching your folders for ComfyUI (a few seconds)..." "正在搜索 ComfyUI（需要几秒钟）……"
    for root in "$HOME" "$HOME/Documents" "$HOME/Desktop" "$HOME/Downloads" \
                /opt /srv /workspace /mnt /media /Volumes; do
      [ -d "$root" ] || continue
      find "$root" -maxdepth 5 \
        \( -name node_modules -o -name .git -o -name .venv -o -name venv \
           -o -name site-packages -o -name Library -o -name .Trash \
           -o -name .cache -o -name Applications \) -prune -o \
        -type d -name custom_nodes -print 2>/dev/null |
        while IFS= read -r hit; do note "$hit"; done
    done
  fi
fi

cat "$SURE" >"$WORK/all"
cat "$MAYBE" >>"$WORK/all"
COUNT=$(wc -l <"$WORK/all" | tr -d ' ')

if [ "$DETECT_ONLY" -eq 1 ]; then
  while IFS= read -r line; do printf 'found %s\n' "${line%/custom_nodes}"; done <"$SURE"
  while IFS= read -r line; do printf 'maybe %s\n' "${line%/custom_nodes}"; done <"$MAYBE"
  exit 0
fi

if [ "$COUNT" -eq 0 ]; then
  t "ComfyUI was not found on this computer." "在本机上没有找到 ComfyUI。"
  answer=$(ask "Type the full path to your ComfyUI folder (or press Enter to stop): " \
               "请输入 ComfyUI 文件夹的完整路径（直接回车则退出）：") || answer=""
  if [ -n "$answer" ]; then note_base "$answer"; fi
  cat "$SURE" >"$WORK/all"
  cat "$MAYBE" >>"$WORK/all"
  COUNT=$(wc -l <"$WORK/all" | tr -d ' ')
fi

if [ "$COUNT" -eq 0 ]; then
  t "Install ComfyUI first - see https://github.com/$REPO#install-comfyui - then run this again." \
    "请先安装 ComfyUI（见 https://github.com/$REPO/blob/main/README.zh-CN.md#安装-comfyui），然后重新运行本脚本。"
  exit 1
fi

SURE_COUNT=$(wc -l <"$SURE" | tr -d ' ')
if [ "$COUNT" -eq 1 ]; then
  TARGET=$(cat "$WORK/all")
  if [ "$SURE_COUNT" -ne 1 ]; then
    # A custom_nodes folder with no ComfyUI beside it - worth a confirmation.
    t "Found: ${TARGET%/custom_nodes}" "找到：${TARGET%/custom_nodes}"
    reply=$(ask "This does not look like a full ComfyUI folder. Install there anyway? [y/N] " \
                "这看起来不像完整的 ComfyUI 文件夹。仍然安装到这里？[y/N] ") || reply="y"
    case "${reply:-n}" in
      y|Y|yes|YES) ;;
      *) die "Stopped. Pass --path with your ComfyUI folder." "已停止。请用 --path 指定 ComfyUI 文件夹。" ;;
    esac
  fi
else
  t "Several ComfyUI folders were found:" "找到多个 ComfyUI 文件夹："
  i=0
  while IFS= read -r line; do
    i=$((i + 1))
    if [ "$i" -le "$SURE_COUNT" ]; then
      printf '  %s) %s\n' "$i" "${line%/custom_nodes}"
    else
      printf '  %s) %s (?)\n' "$i" "${line%/custom_nodes}"
    fi
  done <"$WORK/all"
  choice=$(ask "Which one? [1] " "选择哪一个？[1] ") || choice=1
  case "${choice:-1}" in
    ''|*[!0-9]*) choice=1 ;;
  esac
  if [ "$choice" -lt 1 ] || [ "$choice" -gt "$COUNT" ]; then choice=1; fi
  TARGET=$(sed -n "${choice}p" "$WORK/all")
fi

t "ComfyUI: ${TARGET%/custom_nodes}" "ComfyUI 位置：${TARGET%/custom_nodes}"

if [ ! -w "$TARGET" ]; then
  die "No permission to write to $TARGET - run this again with sudo, or fix the folder's permissions." \
      "没有写入权限：$TARGET —— 请用 sudo 重新运行，或修改该文件夹的权限。"
fi

# ------------------------------------------------------------------ the files

DEST="$TARGET/$NODE_DIR_NAME"

t "Downloading the node..." "正在下载节点……"
command -v curl >/dev/null 2>&1 || die "curl is not installed." "未安装 curl。"
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
[ -f "$DEST/merak_nodes.py" ] || die "Install failed." "安装失败。"
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
t "Done. Restart ComfyUI, double-click the canvas and search for Merak." \
  "完成。请重启 ComfyUI，然后双击画布并搜索 Merak。"
t "You should see: Merak Generate Video, Merak Fetch Video (by id)." \
  "你应该能看到：Merak Generate Video、Merak Fetch Video (by id)。"
t "" ""
