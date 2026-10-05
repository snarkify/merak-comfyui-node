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
        "capability_id": 3,
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


class ResolveTeam(unittest.TestCase):
    def test_the_only_active_team_is_selected_for_every_member_role(self):
        for role in ("OWNER", "ADMIN", "MEMBER"):
            with self.subTest(role=role), mock.patch.object(
                merak_api, "_request",
                return_value={"teams": [{"team_id": "t" * 32, "name": "Video", "role": role}]},
            ) as requested:
                self.assertEqual(merak_api.resolve_team_id("key"), "t" * 32)
                requested.assert_called_once_with("/v1/users/me", "key")

    def test_the_existing_owned_team_default_is_preserved(self):
        teams = [
            {"team_id": "a" * 32, "name": "Personal", "role": "OWNER"},
            {"team_id": "b" * 32, "name": "Shared", "role": "MEMBER"},
        ]
        with mock.patch.object(merak_api, "_request", return_value={"teams": teams}):
            self.assertEqual(merak_api.resolve_team_id("key"), "a" * 32)

    def test_ambiguous_memberships_need_an_explicit_team(self):
        for role in ("OWNER", "MEMBER"):
            teams = [
                {"team_id": "a" * 32, "name": "First", "role": role},
                {"team_id": "b" * 32, "name": "Second", "role": role},
            ]
            with self.subTest(role=role), mock.patch.object(
                merak_api, "_request", return_value={"teams": teams}
            ):
                with self.assertRaisesRegex(merak_api.MerakError, "set team_id") as caught:
                    merak_api.resolve_team_id("key")
            self.assertIn("First", str(caught.exception))
            self.assertIn("Second", str(caught.exception))

    def test_no_membership_reports_an_active_team_is_needed(self):
        with mock.patch.object(merak_api, "_request", return_value={"teams": []}):
            with self.assertRaisesRegex(merak_api.MerakError, "active team"):
                merak_api.resolve_team_id("key")


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
        self.assertEqual(calls[0][:2], ("GET", "/v1/teams/team/jobs/models"))
        self.assertEqual((method, path), ("POST", "/v1/teams/team/jobs"))
        self.assertEqual(body["workload_id"], "w" * 32)
        self.assertEqual(body["capability_id"], 3)
        self.assertEqual(body["job_type"], "VIDEO")
        self.assertEqual(body["request"], {
            "task": "R2V", "prompt": "<Picture 1> and <Picture 2>",
            "frames": 243, "resolution": "P480", "aspect_ratio": "LANDSCAPE",
        })
        self.assertEqual(body["inputs"], [item["input_id"] for item in inputs])
        self.assertNotIn("model_id", body)
        self.assertNotIn("steps", body["request"])
        self.assertNotIn("seed", body["request"])

    def test_seed_zero_is_sent_in_the_video_request(self):
        with mock.patch.object(merak_api, "_request", return_value={}) as requested:
            merak_api.submit(
                "key", "team", prompt="p", clip=next(iter(merak_api.CLIPS)),
                workload_id="w" * 32, seed=0,
            )
        self.assertEqual(requested.call_args.kwargs["body"]["request"]["seed"], 0)

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
        self.assertEqual(calls, ["/v1/teams/team/jobs"])

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

    def test_a_dropped_declaration_reuses_its_input_key(self):
        declared = [{"input_id": "1" * 32, "role": "FIRST_FRAME", "position": 0, "upload": {}}]
        completed = [{"outcome": "success", "input_id": "1" * 32, "input": {"state": "READY"}}]
        sent, fake_open = _fake_open([ConnectionResetError("reset"), declared, completed])
        with mock.patch.object(merak_api._opener, "open", fake_open), \
             mock.patch.object(merak_api.time, "sleep"), \
             mock.patch.object(merak_api, "_put"):
            merak_api.upload_inputs(
                "key", "team", [("FIRST_FRAME", 0, b"a", "image/png")],
                workload_id="w" * 32, model_id=1,
            )
        declarations = [json.loads(request.data) for request in sent[:2]]
        self.assertEqual(declarations[0], declarations[1])
        self.assertRegex(declarations[0]["inputs"][0]["idempotency_key"], r"^[0-9a-f]{32}$")
        self.assertEqual(sent[-1].full_url, merak_api.BASE_URL + "/v1/teams/team/jobs/inputs/complete")

    def test_any_other_post_is_sent_once(self):
        sent, fake_open = _fake_open([ConnectionResetError("reset")])
        with mock.patch.object(merak_api._opener, "open", fake_open), mock.patch.object(
            merak_api.time, "sleep"
        ), self.assertRaises(merak_api.MerakUnavailable):
            merak_api._request("/v1/teams/t/jobs/inputs", "key", method="POST", body={})
        self.assertEqual(len(sent), 1)

    def test_a_dropped_completion_reuses_the_input_ids(self):
        declared = [{"input_id": "1" * 32, "role": "FIRST_FRAME", "position": 0, "upload": {}}]
        completed = [{"outcome": "success", "input_id": "1" * 32, "input": {"state": "READY"}}]
        sent, fake_open = _fake_open([declared, ConnectionResetError("reset"), completed])
        with mock.patch.object(merak_api._opener, "open", fake_open), \
             mock.patch.object(merak_api.time, "sleep"), \
             mock.patch.object(merak_api, "_put"):
            inputs = merak_api.upload_inputs(
                "key", "team", [("FIRST_FRAME", 0, b"a", "image/png")],
                workload_id="w" * 32, model_id=1,
            )
        self.assertEqual(inputs[0]["input_id"], "1" * 32)
        self.assertEqual([json.loads(request.data) for request in sent[1:]], [
            {"input_ids": ["1" * 32]}, {"input_ids": ["1" * 32]},
        ])


