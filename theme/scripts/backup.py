#!/usr/bin/env python3
"""Back up theme-managed files before mutations; never backs up secrets."""
import pathlib,datetime,json,hashlib,shutil,plistlib,sys
from autostart_common import resolve_app
root=pathlib.Path(__file__).resolve().parents[1]
b=root/'backups'/datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f');b.mkdir(parents=True)
files=['settings.json','state/install.json','Launch Liquid Glass.command']
manifest={'time':datetime.datetime.now().isoformat(),'modifiedApplicationFiles':[],'files':{}}
for n in files:
 p=root/n
 if p.is_file():
  dst=b/n;dst.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(p,dst);manifest['files'][n]={'exists':True,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()}
 else:manifest['files'][n]={'exists':False}
appinfo=resolve_app();app=pathlib.Path(appinfo['applicationPath']);manifest['version']=plistlib.loads((app/'Contents/Info.plist').read_bytes()).get('CFBundleShortVersionString')
for n in ['Contents/Info.plist','Contents/Resources/app.asar','Contents/MacOS/'+pathlib.Path(appinfo['executable']).name]:
 h=hashlib.sha256()
 with (app/n).open('rb') as f:
  for chunk in iter(lambda:f.read(1024*1024),b''):h.update(chunk)
 manifest.setdefault('originalAppHashes',{})[n]=h.hexdigest()
(b/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2));print(b)
