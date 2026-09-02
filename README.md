# Merak Video for ComfyUI

Generate video with **MiniMax-H3** on [merak](https://merakcompute.ai), from inside
ComfyUI. Text-to-video and image-to-video, rendered on merak's GPUs and saved to your
output folder. No dependencies.

## Install

```bash
cd ComfyUI/custom_nodes
git clone https://github.com/snarkify/merak-comfyui-node.git
```

Restart ComfyUI. Needs Python 3.10 or newer. To check it loaded, double-click the canvas and search for **Merak** —
you should get *Merak Generate Video* and *Merak Fetch Video (by id)*.

## Set your key

```bash
export MERAK_API_KEY=...
export MERAK_TEAM_ID=...   # from the merak console URL
```

Or write the key to `~/.merak/api_key` (`chmod 600`), which a ComfyUI started from the
Dock will find — it does not read your shell profile.

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
| `403 INFERENCE_NOT_ENABLED` | inference is not enabled for your account |
| `403` / `404` naming the team | you must **own** the team; membership is not enough |
| `401` | key missing or revoked |
| Render `FAILED` with `input image …` | keyframe outside the size or aspect limits — no charge |
| Poll times out | the render is **not** cancelled — re-attach with *Merak Fetch Video* |

## License

[MIT](LICENSE).
