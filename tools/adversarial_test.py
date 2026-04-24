#!/usr/bin/env python3
"""Adversarial regression runner: tx flood + malformed HTTP payloads."""

import argparse
import concurrent.futures
import json
import random
import socket
import subprocess
import threading
import time
from dataclasses import dataclass, field
from typing import Optional
try:
    import blake3
    from nacl.signing import SigningKey
except ModuleNotFoundError as exc:  # pragma: no cover
    raise RuntimeError(
        "Missing python deps for signed tx generation. Install with: "
        "python3 -m pip install --user pynacl blake3"
    ) from exc


NODES = {
    "validator-1": {"rpc": 9003, "p2p": 8083},
    "validator-2": {"rpc": 9013, "p2p": 8093},
    "validator-3": {"rpc": 9023, "p2p": 8103},
    "validator-4": {"rpc": 9033, "p2p": 8113},
    "fullnode": {"rpc": 9043, "p2p": 8123},
}

# P2P wire framing from src/form/network/Transport.zig
P2P_HEADER_SIZE = 45
P2P_MSG_TYPE_HANDSHAKE = 0

FLOOD_DURATION_SECONDS = 30
FLOOD_WORKERS = 24
REQUEST_TIMEOUT = 5

# Prometheus counters that must stay monotonically non-decreasing under soak.
MONOTONIC_SERIES = (
    "zknot3_blocks_committed_total",
    "zknot3_txn_pool_received_total",
    "zknot3_txn_pool_executed_total",
)

# Prometheus gauges we watch for unbounded growth (classic leak symptom).
GAUGE_SERIES = (
    "zknot3_txn_pool_size",
    "zknot3_pending_transactions",
)

# Container names (match deploy/docker/docker-compose.yml) used for RSS/FD
# sampling via `docker stats` / `docker exec`. Keyed by logical node name.
CONTAINER_NAMES = {
    "validator-1": "zknot3-validator-1",
    "validator-2": "zknot3-validator-2",
    "validator-3": "zknot3-validator-3",
    "validator-4": "zknot3-validator-4",
    "fullnode": "zknot3-fullnode",
}

FLOOD_SIGNING_KEY = SigningKey(bytes.fromhex("7f" * 32))
FLOOD_PUBLIC_KEY_HEX = FLOOD_SIGNING_KEY.verify_key.encode().hex()


@dataclass
class ReqResult:
    ok: bool
    status: int
    error: str
    latency_ms: int
    body: str = ""
    error_kind: str = "none"


def random_hex(nbytes: int) -> str:
    return "".join(f"{random.randint(0, 255):02x}" for _ in range(nbytes))


def classify_transport_error(err: str) -> str:
    text = err.lower()
    if "can't assign requested address" in text or "eaddrnotavail" in text:
        return "env_ephemeral_port"
    if "connection refused" in text or "econnrefused" in text:
        return "env_connection_refused"
    if "timed out" in text or "timeout" in text:
        return "env_timeout"
    if "connection reset" in text or "broken pipe" in text:
        return "env_connection_reset"
    return "transport_other"


def raw_http_request_with_body(
    port: int,
    method: str,
    path: str,
    body: bytes | None,
    retries: int = 0,
    retry_backoff_seconds: float = 0.25,
) -> tuple[int, str, str]:
    payload = body or b""
    last_err = ""
    for attempt in range(retries + 1):
        try:
            with socket.create_connection(("localhost", port), timeout=REQUEST_TIMEOUT) as sock:
                sock.settimeout(REQUEST_TIMEOUT)
                headers = [f"{method} {path} HTTP/1.1", f"Host: localhost:{port}", "Connection: close"]
                if payload:
                    headers.append(f"Content-Length: {len(payload)}")
                request = ("\r\n".join(headers) + "\r\n\r\n").encode() + payload
                sock.sendall(request)
                sock.shutdown(socket.SHUT_WR)
                response = b""
                while True:
                    part = sock.recv(4096)
                    if not part:
                        break
                    response += part
            if not response:
                return 0, "", "empty_response"
            raw = response.decode(errors="replace")
            head, _, body_text = raw.partition("\r\n\r\n")
            first_line = head.split("\r\n", 1)[0]
            status = int(first_line.split(" ")[1]) if " " in first_line else 0
            return status, body_text, ""
        except Exception as exc:  # noqa: BLE001
            last_err = str(exc)
            if attempt < retries:
                time.sleep(retry_backoff_seconds * (attempt + 1))
                continue
            return 0, "", last_err
    return 0, "", last_err


