#!/usr/bin/env python3
"""Post-build sanity check: do the first-party Python packages shipped in an
image actually import each other?  (Written 2026-09-19 after an image with
make EXIT:0 shipped a stale batocera_common that batocera-launch could not
import.  `make` success says nothing about this.)

Usage: verify-launch-imports.py <target-dir> [--python /path/to/python] [--squashfs images/rootfs.squashfs]

  <target-dir>   e.g. output/x86_64-focused/target
  --python       interpreter with the third-party deps (aiohttp, pyyaml,
                 pyudev, evdev, pillow, qrcode, uvloop, typing_extensions);
                 enables the real import test. Without it only the static
                 check runs.
  --squashfs     also confirm the modules are in the packed image.
Exit 0 = OK, 1 = problems found.
"""
import argparse, glob, os, re, subprocess, sys

ap = argparse.ArgumentParser()
ap.add_argument('target')
ap.add_argument('--python')
ap.add_argument('--squashfs')
a = ap.parse_args()

sps = glob.glob(os.path.join(a.target, 'usr/lib/python3.*/site-packages'))
if not sps:
    sys.exit(f'no site-packages under {a.target}')
sp = sps[0]
FIRST_PARTY = re.compile(r'^(batocera_[a-z0-9_]+|configgen|hotkeygen)$')
pkgs = [d for d in os.listdir(sp) if FIRST_PARTY.match(d) and os.path.isdir(os.path.join(sp, d))]

def modules(pkg):
    root = os.path.join(sp, pkg)
    out = set()
    for r, _, fs in os.walk(root):
        for f in fs:
            if f.endswith('.py'):
                rel = os.path.relpath(os.path.join(r, f), sp)[:-3].replace(os.sep, '.')
                out.add(rel[:-9] if rel.endswith('.__init__') else rel)
    return out

have = set()
for p in pkgs:
    have |= modules(p)

imp = re.compile(r'^\s*(?:from\s+((?:batocera_[a-z0-9_]+|configgen|hotkeygen)[\w.]*)\s+import\s+([\w, ()*\n]+?)(?:#|$)|import\s+((?:batocera_[a-z0-9_]+)[\w.]*))', re.M)
problems = []
for p in pkgs:
    for r, _, fs in os.walk(os.path.join(sp, p)):
        for f in fs:
            if not f.endswith('.py'):
                continue
            path = os.path.join(r, f)
            src = open(path, errors='ignore').read()
            for m in re.finditer(r'^\s*(?:from\s+((?:batocera_[a-z0-9_]+|configgen|hotkeygen)[\w.]*)\s+import|import\s+((?:batocera_[a-z0-9_]+)[\w.]*))', src, re.M):
                mod = m.group(1) or m.group(2)
                if mod not in have and mod not in pkgs:
                    problems.append((os.path.relpath(path, sp), mod))

print(f'first-party packages in image: {", ".join(sorted(pkgs))}')
missing = sorted({m for _, m in problems})
if missing:
    print(f'STATIC: {len(missing)} imported module(s) not present in the image:')
    for m in missing:
        who = sorted({f for f, mm in problems if mm == m})
        print(f'   {m}   (imported by {who[0]}{" +%d more" % (len(who)-1) if len(who) > 1 else ""})')
else:
    print('STATIC: every first-party import resolves to a shipped module')

fail = bool(missing)

if a.python:
    # Only the first-party packages come from the image; third-party deps
    # (aiohttp, PIL, ...) come from --python's own env. Putting the whole
    # target site-packages on the path would load target-built C extensions
    # (e.g. PIL linked against target libjpeg) that can't run on the host.
    import tempfile
    shim = tempfile.mkdtemp(prefix='fp-shim-')
    for p_ in pkgs:
        os.symlink(os.path.abspath(os.path.join(sp, p_)), os.path.join(shim, p_))
    env = dict(os.environ, PYTHONPATH=shim, PYTHONDONTWRITEBYTECODE='1')
    mods = ['batocera_launch.cli'] + sorted(pkgs)  # configgen removed upstream 2026-10
    for mod in mods:
        r = subprocess.run([a.python, '-c', f'import {mod}'], env=env, capture_output=True, text=True)
        if r.returncode:
            fail = True
            print(f'IMPORT FAIL  {mod}: {r.stderr.strip().splitlines()[-1] if r.stderr.strip() else "?"}')
        else:
            print(f'IMPORT OK    {mod}')

if a.squashfs:
    out = subprocess.run(['unsquashfs', '-l', a.squashfs], capture_output=True, text=True).stdout
    packed = set(re.findall(r'site-packages/(batocera_common/\w+)\.py', out))
    want = {m.replace('.', '/') for m in have if m.startswith('batocera_common.')}
    gone = sorted(want - packed)
    if gone:
        fail = True
        print(f'SQUASHFS: {len(gone)} batocera_common module(s) in target/ but not packed: {gone}')
    else:
        print(f'SQUASHFS: all {len(want)} batocera_common modules packed')

print('RESULT:', 'FAIL' if fail else 'OK')
sys.exit(1 if fail else 0)
