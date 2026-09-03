# Merak Video for ComfyUI

**English** · [中文](README.zh-CN.md)

Generate video with **MiniMax-H3** on [merak](https://merakcompute.ai), from inside
ComfyUI. Text-to-video and image-to-video. The render runs on merak's GPUs, so your own
machine only has to run ComfyUI — no local GPU needed for this node, and nothing to
install beyond it.

## Before you begin

Make sure you have:

* **ComfyUI installed** — no ComfyUI yet? [Install ComfyUI](#install-comfyui) first, it
  takes a few minutes
* **A merak API key** — from the [merak console](https://merakcompute.ai)
* **A terminal open** — Terminal on macOS (press `⌘ Space`, type `Terminal`, Enter);
  PowerShell or Command Prompt on Windows (press the Windows key and type the name)

You do not need a GPU. Renders run on merak's GPUs; your machine only runs ComfyUI.

## Step 1: Install the node

Copy the line for your system, paste it into the terminal, and press Enter.

**macOS, Linux, WSL:**

```bash
curl -fsSL https://raw.githubusercontent.com/snarkify/merak-comfyui-node/main/install.sh | sh
```

**Windows PowerShell:**

```powershell
irm https://raw.githubusercontent.com/snarkify/merak-comfyui-node/main/install.ps1 | iex
```

**Windows CMD:**

```batch
curl -fsSL https://raw.githubusercontent.com/snarkify/merak-comfyui-node/main/install.cmd -o install.cmd && install.cmd && del install.cmd
```

If you see `The token '&&' is not a valid statement separator`, you're in PowerShell, not
CMD. If you see `'irm' is not recognized as an internal or external command`, you're in
CMD, not PowerShell. Your prompt shows `PS C:\` when you're in PowerShell and `C:\`
without the `PS` when you're in CMD.

The installer prints the ComfyUI folder it found and installs into it. Running the line
again upgrades an existing install; the old copy is kept beside it as
`merak-comfyui-node.previous`.

## Step 2: Paste your API key

The installer asks for it. Copy the key from the [merak console](https://merakcompute.ai),
paste it, and press Enter.

It goes into `~/.merak/api_key` — `C:\Users\<you>\.merak\api_key` on Windows — readable
only by you. If a key is already saved there, the installer keeps it and doesn't ask.

## Step 3: Check it loaded

Restart ComfyUI, double-click the canvas, and type `Merak`. You should get:

* **Merak Generate Video**
* **Merak Fetch Video (by id)**

If nothing comes up, see [Troubleshooting](#troubleshooting).

## Step 4: Make your first video

Drag `examples/merak-video.json` onto the canvas for a ready-made graph, or add
**video/merak → Merak Generate Video** yourself, type a prompt, and queue it. The clip
lands in your output folder and previews in the node. [Use](#use) has the rest.

## Options

Pass the answers on the command line to skip the questions. macOS / Linux:

```bash
curl -fsSL https://raw.githubusercontent.com/snarkify/merak-comfyui-node/main/install.sh \
  | sh -s -- --key "YOUR_KEY" --path "/path/to/ComfyUI"
```

Windows PowerShell:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/snarkify/merak-comfyui-node/main/install.ps1))) -ApiKey "YOUR_KEY" -ComfyPath "C:\path\to\ComfyUI"
```

Windows CMD takes the same options as PowerShell: `install.cmd -ApiKey "YOUR_KEY"`.

| Option | |
|---|---|
| `--key` / `-ApiKey` | the API key, instead of being asked for it |
| `--path` / `-ComfyPath` | your ComfyUI folder, when the search misses it |
| `--lang en\|zh` / `-Lang` | message language; the default follows your system |
| `--yes` / `-Yes` | never ask anything — stop with an error instead |
| `--no-scan` / `-NoScan` | use only recorded and default paths, never search the disk |
| `--detect-only` / `-DetectOnly` | list every ComfyUI folder found, then stop |

The installer only ever writes to two places: `custom_nodes/merak-comfyui-node` inside
the ComfyUI folder it reports, and the key file `~/.merak/api_key`. There are three
scripts because no one language runs on all three systems — Windows has no `sh`, macOS
has no PowerShell — but they do the same thing, in the same order, with the same
options, and `tests/detect_test.sh` checks that they agree.

### How it finds ComfyUI

ComfyUI does not sit in one place across systems — but every install has the same shape
inside, `<base>/custom_nodes` next to `main.py`, and the apps that install it write down
where they put it. So the search asks the cheap, exact sources first and only walks the
disk if they all come up empty:

1. `--path`, or the `COMFYUI_PATH` environment variable
2. the desktop app's own records — `installations.json` (every install it made),
   `config.json` and `extra_models_config.yaml` on older builds
3. `comfy-cli`'s `config.ini`, which remembers its workspace
4. a ComfyUI that happens to be running right now
5. the default locations — `ComfyUI-Installs`, `Documents/ComfyUI`, the Windows portable
   build, `/opt`, and the rest
6. the system file index: Spotlight on macOS, `plocate` on Linux — both answer instantly
7. a depth-limited walk of your home and drive roots, skipping `node_modules`,
   `site-packages` and friends

The first six sources are effectively instant. Only the last one walks anything: a few
seconds on macOS and Linux, up to a minute on Windows, which has no index to ask.
`--no-scan` / `-NoScan` skips it.

A folder only counts as ComfyUI if `main.py`, `comfyui_version.py` or `comfy/` sits
beside `custom_nodes`; anything else is offered with a `(?)` and a confirmation. When
more than one turns up, the installer asks which. Run it with `--detect-only` /
`-DetectOnly` to see the list without installing anything.

## Install by hand

```bash
cd ComfyUI/custom_nodes
git clone https://github.com/snarkify/merak-comfyui-node.git
```

Then save your key:

```bash
mkdir -p ~/.merak
printf '%s\n' "YOUR_KEY" > ~/.merak/api_key
chmod 600 ~/.merak/api_key
```

On Windows that file is `C:\Users\<you>\.merak\api_key` — plain text, UTF-8, the key on
one line.

Restart ComfyUI. Needs Python 3.10 or newer. To check it loaded, double-click the canvas
and search for **Merak** — you should get *Merak Generate Video* and *Merak Fetch Video
(by id)*.

A ComfyUI started from the Dock or the Start menu does not read your shell profile, so
the key file is the reliable route. Launching from a terminal, `MERAK_API_KEY` works too.

`team_id` goes on the node, or in `MERAK_TEAM_ID` — find it in the merak console URL.

## Install ComfyUI

Skip this if you already run ComfyUI.

**Windows or macOS, easiest — the desktop app.** Download the installer from
[comfy.org/download](https://www.comfy.org/download), open it, and follow the prompts. It
puts your ComfyUI folder in `Documents/ComfyUI`, which the one-line installer above finds
on its own.

**Windows, portable build.** Download `ComfyUI_windows_portable_nvidia.7z` from the
[releases page](https://github.com/comfyanonymous/ComfyUI/releases), extract it (with
[7-Zip](https://www.7-zip.org/)) to somewhere like `C:\`, and start it with
`run_nvidia_gpu.bat` — or `run_cpu.bat` if you have no NVIDIA card. Merak renders on
merak's GPUs either way.

**macOS, Linux, or from source.** Needs Python 3.10+ and git:

```bash
git clone https://github.com/comfyanonymous/ComfyUI.git
cd ComfyUI
python3 -m venv venv && source venv/bin/activate
pip install -r requirements.txt
python main.py
```

Then open <http://127.0.0.1:8188> in a browser. On Linux, install the PyTorch build for
your GPU first — see [ComfyUI's
README](https://github.com/comfyanonymous/ComfyUI#installing).

## Use

Add **video/merak → Merak Generate Video**, set a prompt, pick a clip, queue it. The clip
lands in your output folder as `video/merak_00001_.mp4` and previews in place. Change
`filename_prefix` to pick a different subfolder or add `%date:yyyy-MM-dd%` tokens.

Connect an image to `first_frame`, `last_frame`, or both to make it image-to-video.

The node outputs the clip as a **VIDEO**, so it can feed Save Video, Trim Video or Get
Video Components, and as **video_path** for anything that wants the file on disk.

**Merak Fetch Video (by id)** re-downloads a render you already submitted — use it if a
queue polls past its timeout. The timeout cancels nothing server-side.

`examples/merak-video.json` is a ready-made graph. Drag it onto the canvas.

## What's served

| | |
|---|---|
| Clips | `480p/243 frames (~10.1 s)`, `720p/243`, `480p/22 (~0.9 s)` |
| Aspect ratio | `16:9`, `9:16`, `1:1` — a keyframe is fitted to the canvas you pick |
| Prompt | up to 7000 characters |
| Audio | every clip has it, muxed in |
| Keyframes | 256–5760 px a side, aspect 0.4–2.5, ≤30 MB |

The 22-frame clip is off-spec — H3 is specified for 5–15 s — and is not the default.

Set a seed to make a render repeatable; at `-1` the server picks one and does not report
it back (`0` is a real seed).

## Troubleshooting

| | |
|---|---|
| The installer says ComfyUI was not found | run it with `--detect-only` / `-DetectOnly` to see what it looked at, then pass `--path` / `-ComfyPath` with your ComfyUI folder |
| It picked the wrong ComfyUI | pass `--path` / `-ComfyPath`; the node goes wherever you point it |
| No **Merak** nodes after restarting | check the node landed in `ComfyUI/custom_nodes/merak-comfyui-node`, and look at the ComfyUI console for the error |
| `403 INFERENCE_NOT_ENABLED` | inference is not enabled for your account |
| `403` / `404` naming the team | you must **own** the team; membership is not enough |
| `401` | key missing or revoked — check `~/.merak/api_key` holds the key and nothing else |
| Render `FAILED` with `input image …` | keyframe outside the size or aspect limits — no charge |
| Poll times out | the render is **not** cancelled — re-attach with *Merak Fetch Video* |

## License

[MIT](LICENSE).
