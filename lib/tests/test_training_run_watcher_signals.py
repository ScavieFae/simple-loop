#!/usr/bin/env python3
"""Tests for training_run_watcher.py — stale / failed / preempted signal firing.

Each test mocks the relevant failure mode against a minimal project fixture
and asserts the correct signal file lands in .loop/state/signals/ with
all required fields.

Pass criteria: brief-121-cont cycles 4 (signals) and 5 (completion).
"""

import json
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parent.parent / "scouts"))
import training_run_watcher as scout


# ─── Fixtures ───────────────────────────────────────────────────────────────

_RUN_CARD_TEMPLATE = """\
---
run-id: {run_id}
type: training-run
policy: act
machine: modal:a10g
status: running
started-at: 2026-01-01T00:00:00Z
completed-at: TBD
---

# Run: {run_id}

## Receipts

| Field | Value |
|---|---|
| Modal app ID | `{app_id}` |
| Local log | `{log_path}` |
| Total steps completed | TBD (scout) |
| Final loss | TBD (scout) |

## Heartbeats

| ts | step | loss | log mtime | app state |
|---|---|---|---|---|

## Outcome

!!! warning "Fill post-run"
    Pending Mattie's rollout eye-check.
"""


def make_project(tmp: Path, run_id: str, app_id: str = "ap-test123",
                 log_path: str = None) -> tuple[Path, Path]:
    """Scaffold minimal project with one running run card. Returns (project_root, log_file)."""
    loop = tmp / ".loop" / "state"
    loop.mkdir(parents=True)
    signals_dir = tmp / ".loop" / "state" / "signals"
    signals_dir.mkdir(parents=True)

    log_file = Path(log_path) if log_path else tmp / "train.log"
    run_dir = tmp / "wiki" / "runs" / run_id
    run_dir.mkdir(parents=True)

    card = run_dir / "index.md"
    card.write_text(_RUN_CARD_TEMPLATE.format(
        run_id=run_id, app_id=app_id, log_path=str(log_file)
    ))
    return tmp, log_file


def write_log(log_file: Path, step: int = 1000, loss: float = 0.05,
              preemption: bool = False):
    """Write a minimal training log file."""
    lines = [
        f"INFO | step:{step} loss:{loss:.4f}",
        f"| {step}/50000 [01:00<10:00, 1.0it/s]",
    ]
    if preemption:
        lines.append("Runner interrupted due to worker preemption")
    log_file.parent.mkdir(parents=True, exist_ok=True)
    log_file.write_text("\n".join(lines))


def write_heartbeats(project_root: Path, run_id: str, entries: list[dict]):
    """Pre-populate heartbeats.jsonl with given entries."""
    sidecar = project_root / "wiki" / "runs" / run_id / "heartbeats.jsonl"
    with open(sidecar, "w") as f:
        for entry in entries:
            f.write(json.dumps(entry) + "\n")


# ─── Test: stale signal ──────────────────────────────────────────────────────

