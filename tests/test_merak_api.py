"""Unit tests for the API client's request shaping. Standard library only:
`python -m unittest discover -s tests -t .` from the repository root."""

import io
import json
import unittest
import urllib.error
from unittest import mock

import merak_api

# `merak_nodes` imports its sibling relatively (it is a ComfyUI package); alias the
# package so the node module is importable here without ComfyUI.
import importlib, sys, types  # noqa: E402
_pkg = types.ModuleType("merak_comfyui_node"); _pkg.__path__ = [str(__import__("pathlib").Path(__file__).resolve().parents[1])]
sys.modules["merak_comfyui_node"] = _pkg
sys.modules["merak_comfyui_node.merak_api"] = merak_api
merak_nodes = importlib.import_module("merak_comfyui_node.merak_nodes")

MENU = [
    {
        "workload_id": "w" * 32,
        "model_id": 3,
        "display_name": "H3 Draft",
        "clips": [{"resolution": "P480", "frames": 243}, {"resolution": "P480", "frames": 22}],
    }
]


class TaskFor(unittest.TestCase):
    def test_nothing_is_text_to_video(self):
        self.assertEqual(merak_api.task_for([]), "T2V")

    def test_a_keyframe_is_image_to_video(self):
        self.assertEqual(merak_api.task_for([{"role": "LAST_FRAME"}]), "I2V")

    def test_any_reference_is_reference_to_video(self):
        for role in ("REFERENCE_IMAGE", "REFERENCE_VIDEO"):
            inputs = [{"role": "FIRST_FRAME"}, {"role": role}]
            self.assertEqual(merak_api.task_for(inputs), "R2V", role)


class Submit(unittest.TestCase):
    def test_body_names_the_workload_and_no_steps(self):
        calls = []

        def fake_request(path, api_key, method="GET", body=None, **_kwargs):
            calls.append((method, path, body))
            return MENU if path.endswith("/models") else {"job_id": "j" * 32}

        inputs = [
            {"role": "REFERENCE_IMAGE", "input_id": "a" * 32, "position": 1},
            {"role": "REFERENCE_IMAGE", "input_id": "b" * 32, "position": 0},
        ]
        with mock.patch.object(merak_api, "_request", fake_request):
            merak_api.submit(
                "key", "team", prompt="<Picture 1> and <Picture 2>", clip=next(iter(merak_api.CLIPS)),
                model="H3 Draft", inputs=inputs,
            )
        method, path, body = calls[-1]
        self.assertEqual((method, path), ("POST", "/v1/teams/team/video_inferences"))
        self.assertEqual(body["workload_id"], "w" * 32)
        self.assertEqual(body["model_id"], 3)
        self.assertEqual(body["task"], "R2V")
        self.assertEqual(body["inputs"], inputs)
        self.assertNotIn("steps", body)
        self.assertNotIn("seed", body)

    def test_a_clip_the_model_does_not_serve_is_refused_before_submit(self):
        def fake_request(path, api_key, method="GET", body=None, **_kwargs):
            if method == "POST":
                raise AssertionError("submitted anyway")
            return MENU

        with mock.patch.object(merak_api, "_request", fake_request), self.assertRaises(
            merak_api.MerakError
        ) as caught:
            merak_api.submit(
                "key", "team", prompt="p", clip="720p · 243 frames (~10.1 s)", model="H3 Draft"
            )
        self.assertIn("does not serve", str(caught.exception))

    def test_a_resolved_workload_id_skips_the_menu(self):
        calls = []

        def fake_request(path, api_key, method="GET", body=None, **_kwargs):
            calls.append(path)
            return {"job_id": "j" * 32}

        with mock.patch.object(merak_api, "_request", fake_request):
            merak_api.submit(
                "key", "team", prompt="p", clip=next(iter(merak_api.CLIPS)), workload_id="w" * 32
            )
        self.assertEqual(calls, ["/v1/teams/team/video_inferences"])

    def test_each_submit_sends_its_own_idempotency_key(self):
        keys = []

        def fake_request(path, api_key, method="GET", body=None, **_kwargs):
            keys.append(body["idempotency_key"])
            return {"job_id": "j" * 32}

        with mock.patch.object(merak_api, "_request", fake_request):
            for _ in range(2):
                merak_api.submit(
                    "key", "team", prompt="p", clip=next(iter(merak_api.CLIPS)), workload_id="w" * 32
                )
        for key in keys:
            self.assertRegex(key, r"^[0-9a-f]{32}$")
        self.assertNotEqual(keys[0], keys[1])

    def test_check_request_needs_no_network(self):
        with mock.patch.object(merak_api, "_request", side_effect=AssertionError("network")):
            self.assertEqual(merak_api.check_request("  hi ", next(iter(merak_api.CLIPS)), "H3", "16:9"), "hi")
            for bad in (dict(prompt=""), dict(clip="4k"), dict(model="H2"), dict(aspect_ratio="2:1")):
                args = {"prompt": "p", "clip": next(iter(merak_api.CLIPS)), "model": "H3", "aspect_ratio": "16:9", **bad}
                with self.assertRaises(merak_api.MerakError):
                    merak_api.check_request(**args)

    def test_unknown_model_is_refused(self):
        with self.assertRaises(merak_api.MerakError):
            merak_api.submit("key", "team", prompt="p", clip=next(iter(merak_api.CLIPS)), model="H2")


