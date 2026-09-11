"""Unit tests for the API client's request shaping. Standard library only:
`python -m unittest discover -s tests -t .` from the repository root."""

import unittest
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
            return MENU if path.endswith("/models") else {"video_inference_id": "j" * 32}

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
            return {"video_inference_id": "j" * 32}

        with mock.patch.object(merak_api, "_request", fake_request):
            merak_api.submit(
                "key", "team", prompt="p", clip=next(iter(merak_api.CLIPS)), workload_id="w" * 32
            )
        self.assertEqual(calls, ["/v1/teams/team/video_inferences"])

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
