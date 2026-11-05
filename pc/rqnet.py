"""The render queue over the local network: lets other BlenderRender computers use this one.

Lives next to rq.py (on a PC in C:\\GeysierRender\\queue, on a Mac in the app's thismac folder).

  rqnet.py serve                    answer rq commands on TCP (port 48211) and say "here I am" on UDP
                                    (port 48210, every 5 s); one per queue, kept running by `rq worker`
  rqnet.py call <host> <port> <rq args...>
                                    run one rq command on another computer: stdin goes to it, its
                                    stdout comes back here, and its exit code and errors too

The other computer only runs rq.py, and only the commands below; nothing else on it. Submitting work
(receive, batch, cache-put) needs this computer to allow render jobs: the `share` flag file is there
(BlenderRender PC's setup makes it; on a Mac, the app's "Allow this computer to do render jobs") and
the PC isn't switched off (`rq off`).

Wire format, request: one JSON line {"args": [...]}, then the command's stdin until the caller shuts
its side down. Reply: frames of 1 type byte + 4-byte big-endian length + data: b"O" stdout, b"E"
stderr, b"X" the exit code (4 bytes, signed). A reply without X means the connection broke.
"""
import json
import os
import socket
import socketserver
import struct
import subprocess
import sys
import threading
import time
import uuid
from pathlib import Path

VERSION = 2
HERE = Path(__file__).resolve().parent
WIN = os.name == "nt"
PORT = 48211
BEACON_PORT = 48210
SHARE = HERE / "share"
COMMANDS = {"version", "list", "stats", "nudge", "receive", "release", "cancel", "delete", "send", "size",
            "log", "preview", "cache-has", "cache-put", "cache-drop", "batch", "pause", "resume",
            "ensure-worker"}
SUBMIT = {"receive", "batch", "cache-put"}


def settings():
    try:
        return json.loads((HERE / "rq_config.json").read_text())
    except (OSError, ValueError):
        return {}


def allowed():
    return SHARE.exists() and not (HERE / "off").exists()


def frame(sock, kind, data):
    sock.sendall(kind + struct.pack(">I", len(data)) + data)


# --- serve ---

