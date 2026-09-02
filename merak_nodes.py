"""The two ComfyUI nodes."""

import io
import os

from .merak_api import (
    ACTIVE_STATES,
    API_KEY_ENV,
    API_KEY_FILE,
    ASPECT_RATIOS,
    CLIPS,
    DEFAULT_ASPECT_RATIO,
    DEFAULT_TIMEOUT_S,
    KEYFRAME_ROLES,
    MerakError,
    download,
    extension,
    output_url,
    poll,
    resolve_api_key,
    resolve_team_id,
    submit,
    upload_keyframes,
)

# A `filename_prefix` may name a subfolder and carry %date:...% tokens; the file
# takes the next counter in that folder.
DEFAULT_FILENAME_PREFIX = "video/merak"

_TEAM_TOOLTIP = "Your merak team id, from the console URL. Blank falls back to MERAK_TEAM_ID."
# Both nodes save the same way, so they offer the same two controls.
_OUTPUT_INPUTS = {
    "timeout_s": ("INT", {"default": DEFAULT_TIMEOUT_S, "min": 60, "max": 21600}),
    "filename_prefix": (
        "STRING",
        {
            "default": DEFAULT_FILENAME_PREFIX,
            "tooltip": (
                "Saved under ComfyUI's output directory. May include a subfolder "
                "and %date:yyyy-MM-dd% style tokens."
            ),
        },
    ),
}


def encode_keyframe(image, label: str) -> bytes:
    """A ComfyUI IMAGE (float tensor, batch x height x width x channel in 0..1)
    as PNG bytes — the first image of the batch.

    numpy and Pillow are imported lazily; ComfyUI supplies both.
    """
    import numpy as np
    from PIL import Image

    if hasattr(image, "detach"):  # a torch tensor, possibly on the GPU
        image = image.detach().cpu().numpy()
    array = np.asarray(image, dtype=np.float32)
    if array.ndim == 4:
        if array.shape[0] > 1:
            # One socket conditions one frame, so only the first is used.
            print(
                f"[merak] WARNING: {label} carries {array.shape[0]} images; using the "
                "first and ignoring the rest"
            )
        array = array[0]
    if array.ndim != 3 or array.shape[-1] < 3:
        raise MerakError(f"a keyframe must be an RGB image, got shape {tuple(array.shape)}")
    raster = np.clip(array[..., :3] * 255.0 + 0.5, 0, 255).astype(np.uint8)
    buffer = io.BytesIO()
    Image.fromarray(raster, "RGB").save(buffer, format="PNG")
    return buffer.getvalue()


def _save_target(filename_prefix: str, suffix: str, fallback_name: str) -> tuple[str, str]:
    """Where to write the clip, and the subfolder the preview needs to find it.

    ComfyUI resolves the prefix, picks the subfolder and hands back the next free
    counter, so a merak render is filed like any other saved video.
    """
    filename_prefix = (filename_prefix or "").strip() or DEFAULT_FILENAME_PREFIX
    try:
        import folder_paths  # ComfyUI; absent when this module is imported alone
    except ImportError:
        folder = os.path.join(os.path.dirname(os.path.abspath(__file__)), "output")
        return os.path.join(folder, f"merak_{fallback_name}{suffix}"), ""

    # ComfyUI refuses a prefix that would write outside the output directory, and
    # that refusal has to reach the user.
    folder, name, counter, subfolder, _ = folder_paths.get_save_image_path(
        filename_prefix, folder_paths.get_output_directory()
    )
    return os.path.join(folder, f"{name}_{counter:05}_{suffix}"), subfolder


def save_output(
    api_key: str, team_id: str, detail: dict, filename_prefix: str = DEFAULT_FILENAME_PREFIX
) -> tuple[str, str]:
    url = output_url(api_key, team_id, detail)
    dest, subfolder = _save_target(
        filename_prefix, extension(url), detail["video_inference_id"]
    )
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    return download(url, dest), subfolder


class _Progress:
    """Drives ComfyUI's node progress bar when there is one to drive.

    The node blocks for minutes on a full-length clip, so without this the graph
    sits at 0% and reads as hung. The server reports progress as a percentage.
    """

    TOTAL = 100

    def __init__(self) -> None:
        try:
            from comfy.utils import ProgressBar

            self._bar = ProgressBar(self.TOTAL)
        except Exception:
            self._bar = None  # no ComfyUI, or one without it; the render is unaffected

    def update(self, detail: dict) -> None:
        # None while queued, which is not zero: nothing has started yet.
        percentage = detail.get("progress_percentage")
        if self._bar is None or detail.get("state") not in ACTIVE_STATES:
            return
        if percentage is None:
            return
        self._set(max(0.0, min(float(percentage) / 100.0, 1.0)))

    def finish(self) -> None:
        self._set(1.0)

    def _set(self, fraction: float) -> None:
        if self._bar is None:
            return
        try:
            self._bar.update_absolute(int(fraction * self.TOTAL), self.TOTAL)
        except Exception:
            # Reporting progress must never be able to fail a paid render.
            self._bar = None


def _resolve(team_id: str) -> tuple[str, str]:
    key = resolve_api_key()
    if not key:
        raise ValueError(
            f"no merak API key. Set {API_KEY_ENV}, or write the key to "
            f"{API_KEY_FILE} (chmod 600), which a ComfyUI started from the Dock "
            "will find — it does not read your shell profile."
        )
    team = (team_id or "").strip() or os.environ.get("MERAK_TEAM_ID", "").strip()
    return key, team or resolve_team_id(key)


