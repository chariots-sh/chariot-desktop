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

def send_reply(text):
    outbox = os.environ["CHARIOT_OUTBOX"]
    os.makedirs(outbox, exist_ok=True)
    stamp = "%d-%d" % (time.time_ns(), os.getpid())
    part = os.path.join(outbox, "." + stamp + ".part")
    with open(part, "w") as f:
        f.write(text)
    os.rename(part, os.path.join(outbox, stamp + ".msg"))
    time.sleep(0.001)  # distinct nanosecond stamps keep the order stable

# Tool-call modes drop a request the way tools/phone.sh does (atomic rename
# to *.req), then poll for the *.res answer and echo it into the reply.
def call_phone_tool(request_text, call_id, wait_seconds):
    tooldir = os.environ["CHARIOT_TOOLCALLS"]
    os.makedirs(tooldir, exist_ok=True)
    part = os.path.join(tooldir, "." + call_id + ".part")
    with open(part, "w") as f:
        f.write(request_text)
    os.rename(part, os.path.join(tooldir, call_id + ".req"))
    res = os.path.join(tooldir, call_id + ".res")
    deadline = time.time() + wait_seconds
    while time.time() < deadline:
        if os.path.exists(res):
            with open(res) as f:
                return f.read()
        time.sleep(0.01)
    return "TOOL-TIMEOUT"

if mode == "tool-call":
    result = call_phone_tool(json.dumps({"request_id": "call-1", "name": "log_water",
                                         "arguments": {"millilitres": 600}}),
                             "call-1", wait_seconds=5)
    send_reply("TOOL-RESULT:" + result)
elif mode == "bad-tool-call":
    result = call_phone_tool("{this is not json", "call-bad", wait_seconds=5)
    send_reply("TOOL-RESULT:" + result)
elif mode == "tool-call-no-answer":
    call_phone_tool(json.dumps({"request_id": "call-lost", "name": "day_summary",
                                "arguments": {}}), "call-lost", wait_seconds=0.1)
    send_reply("GAVE-UP-WAITING")
elif mode != "no-reply":
    for text in (["first", "second"] if mode == "two-replies" else ["VISIBLE-ANSWER"]):
        send_reply(text)

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
            "TOOLCALL_ROOT": os.path.join(self.workspace, ".chariot", "toolcalls"),
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
        bridge.pending_tool_calls.clear()

    def _run_unprivileged(self, argv, extra_env=None, **kwargs):
        env = dict(os.environ)
        env.update(extra_env or {})
        return subprocess.Popen([sys.executable] + argv[:1] + argv[1:], env=env,
                                cwd=self.workspace, start_new_session=True, **kwargs)

    def run_turn(self, prompt="hello", conversation_id="default", mode="ok",
                 attachments=()):
        """One turn; returns (exit code, [(channel, text), …])."""
        seen = []

        def delta(text, channel=bridge.CHANNEL_TRACE):
            seen.append((channel, text))

        os.environ["FAKE_CODEX_MODE"] = mode
        try:
            code = bridge.execute_codex_turn(conversation_id, prompt, delta,
                                             attachments=attachments)
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

    def test_images_ride_dash_i_on_fresh_and_resume(self):
        images = ["/workspace/data/attachments/a.png", "/workspace/data/attachments/b.jpg"]
        for thread_id in (None, "thread-42"):
            argv = bridge.codex_argv("hi", thread_id, images=images)
            self.assertEqual(argv.count("-i"), 2)
            for image in images:
                self.assertEqual(argv[argv.index(image) - 1], "-i",
                                 "each image needs its own -i flag")
            self.assertEqual(argv[-1], "hi", "the prompt stays positional, after -i")

    def test_only_existing_images_are_handed_to_dash_i(self):
        present = os.path.join(self.workspace, "photo.png")
        with open(present, "w") as f:
            f.write("png")
        document = os.path.join(self.workspace, "report.pdf")
        with open(document, "w") as f:
            f.write("pdf")
        missing = os.path.join(self.workspace, "never-uploaded.png")
        # Non-images and files whose upload never landed are prompt-only.
        self.assertEqual(bridge.split_attachments([present, document, missing]),
                         [present])


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


