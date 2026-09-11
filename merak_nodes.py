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
    DEFAULT_MODEL,
    DEFAULT_TIMEOUT_S,
    IMAGE_CONTENT_TYPE,
    KEYFRAME_ROLES,
    MAX_REFERENCE_IMAGES,
    MODELS,
    REFERENCE_IMAGE_ROLE,
    REFERENCE_VIDEO_ROLE,
    REFERENCE_VIDEO_SECONDS,
    VIDEO_CONTENT_TYPE,
    MerakError,
    check_request,
    download,
    extension,
    output_url,
    poll,
    resolve_api_key,
    resolve_team_id,
    resolve_workload,
    submit,
    upload_inputs,
)

# What the service accepts for a reference video's soundtrack.
ACCEPTED_AUDIO_CODECS = ("aac", "mp3")

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


def _as_batch(image):
    """A ComfyUI IMAGE (float tensor, batch x height x width x channel in 0..1)
    as a numpy batch. numpy is imported lazily; ComfyUI supplies it."""
    import numpy as np

    if hasattr(image, "detach"):  # a torch tensor, possibly on the GPU
        image = image.detach().cpu().numpy()
    array = np.asarray(image, dtype=np.float32)
    if array.ndim == 3:
        array = array[None]
    if array.ndim != 4 or array.shape[-1] < 3:
        raise MerakError(f"an image input must be RGB, got shape {tuple(array.shape)}")
    return array


def _encode_png(array) -> bytes:
    """One height x width x channel float image as PNG bytes. Pillow is
    imported lazily; ComfyUI supplies it."""
    import numpy as np
    from PIL import Image

    raster = np.clip(array[..., :3] * 255.0 + 0.5, 0, 255).astype(np.uint8)
    buffer = io.BytesIO()
    Image.fromarray(raster, "RGB").save(buffer, format="PNG")
    return buffer.getvalue()


def encode_keyframe(image, label: str) -> bytes:
    """The first image of a batch as PNG bytes: one socket conditions one frame."""
    batch = _as_batch(image)
    if batch.shape[0] > 1:
        print(
            f"[merak] WARNING: {label} carries {batch.shape[0]} images; using the "
            "first and ignoring the rest"
        )
    return _encode_png(batch[0])


def encode_reference_images(image) -> list[bytes]:
    """Every image of a batch as PNG bytes, in batch order — the order the
    prompt's `<Picture N>` tags count in."""
    batch = _as_batch(image)
    if batch.shape[0] > MAX_REFERENCE_IMAGES:
        raise MerakError(
            f"reference_images carries {batch.shape[0]} images; the service takes at "
            f"most {MAX_REFERENCE_IMAGES}. Nothing was sent."
        )
    return [_encode_png(frame) for frame in batch]


def _stream_layout(path: str) -> tuple[int, list[str]]:
    """(video tracks, audio codec names) of a saved file. PyAV is ComfyUI's."""
    import av

    with av.open(path) as container:
        return (
            len(container.streams.video),
            [stream.codec_context.name for stream in container.streams.audio],
        )


def _service_can_take(videos: int, audios: list[str]) -> bool:
    return (
        videos == 1
        and len(audios) <= 1
        and all(name.startswith(ACCEPTED_AUDIO_CODECS) for name in audios)
    )


