#!/usr/bin/env python3
"""
End-to-end tests for feather-spend.

Starts a fake OpenAI-compatible upstream, runs the proxy against it, and
checks that spend is recorded and that the cap actually refuses requests.

    python3 tests/test_spend.py
"""

import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
BIN = os.path.join(os.path.dirname(HERE), "bin", "feather-spend")

FAILURES = []


def check(name, cond, detail=""):
    print(f"  {'PASS' if cond else 'FAIL'}  {name}" + (f"  — {detail}" if detail and not cond else ""))
    if not cond:
        FAILURES.append(name)


class FakeUpstream(BaseHTTPRequestHandler):
    """Returns a fixed cost per call, and echoes whether usage was requested."""
    cost_per_call = 1.25
    seen_bodies = []

    def log_message(self, *a):
        pass

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n)
        try:
            body = json.loads(raw)
        except ValueError:
            body = {}
        FakeUpstream.seen_bodies.append(body)

        if body.get("stream"):
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            chunks = [
                {"model": "test/model", "choices": [{"delta": {"content": "hi"}}]},
                {"model": "test/model", "choices": [],
                 "usage": {"prompt_tokens": 10, "completion_tokens": 5,
                           "cost": FakeUpstream.cost_per_call}},
            ]
            for c in chunks:
                self.wfile.write(b"data: " + json.dumps(c).encode() + b"\n\n")
                self.wfile.flush()
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
            return

        payload = {
            "id": "x", "model": "test/model",
            "choices": [{"message": {"role": "assistant", "content": "hi"}}],
            "usage": {"prompt_tokens": 10, "completion_tokens": 5,
                      "cost": FakeUpstream.cost_per_call},
        }
        data = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def free_port():
    import socket
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def post(url, payload, timeout=10):
    req = urllib.request.Request(
        url, data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def get(url, timeout=10):
    try:
        with urllib.request.urlopen(url, timeout=timeout) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def wait_for(url, tries=50):
    for _ in range(tries):
        try:
            get(url, timeout=1)
            return True
        except Exception:
            time.sleep(0.1)
    return False


def main():
    up_port, px_port = free_port(), free_port()
    upstream = ThreadingHTTPServer(("127.0.0.1", up_port), FakeUpstream)
    upstream.daemon_threads = True
    threading.Thread(target=upstream.serve_forever, daemon=True).start()

    tmp = tempfile.mkdtemp(prefix="feather-test-")
    db = os.path.join(tmp, "spend.db")
    env = dict(os.environ,
               FEATHER_DB=db,
               FEATHER_UPSTREAM_KEY="test-key",
               FEATHER_DAILY_USD="3.00",
               FEATHER_MONTHLY_USD="100.00")

    proc = subprocess.Popen(
        [sys.executable, BIN, "serve", "--port", str(px_port),
         "--upstream", f"http://127.0.0.1:{up_port}/v1"],
        env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    base = f"http://127.0.0.1:{px_port}"
    try:
        if not wait_for(base + "/healthz"):
            print("proxy failed to start"); print(proc.stderr.read() if proc.stderr else "")
            return 1

        print("\nnon-streaming + accounting")
        status, _ = post(base + "/v1/chat/completions",
                         {"model": "test/model", "messages": [{"role": "user", "content": "hi"}]})
        check("first request forwarded", status == 200, f"got {status}")

        _, raw = get(base + "/healthz")
        st = json.loads(raw)
        check("cost recorded from usage.cost", abs(st["today_usd"] - 1.25) < 1e-6,
              f"today={st['today_usd']}")

        check("proxy asked upstream for usage accounting",
              FakeUpstream.seen_bodies and
              FakeUpstream.seen_bodies[-1].get("usage", {}).get("include") is True,
              f"body={FakeUpstream.seen_bodies[-1] if FakeUpstream.seen_bodies else None}")

        print("\nstreaming")
        status, body = post(base + "/v1/chat/completions",
                            {"model": "test/model", "stream": True,
                             "messages": [{"role": "user", "content": "hi"}]})
        check("stream forwarded", status == 200, f"got {status}")
        check("stream content passed through intact", b"[DONE]" in body and b"hi" in body)
        check("proxy injected stream_options.include_usage",
              FakeUpstream.seen_bodies[-1].get("stream_options", {}).get("include_usage") is True)

        time.sleep(0.3)
        _, raw = get(base + "/healthz")
        st = json.loads(raw)
        check("streaming cost recorded", abs(st["today_usd"] - 2.50) < 1e-6,
              f"today={st['today_usd']}")

        print("\nthe cap actually caps")
        # 2.50 spent, cap 3.00 -> this one is allowed, pushing us to 3.75.
        status, _ = post(base + "/v1/chat/completions",
                         {"model": "test/model", "messages": [{"role": "user", "content": "hi"}]})
        check("request under cap still allowed", status == 200, f"got {status}")

        status, body = post(base + "/v1/chat/completions",
                            {"model": "test/model", "messages": [{"role": "user", "content": "hi"}]})
        check("request over cap refused with 402", status == 402, f"got {status}")
        err = json.loads(body)
        check("refusal names the cap",
              "daily spend cap" in err.get("error", {}).get("message", ""),
              err.get("error", {}).get("message", ""))
        check("refusal uses a code agents recognise",
              err.get("error", {}).get("type") == "insufficient_quota")

        before = len(FakeUpstream.seen_bodies)
        post(base + "/v1/chat/completions",
             {"model": "test/model", "messages": [{"role": "user", "content": "hi"}]})
        check("refused request never reaches upstream",
              len(FakeUpstream.seen_bodies) == before,
              f"upstream saw {len(FakeUpstream.seen_bodies) - before} extra call(s)")

        print("\nstatus + reset")
        out = subprocess.run([sys.executable, BIN, "--daily", "3", "status"],
                             env=env, capture_output=True, text=True)
        check("status reports spend", "3.7500" in out.stdout, out.stdout.strip())

        subprocess.run([sys.executable, BIN, "reset", "--today"], env=env, capture_output=True)
        _, raw = get(base + "/healthz")
        check("reset clears the tally", json.loads(raw)["today_usd"] == 0)

        status, _ = post(base + "/v1/chat/completions",
                         {"model": "test/model", "messages": [{"role": "user", "content": "hi"}]})
        check("requests resume after reset", status == 200, f"got {status}")

        print("\nhardening")
        if os.name == "posix":
            check("database is owner-only (0600)",
                  oct(os.stat(db).st_mode & 0o777) == "0o600",
                  oct(os.stat(db).st_mode & 0o777))
        else:
            # chmod on Windows only toggles the read-only bit, so POSIX mode
            # bits are not a meaningful assertion there.
            print("  SKIP  database permissions (POSIX-only check)")
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
        upstream.shutdown()

    print()
    if FAILURES:
        print(f"{len(FAILURES)} FAILED: {', '.join(FAILURES)}")
        return 1
    print("all tests passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