def raw_http_request(port: int, method: str, path: str, body: bytes | None) -> ReqResult:
    t0 = time.time()
    status, body_text, err = raw_http_request_with_body(port, method, path, body)
    latency = int((time.time() - t0) * 1000)
    if err:
        return ReqResult(False, 0, err, latency, body="", error_kind=classify_transport_error(err))
    if status == 0:
        return ReqResult(False, 0, "empty response", latency, body=body_text, error_kind="empty_response")
    return ReqResult(200 <= status < 300, status, "", latency, body=body_text, error_kind="none")


def valid_tx_body() -> bytes:
    sender = random_hex(32)
    digest = blake3.blake3(bytes.fromhex(sender)).digest()
    signature = FLOOD_SIGNING_KEY.sign(digest).signature.hex()
    return f"{sender}{FLOOD_PUBLIC_KEY_HEX}{signature}".encode()


def tx_body_with_nonce(sender: str, pubkey: str, signature: str, nonce: int) -> bytes:
    return f"{sender}{pubkey}{signature}:{nonce}".encode()


def make_valid_signed_tx_body(sender_hex: str, seed_hex: str, nonce: int) -> bytes:
    sender = bytes.fromhex(sender_hex)
    seed = bytes.fromhex(seed_hex)
    digest = blake3.blake3(sender).digest()
    sk = SigningKey(seed)
    pk = sk.verify_key.encode()
    sig = sk.sign(digest).signature
    return f"{sender_hex}{pk.hex()}{sig.hex()}:{nonce}".encode()


def malformed_tx_cases() -> list[bytes]:
    return [
        b"",
        b"abcd",
        b"0" * 200,  # too short
        b"g" * 256,  # non-hex
        (random_hex(32) + random_hex(32) + random_hex(63)).encode(),  # bad signature length
    ]


def run_flood(duration_seconds: int = FLOOD_DURATION_SECONDS, stop_event: Optional[threading.Event] = None) -> dict:
    label = f"{duration_seconds}s" if duration_seconds < 3600 else f"{duration_seconds / 3600:.1f}h"
    print(f"[1/2] Running tx flood scenario ({label})...")
    deadline = time.time() + duration_seconds
    stats = {"total": 0, "ok": 0, "errors": 0, "p95": 0}
    latencies: list[int] = []

    def still_running() -> bool:
        if stop_event is not None and stop_event.is_set():
            return False
        return time.time() < deadline

    def one_request() -> ReqResult:
        node = random.choice(list(NODES.keys()))
        return raw_http_request(NODES[node]["rpc"], "POST", "/tx", valid_tx_body())

    with concurrent.futures.ThreadPoolExecutor(max_workers=FLOOD_WORKERS) as pool:
        futures = []
        while still_running():
            futures.append(pool.submit(one_request))
            if len(futures) >= FLOOD_WORKERS * 3:
                done, futures = wait_some(futures)
                for fut in done:
                    r = fut.result()
                    stats["total"] += 1
                    if r.ok:
                        stats["ok"] += 1
                    else:
                        stats["errors"] += 1
                    latencies.append(r.latency_ms)

        for fut in concurrent.futures.as_completed(futures):
            r = fut.result()
            stats["total"] += 1
            if r.ok:
                stats["ok"] += 1
            else:
                stats["errors"] += 1
            latencies.append(r.latency_ms)

    if latencies:
        latencies.sort()
        stats["p95"] = latencies[int(len(latencies) * 0.95)]

    print(f"  total={stats['total']} ok={stats['ok']} err={stats['errors']} p95={stats['p95']}ms")
    return stats


