#!/usr/bin/env python3
"""zknot3 Docker multi-node transaction load test (stdlib only)"""

import concurrent.futures
import random
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime

# Node endpoints (host ports mapped by docker-compose)
NODES = {
    "validator-1": {"rpc": 9003, "p2p": 8083, "metrics": 9133},
    "validator-2": {"rpc": 9013, "p2p": 8093, "metrics": 9143},
    "validator-3": {"rpc": 9023, "p2p": 8103, "metrics": 9153},
    "validator-4": {"rpc": 9033, "p2p": 8113, "metrics": 9163},
    "fullnode": {"rpc": 9043, "p2p": 8123, "metrics": 9173},
}

BASE_URL = "http://localhost:{port}"

# Test parameters
DURATION_SECONDS = 60
REQUESTS_PER_SECOND = 1  # conservative due to synchronous HTTP handling in Zig 0.16.0 threaded I/O
TIMEOUT = 5
MAX_WORKERS = 2


def random_sender() -> str:
    """Generate a random 32-byte hex sender."""
    return "".join(f"{random.randint(0, 255):02x}" for _ in range(32))


import socket

def http_request(method: str, path: str, port: int, data: bytes = None) -> dict:
    """Make an HTTP request using raw sockets with SHUT_WR workaround for Zig 0.16.0 threaded I/O."""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(TIMEOUT)
        s.connect(("localhost", port))
        body = data if data else b""
        headers = [
            f"{method} {path} HTTP/1.1",
            f"Host: localhost:{port}",
        ]
        if body:
            headers.append(f"Content-Length: {len(body)}")
        req = "\r\n".join(headers) + "\r\n\r\n"
        if body:
            req = req.encode() + body
        else:
            req = req.encode()
        s.sendall(req)
        s.shutdown(socket.SHUT_WR)
        response = b""
        while True:
            chunk = s.recv(4096)
            if not chunk:
                break
            response += chunk
        s.close()
        if not response:
            return {"error": "empty response", "ok": False}
        # Parse status line
        lines = response.split(b"\r\n")
        status_line = lines[0].decode("utf-8", errors="replace")
        parts = status_line.split(" ")
        status = int(parts[1]) if len(parts) >= 2 else 0
        # Find body
        body_bytes = b""
        for i, line in enumerate(lines):
            if line == b"":
                body_bytes = b"\r\n".join(lines[i + 1 :])
                break
        body_text = body_bytes.decode("utf-8", errors="replace")
        return {"status": status, "body": body_text, "ok": 200 <= status < 300}
    except Exception as e:
        return {"error": str(e), "ok": False}
    """Make an HTTP request and return response info."""
    url = BASE_URL.format(port=port) + path
    try:
        req = urllib.request.Request(url, data=data, method=method)
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            body = resp.read().decode("utf-8", errors="replace")
            return {"status": resp.status, "body": body, "ok": 200 <= resp.status < 300}
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace") if e.fp else ""
        return {"status": e.code, "body": body, "ok": False}
    except Exception as e:
        return {"error": str(e), "ok": False}


def submit_tx(node_name: str, rpc_port: int) -> dict:
    sender = random_sender()
    result = http_request("POST", "/tx", rpc_port, data=sender.encode())
    result["node"] = node_name
    return result


def fetch_health(node_name: str, rpc_port: int) -> dict:
    result = http_request("GET", "/health", rpc_port)
    result["node"] = node_name
    return result


def fetch_metrics(node_name: str, metrics_port: int) -> dict:
    if metrics_port is None:
        return {"node": node_name, "skipped": True}
    result = http_request("GET", "/metrics", metrics_port)
    result["node"] = node_name
    return result


