#!/usr/bin/env python3
"""Chariot guest bridge.

Listens on AF_VSOCK ports inside the Linux guest and speaks newline-delimited
JSON with the macOS host (design §1.4). The host is the only possible peer —
vsock is not reachable from the guest's NAT network or the LAN.

Port 1024: typed agent protocol. The agent is one of several harnesses
           (codex, zeroclaw, openclaw, hermes, muse) running in /workspace as
           the unprivileged `agent` user. The harness is chosen at agent
           creation: preinstalled by cloud-init (/etc/chariot/harness) and
           configured at runtime by the host's `agent.configure` message.
Port 1023: developer-access tunnel → guest sshd (127.0.0.1:22).
Port 1022: OAuth-callback tunnel → Codex login server (127.0.0.1:1455), used
           while the host browser completes the ChatGPT sign-in (design §3.1).

Model access for API-powered agents (power_source chariot/local): harness
configs point at http://127.0.0.1:8090/v1 with a dummy key; this bridge
forwards that loopback port over vsock to the host's model broker, which
attaches the real credential. The guest never holds a Chariot token.
"""

import base64
import glob
import json
import os
import pwd
import re
import shutil
import signal
import socket
import subprocess
import threading
import time
import urllib.request
import uuid as uuid_module

AGENT_PORT = 1024
SSH_TUNNEL_PORT = 1023
LOGIN_TUNNEL_PORT = 1022
LOGIN_CALLBACK_PORT = 1455  # fixed: registered OAuth redirect is localhost:1455

# The model broker: harness configs name the loopback endpoint; each accepted
# connection is piped to the host over vsock (the host listens on 8090).
BROKER_LOCAL_PORT = 8090
BROKER_VSOCK_PORT = 8090
BROKER_BASE_URL = f"http://127.0.0.1:{BROKER_LOCAL_PORT}/v1"

WORKSPACE = "/workspace"
AGENT_USER = "agent"
PROTOCOL_VERSION = 1
# Big enough for a file.put of a phone data snapshot (base64 inflates the
# payload 4/3; a multi-MB archive arrives as one JSON line). vsock is local
# and the host is trusted, so this is a sanity bound, not a defense.
MAX_LINE_BYTES = 64 * 1024 * 1024
OUTPUT_LIMIT_PER_ITEM = 4000

# Two kinds of output.delta (design: the person sees the agent's answer, the
# Mac sees the work). "reply" is what the agent deliberately addressed to its
# person — the host forwards only this to the phone. "trace" is the working
# transcript (commands, edits, mid-turn chatter) and stays on the Mac.
CHANNEL_REPLY = "reply"
CHANNEL_TRACE = "trace"

# Harness session ids, so a conversation survives a bridge or VM restart. Root
# owned and outside /workspace: the agent must not be able to rewrite its own
# continuity, and repopulating a pack must not drop it.
STATE_DIR = "/var/lib/chariot"
SESSIONS_FILE = os.path.join(STATE_DIR, "sessions.json")
LEGACY_THREADS_FILE = os.path.join(STATE_DIR, "threads.json")
# The host-pushed power configuration (agent.configure), persisted so a
# bridge restart before the host reconnects still knows itself.
CONFIG_FILE = os.path.join(STATE_DIR, "agent-config.json")
# Which harness cloud-init preinstalled (written by the seed ISO).
HARNESS_FILE = "/etc/chariot/harness"

# Drop box the agent writes replies into (see packs/*/tools/reply.sh). One
# directory per conversation; one file per message, renamed into place so the
# bridge never reads a half-written message.
OUTBOX_ROOT = os.path.join(WORKSPACE, ".chariot", "outbox")
MESSAGE_SUFFIX = ".msg"
OUTBOX_POLL_SECONDS = 0.25

# Drop box for phone tool calls (see packs/*/tools/phone.sh): the agent writes
# `<id>.req`, the host answers on the phone, and the result comes back as
# `<id>.res` for the polling script. Same rename-into-place discipline as the
# outbox. Harness-agnostic — the pump lives in the shared turn runner.
TOOLCALL_ROOT = os.path.join(WORKSPACE, ".chariot", "toolcalls")
REQUEST_SUFFIX = ".req"
RESULT_SUFFIX = ".res"

# Attachment images ride `codex exec -i` so the model gets pixels; anything
# else is referenced by path in the prompt only. Non-codex harnesses get the
# prompt listing alone.
IMAGE_EXTENSIONS = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".heic", ".bmp"}

start_time = time.time()
state_lock = threading.Lock()
cancel_procs = {}          # conversation_id -> subprocess.Popen
conversation_locks = {}    # conversation_id -> threading.Lock
pending_tool_calls = {}    # request_id -> toolcalls dir awaiting a .res
login_proc = None

# Sentinel: the resumed session was unusable, so run the turn again fresh.
RETRY_FRESH = object()

# A model occasionally ends a turn with no text (e.g. it believes it already
# delivered the reply some other way). One explicit nudge, mirroring the
# backend harness shims.
NUDGE = ("Your previous turn produced no text. Write your reply to the last "
         "message now, as plain text — it is delivered to the user automatically.")


def log(msg):
    print(f"[bridge] {msg}", flush=True)


def send(conn_file, obj):
    data = json.dumps(obj, separators=(",", ":")) + "\n"
    conn_file.write(data.encode())
    conn_file.flush()


def agent_env():
    info = pwd.getpwnam(AGENT_USER)
    return info, {
        "HOME": info.pw_dir,
        "USER": AGENT_USER,
        "LOGNAME": AGENT_USER,
        "PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
    }


def run_as_agent(argv, extra_env=None, **kwargs):
    info, env = agent_env()
    env.update(extra_env or {})
    return subprocess.Popen(argv, user=AGENT_USER, group=info.pw_gid, env=env,
                            cwd=WORKSPACE, start_new_session=True, **kwargs)


def agent_home():
    try:
        return pwd.getpwnam(AGENT_USER).pw_dir
    except KeyError:
        # Test hosts have no `agent` user; the guest always does.
        return os.path.expanduser("~")


def chown_to_agent(path):
    info = pwd.getpwnam(AGENT_USER)
    os.chown(path, info.pw_uid, info.pw_gid)


# --------------------------------------------------------- Power configuration

def read_config():
    """The host-pushed power config: {harness, power_source, model, base_url,
    api_key}. Empty dict = legacy codex-with-ChatGPT (no configure ever ran)."""
    try:
        with open(CONFIG_FILE) as f:
            cfg = json.load(f)
        return cfg if isinstance(cfg, dict) else {}
    except (OSError, ValueError):
        return {}


def write_config(cfg):
    os.makedirs(STATE_DIR, exist_ok=True)
    tmp = CONFIG_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(cfg, f)
    os.replace(tmp, CONFIG_FILE)


def power_source(cfg=None):
    cfg = read_config() if cfg is None else cfg
    return cfg.get("power_source", "chatgpt")


def configured_harness_name():
    """The harness this guest runs: the pushed config wins, else the seed's
    /etc/chariot/harness marker, else codex (pre-harness guests)."""
    cfg = read_config()
    if cfg.get("harness"):
        return cfg["harness"]
    try:
        with open(HARNESS_FILE) as f:
            name = f.read().strip()
        if name:
            return name
    except OSError:
        pass
    return "codex"


# --------------------------------------------------------------- Session store

def _read_sessions():
    try:
        with open(SESSIONS_FILE) as f:
            sessions = json.load(f)
        if isinstance(sessions, dict):
            return sessions
    except (OSError, ValueError):
        pass
    # Migrate the pre-harness store: threads.json mapped conversation → codex
    # thread id. Continuity for existing codex conversations must survive the
    # upgrade.
    try:
        with open(LEGACY_THREADS_FILE) as f:
            threads = json.load(f)
        if isinstance(threads, dict):
            return {conv: {"harness": "codex", "session": tid}
                    for conv, tid in threads.items() if isinstance(tid, str)}
    except (OSError, ValueError):
        pass
    return {}


def _write_sessions(sessions):
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        tmp = SESSIONS_FILE + ".tmp"
        with open(tmp, "w") as f:
            json.dump(sessions, f)
        os.replace(tmp, SESSIONS_FILE)
    except OSError as e:
        log(f"could not persist session ids: {e}")