def wait_some(futures: list[concurrent.futures.Future]) -> tuple[list[concurrent.futures.Future], list[concurrent.futures.Future]]:
    done, pending = concurrent.futures.wait(
        futures,
        timeout=0.5,
        return_when=concurrent.futures.FIRST_COMPLETED,
    )
    return list(done), list(pending)


def run_malformed() -> dict:
    print("[2/4] Running malformed payload scenario...")
    stats = {"total": 0, "rejected_4xx": 0, "unexpected_2xx": 0, "transport_errors": 0}
    cases = malformed_tx_cases()

    for node, ports in NODES.items():
        for body in cases:
            stats["total"] += 1
            result = raw_http_request(ports["rpc"], "POST", "/tx", body)
            if result.status >= 400:
                stats["rejected_4xx"] += 1
            elif 200 <= result.status < 300:
                stats["unexpected_2xx"] += 1
                print(f"  ! unexpected accept on {node}, status={result.status}, len={len(body)}")
            else:
                stats["transport_errors"] += 1

    print(
        "  total={total} rejected_4xx={rejected_4xx} unexpected_2xx={unexpected_2xx} transport_errors={transport_errors}".format(
            **stats
        )
    )
    return stats


def slow_client_request(port: int, per_byte_delay: float, timeout: float) -> ReqResult:
    """Send an HTTP request one byte at a time; expect the server to either
    rate-limit/timeout gracefully, never hang the event loop."""
    body = valid_tx_body()
    headers = (
        f"POST /tx HTTP/1.1\r\nHost: localhost:{port}\r\n"
        f"Content-Length: {len(body)}\r\n\r\n"
    ).encode()
    request = headers + body

    t0 = time.time()
    try:
        with socket.create_connection(("localhost", port), timeout=timeout) as sock:
            sock.settimeout(timeout)
            for b in request:
                sock.sendall(bytes([b]))
                time.sleep(per_byte_delay)
            sock.shutdown(socket.SHUT_WR)
            response = b""
            try:
                while True:
                    part = sock.recv(4096)
                    if not part:
                        break
                    response += part
            except socket.timeout:
                pass
        latency = int((time.time() - t0) * 1000)
        status = 0
        if response:
            first_line = response.split(b"\r\n", 1)[0].decode(errors="replace")
            if " " in first_line:
                status = int(first_line.split(" ")[1])
        return ReqResult(200 <= status < 300, status, "", latency)
    except Exception as exc:  # noqa: BLE001
        latency = int((time.time() - t0) * 1000)
        return ReqResult(False, 0, str(exc), latency)


def oversize_content_length_request(port: int, timeout: float) -> ReqResult:
    """Advertise a giant Content-Length with no body; expect timeout or 4xx."""
    huge_len = 10 * 1024 * 1024 * 1024  # 10 GiB
    headers = (
        f"POST /tx HTTP/1.1\r\nHost: localhost:{port}\r\n"
        f"Content-Length: {huge_len}\r\n\r\n"
    ).encode()

    t0 = time.time()
    try:
        with socket.create_connection(("localhost", port), timeout=timeout) as sock:
            sock.settimeout(timeout)
            sock.sendall(headers)
            # Deliberately send no body; server must time out or reject.
            response = b""
            try:
                while True:
                    part = sock.recv(4096)
                    if not part:
                        break
                    response += part
            except socket.timeout:
                pass
        latency = int((time.time() - t0) * 1000)
        status = 0
        if response:
            first_line = response.split(b"\r\n", 1)[0].decode(errors="replace")
            if " " in first_line:
                status = int(first_line.split(" ")[1])
        return ReqResult(200 <= status < 300, status, "", latency)
    except Exception as exc:  # noqa: BLE001
        latency = int((time.time() - t0) * 1000)
        return ReqResult(False, 0, str(exc), latency)


