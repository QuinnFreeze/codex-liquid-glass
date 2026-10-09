#!/usr/bin/env python3
"""Launch the current signed application and attach external CSS."""
import argparse, os, pathlib, subprocess, sys, time
from autostart_common import ROOT, config, resolve_app, running_pids, status

parser = argparse.ArgumentParser()
parser.add_argument('--test-profile', help=argparse.SUPPRESS)
parser.add_argument('--port', type=int)
args = parser.parse_args()
app = resolve_app()
port = args.port or config().get('port', 9236)
if not 1024 <= port <= 65535:
    raise SystemExit('Invalid local port')
flags = ['--remote-debugging-address=127.0.0.1', '--remote-debugging-port=' + str(port)]
if args.test_profile:
    profile = pathlib.Path(args.test_profile).resolve()
    profile.mkdir(parents=True, exist_ok=True)
    environment = dict(os.environ)
    environment['CODEX_ELECTRON_USER_DATA_PATH'] = str(profile)
    with (ROOT / 'state/test-launch.log').open('ab') as log:
        child = subprocess.Popen([app['executable'], '--user-data-dir=' + str(profile), *flags],
                                 env=environment, stdout=log, stderr=log, start_new_session=True)
    pid = child.pid
else:
    pids = running_pids(app)
    if pids:
        command = subprocess.check_output(['/bin/ps', '-p', str(pids[0]), '-o', 'args='], text=True)
        if flags[1] not in command:
            status(active=False, needsRestart=True, pid=pids[0],
                   message='当前聊天保持运行。退出一次后从 Dock 的 Codex Liquid Glass 入口重新打开即可自动加载。')
            subprocess.run(['/usr/bin/open', '-a', app['applicationPath']], check=True)
            raise SystemExit(0)
    subprocess.run(['/usr/bin/open', '-a', app['applicationPath'], '--args', *flags], check=True)
    for _ in range(100):
        pids = running_pids(app)
        if pids:
            break
        time.sleep(.1)
    else:
        raise SystemExit('Codex 启动进程未就绪。')
    pid = pids[0]
attach = [sys.executable, str(ROOT / 'scripts/auto-attach.py'), '--app', app['applicationPath'], '--port', str(port)]
if pid:
    attach.extend(['--pid', str(pid)])
raise SystemExit(subprocess.call(attach))
