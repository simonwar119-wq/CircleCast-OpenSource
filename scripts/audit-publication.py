#!/usr/bin/env python3
"""Audit staged files and reachable Git history; print finding categories, never secret values.
This is a project-specific guardrail, not a complete secret scanner.
"""
from pathlib import Path
import argparse
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--history', action='store_true', help='Also inspect every reachable commit tree and commit message.')
args = parser.parse_args()

def git(*arguments):
    return subprocess.check_output(['git', '-C', str(root), *arguments], stderr=subprocess.DEVNULL)

allowed_roots = {'Sources', 'Tests', 'Resources', 'scripts', 'docs'}
allowed_top = {'Package.swift', 'README.md', 'LICENSE', 'CHANGELOG.md', 'CONTRIBUTING.md',
               'SECURITY.md', 'THIRD_PARTY_NOTICES.md', '.gitignore'}
allowed_suffixes = {'.swift', '.md', '.plist', '.sh', '.py'}
patterns = {
    'private key': re.compile(rb'-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----'),
    'GitHub token': re.compile(rb'(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})'),
    'AWS access key': re.compile(rb'(?:AKIA|ASIA)[A-Z0-9]{16}'),
    'Slack token': re.compile(rb'xox[baprs]-[A-Za-z0-9-]{20,}'),
    'credential literal': re.compile(rb'''(?i)(?:api[_-]?key|access[_-]?token|password|client[_-]?secret)\s*[:=]\s*["'][A-Za-z0-9_./+=-]{16,}["']'''),
    'absolute home path': re.compile(rb'(?:/Users/|/home/)[A-Za-z0-9_.-]+/'),
    'embedded URL credentials': re.compile(rb'https?://[^/\s:@]+:[^/\s@]+@'),
    'delegation transcript': re.compile(rb'<(?:codex_delegation|transcript_evidence)>'),
}
findings = []
seen = set()

def inspect(path, mode, oid, context):
    key = (path, mode, oid)
    if key in seen:
        return
    seen.add(key)
    p = Path(path)
    if mode not in {'100644', '100755'}:
        findings.append((context, path, 'non-regular file / symlink / submodule'))
        return
    if len(p.parts) == 1:
        allowed = path in allowed_top
    else:
        allowed = p.parts[0] in allowed_roots and p.suffix in allowed_suffixes
    if not allowed:
        findings.append((context, path, 'not in publication allowlist'))
    raw = git('cat-file', 'blob', oid)
    if len(raw) > 256_000 or b'\0' in raw:
        findings.append((context, path, 'binary or oversized content'))
    try:
        raw.decode('utf-8')
    except UnicodeDecodeError:
        findings.append((context, path, 'not UTF-8 text'))
    for category, pattern in patterns.items():
        if pattern.search(raw):
            findings.append((context, path, category))

for entry in git('ls-files', '--stage', '-z').split(b'\0'):
    if not entry:
        continue
    metadata, path = entry.split(b'\t', 1)
    mode, oid, stage = metadata.decode().split()
    if stage != '0':
        findings.append(('index', path.decode(), 'unresolved merge stage'))
    inspect(path.decode(), mode, oid, 'index')

commits = []
if args.history:
    commits = git('rev-list', '--all').decode().splitlines()
    for commit in commits:
        for entry in git('ls-tree', '-r', '-z', commit).split(b'\0'):
            if not entry:
                continue
            metadata, path = entry.split(b'\t', 1)
            mode, kind, oid = metadata.decode().split()
            inspect(path.decode(), mode, oid, commit[:12])
        metadata = git('show', '-s', '--format=%an%n%ae%n%cn%n%ce%n%B', commit)
        for category, pattern in patterns.items():
            if pattern.search(metadata):
                findings.append((commit[:12], 'commit metadata', category))
        emails = git('show', '-s', '--format=%ae%n%ce', commit).decode().splitlines()
        if any(not email.endswith('@users.noreply.github.com') for email in emails):
            findings.append((commit[:12], 'commit metadata', 'non-GitHub-noreply email: manual privacy review required'))

if not seen:
    print('FAIL: no staged/tracked files to audit.', file=sys.stderr)
    sys.exit(1)
for context, path, category in findings:
    print(f'FAIL [{context}] {path}: {category}', file=sys.stderr)
if findings:
    sys.exit(1)
print(f'PASS: {len(seen)} unique file versions; {len(commits)} historical commits; no configured-pattern findings.')
print('Manual ownership, privacy, and full-history review still required.')
