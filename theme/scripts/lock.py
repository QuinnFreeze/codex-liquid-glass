#!/usr/bin/env python3
"""Serialize theme mutations; the kernel releases this lock on exit."""
import fcntl, os, pathlib, subprocess, sys
state = pathlib.Path(__file__).resolve().parents[1] / 'state'
state.mkdir(parents=True, exist_ok=True)
with (state / 'operation.lock').open('a') as lock:
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise SystemExit('另一个主题维护命令正在运行；待它完成后重试。')
    environment = dict(os.environ)
    environment['WYNN_THEME_OPERATION_LOCKED'] = '1'
    raise SystemExit(subprocess.call(sys.argv[1:], env=environment))
