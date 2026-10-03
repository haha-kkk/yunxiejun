"""离线验证 T09 工具的计费边界和失败路径；不会请求真实 API。"""

import contextlib
import importlib.util
import io
import json
from pathlib import Path
import socket
import tempfile
import unittest
from unittest.mock import Mock, patch
from urllib.error import HTTPError
import wave


spec = importlib.util.spec_from_file_location(
    "bailian_sample", Path(__file__).resolve().parents[2] / "Scripts" / "check-bailian.py")
sample = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sample)


def response(text="十五元，不是五十元。", finish="stop"):
    return {"choices": [{"message": {"content": text}, "finish_reason": finish}],
            "usage": {"seconds": 20, "prompt_tokens": 650, "completion_tokens": 120}}


class BailianSampleTests(unittest.TestCase):
    def test_valid_and_invalid_responses(self):
        self.assertEqual(sample.parse_result(response())["text"], "十五元，不是五十元。")
        for body in (None, {}, {"choices": []}, {"choices": [None]}, response(" "),
                     response([], "stop"), response("a" * 4097), response(finish="length"),
                     response(finish="content_filter")):
            with self.subTest(body=str(body)[:50]), self.assertRaises(sample.CheckError):
                sample.parse_result(body)

    def test_missing_usage_is_unknown_not_free(self):
        result = sample.parse_result({"choices": response()["choices"]})
        self.assertIsNone(sample.estimate_cost(result, result))
        result = sample.parse_result(response())
        self.assertAlmostEqual(sample.estimate_cost(result, result), 0.004626)

    def test_payloads_preserve_mixed_language_and_disable_thinking(self):
        asr = sample.asr_payload("data:audio/wav;base64,AA==")
        self.assertEqual(asr["model"], "qwen3-asr-flash")
        self.assertNotIn("language", asr["asr_options"])
        cleaned = sample.text_payload("请在十月三号前完成，先不要发布。")
        self.assertFalse(cleaned["enable_thinking"])
        self.assertEqual(cleaned["max_completion_tokens"], 512)
        for text in (" ", "中" * 1366):
            with self.assertRaises(sample.CheckError):
                sample.text_payload(text)

    def test_budget_survives_reopening_and_stops_at_one_yuan(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "budget"
            for i in range(10):
                self.assertEqual(sample.reserve_attempt(path), round((i + 1) / 10, 2))
            with self.assertRaises(sample.CheckError):
                sample.reserve_attempt(path)
            self.assertEqual(len(path.read_text().splitlines()), 10)
            path.write_text("0.10\nbroken")
            with self.assertRaises(sample.CheckError):
                sample.reserve_attempt(path)

    def test_locked_budget_does_not_allow_another_reservation(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "budget"
            with path.open("wb") as locked:
                sample.fcntl.flock(locked.fileno(), sample.fcntl.LOCK_EX)
                with self.assertRaises(BlockingIOError):
                    sample.reserve_attempt(path)
            self.assertEqual(path.read_bytes(), b"")
            self.assertEqual(sample.reserve_attempt(path), 0.1)

    def test_audio_duration_and_truncation(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "sample.wav"
            for seconds in (0, 1, 31):
                with wave.open(str(path), "wb") as out:
                    out.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
                    out.writeframes(b"\0\0" * (16000 * seconds))
                if seconds == 1:
                    uri, duration = sample.read_audio(path)
                    self.assertTrue(uri.startswith("data:audio/wav;base64,"))
                    self.assertEqual(duration, 1)
                    path.write_bytes(path.read_bytes()[:-10])
                with self.assertRaises(sample.CheckError):
                    sample.read_audio(path)

    def test_http_errors_and_timeout_have_no_retry_or_secret_output(self):
        for issue in (HTTPError(sample.ENDPOINT, 401, "secret-test-key", {}, io.BytesIO(b"secret-test-key")),
                      socket.timeout("secret-test-key")):
            opener = Mock()
            opener.open.side_effect = issue
            with self.assertRaises(sample.CheckError) as raised:
                sample.call_api("secret-test-key", sample.text_payload("测试"), opener)
            self.assertNotIn("secret-test-key", str(raised.exception))
            self.assertEqual(opener.open.call_count, 1)

    def test_redirect_is_rejected(self):
        with self.assertRaises(sample.CheckError):
            sample.NoRedirect().redirect_request(None, None, 307, "", {}, "https://example.com/")

    def test_response_does_not_persist_key_or_unknown_fields(self):
        body = response("secret-test-key")
        body["usage"]["unexpected"] = "secret-test-key"
        opener = Mock()
        opener.open.return_value = contextlib.closing(io.BytesIO(json.dumps(body).encode()))
        result = sample.call_api("secret-test-key", sample.text_payload("测试"), opener)
        self.assertNotIn("secret-test-key", json.dumps(result))

    def test_first_failure_stops_and_second_failure_preserves_transcript(self):
        for results, count in (([sample.CheckError("识别失败")], 1),
                               ([sample.parse_result(response()), sample.CheckError("整理失败")], 2)):
            with tempfile.TemporaryDirectory() as temp, contextlib.redirect_stdout(io.StringIO()), \
                    patch.object(sample, "OUTPUT", Path(temp)), \
                    patch.object(sample, "prepare_audio", return_value=("audio", 20)), \
                    patch.object(sample, "read_key", return_value="secret-test-key"), \
                    patch.object(sample, "call_api", side_effect=results) as calls, \
                    patch.object(sample.sys, "argv", ["check-bailian.py"]):
                with self.assertRaises(sample.CheckError):
                    sample.main()
                self.assertEqual(calls.call_count, count)
                report = next(Path(temp).glob("report-*.json")).read_text()
                self.assertNotIn("secret-test-key", report)
                self.assertEqual(json.loads(report)["status"], "incomplete")
                self.assertEqual("asr" in json.loads(report), count == 2)

    def test_prepare_only_cannot_read_key_or_call_api(self):
        with contextlib.redirect_stdout(io.StringIO()), \
                patch.object(sample, "prepare_audio", return_value=("audio", 20)), \
                patch.object(sample, "read_key") as key, patch.object(sample, "call_api") as api, \
                patch.object(sample.sys, "argv", ["check-bailian.py", "--prepare-only"]):
            self.assertEqual(sample.main(), 0)
            key.assert_not_called()
            api.assert_not_called()


if __name__ == "__main__":
    unittest.main()
