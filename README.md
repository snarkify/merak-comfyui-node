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

**macOS and Linux:**

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

In WSL, use the Windows installer for a Windows ComfyUI. Use the shell installer only for
a ComfyUI installed inside WSL.

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

Windows CMD takes the same options as PowerShell, but the line in Step 1 deletes
`install.cmd` on its way out, so pass them in the same breath:

```batch
curl -fsSL https://raw.githubusercontent.com/snarkify/merak-comfyui-node/main/install.cmd -o install.cmd && install.cmd -ApiKey "YOUR_KEY" && del install.cmd
```

| Option | |
|---|---|
| `--key` / `-ApiKey` | the API key, instead of being asked for it |
| `--path` / `-ComfyPath` | your ComfyUI folder, when the search misses it |
| `--yes` / `-Yes` | never ask anything; missing or ambiguous paths become errors |

## Install ComfyUI

Skip this if you already run ComfyUI.

**Windows or macOS, easiest — the desktop app.** Download it from
[comfy.org/download](https://www.comfy.org/download), open it, and follow the prompts.

**Windows, portable build.** Download `ComfyUI_windows_portable_nvidia.7z` from the
[releases page](https://github.com/comfyanonymous/ComfyUI/releases), extract it (with
[7-Zip](https://www.7-zip.org/)) to somewhere like `C:\`, and start it with
`run_nvidia_gpu.bat` — or `run_cpu.bat` if you have no NVIDIA card. Merak renders on
merak's GPUs either way.

**macOS, Linux, or from source.** Follow ComfyUI's current
[installation guide](https://docs.comfy.org/installation/manual_install). The basic flow is:

```bash
git clone https://github.com/comfyanonymous/ComfyUI.git
cd ComfyUI
python3 -m venv venv && source venv/bin/activate
pip install -r requirements.txt
python main.py
```

Open <http://127.0.0.1:8188> in a browser.

## Use

Add **video/merak → Merak Generate Video**, set a prompt, pick a clip, queue it. The clip
lands in your output folder as `video/merak_00001_.mp4` and previews in place. Change
`filename_prefix` to pick a different subfolder or add `%date:yyyy-MM-dd%` tokens.

`team_id` goes on the node, or in `MERAK_TEAM_ID` — find it in the merak console URL.

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
| The installer says ComfyUI was not found | pass `--path` / `-ComfyPath` with your ComfyUI folder |
| It picked the wrong ComfyUI | pass `--path` / `-ComfyPath`; the node goes wherever you point it |
| No **Merak** nodes after restarting | check the node landed in `ComfyUI/custom_nodes/merak-comfyui-node`, and look at the ComfyUI console for the error |
| `403 INFERENCE_NOT_ENABLED` | inference is not enabled for your account |
| `403` / `404` naming the team | you must **own** the team; membership is not enough |
| `401` | key missing or revoked — check `~/.merak/api_key` holds the key and nothing else |
| Render `FAILED` with `input image …` | keyframe outside the size or aspect limits — no charge |
| Poll times out | the render is **not** cancelled — re-attach with *Merak Fetch Video* |

## License

[MIT](LICENSE).
