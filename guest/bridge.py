#!/usr/bin/env python3
"""Chariot guest bridge.

Listens on AF_VSOCK ports inside the Linux guest and speaks newline-delimited
JSON with the macOS host (design §1.4). The host is the only possible peer —
vsock is not reachable from the guest's NAT network or the LAN.

Port 1024: typed agent protocol. The agent is OpenAI Codex CLI running in
           /workspace as the unprivileged `agent` user.
Port 1023: developer-access tunnel → guest sshd (127.0.0.1:22).
Port 1022: OAuth-callback tunnel → Codex login server (127.0.0.1:1455), used
           while the host browser completes the ChatGPT sign-in (design §3.1).
"""

import base64
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

AGENT_PORT = 1024
SSH_TUNNEL_PORT = 1023
LOGIN_TUNNEL_PORT = 1022
LOGIN_CALLBACK_PORT = 1455  # fixed: registered OAuth redirect is localhost:1455

WORKSPACE = "/workspace"
AGENT_USER = "agent"
CODEX_BIN = "/usr/local/bin/codex"
CODEX_RELEASE = "https://github.com/openai/codex/releases/download/rust-v0.147.0"
CODEX_BINARIES = {
    "/usr/local/bin/codex": "codex-aarch64-unknown-linux-musl",
    "/usr/local/bin/codex-code-mode-host": "codex-code-mode-host-aarch64-unknown-linux-musl",
}
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

# Codex thread ids, so a conversation survives a bridge or VM restart. Root
# owned and outside /workspace: the agent must not be able to rewrite its own
# continuity, and repopulating a pack must not drop it.
STATE_DIR = "/var/lib/chariot"
THREADS_FILE = os.path.join(STATE_DIR, "threads.json")

# Drop box the agent writes replies into (see packs/*/tools/reply.sh). One
# directory per conversation; one file per message, renamed into place so the
# bridge never reads a half-written message.
OUTBOX_ROOT = os.path.join(WORKSPACE, ".chariot", "outbox")
MESSAGE_SUFFIX = ".msg"
OUTBOX_POLL_SECONDS = 0.25

start_time = time.time()
state_lock = threading.Lock()
cancel_procs = {}          # conversation_id -> subprocess.Popen
conversation_locks = {}    # conversation_id -> threading.Lock
login_proc = None
codex_install_error = None

# Sentinel: the resumed session was unusable, so run the turn again fresh.
RETRY_FRESH = object()


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


# ---------------------------------------------------------------- Codex setup

def codex_installed():
    return all(os.path.exists(p) and os.access(p, os.X_OK) for p in CODEX_BINARIES)


def ensure_codex_forever():
    """Keep trying to install Codex until it is there.

    On first boot this races cloud-init bringing up DHCP, and it used to lose
    silently: ensure_codex ran once, failed with no route to host, recorded the
    error and never tried again. Because the sign-in button is gated on
    `installed`, and the only other callers of ensure_codex are a chat turn or a
    login attempt, the agent could sit at installed=false indefinitely — with a
    restart as the only way out.
    """
    delay = 2
    while not codex_installed():
        if ensure_codex():
            return
        time.sleep(delay)
        # Back off to a minute: a guest with no network yet recovers in
        # seconds, but one that needs a human (proxy, captive portal) should
        # not spend the session re-downloading.
        delay = min(delay * 2, 60)


def ensure_codex():
    """Download any missing Codex binaries (guest has NAT internet)."""
    global codex_install_error
    if codex_installed():
        return True
    try:
        for dest, asset in CODEX_BINARIES.items():
            if os.path.exists(dest):
                continue
            log(f"downloading {asset}…")
            tmp = f"/tmp/{asset}.tar.gz"
            urllib.request.urlretrieve(f"{CODEX_RELEASE}/{asset}.tar.gz", tmp)
            subprocess.run(["tar", "-xzf", tmp, "-C", "/tmp"], check=True)
            shutil.move(f"/tmp/{asset}", dest)
            os.chmod(dest, 0o755)
            os.remove(tmp)
        codex_install_error = None
        log("codex installed")
        return True
    except Exception as e:  # noqa: BLE001
        codex_install_error = str(e)
        log(f"codex install failed: {e}")
        return False


def codex_logged_in():
    info, _ = agent_env()
    auth = os.path.join(info.pw_dir, ".codex", "auth.json")
    return os.path.exists(auth)


