#!/usr/bin/env python3
"""List the Material icons a commit adds that the previous commit did not use.

Shorebird refuses to patch when the icon font changes, because the font is an
ASSET and assets are not carried in a code patch. A newly reachable screen that
renders an icon glyph the shipped font does not contain therefore blocks every
patch until either:

  * the new icon is swapped for one already in the shipped font, or
  * a new release ships the new font.

The fix is mechanical, so the diagnosis should be too. This resolves
`Icons.foo` to its real codepoint using the Flutter SDK's own icon table and
prints the delta, so the swap list can be worked through without guessing.

Usage: icon_usage_diff.py <sdk>/packages/flutter/lib/src/material/icons.dart
"""
import re
import subprocess
import sys

ICONS_DART = sys.argv[1]

# icons.dart declares `static const IconData foo = IconData(0xf0000, ...);`
DECL = re.compile(
    r'static const IconData (\w+)\s*=\s*IconData\(\s*(0x[0-9a-fA-F]+)',
)

table = {}
with open(ICONS_DART, encoding='utf-8', errors='ignore') as fh:
    for line in fh:
        m = DECL.search(line)
        if m:
            table[m.group(1)] = int(m.group(2), 16)

print('SDK icon table entries:', len(table))


def icons_in(ref):
    """Every Icons.<name> reachable from lib/ at <ref>."""
    files = subprocess.run(
        ['git', 'ls-tree', '-r', '--name-only', ref, 'lib/'],
        capture_output=True, text=True, check=True,
    ).stdout.split()
    names = set()
    for path in files:
        if not path.endswith('.dart'):
            continue
        blob = subprocess.run(
            ['git', 'show', '%s:%s' % (ref, path)],
            capture_output=True, text=True,
        ).stdout
        names.update(re.findall(r'\bIcons\.(\w+)', blob))
    return names


head = icons_in('HEAD')
prev = icons_in('HEAD~1')
added = sorted(head - prev)
print('icons at HEAD  :', len(head))
print('icons at HEAD~1:', len(prev))
print('ADDED (%d):' % len(added))
for name in added:
    cp = table.get(name)
    print('  %-28s %s' % (name, hex(cp) if cp is not None else 'NOT IN SDK TABLE'))

if '--available' in sys.argv:
    print()
    print('ALREADY IN THE SHIPPED FONT (%d) - safe substitutes:' % len(prev))
    for name in sorted(prev):
        print('  %s' % name)
