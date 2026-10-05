#!/usr/bin/env python3
"""x86_64-focused and zen3-focused must differ ONLY in display stack
(Xorg vs labwc+XWayland). This checks that.

  verify-board-parity.py            board files + resolved .config (fast, no build needed)
  verify-board-parity.py --images   also compare built es_systems.cfg + shipped emulator libs

Exit 0 = parity holds. (Written 2026-09-19 after ares/MAME had silently drifted
onto the x86 board only.)"""
import os, re, sys, glob, xml.etree.ElementTree as ET
R = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
A, B = 'x86_64-focused', 'zen3-focused'
DISPLAY_BOARD_LINES = {'BR2_PACKAGE_BATOCERA_XORG=y', 'BR2_PACKAGE_BATOCERA_XWAYLAND=y', 'BR2_PACKAGE_BATOCERA_WAYLAND_LABWC=y'}
bad = []
def lines(t):
    return {l.strip() for l in open(f'{R}/configs/batocera-{t}.board') if l.strip() and not l.lstrip().startswith('#')}
d = (lines(A) ^ lines(B)) - DISPLAY_BOARD_LINES
print('board files: non-display differences ->', sorted(d) or 'none')
if d: bad.append('board files differ beyond display stack')

# resolved: any emulator-ish package difference is a failure; display-stack packages are expected
DISPLAY = re.compile(r'(XORG|X11|XAPP|XDRIVER|XFONT|XLIB|XSERVER|XDATA|XWAYLAND|WAYLAND|WLR|LABWC|SEAT|GRIM|SWAYBG|WTYPE|WF_RECORDER|LIBDECOR|LIBSFDO|LCMS2|OPENBOX|PICOM|UNCLUTTER|TOUCHEGG|MTDEV|MCOOKIE|LIBCONFIG|UTHASH|SWITCHRES|ONSCREEN_KEYBOARD|LIBINPUT|LIBXKBCOMMON|PYTHON_LIBEVDEV|GST1_PLUGINS_BASE_LIB_OPENGL_GLX|XINPUT)')
def pk(t):
    p = f'{R}/output/{t}/.config'
    return {l.split('=')[0] for l in open(p) if re.match(r'BR2_PACKAGE_[A-Z0-9_]+=y', l)} if os.path.exists(p) else None
pa, pb = pk(A), pk(B)
if pa is not None and pb is not None:
    diff = {s for s in pa ^ pb if not DISPLAY.search(s)}
    print('resolved .config: non-display package differences ->', sorted(diff) or 'none')
    if diff: bad.append('resolved package sets differ beyond display stack')
else:
    print('resolved .config: skipped (run <t>-config first)')

if '--images' in sys.argv:
    def cfg(t):
        r = ET.parse(f'{R}/output/{t}/target/usr/share/emulationstation/es_systems.cfg').getroot()
        return {s.findtext('name'): (sorted((s.findtext('extension') or '').split()),
                {(e.get('name'), c.text) for e in s.iter('emulator') for c in e.iter('core')}) for s in r.iter('system')}
    ca, cb = cfg(A), cfg(B)
    dd = []
    if set(ca) != set(cb): dd.append(f'systems only on one board: {sorted(set(ca) ^ set(cb))}')
    for n in sorted(set(ca) & set(cb)):
        if ca[n] != cb[n]: dd.append(f'{n}: ext/cores differ')
    print('es_systems.cfg:', dd or f'identical ({len(ca)} systems, same cores + extensions)')
    if dd: bad.append('es_systems.cfg differs')
    def libs(t):
        return {os.path.basename(p) for p in glob.glob(f'{R}/output/{t}/target/usr/lib/libretro/*.so')}, \
               {os.path.relpath(p, f'{R}/output/{t}/target') for p in glob.glob(f'{R}/output/{t}/target/usr/bin/*') if os.path.basename(p) in {'ares','mame','sm2-emu','supermodel','xemu','pcsx2-qt','rpcs3','dolphin-emu','duckstation-qt','flycast'}}
    (la, ba), (lb, bb) = libs(A), libs(B)
    print('libretro cores:', 'identical' if la == lb else f'differ: {sorted(la ^ lb)}')
    print('key emulator binaries:', 'identical' if ba == bb else f'differ: {sorted(ba ^ bb)}')
    if la != lb: bad.append('libretro core sets differ')
    if ba != bb: bad.append('emulator binaries differ')
print('PARITY:', 'FAIL - ' + '; '.join(bad) if bad else 'OK')
sys.exit(1 if bad else 0)
