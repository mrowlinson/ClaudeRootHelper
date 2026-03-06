#!/usr/bin/env python3
"""
Claude Root Helper — socket server.
Runs as root, accepts commands over a Unix domain socket.
"""

import socket
import os
import json
import subprocess
import logging
import signal
import sys
import time
import shutil
import threading
import struct

SOCKET_PATH = '/var/run/claude-root-helper.sock'
PID_PATH = '/var/run/claude-root-helper.pid'
APP_PID_PATH = None  # Resolved at startup from launching user's home dir
LOG_PATH = '/var/log/claude-root-helper.log'
ALLOWED_GID = 20  # staff group
CLIENT_INSTALL_PATH = '/usr/local/bin/claude-root-cmd'
ORPHAN_CHECK_INTERVAL = 3  # seconds
SOL_LOCAL = 0
LOCAL_PEERCRED = 0x001

start_time = time.time()
cmd_count = 0
allowed_uid = None

logging.basicConfig(
    filename=LOG_PATH,
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s'
)

def install_client():
    src = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'claude-root-cmd')
    if os.path.exists(src):
        shutil.copy2(src, CLIENT_INSTALL_PATH)
        os.chmod(CLIENT_INSTALL_PATH, 0o755)
        logging.info(f"Installed client to {CLIENT_INSTALL_PATH}")

def get_peer_uid(conn):
    """Get the UID of the peer connected to a Unix domain socket (macOS)."""
    # struct xucred { u_int cr_version; uid_t cr_uid; short cr_ngroups; gid_t cr_groups[16]; }
    xucred_size = 4 + 4 + 2 + 2 + (16 * 4)  # 76 bytes
    buf = conn.getsockopt(SOL_LOCAL, LOCAL_PEERCRED, xucred_size)
    _, uid = struct.unpack('=II', buf[:8])
    return uid

def handle_client(conn):
    global cmd_count
    try:
        peer_uid = get_peer_uid(conn)
        if allowed_uid is not None and peer_uid != allowed_uid and peer_uid != 0:
            logging.warning(f"Rejected connection from UID {peer_uid} (allowed: {allowed_uid})")
            conn.close()
            return

        data = b''
        while True:
            chunk = conn.recv(65536)
            if not chunk:
                break
            data += chunk
            if b'\n' in data:
                break

        request = json.loads(data.decode().strip())
        cmd = request.get('command', '')
        timeout = request.get('timeout', 120)
        cwd = request.get('cwd', '/')

        if cmd == '__quit__':
            response = {'exit_code': 0, 'stdout': 'Shutting down\n', 'stderr': ''}
            conn.sendall(json.dumps(response).encode() + b'\n')
            conn.close()
            logging.info("Quit command received, shutting down")
            cleanup(None, None)
            return

        if cmd == '__ping__':
            response = {'exit_code': 0, 'stdout': 'pong\n', 'stderr': ''}
            conn.sendall(json.dumps(response).encode() + b'\n')
            conn.close()
            return

        if cmd == '__status__':
            uptime = int(time.time() - start_time)
            info = json.dumps({'uptime': uptime, 'commands': cmd_count, 'pid': os.getpid()})
            response = {'exit_code': 0, 'stdout': info + '\n', 'stderr': ''}
            conn.sendall(json.dumps(response).encode() + b'\n')
            conn.close()
            return

        cmd_count += 1
        logging.info(f"CMD: {cmd} (cwd={cwd}, timeout={timeout})")

        try:
            result = subprocess.run(
                cmd, shell=True, capture_output=True, text=True,
                timeout=timeout, cwd=cwd,
                env={**os.environ, 'PATH': '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin'}
            )
            response = {
                'exit_code': result.returncode,
                'stdout': result.stdout,
                'stderr': result.stderr
            }
        except subprocess.TimeoutExpired:
            response = {'exit_code': 124, 'stdout': '', 'stderr': f'Command timed out after {timeout}s'}
        except Exception as e:
            response = {'exit_code': 1, 'stdout': '', 'stderr': str(e)}

        logging.info(f"EXIT: {response['exit_code']}")
        conn.sendall(json.dumps(response).encode() + b'\n')
    except Exception as e:
        logging.error(f"Error handling client: {e}")
    finally:
        try:
            conn.close()
        except:
            pass

def cleanup(signum, frame):
    logging.info("Shutting down")
    for path in [SOCKET_PATH, PID_PATH]:
        try:
            os.unlink(path)
        except:
            pass
    sys.exit(0)

def app_pid_alive(pid):
    """Check if the app process is still running."""
    try:
        os.kill(pid, 0)
        return True
    except (ProcessLookupError, PermissionError):
        # PermissionError means it exists but we can't signal it (shouldn't happen as root)
        # ProcessLookupError means it's gone
        return isinstance(sys.exc_info()[1], PermissionError)

def watchdog():
    """Background thread that exits the server if the app is no longer running."""
    while True:
        time.sleep(ORPHAN_CHECK_INTERVAL)
        try:
            if not os.path.exists(APP_PID_PATH):
                logging.info("App PID file gone, shutting down")
                os._exit(0)
            with open(APP_PID_PATH) as f:
                app_pid = int(f.read().strip())
            if not app_pid_alive(app_pid):
                logging.info(f"App (PID {app_pid}) is no longer running, shutting down")
                for path in [SOCKET_PATH, PID_PATH]:
                    try:
                        os.unlink(path)
                    except:
                        pass
                os._exit(0)
        except Exception as e:
            logging.error(f"Watchdog error: {e}")

def main():
    global APP_PID_PATH, allowed_uid

    signal.signal(signal.SIGTERM, cleanup)
    signal.signal(signal.SIGINT, cleanup)

    # Parse --home argument to locate the app PID file
    args = sys.argv[1:]
    user_home = None
    for i, arg in enumerate(args):
        if arg == '--home' and i + 1 < len(args):
            user_home = args[i + 1]
            break

    if user_home:
        APP_PID_PATH = os.path.join(user_home, '.claude-root-helper.pid')
    else:
        APP_PID_PATH = '/tmp/claude-root-helper-app.pid'  # legacy fallback
        logging.warning("No --home specified, falling back to /tmp PID file")

    install_client()

    try:
        allowed_uid = os.stat(APP_PID_PATH).st_uid
        logging.info(f"Restricting access to UID {allowed_uid}")
    except FileNotFoundError:
        logging.warning("App PID file not found, allowing any staff-group user")

    if os.path.exists(SOCKET_PATH):
        os.unlink(SOCKET_PATH)

    with open(PID_PATH, 'w') as f:
        f.write(str(os.getpid()))

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.bind(SOCKET_PATH)
    os.chmod(SOCKET_PATH, 0o660)
    os.chown(SOCKET_PATH, 0, ALLOWED_GID)
    sock.listen(5)

    # Start watchdog to auto-exit if the app dies
    wd = threading.Thread(target=watchdog, daemon=True)
    wd.start()

    logging.info(f"Root helper started (PID {os.getpid()})")

    while True:
        conn, _ = sock.accept()
        handle_client(conn)

if __name__ == '__main__':
    main()
