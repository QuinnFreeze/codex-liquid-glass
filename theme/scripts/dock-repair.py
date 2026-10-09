#!/usr/bin/env python3
"""Restore managed launcher tiles after preference/update events, without polling."""
import argparse, base64, copy, datetime, fcntl, json, os, pathlib, plistlib, shutil, subprocess
from autostart_common import ROOT, resolve_app

LABEL = 'local.wynn.codex-liquid-glass'
WRAPPER_ID = LABEL + '.launcher'
DISPLAY_NAME = 'Codex Liquid Glass'

def atomic_json(path, value):
    temporary = path.with_name(path.name + '.new')
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')
    os.replace(temporary, path)

def tile_path(tile):
    from urllib.parse import unquote, urlparse
    url = tile.get('tile-data', {}).get('file-data', {}).get('_CFURLString', '')
    parsed = urlparse(url)
    if parsed.scheme != 'file' or parsed.netloc not in ('', 'localhost'):
        return None
    return pathlib.Path(unquote(parsed.path)).resolve()

def plan_tiles(tiles, cfg, app, allow_add=False):
    """Pure plan: edit verified Codex tiles, retaining unrelated order and metadata."""
    planned = copy.deepcopy(tiles)
    updated_cfg = copy.deepcopy(cfg)
    wrapper = pathlib.Path(cfg['wrapperPath']).resolve()
    known_wrappers = {wrapper, *(pathlib.Path(p).resolve() for p in cfg.get('legacyWrapperPaths', []))}
    official = pathlib.Path(app['applicationPath']).resolve()
    originals = {entry['guid']: entry for entry in cfg.get('originalDockEntries', [])}
    managed = set(cfg.get('dockGuids', []))
    changed = []
    found = False
    for index, tile in enumerate(planned):
        data = tile.get('tile-data', {})
        path = tile_path(tile)
        official_tile = data.get('bundle-identifier') == 'com.openai.codex' and path == official
        own_tile = data.get('bundle-identifier') == WRAPPER_ID and path in known_wrappers
        if not (official_tile or own_tile) or 'GUID' not in tile:
            continue
        found = True
        guid = tile['GUID']
        if official_tile:
            # A replacement GUID, or the same GUID repinned by an updater, gets
            # the current official tile as its reversible baseline.
            originals[guid] = {'index': index, 'guid': guid,
                              'tilePlist': base64.b64encode(plistlib.dumps(tiles[index])).decode()}
        managed.add(guid)
        if own_tile and path == wrapper and data.get('file-label') == DISPLAY_NAME:
            continue
        for key in ['book', 'file-mod-date', 'parent-mod-date']:
            data.pop(key, None)
        data.update({'bundle-identifier': WRAPPER_ID, 'file-label': DISPLAY_NAME,
                     'dock-extra': 0, 'file-type': 41,
                     'file-data': {'_CFURLString': wrapper.as_uri() + '/', '_CFURLStringType': 15}})
        tile['tile-data'] = data
        changed.append(guid)
    if not found and allow_add:
        guid = int.from_bytes(os.urandom(4), 'big')
        while guid in managed or any(tile.get('GUID') == guid for tile in planned):
            guid = int.from_bytes(os.urandom(4), 'big')
        planned.append({'GUID': guid, 'tile-type': 'file-tile', 'tile-data': {
            'bundle-identifier': WRAPPER_ID, 'file-label': DISPLAY_NAME, 'file-type': 41, 'dock-extra': 0,
            'file-data': {'_CFURLString': wrapper.as_uri() + '/', '_CFURLStringType': 15}}})
        managed.add(guid)
        changed.append(guid)
    updated_cfg['originalDockEntries'] = list(originals.values())
    updated_cfg['dockGuids'] = sorted(managed)
    return planned, updated_cfg, changed

def read_dock():
    result = subprocess.run(['/usr/bin/defaults', 'export', 'com.apple.dock', '-'],
                            check=True, capture_output=True, timeout=5)
    return plistlib.loads(result.stdout)

def write_tiles(tiles):
    # Write just this key; other settings changed concurrently remain untouched.
    # Suspend briefly so Dock cannot flush its old cached tiles over the commit.
    # Restart without a stale-preferences flush, including on write failure.
    subprocess.run(['/usr/bin/killall', '-STOP', 'Dock'], capture_output=True, timeout=5)
    try:
        subprocess.run(['/usr/bin/defaults', 'write', 'com.apple.dock', 'persistent-apps', '-array',
                        *(plistlib.dumps(tile).decode() for tile in tiles)], check=True, timeout=5)
    finally:
        try:
            subprocess.run(['/usr/bin/killall', '-KILL', 'Dock'], capture_output=True, timeout=5)
        finally:
            subprocess.run(['/usr/bin/killall', '-CONT', 'Dock'], capture_output=True, timeout=5)

def repair(root=ROOT, reason='manual', allow_add=False, require_enabled=True):
    cfg_path = root / 'autostart.json'
    if not cfg_path.exists() or (require_enabled and (root / 'state/autostart-disabled').exists()):
        return {'changed': False, 'skipped': 'disabled or uninstalled'}
    cfg = json.loads(cfg_path.read_text())
    if cfg.get('managedBy') != LABEL:
        return {'changed': False, 'skipped': 'not managed'}
    wrapper = pathlib.Path(cfg['wrapperPath'])
    info = plistlib.loads((wrapper / 'Contents/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != WRAPPER_ID:
        raise RuntimeError('主题启动器不匹配；未修改 Dock。')
    app = resolve_app(cfg.get('applicationPath'))
    for _ in range(3):
        dock = read_dock()
        before = dock.get('persistent-apps', [])
        tiles, updated_cfg, changed = plan_tiles(before, cfg, app, allow_add)
        if not changed:
            if updated_cfg != cfg:
                backup = pathlib.Path.home() / 'Library/Application Support/CodexThemeBackups' / (
                    'dock-receipt-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f'))
                backup.mkdir(parents=True)
                shutil.copy2(cfg_path, backup / 'autostart.json')
                atomic_json(cfg_path, updated_cfg)
            return {'changed': False, 'reason': reason}
        backup = pathlib.Path.home() / 'Library/Application Support/CodexThemeBackups' / (
            'dock-repair-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f'))
        backup.mkdir(parents=True)
        (backup / 'dock.plist').write_bytes(plistlib.dumps(dock))
        shutil.copy2(cfg_path, backup / 'autostart.json')
        if read_dock().get('persistent-apps', []) != before:
            continue
        # Persist ownership/baselines before committing preferences, so even a
        # crash during defaults write remains reversible.
        updated_cfg['applicationPath'] = app['applicationPath']
        atomic_json(cfg_path, updated_cfg)
        write_tiles(tiles)
        result = {'changed': True, 'reason': reason, 'guids': changed, 'backup': str(backup)}
        atomic_json(root / 'state/dock-repair.json', result)
        return result
    raise RuntimeError('Dock 固定项同时发生变动；本次未覆盖，将等待下一个事件。')

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--reason', default='manual')
    args = parser.parse_args()
    backups = pathlib.Path.home() / 'Library/Application Support/CodexThemeBackups'
    backups.mkdir(parents=True, exist_ok=True)
    with (backups / 'integration.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print(json.dumps({'changed': False, 'skipped': 'integration busy'}))
            return
        print(json.dumps(repair(reason=args.reason), ensure_ascii=False))

if __name__ == '__main__':
    main()
