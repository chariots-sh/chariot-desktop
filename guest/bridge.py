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

import json
import os
import pwd
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
MAX_LINE_BYTES = 1 * 1024 * 1024
OUTPUT_LIMIT_PER_ITEM = 4000

start_time = time.time()
state_lock = threading.Lock()
cancel_procs = {}          # conversation_id -> subprocess.Popen
conversations_started = set()
login_proc = None
codex_install_error = None


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


def run_as_agent(argv, **kwargs):
    info, env = agent_env()
    return subprocess.Popen(argv, user=AGENT_USER, group=info.pw_gid, env=env,
                            cwd=WORKSPACE, start_new_session=True, **kwargs)


# ---------------------------------------------------------------- Codex setup

def codex_installed():
    return all(os.path.exists(p) and os.access(p, os.X_OK) for p in CODEX_BINARIES)


def ensure_codex():
    """Download the Codex CLI binary if missing (guest has NAT internet)."""
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


# ---------------------------------------------------------------- Agent turns

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

    def delta(text):
        with write_lock:
            send(conn_file, {
                "type": "output.delta",
                "version": PROTOCOL_VERSION,
                "request_id": request_id,
                "conversation_id": conversation_id,
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
    if prompt.startswith("!"):
        run_shell_debug(prompt[1:].strip(), conversation_id, delta, completed)
        return

    if not codex_installed() and not ensure_codex():
        delta(f"Codex is not installed in the sandbox: {codex_install_error}\n")
        completed(1)
        return
    if not codex_logged_in():
        delta("Codex isn't signed in yet. On the Mac: Sandbox → Agent → Sign in Codex.\n")
        completed(1)
        return

    flags = ["--json", "--skip-git-repo-check",
             "--dangerously-bypass-approvals-and-sandbox", "-C", WORKSPACE]
    with state_lock:
        resume = conversation_id in conversations_started
    argv = [CODEX_BIN, "exec"] + (["resume", "--last"] if resume else []) + flags + [prompt]

    try:
        proc = run_as_agent(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    except Exception as e:  # noqa: BLE001
        delta(f"[failed to start codex: {e}]\n")
        completed(1)
        return
    with state_lock:
        cancel_procs[conversation_id] = proc

    exit_code = 0
    got_output = False
    for line in proc.stdout:
        line = line.strip()
        if not line:
            continue
        try:
            evt = json.loads(line)
        except json.JSONDecodeError:
            continue
        etype = evt.get("type", "")
        if etype in ("item.completed", "item.updated") and etype == "item.completed":
            text = summarize_item(evt.get("item", {}))
            if text:
                got_output = True
                delta(text)
        elif etype == "turn.failed":
            error = (evt.get("error") or {}).get("message", "turn failed")
            delta(f"[codex: {error}]\n")
            exit_code = 1
        elif etype == "error":
            delta(f"[codex: {evt.get('message', 'error')}]\n")
            exit_code = 1
    proc.wait()
    stderr_tail = proc.stderr.read()[-800:] if proc.stderr else ""
    if proc.returncode != 0:
        exit_code = proc.returncode if proc.returncode > 0 else 1
        if resume and not got_output:
            # A broken resume (e.g. no prior session) — retry fresh once.
            with state_lock:
                conversations_started.discard(conversation_id)
                cancel_procs.pop(conversation_id, None)
            log("resume failed; retrying with a fresh session")
            run_codex_turn(conn_file, write_lock, request)
            return
        if stderr_tail.strip() and not got_output:
            delta(f"[codex stderr: {stderr_tail.strip()}]\n")
    else:
        with state_lock:
            conversations_started.add(conversation_id)
    completed(exit_code)


def run_shell_debug(command, conversation_id, delta, completed):
    delta(f"$ {command}\n")
    try:
        proc = run_as_agent(["/bin/bash", "-lc", command],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    except Exception as e:  # noqa: BLE001
        delta(f"[failed: {e}]\n")
        completed(1)
        return
    with state_lock:
        cancel_procs[conversation_id] = proc
    while True:
        chunk = proc.stdout.read(4096)
        if not chunk:
            proc.wait()
            break
        delta(chunk.decode("utf-8", errors="replace"))
    completed(proc.returncode or 0)


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
    threading.Thread(target=ensure_codex, daemon=True).start()
    threading.Thread(target=serve, args=(SSH_TUNNEL_PORT, tcp_tunnel_handler(22)),
                     daemon=True).start()
    threading.Thread(target=serve, args=(LOGIN_TUNNEL_PORT, tcp_tunnel_handler(LOGIN_CALLBACK_PORT)),
                     daemon=True).start()
    serve(AGENT_PORT, handle_agent_connection)


if __name__ == "__main__":
    main()
