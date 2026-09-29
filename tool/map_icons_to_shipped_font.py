#!/usr/bin/env python3
"""Swap newly-introduced Material icons for equivalents already in the font.

Shorebird cannot ship an asset change in a patch, and the MaterialIcons font is
an asset. So rendering an icon glyph the shipped font lacks blocks the patch.
The remedy is mechanical: use an icon that is already present.

Each mapping below is chosen for MEANING first, so the screen still reads
correctly. Where a rounded/outlined variant of the same glyph already exists in
the font, that variant is used, so the change is nearly invisible.

Run from the repo root:  python3 tool/map_icons_to_shipped_font.py
Then verify with:        python3 tool/icon_usage_diff.py <sdk icons.dart>
"""
import pathlib
import re

# new icon -> equivalent already present in the shipped 1.1.0+9 font
MAP = {
    'archive_outlined': 'storefront_outlined',        # archived / stored
    'article_outlined': 'description_outlined',       # a text document
    'checklist': 'done_all_rounded',                  # completed items
    'edit_note': 'event_note_outlined',              # a draft note
    'expand_less': 'keyboard_double_arrow_up_rounded',  # collapse
    'folder_outlined': 'folder_zip_outlined',         # a folder
    'history': 'timelapse',                           # recent / past
    'mic': 'graphic_eq',                              # live audio meter
    'mic_none': 'mic_none_rounded',                   # rounded variant
    'pause': 'pause_rounded',                         # rounded variant
    'pause_circle_filled': 'pause_circle_outline',    # same glyph
    'people_outline': 'groups_outlined',              # a group of people
    'place_outlined': 'location_on',                  # a map pin
    'play_arrow': 'play_arrow_rounded',               # rounded variant
    'replay': 'refresh',                              # run again
    'stop': 'stop_rounded',                           # rounded variant
    'stop_circle_outlined': 'cancel_outlined',        # halt
    'today': 'today_outlined',                        # outlined variant
    'upcoming': 'event',                              # a scheduled event
}

changed = 0
for path in sorted(pathlib.Path('lib/features/imeet').rglob('*.dart')):
    original = path.read_text()
    updated = original
    for old, new in MAP.items():
        updated = re.sub(r'\bIcons\.%s\b' % re.escape(old), 'Icons.%s' % new, updated)
    if updated != original:
        path.write_text(updated)
        changed += 1
        print('updated %s' % path)

print('files changed: %d' % changed)

# Fail loudly rather than leaving a silent blocker for the next patch attempt.
remaining = set()
for path in pathlib.Path('lib').rglob('*.dart'):
    remaining.update(re.findall(r'\bIcons\.(\w+)', path.read_text()))
leftover = sorted(set(MAP) & remaining)
if leftover:
    raise SystemExit('STILL PRESENT, patch would be blocked: %s' % leftover)
print('verified: none of the newly-introduced icons remain')