class OutputUrl(unittest.TestCase):
    def test_the_delivery_route_names_the_video_output(self):
        def fake_open(request, timeout):  # noqa: ARG001
            raise urllib.error.HTTPError(
                request.full_url, 302, "Found", {"Location": "https://storage/v.mp4"}, None
            )

        with mock.patch.object(merak_api._opener, "open", side_effect=fake_open) as opened:
            url = merak_api.output_url("key", "team", {
                "job_id": "j" * 32,
                "outputs": [
                    {"output_id": "p" * 32, "role": "PROOF"},
                    {"output_id": "v" * 32, "role": "VIDEO"},
                ],
            })
        self.assertEqual(url, "https://storage/v.mp4")
        self.assertTrue(
            opened.call_args.args[0].full_url.endswith(
                f"/v1/teams/team/jobs/{'j' * 32}/outputs/{'v' * 32}"
            )
        )

    def test_a_job_without_a_video_output_is_refused(self):
        with mock.patch.object(merak_api._opener, "open", side_effect=AssertionError("network")):
            with self.assertRaisesRegex(merak_api.MerakError, "no video output"):
                merak_api.output_url("key", "team", {"job_id": "j" * 32, "outputs": []})


class Poll(unittest.TestCase):
    def test_reads_the_shared_job_route(self):
        detail = {"job_id": "j" * 32, "state": "SUCCEEDED"}
        with mock.patch.object(merak_api, "_request", return_value=detail) as requested:
            self.assertEqual(merak_api.poll("key", "team", detail["job_id"]), detail)
        requested.assert_called_once_with(f"/v1/teams/team/jobs/{'j' * 32}", "key")


class Upload(unittest.TestCase):
    MEDIA = [("REFERENCE_IMAGE", 1, b"a", "image/png"), ("REFERENCE_VIDEO", 0, b"b", "video/mp4")]

    def _upload(self, media):
        return merak_api.upload_inputs("k", "t", media, workload_id="w" * 32, model_id=1)

    def test_size_caps_follow_the_media_type(self):
        with mock.patch.object(merak_api, "_request", side_effect=AssertionError("sent")):
            for data, content_type in [
                (b"x" * (merak_api.MAX_IMAGE_BYTES + 1), "image/png"),
                (b"x" * (merak_api.MAX_VIDEO_BYTES + 1), "video/mp4"),
            ]:
                with self.assertRaises(merak_api.MerakError):
                    # The oversized file is refused before the valid one beside it is declared.
                    self._upload([self.MEDIA[0], ("REFERENCE_IMAGE", 2, data, content_type)])

    def test_no_media_sends_nothing(self):
        with mock.patch.object(merak_api, "_request", side_effect=AssertionError("sent")):
            self.assertEqual(self._upload([]), [])

    def test_one_declaration_for_every_file_keeps_role_and_position(self):
        declared = [
            {"input_id": "1" * 32, "role": "REFERENCE_IMAGE", "position": 1,
             "upload": {"url": "https://storage/1"}},
            {"input_id": "2" * 32, "role": "REFERENCE_VIDEO", "position": 0,
             "upload": {"url": "https://storage/2"}},
        ]
        completed = [
            {"outcome": "success", "input_id": row["input_id"], "input": {"state": "READY"}}
            for row in declared
        ]
        with mock.patch.object(
            merak_api, "_request", side_effect=[declared, completed]
        ) as requested, mock.patch.object(merak_api, "_put") as put:
            inputs = self._upload(self.MEDIA)

        path, _ = requested.call_args_list[0].args
        body = requested.call_args_list[0].kwargs["body"]
        self.assertEqual(path, "/v1/teams/t/jobs/inputs")
        self.assertEqual((body["workload_id"], body["capability_id"]), ("w" * 32, 1))
        keys = [item["idempotency_key"] for item in body["inputs"]]
        for key in keys:
            self.assertRegex(key, r"^[0-9a-f]{32}$")
        self.assertEqual(len(set(keys)), 2)
        self.assertTrue(requested.call_args_list[0].kwargs["idempotent"])
        self.assertEqual(len(requested.call_args_list), 2)
        self.assertEqual(requested.call_args_list[1].args, (path + "/complete", "k"))
        self.assertEqual(requested.call_args_list[1].kwargs["body"], {
            "input_ids": [row["input_id"] for row in declared],
        })
        self.assertTrue(requested.call_args_list[1].kwargs["idempotent"])
        self.assertEqual(
            [(item["role"], item["position"], item["content_type"]) for item in body["inputs"]],
            [("REFERENCE_IMAGE", 1, "image/png"), ("REFERENCE_VIDEO", 0, "video/mp4")],
        )
        self.assertEqual([call.args for call in put.call_args_list], [
            (declared[0]["upload"], b"a"),
            (declared[1]["upload"], b"b"),
        ])
        self.assertEqual(
            inputs,
            [
                {"role": "REFERENCE_IMAGE", "input_id": "1" * 32, "position": 1},
                {"role": "REFERENCE_VIDEO", "input_id": "2" * 32, "position": 0},
            ],
        )

    def test_a_partial_completion_failure_is_reported(self):
        declared = [
            {"input_id": "1" * 32, "role": "REFERENCE_IMAGE", "position": 1, "upload": {}},
            {"input_id": "2" * 32, "role": "REFERENCE_VIDEO", "position": 0, "upload": {}},
        ]
        completed = [
            {"outcome": "success", "input_id": "1" * 32, "input": {"state": "READY"}},
            {"outcome": "failure", "input_id": "2" * 32, "status_code": 409,
             "code": "INPUT_MISSING", "message": "input was not uploaded"},
        ]
        with mock.patch.object(merak_api, "_request", side_effect=[declared, completed]), \
             mock.patch.object(merak_api, "_put"):
            with self.assertRaisesRegex(merak_api.MerakError, "HTTP 409 INPUT_MISSING"):
                self._upload(self.MEDIA)

    def test_reordered_grants_are_matched_to_the_right_file(self):
        declared = [
            {"input_id": "2" * 32, "role": "REFERENCE_VIDEO", "position": 0, "upload": {"url": "video"}},
            {"input_id": "1" * 32, "role": "REFERENCE_IMAGE", "position": 1, "upload": {"url": "image"}},
        ]
        completed = [
            {"outcome": "success", "input_id": row["input_id"], "input": {"state": "READY"}}
            for row in declared
        ]
        with mock.patch.object(merak_api, "_request", side_effect=[declared, completed]), \
             mock.patch.object(merak_api, "_put") as put:
            inputs = self._upload(self.MEDIA)
        self.assertEqual([call.args for call in put.call_args_list], [
            ({"url": "image"}, b"a"), ({"url": "video"}, b"b"),
        ])
        self.assertEqual([item["input_id"] for item in inputs], ["1" * 32, "2" * 32])


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


