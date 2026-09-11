"""Client for the merak video API. Standard library only, and free of ComfyUI."""

from __future__ import annotations

import contextlib
import hashlib
import http.client
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import PurePosixPath

# Reported in the User-Agent on every request.
VERSION = "1.1.0"

# Override with MERAK_BASE_URL to point the node at another deployment.
BASE_URL = os.environ.get("MERAK_BASE_URL", "").strip() or "https://api.merakcompute.ai"

# Where the key comes from. A value typed into a node widget is written into the
# workflow JSON in clear text, and ComfyUI embeds that workflow in the metadata
# of images a graph saves, so the node has no field for it.
API_KEY_ENV = "MERAK_API_KEY"
API_KEY_FILE = os.path.join(os.path.expanduser("~"), ".merak", "api_key")

# The clips the service serves; the first is the default. The 22-frame one is
# below MiniMax-H3's own 5-15 s specification.
CLIPS: dict[str, tuple[str, int]] = {
    "480p · 243 frames (~10.1 s)": ("P480", 243),
    "720p · 243 frames (~10.1 s)": ("P720", 243),
    "480p · 22 frames (~0.9 s — off-spec)": ("P480", 22),
}

# The canvas a keyframe is fitted to.
ASPECT_RATIOS: dict[str, str] = {"16:9": "LANDSCAPE", "9:16": "PORTRAIT", "1:1": "SQUARE"}
DEFAULT_ASPECT_RATIO = "16:9"

# The models the service serves, by the id the API takes; the first is the
# default. Steps are fixed per model server-side, so none are sent.
MODELS: dict[str, int] = {"H3": 1, "H3 Fast": 2, "H3 Draft": 3}
DEFAULT_MODEL = "H3"

# The API's own bound on `prompt`, mirrored so a violation costs no round trip.
MAX_PROMPT_CHARS = 7000

DEFAULT_TIMEOUT_S = 3600
POLL_INTERVAL_S = 5
UPLOAD_TIMEOUT_S = 300
DOWNLOAD_TIMEOUT_S = 300

# States arrive as uppercase names.
TERMINAL_STATES = frozenset({"SUCCEEDED", "FAILED", "CANCELLED"})
SUCCESS_STATE = "SUCCEEDED"
ACTIVE_STATES = frozenset({"ASSIGNED", "RUNNING"})

# A clip can be conditioned on a first keyframe, a last keyframe, or both
# (image-to-video), and on reference images and one reference video
# (reference-to-video). A reference position N is `<Picture N+1>` or
# `<Video N+1>` in the prompt.
KEYFRAME_ROLES = ("FIRST_FRAME", "LAST_FRAME")
REFERENCE_IMAGE_ROLE = "REFERENCE_IMAGE"
REFERENCE_VIDEO_ROLE = "REFERENCE_VIDEO"
REFERENCE_ROLES = (REFERENCE_IMAGE_ROLE, REFERENCE_VIDEO_ROLE)
MAX_REFERENCE_IMAGES = 9
IMAGE_CONTENT_TYPE = "image/png"
VIDEO_CONTENT_TYPE = "video/mp4"
MAX_IMAGE_BYTES = 30 * 1024 * 1024
MAX_VIDEO_BYTES = 50 * 1024 * 1024
# What the service accepts for a reference video, in seconds.
REFERENCE_VIDEO_SECONDS = (2.0, 15.0)

_USER_AGENT = f"comfyui-merak-video/{VERSION}"
_TRANSIENT = (
    urllib.error.URLError,
    http.client.RemoteDisconnected,
    ConnectionResetError,
    TimeoutError,
)
# Answers that mean "ask again later". A poll runs for as long as a render does,
# so one of these must not end a render that is still going.
_RETRYABLE_STATUSES = frozenset({408, 429})
_MAX_RETRY_AFTER_S = 60


class MerakError(RuntimeError):
    pass


