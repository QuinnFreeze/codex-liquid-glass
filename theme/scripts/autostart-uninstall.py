#!/usr/bin/env python3
"""Remove autoload and restore the original Codex Dock tile, preserving other edits."""
import base64, datetime, fcntl, importlib.util, json, os, pathlib, plistlib, shutil, subprocess, sys
from autostart_common import ROOT, config

cfg = config()
label = 'local.wynn.codex-liquid-glass'
if cfg.get('managedBy') != label:
    raise SystemExit('此目录未登记自动主题；未操作 Dock 或后台服务。')
home = pathlib.Path.home()
backups = home / 'Library/Application Support/CodexThemeBackups'
backups.mkdir(parents=True, exist_ok=True)
integration_lock = (backups / 'integration.lock').open('a')
try:
    fcntl.flock(integration_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    raise SystemExit('另一个自动主题安装/卸载命令正在运行。')
cfg = config()  # Dock events may have updated GUID receipts before we got the lock.
if cfg.get('managedBy') != label:
    raise SystemExit('此目录已撤销自动主题；未操作 Dock 或后台服务。')
backup = home / 'Library/Application Support/CodexThemeBackups' / ('uninstall-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f'))
backup.mkdir(parents=True)
agent = pathlib.Path(cfg['agentPath'])
wrapper = pathlib.Path(cfg['wrapperPath'])
for name, p in [('autostart.json', ROOT / 'autostart.json'), ('settings.json', ROOT / 'settings.json'), ('agent.plist', agent)]:
    if p.exists():
        shutil.copy2(p, backup / name)
if wrapper.exists():
    shutil.copytree(wrapper, backup / 'wrapper.app')
subprocess.run(['/usr/bin/defaults', 'export', 'com.apple.dock', str(backup / 'dock.plist')], check=True)
disabled = ROOT / 'state/autostart-disabled'
disabled.touch()
subprocess.run(['/bin/launchctl', 'bootout', 'gui/' + str(os.getuid()) + '/' + label], capture_output=True)
with (ROOT / 'state/attachment.lock').open('a') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    operation_lock = (ROOT / 'state/operation.lock').open('a')
    fcntl.flock(operation_lock, fcntl.LOCK_EX)
    subprocess.run([sys.executable, str(ROOT / 'scripts/stop.py'), str(ROOT), cfg['nodePath']], check=True)
    original = {e['guid']: plistlib.loads(base64.b64decode(e['tilePlist'])) for e in cfg['originalDockEntries']}
    spec = importlib.util.spec_from_file_location('dock_repair', ROOT / 'scripts/dock-repair.py')
    dock_repair = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(dock_repair)
    # Read current preferences after the locks/renderer cleanup, then restore
    # only our fixed tiles. Other Dock settings are never imported wholesale.
    current_tiles = dock_repair.read_dock().get('persistent-apps', [])
    restored = []
    for tile in current_tiles:
        owned = tile.get('tile-data', {}).get('bundle-identifier') == label + '.launcher'
        known_paths = [cfg['wrapperPath'], *cfg.get('legacyWrapperPaths', [])]
        owned = owned and dock_repair.tile_path(tile) in {pathlib.Path(p).resolve() for p in known_paths}
        if owned:
            if tile['GUID'] in original:
                restored.append(original[tile['GUID']])
        else:
            restored.append(tile)
    (backup / 'dock-restored.plist').write_bytes(plistlib.dumps({'persistent-apps': restored}))
    dock_repair.write_tiles(restored)
    first = pathlib.Path(cfg['firstBackup'])
    baseline = json.loads((first / 'manifest.json').read_text())
    agent.unlink(missing_ok=True)
    if wrapper.exists():
        info = plistlib.loads((wrapper / 'Contents/Info.plist').read_bytes())
        if info.get('CFBundleIdentifier') != label + '.launcher':
            raise SystemExit('启动器被其他应用替换，未删除。')
        shutil.rmtree(wrapper)
    for name, p in [('agent.plist', agent), ('wrapper.app', wrapper)]:
        if baseline['files'][name]['existed']:
            if (first / name).is_dir():
                shutil.copytree(first / name, p)
            else:
                shutil.copy2(first / name, p)
    (ROOT / 'autostart.json').unlink()
    pointer = pathlib.Path(cfg['sourceRoot']) / 'state/autostart-target.json'
    if pointer.exists() and json.loads(pointer.read_text()).get('root') == str(ROOT):
        shutil.copy2(pointer, backup / 'source-pointer.json')
        pointer.unlink()
    (ROOT / 'Launch Liquid Glass.command').unlink(missing_ok=True)
    (ROOT / 'state/install.json').unlink(missing_ok=True)
report = {'managedBy': label, 'removed': True, 'dockRestored': True, 'observerUnloaded': True,
          'themeFilesPreserved': True, 'backup': str(backup), 'applicationFilesModified': []}
(ROOT / 'state/autostart-uninstall.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
print(json.dumps(report, ensure_ascii=False, indent=2))