def codex_version():
    if not codex_installed():
        return None
    try:
        out = subprocess.run([CODEX_BIN, "--version"], capture_output=True,
                             text=True, timeout=15)
        return out.stdout.strip() or None
    except Exception:  # noqa: BLE001
        return None


def sandbox_status():
    return {
        "type": "sandbox.status",
        "version": PROTOCOL_VERSION,
        "state": "running",
        "uptime_seconds": int(time.time() - start_time),
        "workspace": WORKSPACE,
        "kernel": os.uname().release,
        "hostname": socket.gethostname(),
        "agent": {
            "name": "codex",
            "installed": codex_installed(),
            "version": codex_version(),
            "logged_in": codex_logged_in(),
            "install_error": codex_install_error,
        },
    }


# ------------------------------------------------------- Conversation state

def conversation_lock(conversation_id):
    """One turn at a time per conversation: two concurrent turns would share a
    Codex session and an outbox directory, and interleave both."""
    with state_lock:
        lock = conversation_locks.get(conversation_id)
        if lock is None:
            lock = threading.Lock()
            conversation_locks[conversation_id] = lock
        return lock


def read_threads():
    try:
        with open(THREADS_FILE) as f:
            threads = json.load(f)
        return threads if isinstance(threads, dict) else {}
    except (OSError, ValueError):
        return {}


def write_threads(threads):
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        tmp = THREADS_FILE + ".tmp"
        with open(tmp, "w") as f:
            json.dump(threads, f)
        os.replace(tmp, THREADS_FILE)
    except OSError as e:
        log(f"could not persist thread ids: {e}")


def thread_for(conversation_id):
    with state_lock:
        return read_threads().get(conversation_id)


def remember_thread(conversation_id, thread_id):
    with state_lock:
        threads = read_threads()
        if threads.get(conversation_id) == thread_id:
            return
        threads[conversation_id] = thread_id
        write_threads(threads)


def forget_thread(conversation_id):
    with state_lock:
        threads = read_threads()
        if threads.pop(conversation_id, None) is not None:
            write_threads(threads)


# ------------------------------------------------------------------- Outbox

def outbox_dir(conversation_id):
    safe = re.sub(r"[^A-Za-z0-9._-]", "_", conversation_id or "") or "default"
    return os.path.join(OUTBOX_ROOT, safe)


def reset_outbox(path):
    """Empty drop box owned by the agent user, ready for one turn's replies."""
    os.makedirs(path, exist_ok=True)
    for directory in (os.path.dirname(OUTBOX_ROOT), OUTBOX_ROOT, path):
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


# ---------------------------------------------------------------- Agent turns

def close_pipes(proc):
    """The bridge is long-lived; a finished turn must not leak its pipes."""
    for pipe_file in (proc.stdout, proc.stderr):
        try:
            if pipe_file:
                pipe_file.close()
        except OSError:
            pass


def codex_argv(prompt, thread_id):
    """Argv for one turn, resuming `thread_id` when we have one.

    `--cd/-C` is not a clap *global* in the Codex CLI, so it is rejected after
    the `resume` subcommand and the whole turn dies with a usage error. Resumed
    turns get their working root from the process cwd (/workspace) instead,
    which is the same directory `-C` names on a fresh run.
    """
    flags = ["--json", "--skip-git-repo-check",
             "--dangerously-bypass-approvals-and-sandbox"]
    if thread_id:
        return [CODEX_BIN, "exec", "resume", thread_id] + flags + [prompt]
    return [CODEX_BIN, "exec"] + flags + ["-C", WORKSPACE, prompt]


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