class MerakUnavailable(MerakError):
    """The API could not be reached or could not answer.

    Means "ask again". A 4xx is an answer, and asking again cannot change it.
    """


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """Never follow a redirect automatically.

    urllib's default handler copies the request's headers onto the redirected
    request — it strips only Content-Length and Content-Type — so a 3xx would
    replay `X-Api-Key` at whatever host `Location` names. Returning None leaves
    the 3xx to surface as an HTTPError the caller can inspect.
    """

    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: ARG002
        return None  # the signature is urllib's, not ours


# Every credentialed request goes through this opener. `download` does not: it
# carries no credential, and a presigned link is allowed to redirect.
_opener = urllib.request.build_opener(_NoRedirect)


def _error(exc: urllib.error.HTTPError) -> MerakError:
    kind = (
        MerakUnavailable
        if exc.code >= 500 or exc.code in _RETRYABLE_STATUSES
        else MerakError
    )
    raw = b""
    try:
        raw = exc.read()
    except Exception:
        raw = b""
    try:
        detail = json.loads(raw).get("detail")
    except Exception:
        detail = None
    if isinstance(detail, dict):
        return kind(f"HTTP {exc.code} {detail.get('code')}: {detail.get('message')}")
    if detail:
        return kind(f"HTTP {exc.code}: {detail}")
    # Not every error body is JSON. Show what arrived.
    text = raw.decode("utf-8", "replace").strip() if raw else str(exc.reason)
    if len(text) > 400:
        text = text[:400] + "… (message truncated)"
    return kind(f"HTTP {exc.code}: {text}")


def _retry_delay(exc: urllib.error.HTTPError, attempt: int) -> float:
    """Honours `Retry-After` when the server sends a plain number of seconds."""
    header = exc.headers.get("Retry-After") if exc.headers else None
    try:
        return min(float(header), _MAX_RETRY_AFTER_S)
    except (TypeError, ValueError):
        return 2.0 * attempt


def _request(
    path: str,
    api_key: str,
    *,
    method: str = "GET",
    body: dict | None = None,
    timeout: int = 30,
    retries: int = 2,
) -> dict:
    """One API call, returning parsed JSON.

    Retries are for GETs ONLY. Creating a render is not idempotent and the route
    offers no idempotency key, so a retried POST bills a second render. A 4xx is
    an answer and is not retried, except the two that mean "later".
    """
    request = urllib.request.Request(
        BASE_URL.rstrip("/") + path,
        data=json.dumps(body).encode() if body is not None else None,
        headers={
            # NOT `Authorization: Bearer` — the API reads that as a JWT, so a key
            # sent that way fails as a malformed token rather than as a bad key.
            "X-Api-Key": api_key,
            "Content-Type": "application/json",
            "Accept": "application/json",
            "User-Agent": _USER_AGENT,
        },
        method=method,
    )
    attempt = 0
    while True:
        try:
            with _opener.open(request, timeout=timeout) as response:
                return json.loads(response.read())
        except urllib.error.HTTPError as exc:
            retryable = exc.code >= 500 or exc.code in _RETRYABLE_STATUSES
            if method == "GET" and retryable and attempt < retries:
                attempt += 1
                time.sleep(_retry_delay(exc, attempt))
                continue
            raise _error(exc) from None
        except _TRANSIENT as exc:
            if method == "GET" and attempt < retries:
                attempt += 1
                time.sleep(2 * attempt)
                continue
            raise MerakUnavailable(f"connection failed ({type(exc).__name__}): {exc}") from None


def resolve_api_key() -> str:
    """`MERAK_API_KEY`, then `~/.merak/api_key`."""
    from_env = os.environ.get(API_KEY_ENV, "").strip()
    if from_env:
        return from_env
    try:
        with open(API_KEY_FILE, encoding="utf-8") as handle:
            return handle.read().strip()
    except OSError:
        return ""


