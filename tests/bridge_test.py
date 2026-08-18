#!/usr/bin/env python3
"""Unit tests for the guest bridge's turn handling (guest/bridge.py).

These cover the two things a phone conversation depends on and that nothing
else in the suite can see: that a turn resumes the previous Codex session, and
that only what the agent addressed to its person leaves the sandbox.

The Codex CLI is replaced by a scripted stand-in, and `run_as_agent` by a
plain Popen — the real one switches to the `agent` user, which needs root and
a guest filesystem.
"""

import os
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "guest"))
import bridge  # noqa: E402


# A stand-in for `codex exec`. Reads the same argv the real CLI would, writes
# the same JSONL to stdout, and (in some modes) drops a message in the outbox
# the way tools/reply.sh does.
FAKE_CODEX = r'''#!/usr/bin/env python3
import json, os, sys, time

argv = sys.argv[1:]
mode = os.environ.get("FAKE_CODEX_MODE", "ok")
resuming = "resume" in argv
thread_id = argv[argv.index("resume") + 1] if resuming else "thread-fresh"

# The real CLI rejects `-C` after `resume` (it is not a clap global), exiting
# before the session ever opens.
if resuming and ("-C" in argv or "--cd" in argv):
    sys.stderr.write("error: unexpected argument '-C' found\n")
    sys.exit(2)
if mode == "stale-session" and resuming:
    sys.stderr.write("error: no session found\n")
    sys.exit(1)

def emit(obj):
    print(json.dumps(obj), flush=True)

emit({"type": "thread.started", "thread_id": thread_id})
emit({"type": "item.completed",
      "item": {"id": "i0", "type": "command_execution",
               "command": "cat /workspace/data/alist-archive.json",
               "aggregated_output": "SECRET-ARCHIVE-INTERNALS", "exit_code": 0}})

if mode != "no-reply":
    outbox = os.environ["CHARIOT_OUTBOX"]
    os.makedirs(outbox, exist_ok=True)
    for text in (["first", "second"] if mode == "two-replies" else ["VISIBLE-ANSWER"]):
        stamp = "%d-%d" % (time.time_ns(), os.getpid())
        part = os.path.join(outbox, "." + stamp + ".part")
        with open(part, "w") as f:
            f.write(text)
        os.rename(part, os.path.join(outbox, stamp + ".msg"))
        time.sleep(0.001)  # distinct nanosecond stamps keep the order stable

emit({"type": "item.completed",
      "item": {"id": "i1", "type": "agent_message", "text": "INLINE-FINAL-MESSAGE"}})
emit({"type": "turn.completed", "usage": {}})
'''


