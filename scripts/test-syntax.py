#!/usr/bin/env python3
"""Use the declared interpreter: a few historical .sh files are Python."""
import pathlib, subprocess
root=pathlib.Path(__file__).resolve().parents[1]
for folder in ['scripts','web']:
    for file in sorted((root/folder).rglob('*')):
        if file.suffix not in ('.sh','.command','.py'): continue
        text=file.read_text()
        if 'python' in text.splitlines()[0] or file.suffix=='.py': compile(text,str(file),'exec')
        elif text.startswith('#!/bin/bash') or text.startswith('#!/usr/bin/env bash'): subprocess.run(['bash','-n',str(file)],check=True)
        else: subprocess.run(['zsh','-n',str(file)],check=True)
print('Script syntax: passed')