def resolve_team_id(api_key: str) -> str:
    """The team this key submits against.

    The team is a path segment, so when it is not supplied it is derived from the
    key: the one team the account owns. Ownership is the access rule, and
    ambiguity is reported rather than guessed, since a render is billed to the
    team that ran it.
    """
    try:
        teams = _request("/v1/users/me", api_key).get("teams") or []
    except MerakError as failure:
        if "KEY_SCOPE_FORBIDDEN" in str(failure):
            raise MerakError(
                "this key is scoped to inference only, so it cannot look up which team "
                "it belongs to — set team_id on the node (find it in the merak console "
                "URL, or on the team page)"
            ) from None
        raise
    owned = [team for team in teams if team.get("role") == "OWNER"]
    if len(owned) == 1:
        return owned[0]["team_id"]
    if not owned:
        raise MerakError(
            "this key's account owns no team — inference requires you to OWN the team "
            "(being a member of someone else's is not enough)"
        )
    listed = ", ".join(f"{team['team_id']} ({team['name']})" for team in owned)
    raise MerakError(f"this account owns several teams — set team_id to one of: {listed}")


def task_for(inputs: list[dict]) -> str:
    """Which task a set of uploaded inputs asks for: a reference makes it
    reference-to-video, a keyframe alone image-to-video, none text-to-video."""
    roles = {item["role"] for item in inputs}
    if roles & set(REFERENCE_ROLES):
        return "R2V"
    return "I2V" if roles else "T2V"


def resolve_workload(api_key: str, team_id: str, model_id: int, resolution: str, frames: int) -> str:
    """The `workload_id` a submit must name, from the team's model menu.

    The menu is the one place the pairing lives, and it also says whether the
    model serves the requested clip, so a clip it does not serve is refused
    here rather than as a 422 after the uploads.
    """
    menu = _request(f"/v1/teams/{team_id}/video_inferences/models", api_key)
    for model in menu if isinstance(menu, list) else menu.get("items") or []:
        if model.get("model_id") != model_id:
            continue
        served = {(clip.get("resolution"), clip.get("frames")) for clip in model.get("clips") or []}
        if (resolution, frames) not in served:
            raise MerakError(
                f"{model.get('display_name') or model_id} does not serve {resolution} × "
                f"{frames} frames — choose another clip"
            )
        return model["workload_id"]
    raise MerakError(f"model {model_id} is not on this team's model menu right now")


def check_request(prompt: str, clip: str, model: str, aspect_ratio: str) -> str:
    """The request's own fields, checked before any media is encoded or uploaded
    so a bad one costs nothing. Returns the prompt as it will be sent."""
    prompt = (prompt or "").strip()
    if not prompt:
        raise MerakError("the prompt is empty")
    if len(prompt) > MAX_PROMPT_CHARS:
        raise MerakError(
            f"the prompt is {len(prompt)} characters — {len(prompt) - MAX_PROMPT_CHARS} "
            f"over the {MAX_PROMPT_CHARS} the API accepts. Shorten it and queue again; "
            "nothing was sent and nothing was truncated."
        )
    if clip not in CLIPS:
        raise MerakError(f"unknown clip {clip!r} — choose one of: {', '.join(CLIPS)}")
    if model not in MODELS:
        raise MerakError(f"unknown model {model!r} — choose one of: {', '.join(MODELS)}")
    if aspect_ratio not in ASPECT_RATIOS:
        raise MerakError(
            f"unknown aspect ratio {aspect_ratio!r} — choose one of: {', '.join(ASPECT_RATIOS)}"
        )
    return prompt