class TestStaleSignal(unittest.TestCase):

    def test_stale_signal_fires_with_required_fields(self):
        with tempfile.TemporaryDirectory() as d:
            tmp = Path(d)
            run_id = "test-stale-run"
            root, log_file = make_project(tmp, run_id)
            write_log(log_file, step=500, loss=0.08)

            # Age the log file past the stale threshold
            epoch = 1577836800  # 2020-01-01T00:00:00 — clearly stale
            os.utime(str(log_file), (epoch, epoch))

            with patch.object(scout, "check_modal_app_status", return_value="running"):
                scout.run(project_root=root)

            sig_path = root / ".loop" / "state" / "signals" / f"training-stale-{run_id}.json"
            self.assertTrue(sig_path.exists(), f"stale signal not written to {sig_path}")

            sig = json.loads(sig_path.read_text())
            self.assertEqual(sig["run_id"], run_id)
            self.assertIn("app_id", sig)
            self.assertIn("log_mtime", sig)
            self.assertIn("log_tail", sig)
            self.assertIn("suggested_action", sig)
            self.assertIsInstance(sig["log_tail"], list)
            self.assertIn("stall", sig["suggested_action"].lower())

    def test_stale_signal_rate_limited(self):
        """Second run within 30 min must not re-fire the signal."""
        with tempfile.TemporaryDirectory() as d:
            tmp = Path(d)
            run_id = "test-stale-ratelimit"
            root, log_file = make_project(tmp, run_id)
            write_log(log_file, step=100)
            epoch = 1577836800
            os.utime(str(log_file), (epoch, epoch))

            with patch.object(scout, "check_modal_app_status", return_value="running"):
                scout.run(project_root=root)
                mtime_first = (root / ".loop" / "state" / "signals" /
                               f"training-stale-{run_id}.json").stat().st_mtime
                # Second invocation immediately after — signal already exists
                time.sleep(0.05)
                scout.run(project_root=root)
                mtime_second = (root / ".loop" / "state" / "signals" /
                                f"training-stale-{run_id}.json").stat().st_mtime

            self.assertAlmostEqual(mtime_first, mtime_second, delta=1.0,
                                   msg="signal was re-written within rate-limit window")


# ─── Test: failed signal ─────────────────────────────────────────────────────

class TestFailedSignal(unittest.TestCase):

    def test_failed_signal_fires_with_required_fields(self):
        with tempfile.TemporaryDirectory() as d:
            tmp = Path(d)
            run_id = "test-failed-run"
            root, log_file = make_project(tmp, run_id, app_id="ap-failtest")
            write_log(log_file, step=2000, loss=0.03)
            # Fresh log — NOT stale (mtime = now)

            with patch.object(scout, "check_modal_app_status", return_value="failed"):
                scout.run(project_root=root)

            sig_path = root / ".loop" / "state" / "signals" / f"training-failed-{run_id}.json"
            self.assertTrue(sig_path.exists(), f"failed signal not written to {sig_path}")

            sig = json.loads(sig_path.read_text())
            self.assertEqual(sig["run_id"], run_id)
            self.assertEqual(sig["app_id"], "ap-failtest")
            self.assertIn("log_tail", sig)
            self.assertIn("suggested_action", sig)
            self.assertIn("failed", sig["suggested_action"].lower())

    def test_failed_signal_not_fired_when_running(self):
        """No failed signal if Modal says running (even if log is fresh)."""
        with tempfile.TemporaryDirectory() as d:
            tmp = Path(d)
            run_id = "test-running-run"
            root, log_file = make_project(tmp, run_id)
            write_log(log_file, step=300)

            with patch.object(scout, "check_modal_app_status", return_value="running"):
                scout.run(project_root=root)

            sig_path = root / ".loop" / "state" / "signals" / f"training-failed-{run_id}.json"
            self.assertFalse(sig_path.exists(), "failed signal should not fire for running app")


# ─── Test: preempted signal ──────────────────────────────────────────────────