def _as_video(path: str):
    """The saved clip as ComfyUI's VIDEO type, so it can feed Save Video, Trim
    Video, Get Video Components and anything else that takes one.

    None on a ComfyUI too old to offer it; the path output still works.
    """
    try:
        from comfy_api.input_impl import VideoFromFile

        return VideoFromFile(path)
    except Exception as exc:
        print(f"[merak] WARNING: no VIDEO output ({type(exc).__name__}: {exc}); video_path still works")
        return None


def _collect(key: str, team: str, job: str, timeout_s, filename_prefix, on_tick=None) -> dict:
    """Wait for `job`, save it, and return the node result."""
    detail = poll(key, team, job, timeout_s=int(timeout_s), on_tick=on_tick)
    dest, subfolder = save_output(key, team, detail, filename_prefix)
    print(f"[merak] saved {dest}")
    return {
        "ui": {
            "images": [
                {"filename": os.path.basename(dest), "subfolder": subfolder, "type": "output"}
            ],
            "animated": (True,),
        },
        "result": (_as_video(dest), dest),
    }


def _never_cache(cls):
    """Make ComfyUI re-run this node on every queue.

    ComfyUI caches a node whose inputs have not changed and serves its previous
    outputs without calling it. A render is a fresh call to a remote service every
    time, so NaN — never equal to itself — keeps the node out of that cache.
    """

    @classmethod
    def IS_CHANGED(_cls, **_kwargs):
        return float("nan")

    cls.IS_CHANGED = IS_CHANGED
    return cls


@_never_cache
class MerakGenerateVideo:
    """Submit a prompt — and a first and/or last keyframe, if connected — wait,
    then save the video into ComfyUI's output directory.

    Returns it both as a VIDEO, for nodes that take one, and as the path on disk.
    """

    CATEGORY = "video/merak"
    FUNCTION = "generate"
    RETURN_TYPES = ("VIDEO", "STRING")
    RETURN_NAMES = ("video", "video_path")
    OUTPUT_NODE = True

    @classmethod
    def INPUT_TYPES(cls):
        return {
            "required": {
                "prompt": (
                    "STRING",
                    {"multiline": True, "default": "a paper boat floating on a calm pond"},
                ),
                "team_id": ("STRING", {"default": "", "tooltip": _TEAM_TOOLTIP}),
                "clip": (list(CLIPS), {"default": next(iter(CLIPS))}),
            },
            "optional": {
                "first_frame": ("IMAGE", {"tooltip": "the clip opens on this image"}),
                "last_frame": ("IMAGE", {"tooltip": "the clip closes on this image"}),
                "aspect_ratio": (
                    list(ASPECT_RATIOS),
                    {
                        "default": DEFAULT_ASPECT_RATIO,
                        "tooltip": "the canvas; a keyframe is fitted to it",
                    },
                ),
                "seed": (
                    "INT",
                    {
                        "default": -1,
                        "min": -1,
                        "max": 2**31 - 1,
                        "tooltip": "-1 = server picks; 0 is a real seed here",
                    },
                ),
                **_OUTPUT_INPUTS,
            },
        }

    def generate(
        self,
        prompt,
        team_id,
        clip,
        first_frame=None,
        last_frame=None,
        aspect_ratio=DEFAULT_ASPECT_RATIO,
        seed=-1,
        timeout_s=DEFAULT_TIMEOUT_S,
        filename_prefix=DEFAULT_FILENAME_PREFIX,
    ):
        key, team = _resolve(team_id)
        # Keyframes go up first: the submit that names them is the metered call,
        # and it is not made until they are READY.
        frames = [
            (role, encode_keyframe(image, role.lower()))
            for role, image in zip(KEYFRAME_ROLES, (first_frame, last_frame), strict=True)
            if image is not None
        ]
        inputs = upload_keyframes(key, team, frames)
        job = submit(
            key,
            team,
            prompt=prompt,
            clip=clip,
            aspect_ratio=aspect_ratio,
            seed=int(seed),
            inputs=inputs,
        )["video_inference_id"]
        print(f"[merak] inference {job} submitted; polling…")

        bar = _Progress()

        def tick(detail):
            bar.update(detail)
            percentage = detail.get("progress_percentage")
            shown = "" if percentage is None else f" ({int(percentage)}%)"
            print(f"[merak] {job}: {detail.get('state')}{shown}")

        result = _collect(key, team, job, timeout_s, filename_prefix, on_tick=tick)
        bar.finish()
        return result


@_never_cache
class MerakFetchVideo:
    """Fetch an existing inference by id, waiting if it is still running. Use it
    when a queue polls past its timeout — the timeout cancels nothing."""

    CATEGORY = "video/merak"
    FUNCTION = "fetch"
    RETURN_TYPES = ("VIDEO", "STRING")
    RETURN_NAMES = ("video", "video_path")
    OUTPUT_NODE = True

    @classmethod
    def INPUT_TYPES(cls):
        return {
            "required": {
                "video_inference_id": ("STRING", {"default": ""}),
                "team_id": ("STRING", {"default": "", "tooltip": _TEAM_TOOLTIP}),
            },
            "optional": dict(_OUTPUT_INPUTS),
        }

    def fetch(
        self,
        video_inference_id,
        team_id,
        timeout_s=DEFAULT_TIMEOUT_S,
        filename_prefix=DEFAULT_FILENAME_PREFIX,
    ):
        job = (video_inference_id or "").strip()
        if not job:
            raise ValueError("fetch needs a video_inference_id")
        key, team = _resolve(team_id)
        return _collect(key, team, job, timeout_s, filename_prefix)


NODE_CLASS_MAPPINGS = {
    "MerakGenerateVideo": MerakGenerateVideo,
    "MerakFetchVideo": MerakFetchVideo,
}
NODE_DISPLAY_NAME_MAPPINGS = {
    "MerakGenerateVideo": "Merak Generate Video",
    "MerakFetchVideo": "Merak Fetch Video (by id)",
}
