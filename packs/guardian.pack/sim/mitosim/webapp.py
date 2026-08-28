"""Local review web app.

Serves a single page that carries the verification suite results baked in, plus
a live scenario explorer backed by the real engine. Standard library only: no
web framework, no CDN, nothing to install.

The app binds to localhost by default. It exposes a person's health inputs and
runs simulations, so it is not meant to be exposed on a network interface.
"""

from __future__ import annotations

import json
import os
import threading
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Dict, Optional
from urllib.parse import urlparse, parse_qs

from . import guardrails
from .adapters import catalogue
from .levers.androgen_evidence import table as androgen_table
from .mechanisms import catalogue as mechanism_catalogue
from .compare import compare
from .ensemble import (run_ensemble, EST_DEFS, OUTPUT_MEANINGS, MODEL_VERSION,
                       TISSUE, ACTIVITY)
from .effects import STATUS_MEANINGS
from .muscle import reductions
from .outputs import FORBIDDEN_OUTPUTS
from .params import R, REGISTRY_VERSION
from .inputs import PersonInputs
from .profiles import load_person, scenario_from_dict
from .qc import run_qc, LAB_ROLES
from .scenario import grid_report, PATTERNS

HERE = os.path.dirname(os.path.abspath(__file__))
WEB = os.path.join(HERE, "web")


class State:
    person: Optional[PersonInputs] = None
    profile_path = ""
    validation: Dict[str, Any] = {}
    meta: Dict[str, Any] = {}


def _build_meta() -> Dict[str, Any]:
    params = []
    for p in R:
        d = p.to_dict()
        params.append({
            "name": d["name"], "value": d["value"], "unit": d["unit"],
            "pclass": d["pclass"], "support": d["support"],
            "rationale": d["rationale"], "source": d["source"],
            "citation": d["source_detail"]["citation"],
            "url": d["source_detail"]["url"],
            "population": d["source_detail"]["population"],
            "tissue": d["source_detail"]["tissue"],
            "domain": d["source_detail"]["domain"],
            "dist": d["dist"], "tags": list(d["tags"]),
        })
    eqs = [e.to_dict() for e in R.equations()]
    return {
        "model_version": MODEL_VERSION,
        "registry_version": REGISTRY_VERSION,
        "tissue": TISSUE,
        "activity": ACTIVITY,
        "parameters": params,
        "equations": eqs,
        "reductions": reductions(),
        "adapters": catalogue(),
        "mechanisms": mechanism_catalogue(),
        "androgen_mediators": androgen_table(),
        "effect_statuses": {k: v for k, v in STATUS_MEANINGS.items()},
        "grid": grid_report(),
        "network_audit": guardrails.summarise(guardrails.audit_network()),
        "forbidden_outputs": FORBIDDEN_OUTPUTS,
        "lab_roles": {k: v.__dict__ for k, v in LAB_ROLES.items()},
        # What each output key means, taken straight from the definitions the
        # engine reports with, so the page never carries its own copy of the
        # prose that could drift from the engine's.
        "outputs": {key: {"label": label, "unit": unit, "kind": kind,
                          "support": support, "note": note,
                          "meaning": OUTPUT_MEANINGS.get(key, "")}
                    for key, label, unit, kind, support, note in EST_DEFS},
        "patterns": list(PATTERNS),
        "param_class_counts": {c: len(R.by_class(c)) for c in
                               ("observed", "inferred", "population",
                                "structural")},
        "support_counts": _support_counts(),
    }


def _support_counts() -> Dict[str, int]:
    out: Dict[str, int] = {}
    for p in R:
        out[p.support] = out.get(p.support, 0) + 1
    return out


class Handler(BaseHTTPRequestHandler):
    server_version = "mitosim/0.2"

    def log_message(self, fmt, *args):
        pass

    def _send(self, code: int, body: bytes, ctype: str):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        try:
            self.wfile.write(body)
        except BrokenPipeError:
            pass

    def _json(self, obj: Any, code: int = 200):
        self._send(code, json.dumps(obj, default=float).encode(),
                   "application/json; charset=utf-8")

    def do_GET(self):
        u = urlparse(self.path)
        if u.path in ("/", "/index.html"):
            with open(os.path.join(WEB, "index.html"), "rb") as f:
                return self._send(200, f.read(), "text/html; charset=utf-8")
        if u.path == "/api/meta":
            return self._json(State.meta)
        if u.path == "/api/validation":
            return self._json(State.validation)
        if u.path == "/api/profile":
            p = State.person
            assert p is not None, "server serves requests only after a person is loaded"
            qc = run_qc(p)
            return self._json({
                "path": State.profile_path,
                "profile": p.to_dict(),
                "qc": qc.to_dict(),
            })
        return self._send(404, b"not found", "text/plain")

    def do_POST(self):
        u = urlparse(self.path)
        n = int(self.headers.get("Content-Length", "0"))
        try:
            payload = json.loads(self.rfile.read(n) or b"{}")
        except Exception as e:
            return self._json({"error": f"bad request body: {e}"}, 400)
        try:
            if u.path == "/api/run":
                sc = scenario_from_dict(payload.get("scenario", {}))
                nn = int(payload.get("n", 96))
                nn = max(8, min(nn, 600))
                assert State.person is not None
                out = run_ensemble(State.person, sc, n=nn,
                                   seed=int(payload.get("seed", 20260826)),
                                   keep_traj=min(nn, 48))
                return self._json(out.to_dict())
            if u.path == "/api/compare":
                a = scenario_from_dict(payload.get("a", {}))
                b = scenario_from_dict(payload.get("b", {}))
                nn = max(8, min(int(payload.get("n", 96)), 400))
                assert State.person is not None
                res = compare(State.person, a, b, n=nn,
                              seed=int(payload.get("seed", 20260826)))
                d = res.to_dict()
                d.pop("a", None)
                d.pop("b", None)
                d["a_trajectories"] = res.a.trajectories
                d["b_trajectories"] = res.b.trajectories
                d["a_warnings"] = res.a.warnings
                d["b_warnings"] = res.b.warnings
                return self._json(d)
        except Exception as e:
            import traceback
            return self._json({"error": f"{type(e).__name__}: {e}",
                               "traceback": traceback.format_exc()}, 500)
        return self._json({"error": "unknown endpoint"}, 404)


def serve(port: int = 8765, profile_path: str = "examples/runner.json",
          validation_path: str = "out/validation.json",
          open_browser: bool = True, host: str = "127.0.0.1") -> None:
    State.profile_path = profile_path
    State.person = load_person(profile_path)
    if os.path.exists(validation_path):
        with open(validation_path) as f:
            State.validation = json.load(f)
    else:
        State.validation = {
            "missing": True,
            "note": f"No validation report at {validation_path}. Run "
                    "`mitosim validate` to generate it; the verification tab "
                    "will stay empty until then.",
        }
    State.meta = _build_meta()

    httpd = ThreadingHTTPServer((host, port), Handler)
    url = f"http://{host}:{port}/"
    print(f"Mitochondria In Silico review app: {url}")
    print(f"  profile    : {profile_path}")
    print(f"  validation : {validation_path}"
          + ("" if not State.validation.get("missing") else "  (not found)"))
    print("  Ctrl-C to stop.")
    if open_browser:
        threading.Timer(0.6, lambda: webbrowser.open(url)).start()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nstopped")
    finally:
        httpd.server_close()