def run_slow_clients() -> dict:
    print("[3/4] Running slow-client scenario...")
    stats = {"total": 0, "unexpected_2xx": 0, "timeouts": 0, "rejected_4xx": 0}
    # Slow read: tiny per-byte delay keeps the request alive across several
    # server read iterations but must not exceed HTTP server SO_RCVTIMEO.
    for node, ports in NODES.items():
        stats["total"] += 1
        result = slow_client_request(ports["rpc"], per_byte_delay=0.02, timeout=10.0)
        if 200 <= result.status < 300:
            stats["unexpected_2xx"] += 1
            print(f"  ! unexpected accept on {node}, status={result.status}, latency={result.latency_ms}ms")
        elif result.status >= 400:
            stats["rejected_4xx"] += 1
        else:
            stats["timeouts"] += 1

    print("  total={total} rejected_4xx={rejected_4xx} timeouts={timeouts} unexpected_2xx={unexpected_2xx}".format(**stats))
    return stats


def run_oversize_headers() -> dict:
    print("[4/4] Running oversize Content-Length scenario...")
    stats = {"total": 0, "unexpected_2xx": 0, "timeouts": 0, "rejected_4xx": 0, "max_latency_ms": 0}
    for node, ports in NODES.items():
        stats["total"] += 1
        result = oversize_content_length_request(ports["rpc"], timeout=15.0)
        stats["max_latency_ms"] = max(stats["max_latency_ms"], result.latency_ms)
        if 200 <= result.status < 300:
            stats["unexpected_2xx"] += 1
            print(f"  ! unexpected accept on {node}, status={result.status}")
        elif result.status >= 400:
            stats["rejected_4xx"] += 1
        else:
            stats["timeouts"] += 1

    print(
        "  total={total} rejected_4xx={rejected_4xx} timeouts={timeouts} unexpected_2xx={unexpected_2xx} max_latency_ms={max_latency_ms}".format(
            **stats
        )
    )
    return stats


def p2p_attack(port: int, payload: bytes, read_timeout: float) -> ReqResult:
    """Send a raw blob to the P2P port and observe whether the server closes
    the connection (expected). A successful attack is one where we never
    observe the process hang past `read_timeout`."""
    t0 = time.time()
    try:
        with socket.create_connection(("localhost", port), timeout=read_timeout) as sock:
            sock.settimeout(read_timeout)
            if payload:
                sock.sendall(payload)
            # We do not try to read a meaningful response; we just wait for the
            # server to either send something back or close the socket. Either
            # outcome is fine; a hang past read_timeout is what we flag.
            try:
                sock.recv(4096)
            except socket.timeout:
                pass
        return ReqResult(True, 0, "", int((time.time() - t0) * 1000))
    except Exception as exc:  # noqa: BLE001
        return ReqResult(False, 0, str(exc), int((time.time() - t0) * 1000))


def fragmented_p2p_header(declared_payload_len: int) -> bytes:
    """Build a 20-byte prefix of a P2P message header advertising a specific
    payload length. Intentionally truncated so the server must treat it as
    `IncompleteHeader`."""
    buf = bytearray(20)
    buf[0] = P2P_MSG_TYPE_HANDSHAKE
    # Leave sender + sequence zeroed. We only emit 20 of 45 header bytes, so
    # the declared payload length never actually lands on the wire.
    _ = declared_payload_len
    return bytes(buf)


def oversize_p2p_header() -> bytes:
    """Build a full 45-byte header advertising a ludicrously large payload
    (>MAX_MESSAGE_SIZE) but then send nothing; expect the server to reject."""
    buf = bytearray(P2P_HEADER_SIZE)
    buf[0] = P2P_MSG_TYPE_HANDSHAKE
    # payload_len lives at offset 41..45 as u32 big-endian (see Transport.zig).
    huge = (1 << 31) - 1  # beyond default 64 MiB cap
    buf[41:45] = huge.to_bytes(4, "big")
    return bytes(buf)


