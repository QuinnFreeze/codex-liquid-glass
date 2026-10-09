"""Shared paths and exact-bundle checks for the external theme integration."""
import json, pathlib, plistlib, socket, subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
BUNDLE_ID = 'com.openai.codex'

def config():
    p = ROOT / 'autostart.json'
    return json.loads(p.read_text()) if p.exists() else {}

def resolve_app(hint=None):
    candidates = [hint, config().get('applicationPath'), '/Applications/ChatGPT.app', '/Applications/Codex.app']
    result = validate_candidates(candidates)
    if result:
        return result
    # Spotlight is only a fallback: a stalled index must not block a valid bundle.
    try:
        search = subprocess.run(['/usr/bin/mdfind', 'kMDItemCFBundleIdentifier == "com.openai.codex"'],
                                capture_output=True, text=True, timeout=5)
        result = validate_candidates(search.stdout.splitlines())
        if result:
            return result
    except (OSError, subprocess.TimeoutExpired):
        pass
    raise RuntimeError('未找到 bundle id 为 com.openai.codex 的官方安装包。')

def validate_candidates(candidates):
    for candidate in candidates:
        if not candidate:
            continue
        app = pathlib.Path(candidate).resolve()
        try:
            info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
            name = info['CFBundleExecutable']
            if info.get('CFBundleIdentifier') != BUNDLE_ID or pathlib.Path(name).name != name:
                continue
            executable = app / 'Contents/MacOS' / name
            if not executable.is_file():
                continue
            return {'applicationPath': str(app), 'executable': str(executable),
                    'version': info.get('CFBundleShortVersionString'), 'icon': info.get('CFBundleIconFile')}
        except (OSError, ValueError, KeyError, plistlib.InvalidFileException):
            continue
    return None

def running_pids(app):
    output = subprocess.check_output(['/bin/ps', '-ax', '-o', 'pid=,comm='], text=True)
    return [int(parts[0]) for line in output.splitlines()
            if len(parts := line.strip().split(None, 1)) == 2 and parts[1] == app['executable']]

def listener_pids(port):
    p = subprocess.run(['/usr/sbin/lsof', '-nP', '-iTCP:' + str(port), '-sTCP:LISTEN', '-t'],
                       capture_output=True, text=True)
    return [int(value) for value in p.stdout.split() if value.isdigit()]

def status(**values):
    state = ROOT / 'state'
    state.mkdir(parents=True, exist_ok=True)
    (state / 'autostart-status.json').write_text(json.dumps(values, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(values, ensure_ascii=False), flush=True)

def runtime_status():
    try:
        with socket.socket(socket.AF_UNIX) as s:
            s.settimeout(1)
            s.connect(str(ROOT / 'state/control.sock'))
            s.sendall(b'status')
            return json.loads(s.recv(8192))
    except (OSError, ValueError):
        return {}
