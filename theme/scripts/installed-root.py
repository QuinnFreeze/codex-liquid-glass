#!/usr/bin/env python3
"""Public commands follow the durable installation after autostart setup."""
import json, pathlib
root = pathlib.Path(__file__).resolve().parents[1]
pointer = root / 'state/autostart-target.json'
if pointer.exists():
    target = pathlib.Path(json.loads(pointer.read_text())['root'])
    if (target / 'autostart.json').is_file():
        root = target
print(root)