def submit(
    api_key: str,
    team_id: str,
    *,
    prompt: str,
    clip: str,
    model: str = DEFAULT_MODEL,
    aspect_ratio: str = DEFAULT_ASPECT_RATIO,
    seed: int = -1,
    inputs: list[dict] | None = None,
    workload_id: str | None = None,
) -> dict:
    """Create one inference; returns the 202 body (state QUEUED).

    `inputs` are media already uploaded by `upload_inputs`; their roles decide
    the task (see `task_for`). Pass the `workload_id` from `resolve_workload`
    when it was resolved before the uploads; otherwise it is resolved here.
    """
    prompt = check_request(prompt, clip, model, aspect_ratio)
    resolution, frames = CLIPS[clip]
    inputs = list(inputs or [])
    model_id = MODELS[model]
    if workload_id is None:
        workload_id = resolve_workload(api_key, team_id, model_id, resolution, frames)
    body: dict = {
        "workload_id": workload_id,
        "model_id": model_id,
        "task": task_for(inputs),
        "prompt": prompt,
        "frames": frames,
        "resolution": resolution,
        "aspect_ratio": ASPECT_RATIOS[aspect_ratio],
        "inputs": inputs,
    }
    # -1 means the server picks. 0 is a real seed.
    if seed >= 0:
        body["seed"] = seed
    return _request(
        f"/v1/teams/{team_id}/video_inferences", api_key, method="POST", body=body
    )


def upload_input(api_key: str, team_id: str, data: bytes, content_type: str) -> str:
    """Put one image or video where the renderer can fetch it; returns its `input_id`.

    Three legs, and only the ones that talk to merak carry the API key:

    1. DECLARE (authenticated) — type, length and MD5, for which the API signs a
       write-once PUT.
    2. PUT (NO credential) — the bytes go to object storage under that signature,
       with exactly the headers the grant names. They are part of the signature,
       and the storage host is a third party to your credential.
    3. COMPLETE (authenticated) — the server checks the stored object against the
       declaration. Only a READY input can be named in a submit.
    """
    if not data:
        raise MerakError("the input is empty")
    limit = MAX_VIDEO_BYTES if content_type.startswith("video/") else MAX_IMAGE_BYTES
    if len(data) > limit:
        raise MerakError(
            f"the input encodes to {len(data) / 1048576:.1f} MB, over the "
            f"{limit // 1048576} MB the API accepts. Scale it down or trim it; "
            "nothing was sent."
        )

    path = f"/v1/teams/{team_id}/video_inferences/inputs"
    declared = _request(
        path,
        api_key,
        method="POST",
        body={
            "content_type": content_type,
            "content_length": len(data),
            # An integrity checksum, not a security primitive — spelled out so
            # this still works on a FIPS build, where a bare md5() raises.
            "md5": hashlib.md5(data, usedforsecurity=False).hexdigest(),
        },
    )
    grant = declared["upload"]
    request = urllib.request.Request(
        grant["url"],
        data=data,
        method="PUT",
        headers={**(grant.get("headers") or {}), "User-Agent": _USER_AGENT},
    )
    try:
        with _opener.open(request, timeout=UPLOAD_TIMEOUT_S):
            pass
    except urllib.error.HTTPError as exc:
        # Storage answering, not merak: there is no error envelope to read.
        raise MerakError(f"the upload was refused by storage: HTTP {exc.code}") from None
    except _TRANSIENT as exc:
        raise MerakUnavailable(f"the upload failed ({type(exc).__name__}): {exc}") from None

    completed = _request(f"{path}/{declared['input_id']}/complete", api_key, method="POST")
    if completed.get("state") != "READY":
        raise MerakError(f"input {declared['input_id']} is {completed.get('state')}, not READY")
    return declared["input_id"]


def upload_inputs(api_key: str, team_id: str, media) -> list[dict]:
    """`media` is `(role, position, bytes, content_type)` tuples; returns the
    `inputs` list `submit` takes. Uploads happen before the submit, so a bad
    file is refused before anything is queued or billed."""
    inputs = []
    for role, position, data, content_type in media:
        input_id = upload_input(api_key, team_id, data, content_type)
        print(f"[merak] {role.lower()} {position} uploaded as input {input_id}")
        inputs.append({"role": role, "input_id": input_id, "position": position})
    return inputs