def run_load_test():
    print(f"[{datetime.now().isoformat()}] Starting load test")
    print(f"  Duration: {DURATION_SECONDS}s")
    print(f"  Target RPS: {REQUESTS_PER_SECOND}")
    print(f"  Nodes: {list(NODES.keys())}")
    print()

    print("Health check before load test:")
    for name, ports in NODES.items():
        health = fetch_health(name, ports["rpc"])
        if "error" in health:
            print(f"  ❌ {name}: {health['error']}")
        else:
            body = health.get("body", "")
            print(f"  ✅ {name}: {body[:120]}")
    print()

    results = []
    start_time = time.time()
    interval = 1.0 / REQUESTS_PER_SECOND
    next_send = start_time

    with concurrent.futures.ThreadPoolExecutor(max_workers=MAX_WORKERS) as executor:
        futures = []
        while time.time() - start_time < DURATION_SECONDS:
            now = time.time()
            if now >= next_send:
                node_name = random.choice(list(NODES.keys()))
                rpc_port = NODES[node_name]["rpc"]
                futures.append(executor.submit(submit_tx, node_name, rpc_port))
                next_send += interval
                if next_send < now:
                    next_send = now + interval
            else:
                time.sleep(max(0, next_send - now))

        for f in concurrent.futures.as_completed(futures):
            results.append(f.result())

    elapsed = time.time() - start_time
    print(f"[{datetime.now().isoformat()}] Load test finished in {elapsed:.1f}s")
    print(f"  Total requests sent: {len(results)}")

    ok_count = sum(1 for r in results if r.get("ok"))
    error_count = len(results) - ok_count
    node_counts = {name: {"ok": 0, "err": 0} for name in NODES}
    status_codes = {}
    errors = []

    for r in results:
        name = r["node"]
        if r.get("ok"):
            node_counts[name]["ok"] += 1
        else:
            node_counts[name]["err"] += 1
            if "error" in r:
                errors.append(r["error"])
        sc = r.get("status", "EXCEPTION")
        status_codes[sc] = status_codes.get(sc, 0) + 1

    print(f"  Successful: {ok_count} ({100 * ok_count / max(len(results), 1):.1f}%)")
    print(f"  Failed: {error_count} ({100 * error_count / max(len(results), 1):.1f}%)")
    print()
    print("Status code distribution:")
    for sc, cnt in sorted(status_codes.items()):
        print(f"  {sc}: {cnt}")
    print()
    print("Per-node breakdown:")
    for name, cnts in node_counts.items():
        total = cnts["ok"] + cnts["err"]
        print(f"  {name}: {cnts['ok']} OK, {cnts['err']} ERR (total {total})")
    print()

    if errors:
        unique_errors = {}
        for e in errors:
            unique_errors[e] = unique_errors.get(e, 0) + 1
        print("Unique errors (top 10):")
        for e, cnt in sorted(unique_errors.items(), key=lambda x: -x[1])[:10]:
            print(f"  ({cnt}x) {e}")
        print()

    print("Health check after load test:")
    for name, ports in NODES.items():
        health = fetch_health(name, ports["rpc"])
        if "error" in health:
            print(f"  ❌ {name}: {health['error']}")
        else:
            body = health.get("body", "")
            print(f"  ✅ {name}: {body[:120]}")
    print()

    print("Checking container logs for severe errors...")
    severe_keywords = [
        "panic",
        "segfault",
        "assertion",
        "critical",
        "double free",
        "freeze",
    ]
    for name in [f"zknot3-{n}" for n in NODES.keys()]:
        try:
            logs = subprocess.check_output(
                ["docker", "logs", name, "--tail", "50"],
                stderr=subprocess.STDOUT,
                text=True,
                timeout=10,
            )
            hits = [
                line
                for line in logs.splitlines()
                if any(k in line.lower() for k in severe_keywords)
            ]
            if hits:
                print(f"  ⚠️  {name}: found {len(hits)} severe log lines")
                for h in hits[:3]:
                    print(f"      {h.strip()}")
            else:
                print(f"  ✅ {name}: no severe errors in last 50 lines")
        except Exception as e:
            print(f"  ❌ {name}: could not fetch logs ({e})")
    print()

    print("=" * 60)
    if error_count / max(len(results), 1) < 0.05:
        print("ROBUSTNESS VERDICT: PASS ✅")
    elif error_count / max(len(results), 1) < 0.20:
        print("ROBUSTNESS VERDICT: DEGRADED ⚠️")
    else:
        print("ROBUSTNESS VERDICT: FAIL ❌")
    print("=" * 60)


if __name__ == "__main__":
    run_load_test()