def run_p2p_fragmented() -> dict:
    print("[5/6] Running P2P fragmented-framing scenario...")
    stats = {"total": 0, "closed_ok": 0, "hung": 0, "conn_refused": 0, "max_latency_ms": 0}
    payloads = [
        ("half_open", b""),                           # connect + immediately close
        ("20b_header", fragmented_p2p_header(128)),   # truncated header
        ("header_only", bytes(P2P_HEADER_SIZE)),      # full zeroed header, no payload follow-up
        ("oversize", oversize_p2p_header()),          # declared huge payload length
    ]
    for node, ports in NODES.items():
        for label, payload in payloads:
            stats["total"] += 1
            result = p2p_attack(ports["p2p"], payload, read_timeout=6.0)
            stats["max_latency_ms"] = max(stats["max_latency_ms"], result.latency_ms)
            if not result.ok:
                stats["conn_refused"] += 1
                continue
            # A successful disconnect (server closed us) returns within the
            # read_timeout window. Anything at the ceiling means suspected hang.
            if result.latency_ms < 5500:
                stats["closed_ok"] += 1
            else:
                stats["hung"] += 1
                print(f"  ! suspected hang on {node}/{label}, latency={result.latency_ms}ms")

    print(
        "  total={total} closed_ok={closed_ok} hung={hung} conn_refused={conn_refused} max_latency_ms={max_latency_ms}".format(
            **stats
        )
    )
    return stats


def run_case_tx_replay() -> int:
    sender = "11" * 32
    seed = "99" * 32
    payload = make_valid_signed_tx_body(sender, seed, 0)
    status1, body1, err1 = raw_http_request_with_body(NODES["fullnode"]["rpc"], "POST", "/tx", payload)
    status2, body2, err2 = raw_http_request_with_body(NODES["fullnode"]["rpc"], "POST", "/tx", payload)
    ok = status1 == 200 and status2 == 200 and "\"duplicate\":true" in body2
    print(f"[case=tx_replay] status1={status1} err1={err1} body1={body1.strip()} status2={status2} err2={err2} body2={body2.strip()}")
    return 0 if ok else 2


def run_case_tx_bad_signature() -> int:
    sender = "44" * 32
    seed = "aa" * 32
    payload = bytearray(make_valid_signed_tx_body(sender, seed, 0))
    # Keep hex-valid shape, but tamper one nibble inside signature bytes.
    # layout: sender(64) + pub(64) + sig(128) + ":" + nonce
    sig_start = 64 + 64
    payload[sig_start] = ord("f" if chr(payload[sig_start]) != "f" else "e")
    status, body, err = raw_http_request_with_body(NODES["fullnode"]["rpc"], "POST", "/tx", payload)
    ok = status in (400, 422) and "Invalid transaction signature" in body
    print(f"[case=tx_bad_signature] status={status} err={err} body={body.strip()}")
    return 0 if ok else 2


def run_case_tx_nonce_gap() -> int:
    sender = "66" * 32
    seed = "bb" * 32
    # Huge nonce beyond admission window.
    payload = make_valid_signed_tx_body(sender, seed, 10_000_000)
    status, body, err = raw_http_request_with_body(NODES["fullnode"]["rpc"], "POST", "/tx", payload)
    ok = status in (400, 409, 422) and ("nonce" in body.lower() or "invalid" in body.lower())
    print(f"[case=tx_nonce_gap] status={status} err={err} body={body.strip()}")
    return 0 if ok else 2


def run_post_attack_health() -> dict:
    print("[6/6] Running post-attack /health liveness check...")
    stats = {"total": 0, "healthy": 0, "unhealthy_service": 0, "unhealthy_env": 0}
    for node, ports in NODES.items():
        stats["total"] += 1
        result = raw_http_request(ports["rpc"], "GET", "/health", None)
        if not result.ok and result.error_kind.startswith("env_"):
            # Flood后本机可能出现短暂 TIME_WAIT/端口耗尽，做有限退避重试，避免假失败。
            for retry in range(4):
                time.sleep(0.2 * (retry + 1))
                result = raw_http_request(ports["rpc"], "GET", "/health", None)
                if result.ok or not result.error_kind.startswith("env_"):
                    break
        if 200 <= result.status < 300:
            stats["healthy"] += 1
        else:
            if result.error_kind.startswith("env_"):
                stats["unhealthy_env"] += 1
            else:
                stats["unhealthy_service"] += 1
            print(
                f"  ! unhealthy after attack on {node}: status={result.status} "
                f"kind={result.error_kind} err={result.error}"
            )

    print(
        "  total={total} healthy={healthy} unhealthy_service={unhealthy_service} unhealthy_env={unhealthy_env}".format(
            **stats
        )
    )
    return stats