def session_for(harness_name, conversation_id):
    """The stored session id, if it belongs to this harness. A session from a
    different harness (the agent cannot change harness today, but stale state
    must not brick turns) reads as absent."""
    with state_lock:
        entry = _read_sessions().get(conversation_id)
    if isinstance(entry, dict) and entry.get("harness") == harness_name:
        return entry.get("session")
    return None


def remember_session(harness_name, conversation_id, session_id):
    with state_lock:
        sessions = _read_sessions()
        entry = {"harness": harness_name, "session": session_id}
        if sessions.get(conversation_id) == entry:
            return
        sessions[conversation_id] = entry
        _write_sessions(sessions)


def forget_session(conversation_id):
    with state_lock:
        sessions = _read_sessions()
        if sessions.pop(conversation_id, None) is not None:
            _write_sessions(sessions)


# ------------------------------------------------------------------- Outbox

def safe_conversation_name(conversation_id):
    return re.sub(r"[^A-Za-z0-9._-]", "_", conversation_id or "") or "default"


def outbox_dir(conversation_id):
    return os.path.join(OUTBOX_ROOT, safe_conversation_name(conversation_id))


def toolcalls_dir(conversation_id):
    return os.path.join(TOOLCALL_ROOT, safe_conversation_name(conversation_id))


def reset_dropbox(path, root):
    """Empty drop box owned by the agent user, ready for one turn."""
    os.makedirs(path, exist_ok=True)
    for directory in (os.path.dirname(root), root, path):
        try:
            info = pwd.getpwnam(AGENT_USER)
            os.chown(directory, info.pw_uid, info.pw_gid)
            os.chmod(directory, 0o755)
        except (OSError, KeyError):
            pass
    for name in os.listdir(path):
        try:
            os.unlink(os.path.join(path, name))
        except OSError:
            pass


def reset_outbox(path):
    """Empty drop box owned by the agent user, ready for one turn's replies."""
    reset_dropbox(path, OUTBOX_ROOT)


def drain_outbox(path):
    """Take every message the agent has finished writing, oldest first. Names
    are `<nanoseconds>-<pid>.msg`, so lexicographic order is send order."""
    try:
        names = sorted(n for n in os.listdir(path) if n.endswith(MESSAGE_SUFFIX))
    except OSError:
        return []
    messages = []
    for name in names:
        full = os.path.join(path, name)
        try:
            with open(full, encoding="utf-8", errors="replace") as f:
                text = f.read()
            os.unlink(full)
        except OSError:
            continue
        if text.strip():
            messages.append(text if text.endswith("\n") else text + "\n")
    return messages


# --------------------------------------------------------- Phone tool calls

def write_tool_result(dirpath, call_id, payload):
    """Answer one phone.sh call: atomic write-then-rename of `<id>.res`, owned
    by the agent user so the polling script can unlink it."""
    try:
        os.makedirs(dirpath, exist_ok=True)
        part = os.path.join(dirpath, f".{call_id}.part")
        with open(part, "w") as f:
            json.dump(payload, f)
        try:
            info = pwd.getpwnam(AGENT_USER)
            os.chown(part, info.pw_uid, info.pw_gid)
        except (OSError, KeyError):
            pass
        os.replace(part, os.path.join(dirpath, call_id + RESULT_SUFFIX))
    except OSError as e:
        log(f"could not deliver tool result {call_id}: {e}")


def handle_tool_result(request):
    """Host relayed the phone's answer for one in-flight tool call. Unknown or
    late ids (the turn already ended, or the host timed out and answered
    first) are dropped — the script that asked is no longer polling."""
    request_id = request.get("request_id", "")
    with state_lock:
        dirpath = pending_tool_calls.pop(request_id, None)
    if dirpath is None:
        log(f"tool.result for unknown request {request_id!r}; dropped")
        return
    write_tool_result(dirpath, request_id, {
        "ok": bool(request.get("ok")),
        "output": request.get("output") or "",
        "user_visible_summary": request.get("user_visible_summary"),
        "error": request.get("error"),
    })


def split_attachments(paths):
    """The image attachments worth handing to `codex -i`: recognized image
    extension and actually on disk. Everything else (documents, files whose
    upload never landed) stays prompt-only — the model can still open a listed
    path with its own tools, but a missing path on `-i` would fail the turn."""
    return [p for p in paths
            if os.path.splitext(p)[1].lower() in IMAGE_EXTENSIONS
            and os.path.exists(p)]


def close_pipes(proc):
    """The bridge is long-lived; a finished turn must not leak its pipes."""
    for pipe_file in (proc.stdout, proc.stderr):
        try:
            if pipe_file:
                pipe_file.close()
        except OSError:
            pass


# ------------------------------------------------------------------ Harnesses