class TestPreemptedSignal(unittest.TestCase):

    def test_preempted_signal_fires_with_required_fields(self):
        with tempfile.TemporaryDirectory() as d:
            tmp = Path(d)
            run_id = "test-preempted-run"
            root, log_file = make_project(tmp, run_id, app_id="ap-preempt")
            # Write a log that looks like post-preemption restart (step=0, preemption string)
            write_log(log_file, step=0, loss=0.12, preemption=True)
            # Fresh log — not stale

            # Pre-populate heartbeats with a high-step entry to trigger regression
            write_heartbeats(root, run_id, [
                {"ts": "2026-05-02T10:00:00Z", "last_step": 4200, "last_loss": 0.04,
                 "app_state": "running"},
            ])

            with patch.object(scout, "check_modal_app_status", return_value="running"):
                scout.run(project_root=root)

            sig_path = root / ".loop" / "state" / "signals" / f"training-preempted-{run_id}.json"
            self.assertTrue(sig_path.exists(), f"preempted signal not written to {sig_path}")

            sig = json.loads(sig_path.read_text())
            self.assertEqual(sig["run_id"], run_id)
            self.assertIn("wasted_steps", sig)
            self.assertIn("cost_estimate_usd", sig)
            self.assertIsInstance(sig["wasted_steps"], int)
            self.assertGreater(sig["wasted_steps"], 0)
            self.assertIsInstance(sig["cost_estimate_usd"], float)
            self.assertIn("suggested_action", sig)
            self.assertIn("preempt", sig["suggested_action"].lower())

    def test_preempted_requires_both_regression_and_log_string(self):
        """Step regression alone (no preemption string in log) must NOT fire preempted signal."""
        with tempfile.TemporaryDirectory() as d:
            tmp = Path(d)
            run_id = "test-regression-only"
            root, log_file = make_project(tmp, run_id)
            # Log has low step but NO preemption string
            write_log(log_file, step=0, loss=0.10, preemption=False)
            write_heartbeats(root, run_id, [
                {"ts": "2026-05-02T10:00:00Z", "last_step": 3000, "last_loss": 0.05,
                 "app_state": "running"},
            ])

            with patch.object(scout, "check_modal_app_status", return_value="running"):
                scout.run(project_root=root)

            sig_path = root / ".loop" / "state" / "signals" / f"training-preempted-{run_id}.json"
            self.assertFalse(sig_path.exists(),
                             "preempted signal should not fire without preemption string in log")

    def test_wasted_steps_and_cost_estimate_values(self):
        """wasted_steps = prev_step - current_step; cost_estimate uses A10G rate."""
        with tempfile.TemporaryDirectory() as d:
            tmp = Path(d)
            run_id = "test-cost-estimate"
            root, log_file = make_project(tmp, run_id, app_id="ap-cost")
            write_log(log_file, step=0, loss=0.10, preemption=True)
            write_heartbeats(root, run_id, [
                {"ts": "2026-05-02T10:00:00Z", "last_step": 3600, "last_loss": 0.05,
                 "app_state": "running"},
            ])

            with patch.object(scout, "check_modal_app_status", return_value="running"):
                scout.run(project_root=root)

            sig = json.loads((root / ".loop" / "state" / "signals" /
                              f"training-preempted-{run_id}.json").read_text())

            # 3600 wasted steps on A10G: 3600/3600 * 1.10 = $1.10
            self.assertEqual(sig["wasted_steps"], 3600)
            self.assertAlmostEqual(sig["cost_estimate_usd"], 1.10, places=1)


# ─── Test: watcher: off skips run ────────────────────────────────────────────

class TestWatcherOff(unittest.TestCase):

    def test_watcher_off_suppresses_all_signals(self):
        with tempfile.TemporaryDirectory() as d:
            tmp = Path(d)
            run_id = "test-watcher-off"
            root, log_file = make_project(tmp, run_id)

            # Override run card to include watcher: off
            run_card = root / "wiki" / "runs" / run_id / "index.md"
            text = run_card.read_text()
            text = text.replace("status: running\n", "status: running\nwatcher: off\n")
            run_card.write_text(text)

            write_log(log_file, step=100)
            epoch = 1577836800
            os.utime(str(log_file), (epoch, epoch))

            with patch.object(scout, "check_modal_app_status", return_value="failed"):
                result = scout.run(project_root=root)

            # watcher: off → checked=1 but no heartbeats or signals
            self.assertEqual(result["heartbeats_written"], 0)
            self.assertEqual(result["signals_fired"], [])


# ─── Test: completion handling ───────────────────────────────────────────────