@dataclass
class SoakSample:
    t_elapsed: float
    metrics: dict = field(default_factory=dict)  # node -> {series: value}
    rss_mb: dict = field(default_factory=dict)   # container -> MB
    fd_count: dict = field(default_factory=dict) # container -> count


def parse_prometheus_metrics(body: str) -> dict:
    """Parse a Prometheus text-format body into {series_name: float}. Only the
    first sample per series is kept (our /metrics endpoint emits one per series)."""
    out: dict = {}
    for line in body.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        # Lines look like "zknot3_foo_total 123" or "zknot3_foo 0"
        parts = line.split()
        if len(parts) < 2:
            continue
        name = parts[0]
        # Strip labels like name{label="x"} if ever present
        if "{" in name:
            name = name.split("{", 1)[0]
        try:
            out[name] = float(parts[-1])
        except ValueError:
            continue
    return out


def scrape_metrics(port: int) -> dict:
    status, body_text, err = raw_http_request_with_body(port, "GET", "/metrics", None, retries=1)
    if err or status < 200 or status >= 300:
        return {}
    return parse_prometheus_metrics(body_text)


def sample_docker_rss() -> dict:
    """Returns {container_name: rss_mb} or {} if docker isn't reachable."""
    try:
        proc = subprocess.run(
            ["docker", "stats", "--no-stream", "--format", "{{json .}}"],
            capture_output=True, text=True, timeout=10,
        )
        if proc.returncode != 0:
            return {}
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return {}

    wanted = set(CONTAINER_NAMES.values())
    out: dict = {}
    for line in proc.stdout.splitlines():
        try:
            row = json.loads(line)
        except ValueError:
            continue
        name = row.get("Name") or row.get("Container")
        if name not in wanted:
            continue
        mem = (row.get("MemUsage") or "").split("/", 1)[0].strip()
        # Formats like "123.4MiB", "1.2GiB", "512KiB"
        val_mb = None
        for suffix, scale in (("GiB", 1024.0), ("MiB", 1.0), ("KiB", 1 / 1024.0)):
            if mem.endswith(suffix):
                try:
                    val_mb = float(mem[: -len(suffix)]) * scale
                except ValueError:
                    val_mb = None
                break
        if val_mb is not None:
            out[name] = val_mb
    return out


def sample_docker_fd() -> dict:
    """Returns {container_name: fd_count} using `docker exec`. Empty if unavailable."""
    out: dict = {}
    for container in CONTAINER_NAMES.values():
        try:
            proc = subprocess.run(
                ["docker", "exec", container, "sh", "-c", "ls /proc/1/fd | wc -l"],
                capture_output=True, text=True, timeout=5,
            )
            if proc.returncode != 0:
                continue
            count = int(proc.stdout.strip() or "0")
            out[container] = count
        except (FileNotFoundError, subprocess.TimeoutExpired, ValueError):
            continue
    return out