def encode_reference_video(video) -> bytes:
    """A ComfyUI VIDEO as MP4/H.264 bytes with at most one AAC/MP3 soundtrack,
    which is what the service takes.

    When the source already is an H.264 MP4, ComfyUI copies EVERY stream as it
    is — an Opus soundtrack or a second audio track would survive and be
    refused by the renderer after the upload. So the copy is inspected, and a
    non-compliant one is saved again with a quality setting, which makes
    ComfyUI transcode: one video track, one AAC track. The length is checked
    first, for the same reason.
    """
    import tempfile

    low, high = REFERENCE_VIDEO_SECONDS
    try:
        duration = float(video.get_duration())
    except Exception:
        duration = None  # not every VIDEO implementation can say; the service checks
    if duration is not None and not low <= duration <= high:
        raise MerakError(
            f"the reference video is {duration:.1f} s; the service takes {low:g}–{high:g} s. "
            "Trim it (a Trim Video node will do) — nothing was sent."
        )
    with tempfile.TemporaryDirectory() as folder:
        path = os.path.join(folder, "reference.mp4")
        try:
            from comfy_api.util import VideoCodec, VideoContainer

            video.save_to(path, format=VideoContainer.MP4, codec=VideoCodec.H264)
            if not _service_can_take(*_stream_layout(path)):
                video.save_to(path, format=VideoContainer.MP4, codec=VideoCodec.H264, crf=18)
        except Exception as exc:
            raise MerakError(
                f"could not encode the reference video ({type(exc).__name__}: {exc})"
            ) from None
        with open(path, "rb") as handle:
            return handle.read()


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
    """Submit a prompt — with keyframes and/or references, if connected — wait,
    then save the video into ComfyUI's output directory.

    What is connected decides the task: nothing is text-to-video, a first
    and/or last keyframe is image-to-video, and any reference image or video
    is reference-to-video (keyframes may join it). Returns the clip both as a
    VIDEO, for nodes that take one, and as the path on disk.
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
                "reference_images": (
                    "IMAGE",
                    {
                        "tooltip": (
                            f"subject/style references, up to {MAX_REFERENCE_IMAGES} as a "
                            "batch; write <Picture 1>, <Picture 2>… in the prompt, in batch order"
                        )
                    },
                ),
                "reference_video": (
                    "VIDEO",
                    {
                        "tooltip": (
                            "one motion/scene reference of 2–15 s; write <Video 1> in the prompt"
                        )
                    },
                ),
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
                # Appended LAST on purpose: ComfyUI stores widget values by
                # position, so a widget added anywhere else would shift every
                # value in every saved workflow.
                "model": (
                    list(MODELS),
                    {"default": DEFAULT_MODEL, "tooltip": "Fast and Draft trade quality for speed"},
                ),
            },
        }

    def generate(
        self,
        prompt,
        team_id,
        clip,
        first_frame=None,
        last_frame=None,
        reference_images=None,
        reference_video=None,
        aspect_ratio=DEFAULT_ASPECT_RATIO,
        seed=-1,
        timeout_s=DEFAULT_TIMEOUT_S,
        filename_prefix=DEFAULT_FILENAME_PREFIX,
        model=DEFAULT_MODEL,
    ):
        key, team = _resolve(team_id)
        # The request's own fields and the model menu are checked BEFORE any
        # media is encoded or uploaded, so a bad clip or an unserved model costs
        # nothing. Then media goes up: the submit that names it is the metered
        # call, and it is not made until everything is READY.
        check_request(prompt, clip, model, aspect_ratio)
        resolution, frames = CLIPS[clip]
        workload_id = resolve_workload(key, team, MODELS[model], resolution, frames)
        media = [
            (role, 0, encode_keyframe(image, role.lower()), IMAGE_CONTENT_TYPE)
            for role, image in zip(KEYFRAME_ROLES, (first_frame, last_frame), strict=True)
            if image is not None
        ]
        if reference_images is not None:
            media.extend(
                (REFERENCE_IMAGE_ROLE, position, data, IMAGE_CONTENT_TYPE)
                for position, data in enumerate(encode_reference_images(reference_images))
            )
        if reference_video is not None:
            media.append(
                (REFERENCE_VIDEO_ROLE, 0, encode_reference_video(reference_video), VIDEO_CONTENT_TYPE)
            )
        inputs = upload_inputs(key, team, media)
        job = submit(
            key,
            team,
            prompt=prompt,
            clip=clip,
            model=model,
            aspect_ratio=aspect_ratio,
            seed=int(seed),
            inputs=inputs,
            workload_id=workload_id,
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