class TestCompletion(unittest.TestCase):

    def test_completion_flips_status_and_populates_receipts(self):
        """Mock completed status → run card status: complete + Receipts filled."""
        with tempfile.TemporaryDirectory() as d:
            tmp = Path(d)
            run_id = "test-complete-run"
            root, log_file = make_project(tmp, run_id, app_id="ap-complete")
            write_log(log_file, step=50000, loss=0.008)

            with patch.object(scout, "check_modal_app_status", return_value="completed"):
                scout.run(project_root=root)

            text = (root / "wiki" / "runs" / run_id / "index.md").read_text()
            self.assertIn("status: complete", text)
            self.assertNotIn("status: running", text)
            self.assertIn("50000", text)
            self.assertIn("0.008", text)

    def test_completion_triggers_checkpoint_download(self):
        """Mock completed → checkpoint download script invoked with --run-id <run_id>."""
        with tempfile.TemporaryDirectory() as d:
            tmp = Path(d)
            run_id = "test-complete-download"
            root, log_file = make_project(tmp, run_id, app_id="ap-dl")
            write_log(log_file, step=50000, loss=0.008)

            script_path = root / "tools" / "training-ground" / "scripts" / "download_checkpoint.py"
            script_path.parent.mkdir(parents=True, exist_ok=True)
            script_path.write_text("#!/usr/bin/env python3\nimport sys; sys.exit(0)\n")

            with patch.object(scout, "check_modal_app_status", return_value="completed"), \
                 patch("training_run_watcher.subprocess.run") as mock_run:
                mock_run.return_value = unittest.mock.MagicMock(returncode=0, stdout="", stderr="")
                scout.run(project_root=root)

            self.assertTrue(mock_run.called, "download_checkpoint.py subprocess not called")
            called_cmd = mock_run.call_args[0][0]
            self.assertIn("--run-id", called_cmd)
            self.assertIn(run_id, called_cmd)

    def test_completion_download_failure_fires_stale_signal(self):
        """Failed checkpoint download → training-stale signal with cause: checkpoint-download-failed."""
        with tempfile.TemporaryDirectory() as d:
            tmp = Path(d)
            run_id = "test-complete-dl-fail"
            root, log_file = make_project(tmp, run_id, app_id="ap-dl-fail")
            write_log(log_file, step=50000, loss=0.008)

            script_path = root / "tools" / "training-ground" / "scripts" / "download_checkpoint.py"
            script_path.parent.mkdir(parents=True, exist_ok=True)
            script_path.write_text("#!/usr/bin/env python3\nimport sys; sys.exit(1)\n")

            with patch.object(scout, "check_modal_app_status", return_value="completed"), \
                 patch("training_run_watcher.subprocess.run") as mock_run:
                mock_run.return_value = unittest.mock.MagicMock(returncode=1, stdout="", stderr="err")
                scout.run(project_root=root)

            sig_path = root / ".loop" / "state" / "signals" / f"training-stale-{run_id}.json"
            self.assertTrue(sig_path.exists(), "stale signal not fired on download failure")
            sig = json.loads(sig_path.read_text())
            self.assertEqual(sig.get("cause"), "checkpoint-download-failed")


# ─── Test: inference-mode registry stub ─────────────────────────────────────

class TestInferenceModeStub(unittest.TestCase):

    def setUp(self):
        lib_dir = str(Path(__file__).parent.parent)
        if lib_dir not in sys.path:
            sys.path.insert(0, lib_dir)

    def test_inference_dispatch_raises_not_implemented(self):
        """dispatch_scout() with mode: inference raises NotImplementedError."""
        from scouts import dispatch_scout
        with tempfile.TemporaryDirectory() as d:
            spec = Path(d) / "test-inference.md"
            spec.write_text(
                "---\nname: test-inference\nmode: inference\nprompt: check something\n---\n"
            )
            with self.assertRaises(NotImplementedError):
                dispatch_scout(str(spec), d)

    def test_registry_parses_inference_mode_and_prompt(self):
        """Registry accepts mode: inference + prompt: field in frontmatter."""
        from scouts import parse_specialist, get_mode
        with tempfile.TemporaryDirectory() as d:
            spec = Path(d) / "test-inference.md"
            spec.write_text(
                "---\nname: test-inference\nmode: inference\nprompt: check something\n---\n"
            )
            fm, _ = parse_specialist(str(spec))
            self.assertEqual(get_mode(fm), "inference")
            self.assertIn("prompt", fm)
            self.assertEqual(fm["prompt"], "check something")


if __name__ == "__main__":
    unittest.main()