class BridgeTestCase(unittest.TestCase):
    """Points the bridge's paths at a temp dir and its CLI at the stand-in."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = self.tmp.name

        self.workspace = os.path.join(root, "workspace")
        os.makedirs(self.workspace)
        codex = os.path.join(root, "fake-codex")
        with open(codex, "w") as f:
            f.write(FAKE_CODEX)
        os.chmod(codex, 0o755)

        patches = {
            "WORKSPACE": self.workspace,
            "OUTBOX_ROOT": os.path.join(self.workspace, ".chariot", "outbox"),
            "STATE_DIR": os.path.join(root, "state"),
            "THREADS_FILE": os.path.join(root, "state", "threads.json"),
            "CODEX_BIN": codex,
            "OUTBOX_POLL_SECONDS": 0.02,
            "run_as_agent": self._run_unprivileged,
        }
        for name, value in patches.items():
            original = getattr(bridge, name)
            setattr(bridge, name, value)
            self.addCleanup(setattr, bridge, name, original)
        bridge.conversation_locks.clear()
        bridge.cancel_procs.clear()

    def _run_unprivileged(self, argv, extra_env=None, **kwargs):
        env = dict(os.environ)
        env.update(extra_env or {})
        return subprocess.Popen([sys.executable] + argv[:1] + argv[1:], env=env,
                                cwd=self.workspace, start_new_session=True, **kwargs)

    def run_turn(self, prompt="hello", conversation_id="default", mode="ok"):
        """One turn; returns (exit code, [(channel, text), …])."""
        seen = []

        def delta(text, channel=bridge.CHANNEL_TRACE):
            seen.append((channel, text))

        os.environ["FAKE_CODEX_MODE"] = mode
        try:
            code = bridge.execute_codex_turn(conversation_id, prompt, delta)
        finally:
            os.environ.pop("FAKE_CODEX_MODE", None)
        return code, seen

    def replies(self, seen):
        return [text for channel, text in seen if channel == bridge.CHANNEL_REPLY]

    def traces(self, seen):
        return [text for channel, text in seen if channel == bridge.CHANNEL_TRACE]


class CodexArgvTests(BridgeTestCase):
    def test_fresh_turn_names_the_workspace(self):
        argv = bridge.codex_argv("hi", None)
        self.assertEqual(argv[1:2], ["exec"])
        self.assertNotIn("resume", argv)
        self.assertIn("-C", argv)
        self.assertEqual(argv[argv.index("-C") + 1], self.workspace)
        self.assertEqual(argv[-1], "hi")

    def test_resume_omits_cd_because_it_is_not_a_clap_global(self):
        argv = bridge.codex_argv("hi", "thread-42")
        self.assertEqual(argv[1:4], ["exec", "resume", "thread-42"])
        self.assertNotIn("-C", argv)
        self.assertNotIn("--cd", argv)
        self.assertEqual(argv[-1], "hi")


class ThreadStateTests(BridgeTestCase):
    def test_thread_ids_round_trip_through_disk(self):
        self.assertIsNone(bridge.thread_for("default"))
        bridge.remember_thread("default", "thread-a")
        bridge.remember_thread("local", "thread-b")
        self.assertEqual(bridge.thread_for("default"), "thread-a")
        self.assertEqual(bridge.thread_for("local"), "thread-b")
        bridge.forget_thread("default")
        self.assertIsNone(bridge.thread_for("default"))
        self.assertEqual(bridge.thread_for("local"), "thread-b")

    def test_unreadable_state_reads_as_no_thread(self):
        os.makedirs(bridge.STATE_DIR, exist_ok=True)
        with open(bridge.THREADS_FILE, "w") as f:
            f.write("{not json")
        self.assertIsNone(bridge.thread_for("default"))


class OutboxTests(BridgeTestCase):
    def test_conversation_ids_cannot_escape_the_outbox_root(self):
        self.assertTrue(bridge.outbox_dir("../../etc").startswith(bridge.OUTBOX_ROOT + os.sep))
        self.assertEqual(os.path.basename(bridge.outbox_dir("")), "default")

    def test_drain_takes_finished_messages_in_order_and_leaves_partials(self):
        path = bridge.outbox_dir("default")
        bridge.reset_outbox(path)
        for name, text in [("100-1.msg", "one"), ("200-1.msg", "two"),
                           (".300-1.part", "half-written"), ("400-1.msg", "   ")]:
            with open(os.path.join(path, name), "w") as f:
                f.write(text)
        self.assertEqual(bridge.drain_outbox(path), ["one\n", "two\n"])
        self.assertEqual(bridge.drain_outbox(path), [])
        self.assertTrue(os.path.exists(os.path.join(path, ".300-1.part")))

    def test_reset_clears_a_previous_turn(self):
        path = bridge.outbox_dir("default")
        bridge.reset_outbox(path)
        with open(os.path.join(path, "100-1.msg"), "w") as f:
            f.write("stale")
        bridge.reset_outbox(path)
        self.assertEqual(bridge.drain_outbox(path), [])


class TurnTests(BridgeTestCase):
    def test_only_the_agents_reply_reaches_the_phone(self):
        code, seen = self.run_turn()
        self.assertEqual(code, 0)
        self.assertEqual(self.replies(seen), ["VISIBLE-ANSWER\n"])
        # The work — commands and their output — is trace only.
        self.assertTrue(any("SECRET-ARCHIVE-INTERNALS" in t for t in self.traces(seen)))
        self.assertFalse(any("SECRET-ARCHIVE-INTERNALS" in t for t in self.replies(seen)))
        # An inline final message is not a reply when the tool was used.
        self.assertFalse(any("INLINE-FINAL-MESSAGE" in t for t in self.replies(seen)))

    def test_each_tool_call_is_its_own_message_in_order(self):
        _, seen = self.run_turn(mode="two-replies")
        self.assertEqual(self.replies(seen), ["first\n", "second\n"])

    def test_a_turn_that_forgets_the_tool_still_answers(self):
        _, seen = self.run_turn(mode="no-reply")
        self.assertEqual(self.replies(seen), ["INLINE-FINAL-MESSAGE\n"])

    def test_the_next_turn_resumes_the_same_session(self):
        self.run_turn(prompt="my codeword is BLUEFALCON")
        self.assertEqual(bridge.thread_for("default"), "thread-fresh")

        argv_seen = []
        real_run = bridge.run_as_agent

        def record(argv, **kwargs):
            argv_seen.append(argv)
            return real_run(argv, **kwargs)

        bridge.run_as_agent = record
        code, seen = self.run_turn(prompt="what was the codeword?")
        bridge.run_as_agent = real_run

        self.assertEqual(code, 0)
        self.assertEqual(argv_seen[0][1:4], ["exec", "resume", "thread-fresh"])
        self.assertEqual(self.replies(seen), ["VISIBLE-ANSWER\n"])

    def test_conversations_resume_their_own_sessions(self):
        self.run_turn(conversation_id="default")
        bridge.remember_thread("default", "thread-guardian")
        self.run_turn(conversation_id="local")
        self.assertEqual(bridge.thread_for("default"), "thread-guardian")
        self.assertEqual(bridge.thread_for("local"), "thread-fresh")

    def test_a_stale_session_asks_for_one_clean_retry(self):
        bridge.remember_thread("default", "thread-gone")
        code, seen = self.run_turn(mode="stale-session")
        self.assertIs(code, bridge.RETRY_FRESH)
        self.assertEqual(self.replies(seen), [])

    def test_the_retry_runs_without_the_dead_session(self):
        bridge.remember_thread("default", "thread-gone")
        seen = []

        def delta(text, channel=bridge.CHANNEL_TRACE):
            seen.append((channel, text))

        os.environ["FAKE_CODEX_MODE"] = "stale-session"
        try:
            code = bridge.execute_codex_turn("default", "hello", delta)
            self.assertIs(code, bridge.RETRY_FRESH)
            bridge.forget_thread("default")
            code = bridge.execute_codex_turn("default", "hello", delta)
        finally:
            os.environ.pop("FAKE_CODEX_MODE", None)
        self.assertEqual(code, 0)
        self.assertEqual(self.replies(seen), ["VISIBLE-ANSWER\n"])
        self.assertEqual(bridge.thread_for("default"), "thread-fresh")


class SummarizeItemTests(BridgeTestCase):
    def test_commands_carry_their_output_and_failures(self):
        text = bridge.summarize_item({"type": "command_execution", "command": "ls",
                                      "aggregated_output": "a\nb\n", "exit_code": 3})
        self.assertIn("$ ls", text)
        self.assertIn("[exit 3]", text)
        self.assertIn("a\nb\n", text)

    def test_reasoning_stays_quiet(self):
        self.assertIsNone(bridge.summarize_item({"type": "reasoning", "text": "thinking"}))


class CodexInstallTests(unittest.TestCase):
    """The startup install must survive losing the race with DHCP.

    It used to run once: a first-boot failure left `installed` false for the
    life of the VM, which disabled the Sign in Codex button, whose only other
    path to triggering a retry was a chat turn the user could not yet send.
    Restarting the VM was the sole way out.
    """

    def setUp(self):
        self._ensure = bridge.ensure_codex
        self._installed = bridge.codex_installed
        self._sleep = bridge.time.sleep
        bridge.time.sleep = lambda _seconds: None

    def tearDown(self):
        bridge.ensure_codex = self._ensure
        bridge.codex_installed = self._installed
        bridge.time.sleep = self._sleep

    def test_retries_until_the_install_succeeds(self):
        attempts = []
        installed = {"value": False}

        def flaky():
            attempts.append(1)
            # Fails twice — no route to host while cloud-init configures the
            # NIC — then succeeds.
            if len(attempts) < 3:
                return False
            installed["value"] = True
            return True

        bridge.ensure_codex = flaky
        bridge.codex_installed = lambda: installed["value"]

        bridge.ensure_codex_forever()

        self.assertEqual(len(attempts), 3)
        self.assertTrue(installed["value"])

    def test_does_nothing_when_already_installed(self):
        called = []
        bridge.ensure_codex = lambda: called.append(1) or True
        bridge.codex_installed = lambda: True

        bridge.ensure_codex_forever()

        self.assertEqual(called, [], "a healthy guest must not re-download")


if __name__ == "__main__":
    unittest.main()