class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        sock = self.request
        try:
            line = self.rfile.readline(65536)
            req = json.loads(line)
            args = req["args"]
            if not (isinstance(args, list) and args and all(isinstance(a, str) for a in args)):
                raise ValueError
        except (ValueError, KeyError, TypeError):
            return self.fail(sock, "bad request")
        if args[0] not in COMMANDS:
            return self.fail(sock, f"{args[0]} isn't allowed over the network")
        if args[0] in SUBMIT and not allowed():
            return self.fail(sock, "This computer doesn't allow render jobs right now")
        flags = subprocess.CREATE_NO_WINDOW if WIN else 0
        env = dict(os.environ, BR_FROM=str(req.get("from") or self.client_address[0])[:64])
        proc = subprocess.Popen([sys.executable, str(HERE / "rq.py"), *args], cwd=HERE, creationflags=flags, env=env,
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        errors = []

        def feed():  # the caller's stdin, until it shuts its side down
            try:
                while chunk := self.rfile.read1(1 << 20):
                    proc.stdin.write(chunk)
            except OSError:
                pass
            finally:
                try:
                    proc.stdin.close()
                except OSError:
                    pass

        threading.Thread(target=feed, daemon=True).start()
        threading.Thread(target=lambda: errors.append(proc.stderr.read()), daemon=True).start()
        try:
            while chunk := proc.stdout.read1(1 << 20):
                frame(sock, b"O", chunk)
            rc = proc.wait()
            for _ in range(40):
                if errors:
                    break
                time.sleep(0.05)
            if errors and errors[0]:
                frame(sock, b"E", errors[0])
            frame(sock, b"X", struct.pack(">i", rc))
        except OSError:  # the caller went away: don't leave e.g. a `send` tar running
            proc.kill()

    @staticmethod
    def fail(sock, message):
        frame(sock, b"E", message.encode())
        frame(sock, b"X", struct.pack(">i", 2))


class Server(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = not WIN  # on Windows it would let a second server share the port


def computer_name():
    name = settings().get("name") or os.environ.get("COMPUTERNAME")
    if not name and not WIN:
        try:
            name = subprocess.run(["scutil", "--get", "ComputerName"], capture_output=True, text=True).stdout.strip()
        except OSError:
            pass
    return name or socket.gethostname()


def node_id():
    p = HERE / "node_id"
    try:
        return p.read_text().strip()
    except OSError:
        nid = uuid.uuid4().hex
        p.write_text(nid)
        return nid


def rq_version():
    """rq.py's VERSION as it is on disk now: the app may have updated it since this started."""
    import re
    try:
        m = re.search(r"^VERSION = (\d+)", (HERE / "rq.py").read_text(encoding="utf-8"), re.M)
        return int(m.group(1)) if m else 0
    except OSError:
        return 0


def beacon(port):
    """Say who this is, every 5 s, to everyone on the local network."""
    sys.path.insert(0, str(HERE))
    import rq
    nid = node_id()
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    while True:
        try:
            state = rq.read_json(HERE / "worker_state.json", {})
            rendering = any(rq.read_json(d / "status.json", {}).get("state") == "rendering"
                            for d in rq.JOBS.iterdir()) if rq.JOBS.is_dir() else False
            msg = {"br": 1, "id": nid, "name": computer_name(), "kind": "pc" if WIN else "mac", "port": port,
                   "allow": allowed(), "off": rq.OFF.exists(), "paused": rq.PAUSED.exists(),
                   "rendering": rendering, "gpu": state.get("gpu", ""), "blender": rq.blender_version(),
                   "version": rq_version(), "net": VERSION}
            data = json.dumps(msg).encode()
            for addr in ("255.255.255.255", "<broadcast>"):
                try:
                    s.sendto(data, (addr, BEACON_PORT))
                except OSError:
                    pass
        except Exception:  # keep saying hello whatever one look at the queue does
            pass
        time.sleep(5)


def serve():
    import rq
    lock = open(HERE / "agent.lock", "a+")
    if not rq._try_lock(lock):
        return  # already running
    port = int(settings().get("net_port") or PORT)
    server = Server(("0.0.0.0", port), Handler)
    (HERE / "agent.json").write_text(json.dumps({"pid": os.getpid(), "version": VERSION, "port": port}))
    threading.Thread(target=beacon, args=(port,), daemon=True).start()
    server.serve_forever()


# --- call ---

def call(host, port, args):
    sock = socket.create_connection((host, int(port)), timeout=8)
    sock.settimeout(None)
    sock.sendall(json.dumps({"args": args, "from": os.environ.get("BR_FROM", "")}).encode() + b"\n")

    def feed():
        try:
            if not sys.stdin.isatty():  # os.read: a buffered stdin left mid-read stops Python exiting
                while chunk := os.read(0, 1 << 20):
                    sock.sendall(chunk)
        except OSError:
            pass
        finally:
            try:
                sock.shutdown(socket.SHUT_WR)
            except OSError:
                pass

    threading.Thread(target=feed, daemon=True).start()
    f = sock.makefile("rb")

    def read(n):
        data = f.read(n)
        if len(data) < n:
            raise ConnectionError(f"{host} stopped answering")
        return data

    out, err = sys.stdout.buffer, sys.stderr.buffer
    while True:
        kind = f.read(1)
        if not kind:
            raise ConnectionError(f"{host} stopped answering")
        n = struct.unpack(">I", read(4))[0]
        data = read(n)
        if kind == b"O":
            out.write(data)
        elif kind == b"E":
            err.write(data)
        elif kind == b"X":
            out.flush()
            err.flush()
            return struct.unpack(">i", data)[0]


def main():
    if len(sys.argv) >= 2 and sys.argv[1] == "serve":
        serve()
    elif len(sys.argv) >= 5 and sys.argv[1] == "call":
        try:
            code = call(sys.argv[2], sys.argv[3], sys.argv[4:])
        except OSError as e:
            sys.stderr.write(f"Can't reach {sys.argv[2]}: {e.strerror or e}\n")
            code = 1
        sys.stdout.flush()
        sys.stderr.flush()
        os._exit(code)  # without waiting for the stdin thread
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