def summarize_drift(samples: list[SoakSample]) -> dict:
    """Compute drift between first and last sample for each tracked metric."""
    drift = {
        "rss_mb": {},
        "fd_count": {},
        "metrics": {},
        "regressions": [],
    }
    if len(samples) < 2:
        return drift

    first, last = samples[0], samples[-1]

    for container, v0 in first.rss_mb.items():
        v1 = last.rss_mb.get(container)
        if v1 is None:
            continue
        drift["rss_mb"][container] = {"start": v0, "end": v1, "delta_pct": _pct(v0, v1)}
        if v0 > 0 and (v1 - v0) / v0 > 0.50:
            drift["regressions"].append(f"rss_mb:{container} grew >50%: {v0:.1f} -> {v1:.1f} MiB")

    for container, v0 in first.fd_count.items():
        v1 = last.fd_count.get(container)
        if v1 is None:
            continue
        drift["fd_count"][container] = {"start": v0, "end": v1, "delta": v1 - v0}
        # Allow small churn; flag if FDs grew by more than 2x baseline or +200.
        if v0 > 0 and (v1 > v0 * 2 and v1 - v0 > 50) or (v1 - v0 > 200):
            drift["regressions"].append(f"fd_count:{container} grew: {v0} -> {v1}")

    for node, series_first in first.metrics.items():
        series_last = last.metrics.get(node, {})
        node_drift: dict = {}
        for name in MONOTONIC_SERIES:
            v0 = series_first.get(name)
            v1 = series_last.get(name)
            if v0 is None or v1 is None:
                continue
            node_drift[name] = {"start": v0, "end": v1, "delta": v1 - v0}
            if v1 < v0:
                drift["regressions"].append(f"{node}/{name} went backwards: {v0} -> {v1}")
        for name in GAUGE_SERIES:
            v0 = series_first.get(name)
            v1 = series_last.get(name)
            if v0 is None or v1 is None:
                continue
            node_drift[name] = {"start": v0, "end": v1, "delta": v1 - v0}
        drift["metrics"][node] = node_drift

    return drift


def _pct(a: float, b: float) -> float:
    if a <= 0:
        return 0.0
    return (b - a) / a * 100.0


def run_soak(hours: float, sample_interval: int) -> dict:
    duration_seconds = int(hours * 3600)
    print(f"[soak] Running long-duration stability soak for {hours:.2f}h "
          f"(sample every {sample_interval}s)")

    stop = threading.Event()
    results: dict = {}

    def flood_worker() -> None:
        results["flood"] = run_flood(duration_seconds=duration_seconds, stop_event=stop)

    flood_thread = threading.Thread(target=flood_worker, name="soak-flood", daemon=True)
    flood_thread.start()

    samples: list[SoakSample] = []
    start_ts = time.time()
    next_sample = start_ts
    while time.time() - start_ts < duration_seconds:
        now = time.time()
        if now < next_sample:
            time.sleep(min(1.0, next_sample - now))
            continue
        elapsed = now - start_ts
        metrics_by_node = {node: scrape_metrics(ports["rpc"]) for node, ports in NODES.items()}
        rss = sample_docker_rss()
        fds = sample_docker_fd()
        samples.append(SoakSample(
            t_elapsed=elapsed,
            metrics=metrics_by_node,
            rss_mb=rss,
            fd_count=fds,
        ))
        print(
            f"  [t={elapsed:7.0f}s] samples={len(samples)} "
            f"nodes_ok={sum(1 for m in metrics_by_node.values() if m)} "
            f"rss_ok={len(rss)} fd_ok={len(fds)}"
        )
        next_sample = start_ts + len(samples) * sample_interval

    stop.set()
    flood_thread.join(timeout=30)

    drift = summarize_drift(samples)
    print("[soak] drift summary:")
    for container, row in drift["rss_mb"].items():
        print(f"  rss {container}: {row['start']:.1f} -> {row['end']:.1f} MiB ({row['delta_pct']:+.1f}%)")
    for container, row in drift["fd_count"].items():
        print(f"  fds {container}: {row['start']} -> {row['end']} (Δ{row['delta']:+d})")
    if drift["regressions"]:
        print("  regressions detected:")
        for r in drift["regressions"]:
            print(f"    ! {r}")
    else:
        print("  no regressions detected")

    return {
        "samples": len(samples),
        "duration_seconds": duration_seconds,
        "drift": drift,
        "flood": results.get("flood", {}),
    }


