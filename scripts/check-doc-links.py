#!/usr/bin/env python3
"""Check repository-local Markdown links. No network requests."""
from pathlib import Path
import re
import sys
from urllib.parse import unquote

root = Path(__file__).resolve().parents[1]
errors = []
count = 0
for document in sorted(root.rglob('*.md')):
    if any(part in {'.git', '.build', 'dist', 'TestArtifacts'} for part in document.relative_to(root).parts):
        continue
    for target in re.findall(r'\[[^\]]*\]\(([^\s)]+)(?:\s+[^)]*)?\)', document.read_text()):
        if target.startswith(('https://', 'http://', 'mailto:', '#')):
            continue
        path = unquote(target.split('#', 1)[0].strip('<>'))
        count += 1
        resolved = (document.parent / path).resolve()
        if not resolved.is_relative_to(root) or not resolved.exists():
            errors.append(f'{document.relative_to(root)}: {path}')
if errors:
    print('\n'.join(errors), file=sys.stderr)
    sys.exit(1)
print(f'PASS: {count} local documentation links resolve.')