class WorkflowCompatibility(unittest.TestCase):
    def test_the_example_outputs_match_the_node_sockets(self):
        from pathlib import Path

        workflow = json.loads(
            (Path(__file__).resolve().parents[1] / "examples" / "merak-video.json").read_text(encoding="utf-8")
        )
        node = next(row for row in workflow["nodes"] if row["type"] == "MerakGenerateVideo")
        expected = list(zip(
            merak_nodes.MerakGenerateVideo.RETURN_NAMES,
            merak_nodes.MerakGenerateVideo.RETURN_TYPES,
        ))
        self.assertEqual([(row["name"], row["type"]) for row in node["outputs"]], expected)
        self.assertEqual([row["slot_index"] for row in node["outputs"]], [0, 1])

    def test_saved_widget_and_input_names_remain_compatible(self):
        schema = merak_nodes.MerakGenerateVideo.INPUT_TYPES()
        fields = {**schema["required"], **schema["optional"]}
        sockets = [name for name, (kind, *_) in fields.items() if kind in ("IMAGE", "VIDEO")]
        widgets = [name for name in fields if name not in sockets]
        self.assertEqual(sockets, ["first_frame", "last_frame", "reference_images", "reference_video"])
        self.assertEqual(widgets, [
            "prompt", "team_id", "clip", "aspect_ratio", "seed", "timeout_s",
            "filename_prefix", "model",
        ])
        fetch = merak_nodes.MerakFetchVideo.INPUT_TYPES()
        self.assertEqual(list(fetch["required"]), ["video_inference_id", "team_id"])
        self.assertIn("job_id", fetch["required"]["video_inference_id"][1]["tooltip"])


class ProgressDisplay(unittest.TestCase):
    def test_integer_api_percentages_are_displayed_without_rounding_down(self):
        progress = merak_nodes._Progress()
        progress._bar = mock.Mock()
        for percentage in range(101):
            with self.subTest(percentage=percentage):
                progress.update({"state": "RUNNING", "progress_percentage": percentage})
                progress._bar.update_absolute.assert_called_with(percentage, 100)

    def test_queued_and_missing_progress_leave_the_bar_unchanged(self):
        progress = merak_nodes._Progress()
        progress._bar = mock.Mock()
        progress.update({"state": "QUEUED", "progress_percentage": None})
        progress.update({"state": "RUNNING", "progress_percentage": None})
        progress._bar.update_absolute.assert_not_called()
        progress.finish()
        progress._bar.update_absolute.assert_called_once_with(100, 100)