def parse_args(argv: Optional[list[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="zknot3 adversarial regression runner")
    parser.add_argument(
        "--soak",
        type=float,
        default=0.0,
        metavar="HOURS",
        help="Run long-duration soak mode for N hours (flood + periodic /metrics, RSS, FD sampling)."
             " Default 0 disables soak and runs the short burst suite.",
    )
    parser.add_argument(
        "--sample-interval",
        type=int,
        default=60,
        metavar="SECONDS",
        help="Soak sampling interval in seconds (default: 60).",
    )
    parser.add_argument(
        "--case",
        choices=["tx_replay", "tx_bad_signature", "tx_nonce_gap"],
        default=None,
        help="Run a focused adversarial case for tx admission gates.",
    )
    return parser.parse_args(argv)


def main() -> None:
    args = parse_args()

    if args.case == "tx_replay":
        raise SystemExit(run_case_tx_replay())
    if args.case == "tx_bad_signature":
        raise SystemExit(run_case_tx_bad_signature())
    if args.case == "tx_nonce_gap":
        raise SystemExit(run_case_tx_nonce_gap())

    if args.soak > 0:
        print("zknot3 adversarial test (soak mode)")
        soak = run_soak(hours=args.soak, sample_interval=args.sample_interval)
        # Soak verdict focuses on no regressions + final health.
        health = run_post_attack_health()
        business_failures = []
        env_failures = []
        if soak["drift"]["regressions"]:
            business_failures.append(f"drift_regressions={len(soak['drift']['regressions'])}")
        if health["unhealthy_service"] > 0:
            business_failures.append(f"health_unhealthy_service={health['unhealthy_service']}")
        if health["unhealthy_env"] > 0:
            env_failures.append(f"health_unhealthy_env={health['unhealthy_env']}")
        if soak.get("flood", {}).get("total", 0) <= 0:
            business_failures.append("flood_total=0")
        verdict_ok = (
            not business_failures
            and not env_failures
        )
        print("=" * 60)
        print(f"SOAK VERDICT: {'PASS ✅' if verdict_ok else 'FAIL ❌'}"
              f" (samples={soak['samples']}, regressions={len(soak['drift']['regressions'])})")
        if business_failures:
            print("  business_failures:", ", ".join(business_failures))
        if env_failures:
            print("  environment_failures:", ", ".join(env_failures))
        print("=" * 60)
        raise SystemExit(0 if verdict_ok else 2)

    print("zknot3 adversarial test (DoS + malformed + slow clients + P2P fragmentation)")
    flood = run_flood()
    malformed = run_malformed()
    slow = run_slow_clients()
    oversize = run_oversize_headers()
    p2p = run_p2p_fragmented()
    health = run_post_attack_health()

    business_failures = []
    env_failures = []
    if malformed["unexpected_2xx"] != 0:
        business_failures.append(f"malformed_unexpected_2xx={malformed['unexpected_2xx']}")
    if flood["total"] <= 0:
        business_failures.append("flood_total=0")
    if slow["unexpected_2xx"] != 0:
        business_failures.append(f"slow_unexpected_2xx={slow['unexpected_2xx']}")
    if oversize["unexpected_2xx"] != 0:
        business_failures.append(f"oversize_unexpected_2xx={oversize['unexpected_2xx']}")
    if p2p["hung"] != 0:
        business_failures.append(f"p2p_hung={p2p['hung']}")
    if health["unhealthy_service"] != 0:
        business_failures.append(f"health_unhealthy_service={health['unhealthy_service']}")
    if health["unhealthy_env"] != 0:
        env_failures.append(f"health_unhealthy_env={health['unhealthy_env']}")

    verdict_ok = (
        malformed["unexpected_2xx"] == 0
        and flood["total"] > 0
        and slow["unexpected_2xx"] == 0
        and oversize["unexpected_2xx"] == 0
        and p2p["hung"] == 0
        and health["unhealthy_service"] == 0
        and health["unhealthy_env"] == 0
    )
    print("=" * 60)
    print("VERDICT:", "PASS ✅" if verdict_ok else "FAIL ❌")
    if business_failures:
        print("business_failures:", ", ".join(business_failures))
    if env_failures:
        print("environment_failures:", ", ".join(env_failures))
    print("=" * 60)
    raise SystemExit(0 if verdict_ok else 2)


if __name__ == "__main__":
    main()