class Harness:
    """One agentic runtime. Subclasses own installation, native config
    rendering, and turn execution; the generic runner owns the reply contract
    (outbox pump + last-message fallback) and session retry."""

    name = "?"

    def __init__(self):
        self.install_error = None

    # -- installation ------------------------------------------------------
    def installed(self):
        raise NotImplementedError

    def ensure(self):
        """Install missing pieces (guest has NAT internet). Returns bool and
        records install_error on failure."""
        raise NotImplementedError

    def version(self):
        return None

    def _version_from(self, argv, timeout=30):
        if not self.installed():
            return None
        try:
            out = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
            return out.stdout.strip().splitlines()[0] if out.stdout.strip() else None
        except Exception:  # noqa: BLE001
            return None

    # -- readiness / config ------------------------------------------------
    def ready(self, cfg):
        """(ok, reason). API-powered harnesses are ready once configured;
        chatgpt-codex additionally needs its OAuth credential."""
        if power_source(cfg) == "chatgpt":
            return (False, f"{self.name} does not support ChatGPT sign-in")
        if not cfg.get("model") and self.name != "codex":
            return (False, "no model configured — set one on the Mac")
        return (True, "")

    def render_config(self, cfg):
        """Write the harness-native config file(s) from the pushed settings."""

    def supports_login(self):
        return False

    # -- turns -------------------------------------------------------------
    def execute_turn(self, conversation_id, prompt, cfg, delta, register_proc,
                     turn_env, attachments=()):
        """Run one turn. Returns an exit code, or RETRY_FRESH when a resumed
        session was unusable and the turn should re-run fresh. `delta` streams
        output (trace by default); the generic runner handles the outbox and
        tool-call pumps and the reply fallback via `self.last_agent_message`.
        `turn_env` (CHARIOT_OUTBOX + CHARIOT_TOOLCALLS) must reach the harness
        process so packs' tools/reply.sh and tools/phone.sh work identically
        on every runtime. `attachments` are already framed into the prompt by
        the runner; codex additionally feeds image pixels via `-i`."""
        raise NotImplementedError

    # Set by execute_turn: the text used as a reply when the agent never
    # called its reply tool.
    last_agent_message = None

    # -- shared helper for collect-at-end CLIs ------------------------------
    def run_collected(self, argv, extra_env=None, stdin_text=None,
                      register_proc=None, timeout=600):
        """Run a turn subprocess to completion; returns (returncode, stdout,
        stderr_tail). The process runs as the agent user in /workspace."""
        try:
            proc = run_as_agent(argv, extra_env=extra_env,
                                stdin=subprocess.PIPE if stdin_text is not None else subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        except Exception as e:  # noqa: BLE001
            return (127, "", f"failed to start {self.name}: {e}")
        if register_proc:
            register_proc(proc)
        try:
            stdout, stderr = proc.communicate(input=stdin_text, timeout=timeout)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
            except OSError:
                pass
            stdout, stderr = proc.communicate()
            return (124, stdout or "", (stderr or "")[-800:])
        finally:
            close_pipes(proc)
        return (proc.returncode, stdout or "", (stderr or "")[-800:])


# ---------------------------------------------------------------------- Codex

class CodexHarness(Harness):
    name = "codex"
    BIN = "/usr/local/bin/codex"
    RELEASE = "https://github.com/openai/codex/releases/download/rust-v0.147.0"
    BINARIES = {
        "/usr/local/bin/codex": "codex-aarch64-unknown-linux-musl",
        "/usr/local/bin/codex-code-mode-host": "codex-code-mode-host-aarch64-unknown-linux-musl",
    }

    def installed(self):
        return all(os.path.exists(p) and os.access(p, os.X_OK) for p in self.BINARIES)

    def ensure(self):
        if self.installed():
            return True
        try:
            for dest, asset in self.BINARIES.items():
                if os.path.exists(dest):
                    continue
                log(f"downloading {asset}…")
                tmp = f"/tmp/{asset}.tar.gz"
                urllib.request.urlretrieve(f"{self.RELEASE}/{asset}.tar.gz", tmp)
                subprocess.run(["tar", "-xzf", tmp, "-C", "/tmp"], check=True)
                shutil.move(f"/tmp/{asset}", dest)
                os.chmod(dest, 0o755)
                os.remove(tmp)
            self.install_error = None
            log("codex installed")
            return True
        except Exception as e:  # noqa: BLE001
            self.install_error = str(e)
            log(f"codex install failed: {e}")
            return False

    def version(self):
        return self._version_from([self.BIN, "--version"], timeout=15)

    def logged_in(self):
        return os.path.exists(os.path.join(agent_home(), ".codex", "auth.json"))

    def supports_login(self):
        return True

    def ready(self, cfg):
        if power_source(cfg) == "chatgpt":
            if self.logged_in():
                return (True, "")
            return (False, "Codex isn't signed in yet. On the Mac: Sandbox → Agent → Sign in Codex.")
        return (True, "")

    def render_config(self, cfg):
        """API-powered codex: ~/.codex/config.toml names the loopback broker
        as a custom provider (port of images/codex/render-config.mjs). The key
        is env-indirected — the dummy broker key, never a real credential.
        Always the Responses wire: codex 0.147.0 removed `wire_api = "chat"`,
        and both upstreams speak Responses (the chariot proxy's passthrough,
        and Ollama's /v1/responses — verified in the M6 matrix)."""
        if power_source(cfg) == "chatgpt":
            return  # ChatGPT flow: codex manages ~/.codex itself after login.
        wire = "responses"
        model = cfg.get("model", "")
        config_dir = os.path.join(agent_home(), ".codex")
        os.makedirs(config_dir, exist_ok=True)
        chown_to_agent(config_dir)
        path = os.path.join(config_dir, "config.toml")
        with open(path, "w") as f:
            f.write(f"""# Rendered by the Chariot bridge from agent.configure.
model = {json.dumps(model)}
model_provider = "chariot"
approval_policy = "never"
sandbox_mode = "danger-full-access"

[model_providers.chariot]
name = "Chariot broker"
base_url = {json.dumps(cfg.get("base_url", BROKER_BASE_URL))}
env_key = "CHARIOT_API_KEY"
wire_api = {json.dumps(wire)}
""")
        chown_to_agent(path)

    def argv(self, prompt, session_id, images=()):
        """Argv for one turn, resuming `session_id` when we have one.

        `--cd/-C` is not a clap *global* in the Codex CLI, so it is rejected
        after the `resume` subcommand and the whole turn dies with a usage
        error. Resumed turns get their working root from the process cwd
        (/workspace) instead, which is the same directory `-C` names fresh.
        `-i` *is* accepted on both the fresh and resume forms (verified
        against rust-v0.147.0).
        """
        flags = ["--json", "--skip-git-repo-check",
                 "--dangerously-bypass-approvals-and-sandbox"]
        for image in images:
            flags += ["-i", image]
        if session_id:
            return [self.BIN, "exec", "resume", session_id] + flags + [prompt]
        return [self.BIN, "exec"] + flags + ["-C", WORKSPACE, prompt]

    @staticmethod
    def summarize_item(item):
        """Map a codex exec --json item to display text (or None to skip)."""
        itype = item.get("item_type") or item.get("type")
        if itype == "agent_message":
            text = item.get("text", "")
            return text + "\n" if text else None
        if itype == "command_execution":
            command = item.get("command", "")
            output = (item.get("aggregated_output") or "")[:OUTPUT_LIMIT_PER_ITEM]
            exit_code = item.get("exit_code")
            suffix = "" if exit_code in (0, None) else f"  [exit {exit_code}]"
            block = f"$ {command}{suffix}\n"
            if output.strip():
                block += output if output.endswith("\n") else output + "\n"
            return block
        if itype == "file_change":
            changes = item.get("changes") or []
            if changes:
                files = ", ".join(c.get("path", "?") for c in changes[:8])
                return f"[edited: {files}]\n"
            return None
        if itype == "error":
            return f"[error: {item.get('message', 'unknown')}]\n"
        return None  # reasoning, todo lists, etc. stay quiet

    def execute_turn(self, conversation_id, prompt, cfg, delta, register_proc,
                     turn_env, attachments=()):
        """One `codex exec`, streamed. Codex is the only harness that streams
        its transcript as trace deltas; the others collect at the end."""
        self.last_agent_message = None
        session_id = session_for(self.name, conversation_id)
        extra_env = dict(turn_env)
        if power_source(cfg) != "chatgpt":
            extra_env["CHARIOT_API_KEY"] = cfg.get("api_key", "chariot-broker")
        try:
            proc = run_as_agent(self.argv(prompt, session_id,
                                          images=split_attachments(attachments)),
                                extra_env=extra_env,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        except Exception as e:  # noqa: BLE001
            delta(f"[failed to start codex: {e}]\n", CHANNEL_REPLY)
            return 1
        register_proc(proc)

        exit_code = 0
        thread_started = False
        for line in proc.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                evt = json.loads(line)
            except json.JSONDecodeError:
                continue
            etype = evt.get("type", "")
            if etype == "thread.started":
                thread_started = True
                if evt.get("thread_id"):
                    remember_session(self.name, conversation_id, evt["thread_id"])
            elif etype == "item.completed":
                item = evt.get("item", {})
                if (item.get("item_type") or item.get("type")) == "agent_message":
                    self.last_agent_message = item.get("text") or self.last_agent_message
                text = self.summarize_item(item)
                if text:
                    delta(text)
            elif etype == "turn.failed":
                error = (evt.get("error") or {}).get("message", "turn failed")
                delta(f"[codex: {error}]\n", CHANNEL_REPLY)
                exit_code = 1
            elif etype == "error":
                delta(f"[codex: {evt.get('message', 'error')}]\n", CHANNEL_REPLY)
                exit_code = 1
        proc.wait()

        stderr_tail = proc.stderr.read()[-800:] if proc.stderr else ""
        close_pipes(proc)
        if proc.returncode != 0:
            exit_code = proc.returncode if proc.returncode > 0 else 1
            if session_id and not thread_started:
                # The session never opened — a stale thread id, or a CLI that
                # rejected the resume. Worth one clean attempt.
                return RETRY_FRESH
            if stderr_tail.strip():
                delta(f"[codex stderr: {stderr_tail.strip()}]\n", CHANNEL_TRACE)
        return exit_code


# ------------------------------------------------------------------- ZeroClaw

class ZeroclawHarness(Harness):
    """ZeroClaw, pinned to the same v0.7.5 the Guardian fleet runs.

    Turn protocol mirrors the Guardian gateway's cold path
    (ateamdms/zeroclaw-agents-template/agent_gateway.py::_run_turn_cold):
    interactive `zeroclaw agent --session-state-file <file>` fed
    `<message>\\n/exit\\n` on stdin, because single-shot `-m` ignores the
    session file. The REPL reads one line per turn, so real newlines in the
    message are flattened to the two-char `\\n` escape.
    """

    name = "zeroclaw"
    BIN = "/usr/local/bin/zeroclaw"
    VERSION_PIN = "v0.7.5"
    RELEASE = f"https://github.com/zeroclaw-labs/zeroclaw/releases/download/{VERSION_PIN}"
    ASSET = "zeroclaw-aarch64-unknown-linux-musl.tar.gz"

    def installed(self):
        return os.path.exists(self.BIN) and os.access(self.BIN, os.X_OK)

    def ensure(self):
        if self.installed():
            return True
        try:
            log(f"downloading zeroclaw {self.VERSION_PIN}…")
            tmp = "/tmp/zeroclaw.tar.gz"
            urllib.request.urlretrieve(f"{self.RELEASE}/{self.ASSET}", tmp)
            subprocess.run(["tar", "-xzf", tmp, "-C", "/tmp"], check=True)
            shutil.move("/tmp/zeroclaw", self.BIN)
            os.chmod(self.BIN, 0o755)
            os.remove(tmp)
            self.install_error = None
            log("zeroclaw installed")
            return True
        except Exception as e:  # noqa: BLE001
            self.install_error = str(e)
            log(f"zeroclaw install failed: {e}")
            return False

    def version(self):
        return self._version_from([self.BIN, "--version"], timeout=15)

    def render_config(self, cfg):
        """~/.zeroclaw/config.toml pointed at the loopback broker (port of
        handler/provisioning.py::render_config_toml, gateway section dropped —
        the bridge is the gateway here). The
        [providers.models."custom:<url>"] key MUST equal the fallback value
        exactly or the daemon silently ignores api_key/model (a documented
        Guardian gotcha)."""
        base_url = cfg.get("base_url", BROKER_BASE_URL)
        config_dir = os.path.join(agent_home(), ".zeroclaw")
        os.makedirs(config_dir, exist_ok=True)
        chown_to_agent(config_dir)
        # The backend's shell allowlist (provisioning._SHELL_ALLOWED_COMMANDS):
        # without allowed_commands the daemon's default policy blocks even
        # `bash`, which silently kills the reply.sh contract.
        commands = ", ".join(f'"{c}"' for c in [
            "sh", "bash", "python3", "curl", "wget", "cat", "echo", "printf",
            "ls", "head", "tail", "wc", "grep", "sed", "awk", "cut", "tr",
            "sort", "uniq", "base64", "date", "env", "test", "true", "false",
        ])
        path = os.path.join(config_dir, "config.toml")
        with open(path, "w") as f:
            f.write(f"""schema_version = 2

[providers]
fallback = "custom:{base_url}"

[providers.models."custom:{base_url}"]
api_key = {json.dumps(cfg.get("api_key", "chariot-broker"))}
model = {json.dumps(cfg.get("model", ""))}

[autonomy]
level = "full"
max_actions_per_hour = 1000
allowed_commands = [{commands}]

[agent]
max_tool_iterations = 50
max_context_tokens = 200000

[shell_tool]
timeout_secs = 120

[http_request]
enabled = true
allowed_domains = ["*"]

[web_search]
enabled = true
provider = "duckduckgo"
""")
        chown_to_agent(path)

    def execute_turn(self, conversation_id, prompt, cfg, delta, register_proc,
                     turn_env, attachments=()):
        self.last_agent_message = None
        sessions_dir = os.path.join(agent_home(), "chariot", "zeroclaw-sessions")
        os.makedirs(sessions_dir, exist_ok=True)
        chown_to_agent(os.path.join(agent_home(), "chariot"))
        chown_to_agent(sessions_dir)
        session_file = os.path.join(sessions_dir, safe_conversation_name(conversation_id) + ".json")
        flattened = prompt.replace("\n", "\\n")
        code, stdout, stderr = self.run_collected(
            # --config-dir is explicit because zeroclaw's own config-root
            # resolution is environment-sensitive (observed resolving to
            # "/.zeroclaw" under the bridge's direct spawn even with HOME and
            # ZEROCLAW_DATA_DIR set); the flag is deterministic.
            [self.BIN, "agent",
             "--config-dir", os.path.join(agent_home(), ".zeroclaw"),
             "--session-state-file", session_file],
            extra_env={"ZEROCLAW_WORKSPACE": WORKSPACE,
                       "ZEROCLAW_DATA_DIR": agent_home(), **turn_env},
            stdin_text=f"{flattened}\n/exit\n",
            register_proc=register_proc)
        cleaned = self._clean_stdout(stdout)
        if cleaned:
            delta(cleaned if cleaned.endswith("\n") else cleaned + "\n")
            self.last_agent_message = cleaned
        if code != 0 and stderr.strip():
            delta(f"[zeroclaw stderr: {stderr.strip()}]\n")
        return 0 if code == 0 else (code if code > 0 else 1)

    @staticmethod
    def _clean_stdout(stdout):
        """The REPL transcript minus ANSI color, the banner, and prompt
        markers. Response lines arrive prefixed with the "> " prompt, so the
        prefix is stripped rather than the line dropped (dropping them ate
        the actual replies)."""
        text = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", stdout or "")
        lines = []
        for line in text.splitlines():
            line = line.strip()
            while line.startswith(">"):
                line = line[1:].lstrip()
            if not line or line.startswith("🦀") or line == "Type /help for commands.":
                continue
            lines.append(line)
        return "\n".join(lines).strip()


# ------------------------------------------------------------------- OpenClaw

class OpenclawHarness(Harness):
    """OpenClaw via npm (Node 24 from NodeSource), pinned to the backend's
    verified version. Turn shape ports images/openclaw/turn.mjs; like the
    backend image's entrypoint (`exec openclaw gateway`), the bridge keeps a
    long-lived `openclaw gateway` daemon running — per-turn auto-spawned
    gateways proved flaky. The reply contract is stdout-first here (the
    backend's turn.mjs posts extracted payload text); reply.sh still works
    when the model uses it, via the shared outbox pump."""

    name = "openclaw"
    BIN = "/usr/local/bin/openclaw"
    VERSION_PIN = "2026.6.11"
    NODESOURCE = "https://deb.nodesource.com/setup_24.x"

    def __init__(self):
        super().__init__()
        self._gateway = None

    def _ensure_gateway(self, turn_env):
        with state_lock:
            if self._gateway is not None and self._gateway.poll() is None:
                return
        proc = run_as_agent(["openclaw", "gateway"],
                            extra_env=dict(turn_env),
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        with state_lock:
            self._gateway = proc
        time.sleep(2)  # accept the websocket before the first turn

    def _stop_gateway(self):
        with state_lock:
            proc, self._gateway = self._gateway, None
        if proc is not None and proc.poll() is None:
            try:
                os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
            except OSError:
                pass

    def installed(self):
        return shutil.which("openclaw") is not None

    def ensure(self):
        if self.installed():
            return True
        try:
            if shutil.which("npm") is None:
                log("installing Node 24 (NodeSource)…")
                script = "/tmp/nodesource-setup.sh"
                urllib.request.urlretrieve(self.NODESOURCE, script)
                subprocess.run(["bash", script], check=True, capture_output=True)
                subprocess.run(["apt-get", "install", "-y", "nodejs"], check=True,
                               capture_output=True,
                               env={**os.environ, "DEBIAN_FRONTEND": "noninteractive"})
                os.remove(script)
            log(f"npm install -g openclaw@{self.VERSION_PIN}…")
            subprocess.run(["npm", "install", "-g", f"openclaw@{self.VERSION_PIN}"],
                           check=True, capture_output=True, timeout=1800)
            self.install_error = None
            log("openclaw installed")
            return True
        except subprocess.CalledProcessError as e:
            tail = ((e.stderr or b"").decode(errors="replace"))[-300:]
            self.install_error = f"{e} {tail}"
            log(f"openclaw install failed: {self.install_error}")
            return False
        except Exception as e:  # noqa: BLE001
            self.install_error = str(e)
            log(f"openclaw install failed: {e}")
            return False

    def version(self):
        return self._version_from(["openclaw", "--version"])

    def render_config(self, cfg):
        """~/.openclaw/openclaw.json — a full port of
        images/openclaw/render-config.mjs, gateway section included: the
        `openclaw agent` CLI opens a websocket to its own loopback gateway
        and refuses to run without configured credentials (the dummy broker
        key doubles as the gateway token, exactly as the backend image uses
        the agent token)."""
        base_url = cfg.get("base_url", BROKER_BASE_URL)
        model = cfg.get("model", "")
        token = cfg.get("api_key", "chariot-broker")
        config = {
            "models": {
                "providers": {
                    "chariot": {
                        "baseUrl": base_url,
                        "apiKey": token,
                        "api": "openai-completions",
                        "request": {"allowPrivateNetwork": True},
                        "models": [{
                            "id": model,
                            "name": f"Chariot broker ({model})",
                            "reasoning": False,
                            "input": ["text"],
                            "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0},
                            "contextWindow": 128000,
                            "maxTokens": 8192,
                        }],
                    }
                }
            },
            # The shared /workspace, not OpenClaw's ~/.openclaw/workspace
            # default: packs (and the reply.sh contract) live there.
            "agents": {"defaults": {"model": f"chariot/{model}",
                                    "workspace": WORKSPACE}},
            "gateway": {
                "mode": "local",
                "port": 42617,
                "auth": {"mode": "token", "token": token},
            },
        }
        config_dir = os.path.join(agent_home(), ".openclaw")
        os.makedirs(config_dir, exist_ok=True)
        chown_to_agent(config_dir)
        path = os.path.join(config_dir, "openclaw.json")
        with open(path, "w") as f:
            json.dump(config, f, indent=2)
            f.write("\n")
        chown_to_agent(path)
        # OpenClaw scopes its file/shell tools to its own workspace dir and
        # canonicalizes paths (a symlink out of it reads as "not in your
        # workspace"). A root bind mount makes the shared /workspace (packs,
        # tools/reply.sh) BE that workspace — same inode, no escape to
        # detect. Idempotent across re-configures.
        ws_dir = os.path.join(config_dir, "workspace")
        os.makedirs(ws_dir, exist_ok=True)
        chown_to_agent(ws_dir)
        if not os.path.ismount(ws_dir):
            subprocess.run(["mount", "--bind", WORKSPACE, ws_dir],
                           check=False, capture_output=True)
        # Config changed → the running gateway must reread it.
        self._stop_gateway()

    @staticmethod
    def _extract_reply(parsed):
        """`openclaw agent --json` result payloads; liberal about the envelope
        shape across versions (port of turn.mjs::extractReply)."""
        for payloads in (parsed.get("payloads"), (parsed.get("result") or {}).get("payloads")):
            if isinstance(payloads, list):
                texts = [p.get("text") for p in payloads
                         if isinstance(p, dict) and p.get("text")]
                if texts:
                    return "\n\n".join(texts).strip()
        return ""

    def execute_turn(self, conversation_id, prompt, cfg, delta, register_proc,
                     turn_env, attachments=()):
        self.last_agent_message = None
        self._ensure_gateway(turn_env)
        session = "chariot-" + safe_conversation_name(conversation_id)
        code, stdout, stderr = self.run_collected(
            ["openclaw", "agent", "--session-id", session, "--message", prompt, "--json"],
            extra_env=dict(turn_env),
            register_proc=register_proc)
        reply = ""
        if stdout.strip():
            try:
                reply = self._extract_reply(json.loads(stdout))
            except json.JSONDecodeError:
                reply = ""
        if reply:
            delta(reply + "\n")
            self.last_agent_message = reply
        if code != 0:
            if stderr.strip():
                delta(f"[openclaw stderr: {stderr.strip()}]\n")
            return code if code > 0 else 1
        return 0


# --------------------------------------------------------------------- Hermes

# Runner executed as the agent user inside a dedicated venv: one message → one
# Hermes turn → the reply (and only the reply) on stdout. Port of
# images/hermes/turn.py with the outbound POST replaced by stdout capture —
# the bridge owns delivery here.
HERMES_RUNNER = '''\
import json, os, sys
from pathlib import Path

MAX_ITERATIONS = 10
HISTORY_TRIM_THRESHOLD = 60
HISTORY_KEEP_TAIL = 40

history_path = Path(os.environ["CHARIOT_HISTORY_FILE"])

def load_history():
    try:
        loaded = json.loads(history_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return []
    return [m for m in loaded if isinstance(m, dict)] if isinstance(loaded, list) else []

def trim(messages):
    if len(messages) <= HISTORY_TRIM_THRESHOLD:
        return messages
    tail = messages[-HISTORY_KEEP_TAIL:]
    for i, message in enumerate(tail):
        if message.get("role") == "user":
            return tail[i:]
    return []

def save_history(messages):
    history_path.parent.mkdir(parents=True, exist_ok=True)
    try:
        history_path.write_text(json.dumps(trim(messages), ensure_ascii=False, default=str),
                                encoding="utf-8")
    except OSError as exc:
        print(f"failed to persist history: {exc}", file=sys.stderr)

def main():
    from run_agent import AIAgent
    message = sys.stdin.read()
    if not message.strip():
        print("no message on stdin", file=sys.stderr)
        return 1
    agent = AIAgent(
        base_url=os.environ["CHARIOT_BASE_URL"],
        api_key=os.environ.get("CHARIOT_API_KEY", "chariot-broker"),
        provider="custom",
        model=os.environ["CHARIOT_MODEL"],
        max_iterations=MAX_ITERATIONS,
        quiet_mode=True,
        skip_context_files=True,
    )
    history = load_history()
    result = agent.run_conversation(message, conversation_history=history or None)
    messages = result.get("messages") or []
    reply = (result.get("final_response") or "").strip()
    save_history(messages)
    if not reply:
        print("agent produced no reply text", file=sys.stderr)
        return 1
    sys.stdout.write(reply)
    return 0

if __name__ == "__main__":
    sys.exit(main())
'''


class HermesHarness(Harness):
    """Nous Research hermes-agent in a dedicated venv, exact-pinned like the
    backend image. Debian 12 ships Python 3.11 (the backend image is 3.12);
    the pin is tried on 3.11 first — if it needs 3.12 the install error says
    so loudly and the pin moves to a uv-managed interpreter (plan risk R1)."""

    name = "hermes"
    VENV = "/opt/hermes"
    VERSION_PIN = "0.18.0"
    RUNNER = "/opt/chariot/hermes_turn.py"

    def installed(self):
        # The venv's bin/python appears even when venv creation failed halfway
        # (Debian ships python3 without ensurepip); the package itself is the
        # real marker.
        return bool(glob.glob(os.path.join(
            self.VENV, "lib", "python*", "site-packages", "run_agent*")))

    def ensure(self):
        if self.installed():
            return True
        try:
            log(f"installing hermes-agent {self.VERSION_PIN} (venv)…")
            # Debian's python3 has no ensurepip until python3-venv is present,
            # and the fresh cloud image has no apt lists until update runs.
            apt_env = {**os.environ, "DEBIAN_FRONTEND": "noninteractive"}
            subprocess.run(["apt-get", "update"], check=True,
                           capture_output=True, timeout=600, env=apt_env)
            subprocess.run(["apt-get", "install", "-y", "python3-venv"],
                           check=True, capture_output=True, timeout=600, env=apt_env)
            subprocess.run(["python3", "-m", "venv", "--clear", self.VENV], check=True,
                           capture_output=True, timeout=300)
            subprocess.run([os.path.join(self.VENV, "bin", "pip"), "install",
                            "--no-cache-dir", f"hermes-agent=={self.VERSION_PIN}"],
                           check=True, capture_output=True, timeout=1800)
            self._write_runner()
            self.install_error = None
            log("hermes installed")
            return True
        except subprocess.CalledProcessError as e:
            tail = ((e.stderr or b"").decode(errors="replace"))[-300:]
            self.install_error = f"{e} {tail}"
            log(f"hermes install failed: {self.install_error}")
            return False
        except Exception as e:  # noqa: BLE001
            self.install_error = str(e)
            log(f"hermes install failed: {e}")
            return False

    def version(self):
        return self.VERSION_PIN if self.installed() else None

    def _write_runner(self):
        os.makedirs(os.path.dirname(self.RUNNER), exist_ok=True)
        with open(self.RUNNER, "w") as f:
            f.write(HERMES_RUNNER)

    def render_config(self, cfg):
        """~/.hermes/config.yaml (port of images/hermes/turn.py::
        ensure_hermes_config). context_length is pinned because the broker
        exposes no /models to probe. The runner is (re)written here too —
        cloud-init preinstalls the venv, so ensure() may never run."""
        self._write_runner()
        config_dir = os.path.join(agent_home(), ".hermes")
        os.makedirs(config_dir, exist_ok=True)
        chown_to_agent(config_dir)
        path = os.path.join(config_dir, "config.yaml")
        with open(path, "w") as f:
            f.write("# Rendered by the Chariot bridge from agent.configure.\n"
                    "model:\n"
                    f"  default: {json.dumps(cfg.get('model', ''))}\n"
                    "  provider: custom\n"
                    f"  base_url: {json.dumps(cfg.get('base_url', BROKER_BASE_URL))}\n"
                    "  context_length: 128000\n")
        chown_to_agent(path)

    def execute_turn(self, conversation_id, prompt, cfg, delta, register_proc,
                     turn_env, attachments=()):
        self.last_agent_message = None
        history_dir = os.path.join(agent_home(), "chariot", "hermes-history")
        os.makedirs(history_dir, exist_ok=True)
        chown_to_agent(os.path.join(agent_home(), "chariot"))
        chown_to_agent(history_dir)
        history = os.path.join(history_dir, safe_conversation_name(conversation_id) + ".json")
        code, stdout, stderr = self.run_collected(
            [os.path.join(self.VENV, "bin", "python"), self.RUNNER],
            extra_env={
                "CHARIOT_BASE_URL": cfg.get("base_url", BROKER_BASE_URL),
                "CHARIOT_API_KEY": cfg.get("api_key", "chariot-broker"),
                "CHARIOT_MODEL": cfg.get("model", ""),
                "CHARIOT_HISTORY_FILE": history,
                **turn_env,
            },
            stdin_text=prompt,
            register_proc=register_proc)
        reply = stdout.strip()
        if reply:
            delta(reply + "\n")
            self.last_agent_message = reply
        if code != 0:
            if stderr.strip():
                delta(f"[hermes stderr: {stderr.strip()}]\n")
            return code if code > 0 else 1
        return 0


# ----------------------------------------------------------------------- Muse

class MuseHarness(Harness):
    """Meta's Muse Code CLI via the documented curl|bash installer (arm64
    artifacts exist; MUSE_NO_AUTO_UPDATE pins whatever installed). Turn shape
    ports images/muse/turn.mjs: per-conversation client-minted session UUID,
    rotate-on-resume-failure, reply from the run.terminal.completed event."""

    name = "muse"
    BIN = "/usr/local/bin/muse"
    INSTALLER = "https://dev.meta.ai/install.sh"

    def installed(self):
        return os.path.exists(self.BIN) and os.access(self.BIN, os.X_OK)

    def ensure(self):
        if self.installed():
            return True
        try:
            log("installing muse (dev.meta.ai installer)…")
            subprocess.run(
                ["bash", "-c", f"curl -fsSL {self.INSTALLER} | bash"],
                check=True, capture_output=True, timeout=1800,
                env={**os.environ, "MUSE_INSTALL_DIR": "/usr/local/bin",
                     "MUSE_NO_MODIFY_PATH": "1", "MUSE_NO_AUTO_UPDATE": "1"})
            subprocess.run([self.BIN, "--version"], check=True,
                           capture_output=True, timeout=120)
            self.install_error = None
            log("muse installed")
            return True
        except subprocess.CalledProcessError as e:
            tail = ((e.stderr or b"").decode(errors="replace"))[-300:]
            self.install_error = f"{e} {tail}"
            log(f"muse install failed: {self.install_error}")
            return False
        except Exception as e:  # noqa: BLE001
            self.install_error = str(e)
            log(f"muse install failed: {e}")
            return False

    def version(self):
        return self._version_from([self.BIN, "--version"], timeout=60)

    def argv(self, session_id, prompt_path, cfg):
        return [
            self.BIN, "exec", "--json",
            # Muse's own wire (OpenAI Responses over SSE); the chariot proxy's
            # /responses passthrough speaks it. Local servers that lack a
            # Responses endpoint are surfaced by the M6 matrix (plan risk).
            "--provider", "meta",
            "--base-url", cfg.get("base_url", BROKER_BASE_URL),
            "--model", cfg.get("model", ""),
            "--api-key-stdin",
            "--disable-approval",
            "--disable-sandbox",
            "--trust-workspace",
            "--workspace", WORKSPACE,
            "--session-id", session_id,
            "--prompt-file", prompt_path,
        ]

    @staticmethod
    def _reply_from_events(stdout):
        text, terminal = "", ""
        for line in (stdout or "").splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue
            if record.get("payload_type") != "run.terminal.completed":
                continue
            payload = record.get("payload") or {}
            terminal = payload.get("terminal") or ""
            text = payload.get("text") if isinstance(payload.get("text"), str) else ""
        return (text or "").strip(), terminal

    def execute_turn(self, conversation_id, prompt, cfg, delta, register_proc,
                     turn_env, attachments=()):
        self.last_agent_message = None
        session_id = session_for(self.name, conversation_id)
        resuming = bool(session_id)
        if not session_id:
            session_id = str(uuid_module.uuid4())

        prompt_path = f"/tmp/muse-prompt-{uuid_module.uuid4()}"
        with open(prompt_path, "w") as f:
            f.write(prompt)
        os.chmod(prompt_path, 0o644)
        try:
            code, stdout, stderr = self.run_collected(
                self.argv(session_id, prompt_path, cfg),
                extra_env=dict(turn_env),
                stdin_text=cfg.get("api_key", "chariot-broker") + "\n",
                register_proc=register_proc)
            if code != 0 and resuming:
                # Rotate a poisoned session instead of bricking every future
                # turn (port of turn.mjs).
                forget_session(conversation_id)
                return RETRY_FRESH
            reply, terminal = self._reply_from_events(stdout)
            if terminal and terminal != "completed":
                delta(f"[muse: run ended {terminal}]\n")
            if reply:
                delta(reply + "\n")
                self.last_agent_message = reply
            if code != 0:
                if stderr.strip():
                    delta(f"[muse stderr: {stderr.strip()}]\n")
                return code if code > 0 else 1
            remember_session(self.name, conversation_id, session_id)
            return 0
        finally:
            try:
                os.remove(prompt_path)
            except OSError:
                pass


HARNESSES = {cls.name: cls for cls in
             (CodexHarness, ZeroclawHarness, OpenclawHarness, HermesHarness, MuseHarness)}

_adapter_lock = threading.Lock()
_adapter = None


def current_adapter():
    global _adapter
    with _adapter_lock:
        name = configured_harness_name()
        if _adapter is None or _adapter.name != name:
            _adapter = HARNESSES.get(name, CodexHarness)()
        return _adapter


def ensure_harness_forever():
    """Keep trying to install the harness until it is there.

    On first boot this races cloud-init bringing up DHCP, and the codex-only
    ancestor of this loop used to lose silently: ensure ran once, failed with
    no route to host, and never tried again. The backoff also covers the
    flakier installers (npm, curl|bash) the new harnesses bring.
    """
    delay = 2
    while True:
        adapter = current_adapter()
        if adapter.installed() or adapter.ensure():
            return
        time.sleep(delay)
        # Back off to a minute: a guest with no network yet recovers in
        # seconds, but one that needs a human (proxy, captive portal) should
        # not spend the session re-downloading.
        delay = min(delay * 2, 60)


def sandbox_status():
    adapter = current_adapter()
    cfg = read_config()
    power = power_source(cfg)
    if power == "chatgpt":
        # A non-codex harness that never received agent.configure reads as
        # not-ready rather than crashing on a codex-only credential check.
        ready = isinstance(adapter, CodexHarness) and adapter.logged_in()
    else:
        ready = bool(cfg.get("base_url"))
    return {
        "type": "sandbox.status",
        "version": PROTOCOL_VERSION,
        "state": "running",
        "uptime_seconds": int(time.time() - start_time),
        "workspace": WORKSPACE,
        "kernel": os.uname().release,
        "hostname": socket.gethostname(),
        "agent": {
            "name": adapter.name,
            "installed": adapter.installed(),
            "version": adapter.version(),
            # Historical key: for chatgpt-codex this is the OAuth state; for
            # API-powered agents it means "configured and ready".
            "logged_in": ready,
            "install_error": adapter.install_error,
            "power_source": power,
            "config_applied": bool(cfg),
        },
    }


# ------------------------------------------------------- Conversation state

def conversation_lock(conversation_id):
    """One turn at a time per conversation: two concurrent turns would share a
    harness session and an outbox directory, and interleave both."""
    with state_lock:
        lock = conversation_locks.get(conversation_id)
        if lock is None:
            lock = threading.Lock()
            conversation_locks[conversation_id] = lock
        return lock


# ---------------------------------------------------------------- Agent turns

def run_agent_turn(conn_file, write_lock, request):
    conversation_id = request.get("conversation_id", "default")
    request_id = request.get("request_id", "")
    prompt = request.get("body", {}).get("text", "")
    attachments = request.get("body", {}).get("attachments") or []
    adapter = current_adapter()
    cfg = read_config()

    def emit(obj):
        with write_lock:
            send(conn_file, obj)

    def delta(text, channel=CHANNEL_TRACE):
        emit({
            "type": "output.delta",
            "version": PROTOCOL_VERSION,
            "request_id": request_id,
            "conversation_id": conversation_id,
            "channel": channel,
            "text": text,
        })

    def completed(code):
        with state_lock:
            cancel_procs.pop(conversation_id, None)
        with write_lock:
            send(conn_file, {
                "type": "output.completed",
                "version": PROTOCOL_VERSION,
                "request_id": request_id,
                "conversation_id": conversation_id,
                "exit_code": code,
            })

    # Debug fallback: '!' runs a raw shell command (kept per goal statement).
    # Its output *is* the answer to an explicit request, so it goes out on the
    # reply channel rather than the trace.
    if prompt.startswith("!"):
        run_shell_debug(prompt[1:].strip(), conversation_id, delta, completed)
        return

    if not adapter.installed() and not adapter.ensure():
        delta(f"{adapter.name} is not installed in the sandbox: {adapter.install_error}\n",
              CHANNEL_REPLY)
        completed(1)
        return
    ok, reason = adapter.ready(cfg)
    if not ok:
        delta(reason + "\n", CHANNEL_REPLY)
        completed(1)
        return

    with conversation_lock(conversation_id):
        exit_code = execute_turn(adapter, conversation_id, prompt, cfg, delta,
                                 attachments=attachments,
                                 request_id=request_id, emit=emit)
        if exit_code is RETRY_FRESH:
            log("resume failed; retrying with a fresh session")
            forget_session(conversation_id)
            exit_code = execute_turn(adapter, conversation_id, prompt, cfg, delta,
                                     attachments=attachments,
                                     request_id=request_id, emit=emit)
            if exit_code is RETRY_FRESH:  # can only happen with a session id
                exit_code = 1
    completed(exit_code)


def execute_turn(adapter, conversation_id, prompt, cfg, delta,
                 attachments=(), request_id="", emit=None):
    """One harness turn wrapped in the shared reply contract: the outbox and
    tool-call drop boxes are reset and pumped for the duration (replies reach
    the phone mid-turn; phone tool calls only make sense mid-turn, while
    their script still polls), and a turn that never used its reply tool
    falls back to the harness's last agent message rather than silence.
    `emit` sends a raw guest→host object (tool.call forwarding); without it,
    phone tool calls are answered with an immediate failure so the calling
    script does not sit out its timeout."""
    outbox = outbox_dir(conversation_id)
    toolcalls = toolcalls_dir(conversation_id)
    try:
        reset_outbox(outbox)
    except OSError as e:
        log(f"outbox unavailable ({e}); falling back to the final agent message")
    try:
        reset_dropbox(toolcalls, TOOLCALL_ROOT)
    except OSError as e:
        log(f"toolcalls dropbox unavailable ({e}); phone tools disabled this turn")

    if attachments:
        # The model always gets the paths — codex additionally gets pixels
        # via -i — so it can re-open any attachment with its own tools.
        listing = "\n".join(f"- {p}" for p in attachments)
        prompt = f"{prompt}\n\n[Attached files from your person:\n{listing}\n]"

    replies = 0
    stop_pump = threading.Event()

    def flush_outbox():
        nonlocal replies
        for message in drain_outbox(outbox):
            replies += 1
            delta(message, CHANNEL_REPLY)

    def flush_toolcalls():
        # Requests the agent's phone.sh dropped since the last scan. Read and
        # unlink first: a request must never be forwarded twice.
        try:
            names = sorted(n for n in os.listdir(toolcalls)
                           if n.endswith(REQUEST_SUFFIX))
        except OSError:
            return
        for name in names:
            full = os.path.join(toolcalls, name)
            try:
                with open(full, encoding="utf-8", errors="replace") as f:
                    raw = f.read()
                os.unlink(full)
            except OSError:
                continue
            call_id = name[:-len(REQUEST_SUFFIX)]
            try:
                call = json.loads(raw)
                tool_name = call["name"]
                arguments = call.get("arguments")
                if not isinstance(arguments, dict):
                    arguments = {}
                call_id = call.get("request_id") or call_id
            except (ValueError, KeyError, TypeError):
                # Fail the script fast; the filename is the only id we have.
                write_tool_result(toolcalls, call_id,
                                  {"ok": False, "output": "",
                                   "error": "malformed request"})
                continue
            if emit is None:
                write_tool_result(toolcalls, call_id,
                                  {"ok": False, "output": "",
                                   "error": "tool channel unavailable"})
                continue
            with state_lock:
                pending_tool_calls[call_id] = toolcalls
            emit({"type": "tool.call", "version": PROTOCOL_VERSION,
                  "request_id": call_id, "turn_request_id": request_id,
                  "conversation_id": conversation_id, "name": tool_name,
                  "arguments": arguments})

    def pump_dropboxes():
        while not stop_pump.is_set():
            flush_outbox()
            flush_toolcalls()
            time.sleep(OUTBOX_POLL_SECONDS)

    pump = threading.Thread(target=pump_dropboxes, daemon=True)
    pump.start()

    def register_proc(proc):
        with state_lock:
            cancel_procs[conversation_id] = proc

    turn_env = {"CHARIOT_OUTBOX": outbox, "CHARIOT_TOOLCALLS": toolcalls}
    try:
        exit_code = adapter.execute_turn(conversation_id, prompt, cfg, delta,
                                         register_proc, turn_env,
                                         attachments=attachments)
    finally:
        stop_pump.set()
        pump.join(timeout=OUTBOX_POLL_SECONDS * 8)
        flush_outbox()
        # Final sweep: a request written in the turn's last instant still
        # goes out (its answer will be dropped below, but the phone may act
        # on it). Then drop the calls nobody is polling for anymore — a
        # result arriving after this would otherwise write into a dead
        # dropbox.
        flush_toolcalls()
        with state_lock:
            for rid in [rid for rid, d in pending_tool_calls.items() if d == toolcalls]:
                pending_tool_calls.pop(rid, None)

    if exit_code is RETRY_FRESH:
        return RETRY_FRESH
    if replies == 0 and adapter.last_agent_message:
        # Safety net for a turn that never called its reply tool: better a
        # slightly raw answer than silence on the phone.
        delta(adapter.last_agent_message.rstrip("\n") + "\n", CHANNEL_REPLY)
    return exit_code


def run_shell_debug(command, conversation_id, delta, completed):
    delta(f"$ {command}\n", CHANNEL_REPLY)
    try:
        proc = run_as_agent(["/bin/bash", "-lc", command],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    except Exception as e:  # noqa: BLE001
        delta(f"[failed: {e}]\n", CHANNEL_REPLY)
        completed(1)
        return
    with state_lock:
        cancel_procs[conversation_id] = proc
    while True:
        chunk = proc.stdout.read(4096)
        if not chunk:
            proc.wait()
            break
        delta(chunk.decode("utf-8", errors="replace"), CHANNEL_REPLY)
    close_pipes(proc)
    completed(proc.returncode or 0)


def handle_file_put(conn_file, write_lock, request):
    """Install one file into the workspace (Milestone 1: agent packs).

    The host pushes pack content (markdown, skills, tool scripts) through this
    op. Paths are restricted to /workspace, parent directories are created and
    handed to the agent user, and the write is atomic (temp file + rename).
    `if_absent` skips files that already exist, which is how seed-only content
    (e.g. MEMORY.md) survives re-populates without being overwritten.
    """
    request_id = request.get("request_id", "")

    def result(ok, error=None, written=True):
        with write_lock:
            send(conn_file, {"type": "file.put.result", "version": PROTOCOL_VERSION,
                             "request_id": request_id, "ok": ok,
                             "written": ok and written, "error": error})

    path = os.path.normpath(request.get("path", ""))
    if not path.startswith(WORKSPACE + "/"):
        result(False, f"path must be under {WORKSPACE}")
        return
    try:
        content = base64.b64decode(request.get("content_b64", ""), validate=True)
    except (ValueError, TypeError) as e:
        result(False, f"invalid base64 body: {e}")
        return
    if request.get("if_absent") and os.path.lexists(path):
        result(True, written=False)
        return
    try:
        info = pwd.getpwnam(AGENT_USER)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        parent = os.path.dirname(path)
        while parent != WORKSPACE and parent.startswith(WORKSPACE):
            os.chown(parent, info.pw_uid, info.pw_gid)
            parent = os.path.dirname(parent)
        tmp = path + ".chariot-put"
        with open(tmp, "wb") as f:
            f.write(content)
        os.chmod(tmp, int(request.get("mode", 0o644)))
        os.chown(tmp, info.pw_uid, info.pw_gid)
        os.replace(tmp, path)
        result(True)
    except OSError as e:
        result(False, str(e))


def handle_agent_configure(conn_file, write_lock, request):
    """Apply the host-pushed power configuration: persist it (outside
    /workspace, so the agent cannot rewrite its own power source), render the
    harness-native config as the agent user, and make sure the loopback model
    forwarder is up before acking."""
    request_id = request.get("request_id", "")

    def result(ok, error=None):
        with write_lock:
            send(conn_file, {"type": "agent.configure.result",
                             "version": PROTOCOL_VERSION,
                             "request_id": request_id, "ok": ok, "error": error})

    cfg = {key: request[key] for key in
           ("harness", "power_source", "model", "base_url", "api_key")
           if key in request}
    try:
        write_config(cfg)
        adapter = current_adapter()
        if power_source(cfg) != "chatgpt":
            start_broker_forwarder()
            adapter.render_config(cfg)
        log(f"configured: {adapter.name}/{power_source(cfg)} model={cfg.get('model', '')!r}")
        result(True)
    except Exception as e:  # noqa: BLE001
        log(f"agent.configure failed: {e}")
        result(False, str(e))


def cancel_conversation(conversation_id):
    with state_lock:
        proc = cancel_procs.get(conversation_id)
    if proc:
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
        except OSError:
            pass
        log(f"cancelled turn for {conversation_id}")


# ---------------------------------------------------------------- Codex login

def start_login(conn_file, write_lock):
    """Run `codex login` and broker the browser step to the host (design §3.1):
    emit oauth.requested with the auth URL; the host opens it and forwards the
    localhost:1455 callback back in over vsock port 1022. Only meaningful for
    the chatgpt-powered codex harness; the host guards too, but the bridge is
    the authority."""
    global login_proc

    def notify(obj):
        with write_lock:
            send(conn_file, obj)

    adapter = current_adapter()
    if not adapter.supports_login() or power_source() != "chatgpt":
        notify({"type": "oauth.completed", "version": PROTOCOL_VERSION,
                "success": False,
                "message": f"{adapter.name}/{power_source()} has no ChatGPT sign-in"})
        return

    with state_lock:
        if login_proc is not None and login_proc.poll() is None:
            notify({"type": "error", "error": "login already in progress"})
            return

    if not adapter.installed() and not adapter.ensure():
        notify({"type": "oauth.completed", "version": PROTOCOL_VERSION,
                "success": False, "message": f"codex install failed: {adapter.install_error}"})
        return
    if adapter.logged_in():
        notify({"type": "oauth.completed", "version": PROTOCOL_VERSION,
                "success": True, "message": "already signed in"})
        return

    try:
        proc = run_as_agent([CodexHarness.BIN, "login"],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    except Exception as e:  # noqa: BLE001
        notify({"type": "oauth.completed", "version": PROTOCOL_VERSION,
                "success": False, "message": f"could not start codex login: {e}"})
        return
    with state_lock:
        login_proc = proc

    def pump():
        url_sent = False
        for line in proc.stdout:
            line = line.strip()
            log(f"codex login: {line}")
            if not url_sent and "https://" in line:
                url = line[line.index("https://"):].split()[0]
                if "auth" in url or "openai" in url:
                    url_sent = True
                    notify({"type": "oauth.requested", "version": PROTOCOL_VERSION,
                            "provider": "openai-chatgpt",
                            "purpose": "Sign in Codex inside the sandbox",
                            "auth_url": url})
        proc.wait()
        success = proc.returncode == 0 and adapter.logged_in()
        notify({"type": "oauth.completed", "version": PROTOCOL_VERSION,
                "success": success,
                "message": "signed in" if success else f"login exited {proc.returncode}"})
        notify(sandbox_status())

    threading.Thread(target=pump, daemon=True).start()


def cancel_login():
    with state_lock:
        proc = login_proc
    if proc and proc.poll() is None:
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
        except OSError:
            pass


# ---------------------------------------------------------------- Connections

def handle_agent_connection(conn):
    conn_file = conn.makefile("rwb")
    write_lock = threading.Lock()
    log("host connected to agent port")
    with write_lock:
        send(conn_file, sandbox_status())
    buffer = b""
    try:
        while True:
            chunk = conn.recv(65536)
            if not chunk:
                break
            buffer += chunk
            if len(buffer) > MAX_LINE_BYTES:
                log("oversized message; closing connection")
                return
            while b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                if not line.strip():
                    continue
                try:
                    request = json.loads(line)
                except json.JSONDecodeError:
                    with write_lock:
                        send(conn_file, {"type": "error", "error": "malformed json"})
                    continue
                rtype = request.get("type")
                if rtype == "conversation.send":
                    threading.Thread(target=run_agent_turn,
                                     args=(conn_file, write_lock, request),
                                     daemon=True).start()
                elif rtype == "conversation.cancel":
                    cancel_conversation(request.get("conversation_id", "default"))
                elif rtype == "sandbox.status":
                    with write_lock:
                        send(conn_file, sandbox_status())
                elif rtype == "file.put":
                    # Inline (not threaded): pack pushes stay ordered ahead of
                    # any conversation.send that follows them.
                    handle_file_put(conn_file, write_lock, request)
                elif rtype == "agent.configure":
                    # Inline for the same reason: the config must land before
                    # any turn that follows it.
                    handle_agent_configure(conn_file, write_lock, request)
                elif rtype == "tool.result":
                    # Inline like file.put: just a dropbox write, and the
                    # polling script is waiting on it.
                    handle_tool_result(request)
                elif rtype == "oauth.start":
                    threading.Thread(target=start_login,
                                     args=(conn_file, write_lock), daemon=True).start()
                elif rtype == "oauth.cancel":
                    cancel_login()
                elif rtype == "ping":
                    with write_lock:
                        send(conn_file, {"type": "pong", "version": PROTOCOL_VERSION})
                else:
                    with write_lock:
                        send(conn_file, {"type": "error", "error": f"unknown type {rtype!r}"})
    except OSError as e:
        log(f"agent connection error: {e}")
    finally:
        log("host disconnected from agent port")
        try:
            conn.close()
        except OSError:
            pass


def pipe(src, dst):
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        for s in (src, dst):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


def tcp_tunnel_handler(target_port):
    def handle(conn):
        try:
            target = socket.create_connection(("127.0.0.1", target_port), timeout=10)
        except OSError as e:
            log(f"tunnel to :{target_port} unreachable: {e}")
            conn.close()
            return
        threading.Thread(target=pipe, args=(conn, target), daemon=True).start()
        threading.Thread(target=pipe, args=(target, conn), daemon=True).start()
    return handle


# ---------------------------------------------------------- Model forwarder

_broker_thread = None


def start_broker_forwarder():
    """Loopback → host model broker: listen on 127.0.0.1:8090 and pipe each
    accepted connection to the host over vsock (the host's ModelBroker
    listens on port 8090 and attaches the real credential). Idempotent."""
    global _broker_thread
    with state_lock:
        if _broker_thread is not None and _broker_thread.is_alive():
            return
        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind(("127.0.0.1", BROKER_LOCAL_PORT))
        server.listen(16)

        def accept_loop():
            log(f"model forwarder on 127.0.0.1:{BROKER_LOCAL_PORT}")
            while True:
                conn, _ = server.accept()
                try:
                    host = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
                    host.connect((socket.VMADDR_CID_HOST, BROKER_VSOCK_PORT))
                except OSError as e:
                    log(f"model broker unreachable over vsock: {e}")
                    conn.close()
                    continue
                threading.Thread(target=pipe, args=(conn, host), daemon=True).start()
                threading.Thread(target=pipe, args=(host, conn), daemon=True).start()

        _broker_thread = threading.Thread(target=accept_loop, daemon=True)
        _broker_thread.start()


def serve(port, handler):
    s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
    s.bind((socket.VMADDR_CID_ANY, port))
    s.listen(4)
    log(f"listening on vsock port {port}")
    while True:
        conn, addr = s.accept()
        log(f"connection on port {port} from cid {addr[0]}")
        threading.Thread(target=handler, args=(conn,), daemon=True).start()


def main():
    os.makedirs(WORKSPACE, exist_ok=True)
    os.makedirs(STATE_DIR, exist_ok=True)
    threading.Thread(target=ensure_harness_forever, daemon=True).start()
    # A persisted config from a previous boot: come up configured before the
    # host reconnects, so the first turn does not race agent.configure.
    cfg = read_config()
    if cfg and power_source(cfg) != "chatgpt":
        try:
            start_broker_forwarder()
            current_adapter().render_config(cfg)
        except Exception as e:  # noqa: BLE001
            log(f"could not restore persisted config: {e}")
    threading.Thread(target=serve, args=(SSH_TUNNEL_PORT, tcp_tunnel_handler(22)),
                     daemon=True).start()
    threading.Thread(target=serve, args=(LOGIN_TUNNEL_PORT, tcp_tunnel_handler(LOGIN_CALLBACK_PORT)),
                     daemon=True).start()
    serve(AGENT_PORT, handle_agent_connection)


if __name__ == "__main__":
    main()