def poll(
    api_key: str,
    team_id: str,
    video_inference_id: str,
    *,
    timeout_s: int = DEFAULT_TIMEOUT_S,
    on_tick=None,
) -> dict:
    """Block until the inference reaches a terminal state, and return it.

    A FAILED POLL IS NOT A FAILED RENDER. The render continues server-side
    whether or not this process can reach the API, so an unreachable API costs a
    tick, not the render. The deadline is the only thing that ends this loop, and
    it covers queue time as well as render time. Timing out cancels nothing.
    """
    path = f"/v1/teams/{team_id}/video_inferences/{video_inference_id}"
    deadline = time.monotonic() + timeout_s
    while True:
        try:
            detail = _request(path, api_key)
        except MerakUnavailable as exc:
            print(f"[merak] poll failed, retrying in {POLL_INTERVAL_S}s: {exc}")
            if time.monotonic() >= deadline:
                raise
            time.sleep(POLL_INTERVAL_S)
            continue
        state = detail.get("state")
        if on_tick:
            on_tick(detail)
        if state in TERMINAL_STATES:
            if state != SUCCESS_STATE:
                raise MerakError(
                    f"inference {video_inference_id} {state}: "
                    f"{detail.get('error') or 'no reason reported'}"
                )
            return detail
        if time.monotonic() >= deadline:
            raise MerakError(
                f"inference {video_inference_id} still {state} after {timeout_s}s "
                f"(it is NOT cancelled — re-attach with Merak Fetch Video)"
            )
        time.sleep(POLL_INTERVAL_S)


def output_url(api_key: str, team_id: str, detail: dict) -> str:
    """The presigned link to the rendered video.

    A SUCCEEDED inference normally carries `output_url` already; the delivery
    route below covers one that arrives without it.
    """
    url = detail.get("output_url")
    if url:
        return url
    path = f"/v1/teams/{team_id}/video_inferences/{detail['video_inference_id']}/output"
    request = urllib.request.Request(
        BASE_URL.rstrip("/") + path,
        headers={"X-Api-Key": api_key, "User-Agent": _USER_AGENT},
    )
    try:
        with _opener.open(request, timeout=30) as response:
            raise MerakError(f"expected a redirect to the video, got HTTP {response.status}")
    except urllib.error.HTTPError as exc:
        if exc.code in (301, 302, 303, 307, 308):
            location = exc.headers.get("Location")
            if not location:
                raise MerakError("delivery redirect carried no Location") from None
            return location
        raise _error(exc) from None
    except _TRANSIENT as exc:
        raise MerakUnavailable(f"connection failed ({type(exc).__name__}): {exc}") from None


def download(url: str, dest: str) -> str:
    """Fetch the rendered video, WITH NO CREDENTIAL ATTACHED.

    Leg two of a two-leg download: `output_url` is leg one and it is
    authenticated — the API key is what buys the link. This only spends it. The
    presigned query string is the whole authorisation, storage rejects a request
    that also carries an `Authorization` header, and sending the API key to a
    third-party host would leak it. Nothing but a User-Agent goes out.

    Written to a `.part` file and moved into place once whole: a truncated file
    under the real name is indistinguishable from a finished render.
    """
    partial = dest + ".part"
    request = urllib.request.Request(url, headers={"User-Agent": _USER_AGENT})
    try:
        with urllib.request.urlopen(request, timeout=DOWNLOAD_TIMEOUT_S) as response, open(
            partial, "wb"
        ) as handle:
            while True:
                chunk = response.read(1 << 16)
                if not chunk:
                    break
                handle.write(chunk)
    except urllib.error.HTTPError as exc:
        _discard(partial)
        raise MerakError(f"the video download was refused by storage: HTTP {exc.code}") from None
    except (*_TRANSIENT, http.client.IncompleteRead, OSError) as exc:
        _discard(partial)
        raise MerakUnavailable(f"the video download failed ({type(exc).__name__}): {exc}") from None
    os.replace(partial, dest)
    return dest


def _discard(path: str) -> None:
    with contextlib.suppress(OSError):
        os.unlink(path)


def extension(url: str) -> str:
    """`.mp4` or `.webm`, read off the link so the saved name matches the bytes."""
    suffix = PurePosixPath(urllib.parse.urlparse(url).path).suffix
    return suffix if suffix in (".mp4", ".webm") else ".mp4"
