#!/usr/bin/env python3
"""Remove runtime hooks, allowing cleanup of a confirmed dead daemon."""
import json, os, pathlib, socket, subprocess, sys

root = pathlib.Path(sys.argv[1]).resolve()
node = sys.argv[2]
state = root / 'state'
endpoint = state / 'control.sock'
metadata = state / 'daemon.json'
info = json.loads(metadata.read_text()) if metadata.exists() else {}
port = int(info.get('port', sys.argv[3] if len(sys.argv) > 3 else 9236))

if endpoint.exists():
    try:
        with socket.socket(socket.AF_UNIX) as control:
            control.settimeout(30)
            control.connect(str(endpoint))
            control.sendall(b'remove')
            chunks = []
            while chunk := control.recv(8192):
                chunks.append(chunk)
        result = json.loads(b''.join(chunks))
        if result.get('removed') is not True:
            raise SystemExit('主题服务未确认撤销：' + str(result))
        print(json.dumps(result))
        raise SystemExit(0)
    except (ConnectionRefusedError, FileNotFoundError):
        pass

pid = info.get('pid')
if isinstance(pid, int):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        pass
    else:
        raise SystemExit('主题服务进程仍存在但控制接口未响应；保留状态以避免重复注入。')

if (state / 'registrations.json').exists():
    listener = subprocess.run(['/usr/sbin/lsof', '-nP', '-iTCP:' + str(port),
                               '-sTCP:LISTEN', '-t'], capture_output=True, text=True)
    if listener.stdout.strip():
        subprocess.run([node, str(root / 'scripts/runtime.mjs'), 'once-remove', str(port)], check=True)
    # Without a listener the renderer and its hooks no longer exist.

for name in ['control.sock', 'registrations.json', 'daemon.json']:
    (state / name).unlink(missing_ok=True)
print(json.dumps({'removed': True, 'staleStateCleared': True}))
