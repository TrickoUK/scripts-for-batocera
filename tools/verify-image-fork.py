#!/usr/bin/env python3
"""Fork-specific post-build assertions on an output/<target>/target tree.
Usage: verify-image-fork.py <target-dir>   (exit 0 = all ok)"""
import glob, os, sys, xml.etree.ElementTree as ET
t = sys.argv[1]
bad = []
# Board-aware: read what this board actually enables (both boards enable
# standalone MAME + ares as of 2026-10).
cfg = os.path.join(os.path.dirname(os.path.abspath(t.rstrip('/'))), '.config')
CONF = open(cfg).read() if os.path.exists(cfg) else ''
HAS_ARES = 'BR2_PACKAGE_ARES=y' in CONF
HAS_MAME = 'BR2_PACKAGE_MAME=y' in CONF
print(f'board flags from .config: ares={HAS_ARES} standalone-mame={HAS_MAME}')
def chk(cond, msg):
    print(('ok   ' if cond else 'FAIL ') + msg)
    if not cond: bad.append(msg)
r = ET.parse(os.path.join(t, 'usr/share/emulationstation/es_systems.cfg')).getroot()
S = {s.findtext('name'): s for s in r.iter('system')}
def cores(n): return {(e.get('name'), c.text) for e in S[n].iter('emulator') for c in e.iter('core')} if n in S else set()
def exts(n): return set((S[n].findtext('extension') or '').split()) if n in S else set()
chk(len(S) >= (144 if HAS_MAME else 143), f'{len(S)} systems in es_systems.cfg (>= {144 if HAS_MAME else 143}; vectrex only via standalone MAME)')
chk('.neo' in exts('neogeo'), 'neogeo lists .neo')
chk(('libretro', 'geolith') in cores('neogeo') and ('libretro', 'geolith') in cores('neogeocd'), 'geolith serves neogeo + neogeocd')
for sysn in ('n64', 'snes', 'nes', 'megadrive', 'pcengine', 'mastersystem', 'sega32x', 'megacd'):
    if HAS_ARES: chk(('ares', 'ares') in cores(sysn), f'ares serves {sysn}')
    else: chk(('ares', 'ares') not in cores(sysn), f'{sysn}: no ares core (ares not enabled on this board)')
if HAS_MAME: chk(('mame', 'mame') in cores('neogeo'), 'standalone mame serves neogeo')
chk(('sm2-emu', 'sm2-emu') in cores('model2'), 'model2 served by sm2-emu')
chk(('pcsx2x6', 'pcsx2x6') in cores('namco2x6'), 'namco2x6 served by pcsx2x6')
chk(('libretro', 'mednafen_psx') in cores('psx'), 'psx served by beetle-psx')
chk(('libretro', 'pcsx2') in cores('ps2'), 'ps2 served by libretro-ps2')
chk(('mame', 'mame') in cores('arcade') or ('mame', 'mame') in cores('mame'), 'standalone mame present (x86 board) or n/a') if False else None
d = os.path.join(t, 'usr/share/batocera/launch/defaults/config-arch.yml')
txt = open(d).read() if os.path.exists(d) else ''
chk('parallel_n64' in txt.split('n64:')[1][:120] if 'n64:' in txt else False, 'fork default fixups installed (n64 -> parallel_n64)')
sp = glob.glob(os.path.join(t, 'usr/lib/python3.*/site-packages'))[0]
# Upstream removed batocera-configgen entirely (#16766, merged 2026-10-04 evening); ares moved to
# the fork-only python-src/batocera-launch-ares. Buildroot never deletes stale target files, so
# a non-wiped target/ would still carry the old tree.
chk(not os.path.isdir(os.path.join(sp, 'configgen')), 'no stale configgen package (removed upstream 2026-10)')
chk(not os.path.exists(os.path.join(t, 'usr/share/batocera/configgen')), 'no stale /usr/share/batocera/configgen')
if HAS_ARES:
    chk(os.path.exists(os.path.join(sp, 'batocera_launch_ares/emulator.py')), 'batocera_launch_ares shipped')
    ep_ares = ''.join(open(f).read() for f in glob.glob(os.path.join(sp, 'batocera_launch_ares-*.dist-info/entry_points.txt')))
    chk('ares = batocera_launch_ares:Ares' in ep_ares, 'ares registered as a batocera_launch.emulators entry point')
lr = os.path.join(sp, 'batocera_launch_libretro')
for core in ('geolith', 'supermodel', 'mednafen_psx', 'pcsx2'):
    chk(os.path.exists(os.path.join(lr, f'cores/{core}.py')), f'batocera_launch_libretro/cores/{core}.py shipped')
ep = ''.join(open(f).read() for f in glob.glob(os.path.join(sp, 'batocera_launch_libretro-*.dist-info/entry_points.txt')))
for core in ('geolith', 'supermodel'):
    chk(f'cores.{core}:' in ep, f'{core} registered as a batocera_launch_libretro.cores entry point')
chk('beetle_psx_hw_pgxp_mode' in open(os.path.join(lr, 'cores/mednafen_psx.py')).read(), 'fork beetle-psx options in mednafen_psx.py')
chk('lr_pcsx2_pgs_ssaa' in open(os.path.join(lr, 'cores/pcsx2.py')).read(), 'fork pcsx2 options in pcsx2.py')
# Libretro.__post_init__ must chain to Emulator.__post_init__ (sets .system); upstream's port missed it and
# every libretro launch died with "'Libretro' object has no attribute 'system'" (2026-10-04 image).
chk('super().__post_init__()' in open(os.path.join(lr, 'emulator.py')).read(), 'Libretro.__post_init__ calls Emulator.__post_init__')
lm = os.path.join(sp, 'batocera_launch_libretro_mame')
chk('write_crosshair_config' in open(os.path.join(lm, 'controllers.py')).read(), 'libretro-mame per-driver crosshair cfg writer shipped')
chk('mame_voodoo_edge_aa' in open(os.path.join(lm, 'core.py')).read(), 'libretro-mame PSX GPU / Voodoo options shipped')
chk("core == 'mame' and" in open(os.path.join(lm, 'command.py')).read(), 'offscreenreload plugin gated to libretro-mame only')
for so in ('geolith', 'mame', 'fbneo', 'mednafen_psx', 'pcsx2'):
    chk(os.path.exists(os.path.join(t, f'usr/lib/libretro/{so}_libretro.so')), f'{so}_libretro.so shipped')
for b in (['usr/bin/ares'] if HAS_ARES else []) + ['usr/bin/sm2-emu', 'usr/bin/supermodel', 'usr/pcsx2x6/bin/pcsx2x6-qt']:
    chk(os.path.exists(os.path.join(t, b)), f'{b} shipped')
# Lindbergh: the launcher reads /usr/bin/linuxloader/*.ini, which on x86_64 only
# arrives via the prebuilt wine-x86 tarball (moving "44-dev" tag, never
# re-extracted on its own) — a stale extraction shipped the old /usr/bin/lindbergh
# layout and every Lindbergh launch died (2026-10-05). See my-docs/tools/check-wine-x86.sh.
if 'BR2_PACKAGE_LINUXLOADER=y' in CONF:
    chk(os.path.exists(os.path.join(t, 'usr/bin/linuxloader/linuxloader.ini')), 'usr/bin/linuxloader/linuxloader.ini shipped (wine-x86 not stale)')
print('FORK RESULT:', 'FAIL' if bad else 'OK'); sys.exit(1 if bad else 0)