def _fake_open(outcomes):
    """An `_opener.open` stand-in: each call takes the next outcome, raising it
    if it is an exception, else answering it as the JSON body."""
    sent = []

    def fake_open(request, timeout):  # noqa: ARG001
        sent.append(request)
        outcome = outcomes.pop(0)
        if isinstance(outcome, Exception):
            raise outcome
        return io.BytesIO(json.dumps(outcome).encode())

    return sent, fake_open


class Retry(unittest.TestCase):
    def test_a_dropped_submit_is_retried_with_the_same_key(self):
        sent, fake_open = _fake_open([ConnectionResetError("reset"), {"job_id": "j" * 32}])
        with mock.patch.object(merak_api._opener, "open", fake_open), mock.patch.object(
            merak_api.time, "sleep"
        ):
            created = merak_api.submit(
                "key", "team", prompt="p", clip=next(iter(merak_api.CLIPS)), workload_id="w" * 32
            )
        self.assertEqual(created["job_id"], "j" * 32)
        keys = [json.loads(request.data)["idempotency_key"] for request in sent]
        self.assertEqual(len(keys), 2)
        self.assertEqual(keys[0], keys[1])

    def test_any_other_post_is_sent_once(self):
        sent, fake_open = _fake_open([ConnectionResetError("reset")])
        with mock.patch.object(merak_api._opener, "open", fake_open), mock.patch.object(
            merak_api.time, "sleep"
        ), self.assertRaises(merak_api.MerakUnavailable):
            merak_api._request("/v1/teams/t/video_inferences/inputs", "key", method="POST", body={})
        self.assertEqual(len(sent), 1)


class OutputUrl(unittest.TestCase):
    def test_the_delivery_route_is_named_by_job_id(self):
        def fake_open(request, timeout):  # noqa: ARG001
            raise urllib.error.HTTPError(
                request.full_url, 302, "Found", {"Location": "https://storage/v.mp4"}, None
            )

        with mock.patch.object(merak_api._opener, "open", side_effect=fake_open) as opened:
            url = merak_api.output_url("key", "team", {"job_id": "j" * 32})
        self.assertEqual(url, "https://storage/v.mp4")
        self.assertTrue(
            opened.call_args.args[0].full_url.endswith(f"/v1/teams/team/video_inferences/{'j' * 32}/output")
        )


class Upload(unittest.TestCase):
    def test_size_caps_follow_the_media_type(self):
        with mock.patch.object(merak_api, "_request", side_effect=AssertionError("sent")):
            with self.assertRaises(merak_api.MerakError):
                merak_api.upload_input("k", "t", b"x" * (merak_api.MAX_IMAGE_BYTES + 1), "image/png")
            with self.assertRaises(merak_api.MerakError):
                merak_api.upload_input("k", "t", b"x" * (merak_api.MAX_VIDEO_BYTES + 1), "video/mp4")

    def test_upload_inputs_keeps_role_and_position(self):
        with mock.patch.object(merak_api, "upload_input", side_effect=["1" * 32, "2" * 32]):
            inputs = merak_api.upload_inputs(
                "k", "t", [("REFERENCE_IMAGE", 1, b"a", "image/png"), ("REFERENCE_VIDEO", 0, b"b", "video/mp4")]
            )
        self.assertEqual(
            inputs,
            [
                {"role": "REFERENCE_IMAGE", "input_id": "1" * 32, "position": 1},
                {"role": "REFERENCE_VIDEO", "input_id": "2" * 32, "position": 0},
            ],
        )


if __name__ == "__main__":
    unittest.main()


class ReferenceVideoStreams(unittest.TestCase):
    def test_service_layout_rule(self):
        ok = merak_nodes._service_can_take
        self.assertTrue(ok(1, []))
        self.assertTrue(ok(1, ["aac"]))
        self.assertTrue(ok(1, ["mp3float"]))
        self.assertFalse(ok(1, ["opus"]))
        self.assertFalse(ok(1, ["aac", "aac"]))
        self.assertFalse(ok(2, ["aac"]))
