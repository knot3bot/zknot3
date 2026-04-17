#!/usr/bin/env python3
"""zknot3 aggressive stress test against Docker multi-node network"""

import concurrent.futures
import random
import socket
import subprocess
import sys
import time
from datetime import datetime

NODES = {
    "validator-1": {"rpc": 9000, "p2p": 8080},
    "validator-2": {"rpc": 9010, "p2p": 8090},
    "validator-3": {"rpc": 9020, "p2p": 8100},
    "validator-4": {"rpc": 9030, "p2p": 8110},
    "fullnode": {"rpc": 9040, "p2p": 8120},
}

# Stress parameters
DURATION_SECONDS = 120
REQUESTS_PER_SECOND = 3  # per node, so 15 total RPS
TIMEOUT = 12
MAX_WORKERS = 10
TIMEOUT = 10
MAX_WORKERS = 8
TIMEOUT = 10
MAX_WORKERS = 5
TIMEOUT = 10
MAX_WORKERS = 8


def random_sender() -> str:
    return "".join(f"{random.randint(0, 255):02x}" for _ in range(32))


def http_request(method: str, path: str, port: int, data: bytes = None) -> dict:
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(TIMEOUT)
        s.connect(("localhost", port))
        body = data if data else b""
        headers = [f"{method} {path} HTTP/1.1", f"Host: localhost:{port}"]
        if body:
            headers.append(f"Content-Length: {len(body)}")
        req = "\r\n".join(headers) + "\r\n\r\n"
        req = req.encode() + body if body else req.encode()
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
        lines = response.split(b"\r\n")
        status_line = lines[0].decode("utf-8", errors="replace")
        parts = status_line.split(" ")
        status = int(parts[1]) if len(parts) >= 2 else 0
        body_bytes = b""
        for i, line in enumerate(lines):
            if line == b"":
                body_bytes = b"\r\n".join(lines[i + 1 :])
                break
        body_text = body_bytes.decode("utf-8", errors="replace")
        return {"status": status, "body": body_text, "ok": 200 <= status < 300}
    except Exception as e:
        return {"error": str(e), "ok": False}


def submit_tx(node_name: str, rpc_port: int) -> dict:
    sender = random_sender()
    t0 = time.time()
    result = http_request("POST", "/tx", rpc_port, data=sender.encode())
    result["node"] = node_name
    result["latency_ms"] = int((time.time() - t0) * 1000)
    return result


def fetch_health(node_name: str, rpc_port: int) -> dict:
    t0 = time.time()
    result = http_request("GET", "/health", rpc_port)
    result["node"] = node_name
    result["latency_ms"] = int((time.time() - t0) * 1000)
    return result


