"""Runs the network probe twice against listeners on 127.0.0.1 and ::1 and
checks the outcome. Usage: prove-offline.py <probe-dir> <Scrub.app>"""

import socket
import subprocess
import sys
import threading

probes, app = sys.argv[1], sys.argv[2]
failures: list[str] = []
hits = {"tcp": 0, "udp": 0}
lock = threading.Lock()


def check(ok: bool, message: str) -> None:
    print(f"{'PASS' if ok else 'FAIL'}  {message}")
    if not ok:
        failures.append(message)


def tcp_listener(family: int, host: str, port: int) -> int:
    server = socket.socket(family, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((host, port))
    server.listen()

    def serve() -> None:
        while True:
            conn, _ = server.accept()
            with lock:
                hits["tcp"] += 1
            conn.close()

    threading.Thread(target=serve, daemon=True).start()
    return server.getsockname()[1]


def udp_listener(family: int, host: str, port: int) -> int:
    server = socket.socket(family, socket.SOCK_DGRAM)
    server.bind((host, port))

    def serve() -> None:
        while True:
            server.recvfrom(64)
            with lock:
                hits["udp"] += 1

    threading.Thread(target=serve, daemon=True).start()
    return server.getsockname()[1]


tcp_port = tcp_listener(socket.AF_INET, "127.0.0.1", 0)
tcp_listener(socket.AF_INET6, "::1", tcp_port)
udp_port = udp_listener(socket.AF_INET, "127.0.0.1", 0)
udp_listener(socket.AF_INET6, "::1", udp_port)


def run(name: str) -> dict[str, str]:
    # Launched through LaunchServices, as a user would, not exec'd from a shell.
    output = f"{probes}/{name}.out"
    subprocess.run(["open", "-n", "-W", "--stdout", output, "--stderr", output, f"{probes}/{name}.app", "--args", str(tcp_port), str(udp_port)], timeout=180, check=True)
    results = {}
    for line in open(output).read().splitlines():
        if " " not in line:
            continue
        probe, rest = line.split(" ", 1)
        results[probe] = rest
    return results


LOOPBACK = ["tcp-ipv4-loopback", "tcp-ipv6-loopback", "udp-ipv4-loopback", "udp-ipv6-loopback", "network-framework-loopback", "child-process-loopback"]

control = run("control")
print("Control run, unsandboxed:")
for probe, outcome in control.items():
    print(f"        {probe}: {outcome}")
check(all(control.get(p, "").startswith("ok") for p in LOOPBACK) and hits["tcp"] > 0 and hits["udp"] > 0, "the probe gets through when unsandboxed (loopback TCP, UDP, Network.framework, child process)")

before = dict(hits)
sandboxed = run("sandboxed")
print("Sandboxed run, Scrub's entitlements:")
for probe, outcome in sandboxed.items():
    print(f"        {probe}: {outcome}")
check(len(sandboxed) == 12, f"every probe ran ({len(sandboxed)} of 12)")
leaked = [p for p, outcome in sandboxed.items() if not outcome.startswith("refused")]
check(not leaked, f"the OS refused every way out ({', '.join(leaked) or 'none got through'})")
check(hits == before, f"the listeners received nothing from the sandboxed run (TCP {hits['tcp'] - before['tcp']}, UDP {hits['udp'] - before['udp']})")


def entitlements(path: str) -> str:
    return subprocess.run(["codesign", "-d", "--entitlements", "-", "--xml", path], capture_output=True, text=True).stdout


check(entitlements(app) != "" and entitlements(app) == entitlements(f"{probes}/sandboxed.app"), "Scrub.app is signed with exactly the entitlements the probe ran under")

print(f"\n{'Offline proven' if not failures else f'{len(failures)} failed'}")
sys.exit(1 if failures else 0)
