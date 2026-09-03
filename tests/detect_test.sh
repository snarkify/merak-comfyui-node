#!/bin/sh
# Feeds install.sh and install.ps1 the same fake ComfyUI layouts and checks that
# both find the same thing. The two installers are separate files because no one
# language runs on all three systems, so this is what keeps them in step.
#
#   tests/detect_test.sh
#
# PowerShell is optional: set PWSH to a pwsh binary to include install.ps1,
# otherwise only install.sh is checked.

set -u
REPO=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d 2>/dev/null || mktemp -d -t merak-test)
# The installers report resolved paths, so the fixtures must be resolved too
# (on macOS mktemp hands back a /var symlink into /private/var).
WORK=$(cd "$WORK" && pwd -P)
trap 'rm -rf "$WORK"' EXIT INT TERM

PWSH=${PWSH:-pwsh}
if command -v "$PWSH" >/dev/null 2>&1; then HAVE_PWSH=1; else HAVE_PWSH=0; fi

# Spotlight and locate answer with the real installs on this machine, which the
# fixtures know nothing about, so hide them from the search.
STUB="$WORK/stub"
mkdir -p "$STUB"
for tool in mdfind locate plocate; do
  printf '#!/bin/sh\nexit 1\n' >"$STUB/$tool"
  chmod +x "$STUB/$tool"
done

comfy() { mkdir -p "$1/custom_nodes"; : >"$1/main.py"; }
fails=0

check() { # check <case> <expected line, or NONE>
  name=$1
  want=$2
  home="$WORK/$name/home"

  out=$(HOME="$home" PATH="$STUB:$PATH" sh "$REPO/install.sh" --detect-only --yes 2>&1 |
        grep -E '^(found|maybe)' | sed "s|$home|~|g")
  verdict sh "$name" "$want" "$out"

  if [ "$HAVE_PWSH" -eq 1 ]; then
    out=$(HOME="$home" APPDATA="$home/AppData/Roaming" LOCALAPPDATA="$home/AppData/Local" \
          "$PWSH" -NoProfile -File "$REPO/install.ps1" -DetectOnly -Yes 2>&1 |
          grep -E '^(found|maybe)' | sed "s|$home|~|g")
    verdict ps "$name" "$want" "$out"
  fi
}

verdict() { # verdict <which> <case> <expected> <output>
  if [ "$3" = NONE ]; then
    if [ -z "$4" ]; then
      echo "  ok   $1 $2 -> nothing"
    else
      echo "  FAIL $1 $2 -> $4"
      fails=$((fails + 1))
    fi
  elif echo "$4" | grep -qF "$3"; then
    echo "  ok   $1 $2 -> $(echo "$4" | tr '\n' ' ')"
  else
    echo "  FAIL $1 $2: wanted '$3', got '$(echo "$4" | tr '\n' ' ')'"
    fails=$((fails + 1))
  fi
}

# The desktop app records every install it made, with ComfyUI one level down.
H="$WORK/desktop2/home"
comfy "$H/ComfyUI-Installs/My Install/ComfyUI"
mkdir -p "$H/Library/Application Support/Comfy Desktop" "$H/AppData/Roaming/Comfy Desktop"
RECORD='[{"id":"i1","name":"My Install","installPath":"'"$H"'/ComfyUI-Installs/My Install"}]'
printf '%s' "$RECORD" >"$H/Library/Application Support/Comfy Desktop/installations.json"
printf '%s' "$RECORD" >"$H/AppData/Roaming/Comfy Desktop/installations.json"
check desktop2 "~/ComfyUI-Installs/My Install/ComfyUI"

# Older desktop builds record one basePath instead.
H="$WORK/desktop1/home"
comfy "$H/Documents/ComfyUI-Custom"
mkdir -p "$H/Library/Application Support/ComfyUI" "$H/AppData/Roaming/ComfyUI"
RECORD='{"basePath":"'"$H"'/Documents/ComfyUI-Custom"}'
printf '%s' "$RECORD" >"$H/Library/Application Support/ComfyUI/config.json"
printf '%s' "$RECORD" >"$H/AppData/Roaming/ComfyUI/config.json"
check desktop1 "~/Documents/ComfyUI-Custom"

# The same path turns up in extra_models_config.yaml.
H="$WORK/yaml/home"
comfy "$H/elsewhere/ComfyUI"
mkdir -p "$H/Library/Application Support/ComfyUI" "$H/AppData/Roaming/ComfyUI"
printf 'comfyui:\n  base_path: %s/elsewhere/ComfyUI\n' "$H" >"$H/Library/Application Support/ComfyUI/extra_models_config.yaml"
cp "$H/Library/Application Support/ComfyUI/extra_models_config.yaml" "$H/AppData/Roaming/ComfyUI/extra_models_config.yaml"
check yaml "~/elsewhere/ComfyUI"

# comfy-cli remembers the workspace it installed into.
H="$WORK/cli/home"
comfy "$H/work/comfy"
mkdir -p "$H/.config/comfy-cli"
printf '[DEFAULT]\ndefault_workspace = %s/work/comfy\n' "$H" >"$H/.config/comfy-cli/config.ini"
check cli "~/work/comfy"

# A plain clone in the obvious place.
H="$WORK/default/home"
comfy "$H/ComfyUI"
check default "~/ComfyUI"

# custom_nodes with no ComfyUI beside it is a maybe, not a match.
H="$WORK/bare/home"
mkdir -p "$H/ComfyUI/custom_nodes"
check bare "maybe ~/ComfyUI"

# Nowhere anyone records: only the disk walk can turn this up.
H="$WORK/deep/home"
comfy "$H/projects/ai/stuff/ComfyUI"
check deep "~/projects/ai/stuff/ComfyUI"

# Nothing installed at all.
H="$WORK/none/home"
mkdir -p "$H"
check none NONE

# Two installs: both are offered.
H="$WORK/multi/home"
comfy "$H/ComfyUI"
comfy "$H/Documents/ComfyUI"
check multi "~/Documents/ComfyUI"

echo
if [ "$HAVE_PWSH" -eq 0 ]; then
  echo "(install.ps1 not checked - no pwsh on PATH; set PWSH=/path/to/pwsh)"
fi
if [ "$fails" -eq 0 ]; then
  echo "all detection cases pass"
else
  echo "$fails failures"
  exit 1
fi