def run_stress_test():
    print(f"[{datetime.now().isoformat()}] Starting STRESS TEST")
    print(f"  Duration: {DURATION_SECONDS}s")
    print(
        f"  Target RPS: {REQUESTS_PER_SECOND} per node ({REQUESTS_PER_SECOND * len(NODES)} total)"
    )
    print(f"  Max workers: {MAX_WORKERS}")
    print(f"  Nodes: {list(NODES.keys())}")
    print()

    print("Pre-stress health checks:")
    for name, ports in NODES.items():
        health = fetch_health(name, ports["rpc"])
        if "error" in health:
            print(f"  ❌ {name}: {health['error']}")
        else:
            print(
                f"  ✅ {name}: {health['body'][:120]} (latency {health['latency_ms']}ms)"
            )
    print()

    results = []
    start_time = time.time()
    interval = 1.0 / (REQUESTS_PER_SECOND * len(NODES))
    next_send = start_time

    with concurrent.futures.ThreadPoolExecutor(max_workers=MAX_WORKERS) as executor:
        futures = []
        nodes_list = list(NODES.keys())
        node_idx = 0
        while time.time() - start_time < DURATION_SECONDS:
            now = time.time()
            if now >= next_send:
                node_name = nodes_list[node_idx % len(nodes_list)]
                node_idx += 1
                rpc_port = NODES[node_name]["rpc"]
                futures.append(executor.submit(submit_tx, node_name, rpc_port))
                next_send += interval
                if next_send < now:
                    next_send = now + interval
            else:
                time.sleep(max(0, next_send - now))

        for i, f in enumerate(concurrent.futures.as_completed(futures)):
            results.append(f.result())
            if (i + 1) % 50 == 0:
                print(f"  ... completed {i + 1}/{len(futures)}")

    elapsed = time.time() - start_time
    total = len(results)
    ok_count = sum(1 for r in results if r.get("ok"))
    error_count = total - ok_count
    latencies = [r["latency_ms"] for r in results if "latency_ms" in r]

    print(f"\n[{datetime.now().isoformat()}] Stress test finished in {elapsed:.1f}s")
    print(f"  Total requests: {total}")
    print(f"  Successful: {ok_count} ({100 * ok_count / max(total, 1):.1f}%)")
    print(f"  Failed: {error_count} ({100 * error_count / max(total, 1):.1f}%)")
    if latencies:
        latencies.sort()
        print(
            f"  Latency: min={latencies[0]}ms, p50={latencies[len(latencies) // 2]}ms, p95={latencies[int(len(latencies) * 0.95)]}ms, max={latencies[-1]}ms"
        )
    print()

    node_counts = {name: {"ok": 0, "err": 0, "latencies": []} for name in NODES}
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
        if "latency_ms" in r:
            node_counts[name]["latencies"].append(r["latency_ms"])
        sc = r.get("status", "EXCEPTION")
        status_codes[sc] = status_codes.get(sc, 0) + 1

    print("Status code distribution:")
    print("Status code distribution:")
    for sc, cnt in sorted(status_codes.items(), key=lambda x: str(x[0])):
        print(f"  {sc}: {cnt}")
    print()

    print("Per-node breakdown:")
    for name, cnts in node_counts.items():
        total_n = cnts["ok"] + cnts["err"]
        lats = sorted(cnts["latencies"]) if cnts["latencies"] else []
        p50 = lats[len(lats) // 2] if lats else 0
        print(
            f"  {name}: {cnts['ok']} OK, {cnts['err']} ERR (total {total_n}) | p50 latency {p50}ms"
        )
    print()

    if errors:
        unique_errors = {}
        for e in errors:
            unique_errors[e] = unique_errors.get(e, 0) + 1
        print("Unique errors (top 10):")
        for e, cnt in sorted(unique_errors.items(), key=lambda x: -x[1])[:10]:
            print(f"  ({cnt}x) {e}")
        print()

    print("Post-stress health checks:")
    for name, ports in NODES.items():
        health = fetch_health(name, ports["rpc"])
        if "error" in health:
            print(f"  ❌ {name}: {health['error']}")
        else:
            print(
                f"  ✅ {name}: {health['body'][:120]} (latency {health['latency_ms']}ms)"
            )
    print()

    print("Container health status:")
    try:
        ps = subprocess.check_output(
            [
                "docker",
                "ps",
                "--filter",
                "name=zknot3",
                "--format",
                "{{.Names}}\t{{.Status}}",
            ],
            text=True,
            timeout=10,
        )
        for line in ps.strip().splitlines():
            print(f"  {line}")
    except Exception as e:
        print(f"  ❌ could not fetch container status: {e}")
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
                ["docker", "logs", name, "--tail", "100"],
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
                print(f"  ✅ {name}: no severe errors in last 100 lines")
        except Exception as e:
            print(f"  ❌ {name}: could not fetch logs ({e})")
    print()

    print("=" * 60)
    if error_count / max(total, 1) < 0.05:
        print("STRESS VERDICT: PASS ✅")
    elif error_count / max(total, 1) < 0.20:
        print("STRESS VERDICT: DEGRADED ⚠️")
    else:
        print("STRESS VERDICT: FAIL ❌")
    print("=" * 60)


if __name__ == "__main__":
    run_stress_test()