class AttachmentTests(BridgeTestCase):
    def test_attachments_reach_the_prompt_and_images_reach_argv(self):
        present = os.path.join(self.workspace, "meal.png")
        with open(present, "w") as f:
            f.write("png")
        document = os.path.join(self.workspace, "labs.pdf")
        with open(document, "w") as f:
            f.write("pdf")

        argv_seen = []
        real_run = bridge.run_as_agent

        def record(argv, **kwargs):
            argv_seen.append(argv)
            return real_run(argv, **kwargs)

        bridge.run_as_agent = record
        try:
            code, _seen = self.run_turn(prompt="what do you see?",
                                        attachments=[present, document])
        finally:
            bridge.run_as_agent = real_run

        self.assertEqual(code, 0)
        argv = argv_seen[0]
        # The image gets pixels; the document is prompt-only.
        self.assertEqual(argv[argv.index("-i") + 1], present)
        self.assertEqual(argv.count("-i"), 1)
        prompt = argv[-1]
        self.assertIn("what do you see?", prompt)
        self.assertIn("[Attached files from your person's phone:", prompt)
        # Every attachment is listed by path, images included, so the model
        # can re-open them with tools.
        self.assertIn(present, prompt)
        self.assertIn(document, prompt)


class ToolCallTests(BridgeTestCase):
    """The reverse RPC dropbox: phone.sh-style *.req files become tool.call
    events, tool.result answers land as *.res files, and nothing survives the
    turn that nobody is polling for."""

    def tool_turn(self, mode, emit, request_id="turn-1"):
        seen = []

        def delta(text, channel=bridge.CHANNEL_TRACE):
            seen.append((channel, text))

        os.environ["FAKE_CODEX_MODE"] = mode
        try:
            code = bridge.execute_codex_turn("default", "hello", delta,
                                             request_id=request_id, emit=emit)
        finally:
            os.environ.pop("FAKE_CODEX_MODE", None)
        return code, seen

    def test_tool_call_round_trip(self):
        events = []

        def emit(obj):
            events.append(obj)
            if obj.get("type") == "tool.call":
                # The host answering mid-turn, while the script still polls.
                bridge.handle_tool_result({"request_id": obj["request_id"],
                                           "ok": True, "output": "logged 600 ml"})

        code, seen = self.tool_turn("tool-call", emit)
        self.assertEqual(code, 0)

        calls = [e for e in events if e.get("type") == "tool.call"]
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0]["request_id"], "call-1")
        self.assertEqual(calls[0]["turn_request_id"], "turn-1")
        self.assertEqual(calls[0]["conversation_id"], "default")
        self.assertEqual(calls[0]["name"], "log_water")
        self.assertEqual(calls[0]["arguments"], {"millilitres": 600})

        reply = "".join(self.replies(seen))
        self.assertIn("TOOL-RESULT:", reply)
        self.assertIn('"ok": true', reply)
        self.assertIn("logged 600 ml", reply)
        self.assertEqual(bridge.pending_tool_calls, {})

    def test_malformed_request_fails_fast_without_reaching_the_host(self):
        events = []
        code, seen = self.tool_turn("bad-tool-call", events.append)
        self.assertEqual(code, 0)
        self.assertEqual([e for e in events if e.get("type") == "tool.call"], [])
        reply = "".join(self.replies(seen))
        self.assertIn("malformed request", reply)
        self.assertEqual(bridge.pending_tool_calls, {})

    def test_unanswered_calls_are_dropped_when_the_turn_ends(self):
        events = []
        code, seen = self.tool_turn("tool-call-no-answer", events.append)
        self.assertEqual(code, 0)
        calls = [e for e in events if e.get("type") == "tool.call"]
        self.assertEqual([c["request_id"] for c in calls], ["call-lost"])
        self.assertIn("GAVE-UP-WAITING", "".join(self.replies(seen)))
        # The teardown sweep dropped the pending call…
        self.assertEqual(bridge.pending_tool_calls, {})
        # …so a result arriving after the turn is dropped, not written into
        # the dead dropbox.
        bridge.handle_tool_result({"request_id": "call-lost", "ok": True,
                                   "output": "too late"})
        leftovers = [n for n in os.listdir(bridge.toolcalls_dir("default"))
                     if n.endswith(".res")]
        self.assertEqual(leftovers, [])


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