def run_codex_turn(conn_file, write_lock, request):
    conversation_id = request.get("conversation_id", "default")
    request_id = request.get("request_id", "")
    prompt = request.get("body", {}).get("text", "")

    def delta(text, channel=CHANNEL_TRACE):
        with write_lock:
            send(conn_file, {
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

    if not codex_installed() and not ensure_codex():
        delta(f"Codex is not installed in the sandbox: {codex_install_error}\n", CHANNEL_REPLY)
        completed(1)
        return
    if not codex_logged_in():
        delta("Codex isn't signed in yet. On the Mac: Sandbox → Agent → Sign in Codex.\n",
              CHANNEL_REPLY)
        completed(1)
        return

    with conversation_lock(conversation_id):
        exit_code = execute_codex_turn(conversation_id, prompt, delta)
        if exit_code is RETRY_FRESH:
            log("resume failed; retrying with a fresh session")
            forget_thread(conversation_id)
            exit_code = execute_codex_turn(conversation_id, prompt, delta)
            if exit_code is RETRY_FRESH:  # can only happen with a thread id
                exit_code = 1
    completed(exit_code)


def execute_codex_turn(conversation_id, prompt, delta):
    """Run one `codex exec` and stream it. Returns the exit code, or
    RETRY_FRESH when a resumed session never started and the turn is worth
    retrying without one."""
    thread_id = thread_for(conversation_id)
    outbox = outbox_dir(conversation_id)
    try:
        reset_outbox(outbox)
    except OSError as e:
        log(f"outbox unavailable ({e}); falling back to the final agent message")

    try:
        proc = run_as_agent(codex_argv(prompt, thread_id),
                            extra_env={"CHARIOT_OUTBOX": outbox},
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    except Exception as e:  # noqa: BLE001
        delta(f"[failed to start codex: {e}]\n", CHANNEL_REPLY)
        return 1
    with state_lock:
        cancel_procs[conversation_id] = proc

    replies = 0

    def flush_outbox():
        nonlocal replies
        for message in drain_outbox(outbox):
            replies += 1
            delta(message, CHANNEL_REPLY)

    def pump_outbox():
        # Replies reach the phone while the turn is still working, rather than
        # arriving in one lump at the end.
        while proc.poll() is None:
            flush_outbox()
            time.sleep(OUTBOX_POLL_SECONDS)

    pump = threading.Thread(target=pump_outbox, daemon=True)
    pump.start()

    exit_code = 0
    thread_started = False
    last_agent_message = None
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
                remember_thread(conversation_id, evt["thread_id"])
        elif etype == "item.completed":
            item = evt.get("item", {})
            if (item.get("item_type") or item.get("type")) == "agent_message":
                last_agent_message = item.get("text") or last_agent_message
            text = summarize_item(item)
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
    pump.join(timeout=OUTBOX_POLL_SECONDS * 8)
    flush_outbox()

    stderr_tail = proc.stderr.read()[-800:] if proc.stderr else ""
    close_pipes(proc)
    if proc.returncode != 0:
        exit_code = proc.returncode if proc.returncode > 0 else 1
        if thread_id and not thread_started:
            # The session never opened — a stale thread id, or a CLI that
            # rejected the resume. Worth one clean attempt.
            with state_lock:
                cancel_procs.pop(conversation_id, None)
            return RETRY_FRESH
        if stderr_tail.strip() and replies == 0:
            delta(f"[codex stderr: {stderr_tail.strip()}]\n", CHANNEL_REPLY)
    if replies == 0 and last_agent_message:
        # Safety net for a turn that never called its reply tool: better a
        # slightly raw answer than silence on the phone.
        delta(last_agent_message + "\n", CHANNEL_REPLY)
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
    localhost:1455 callback back in over vsock port 1022."""
    global login_proc

    def notify(obj):
        with write_lock:
            send(conn_file, obj)

    with state_lock:
        if login_proc is not None and login_proc.poll() is None:
            notify({"type": "error", "error": "login already in progress"})
            return

    if not codex_installed() and not ensure_codex():
        notify({"type": "oauth.completed", "version": PROTOCOL_VERSION,
                "success": False, "message": f"codex install failed: {codex_install_error}"})
        return
    if codex_logged_in():
        notify({"type": "oauth.completed", "version": PROTOCOL_VERSION,
                "success": True, "message": "already signed in"})
        return

    try:
        proc = run_as_agent([CODEX_BIN, "login"],
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
        success = proc.returncode == 0 and codex_logged_in()
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
                    threading.Thread(target=run_codex_turn,
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
    threading.Thread(target=ensure_codex_forever, daemon=True).start()
    threading.Thread(target=serve, args=(SSH_TUNNEL_PORT, tcp_tunnel_handler(22)),
                     daemon=True).start()
    threading.Thread(target=serve, args=(LOGIN_TUNNEL_PORT, tcp_tunnel_handler(LOGIN_CALLBACK_PORT)),
                     daemon=True).start()
    serve(AGENT_PORT, handle_agent_connection)


if __name__ == "__main__":
    main()
