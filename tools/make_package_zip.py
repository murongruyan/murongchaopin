#!/usr/bin/env python3
# make_package_zip.py - deterministic ZIP builder for paid display packages.
# Supports optional symlink injection for negative tests.
#
# Usage: python3 make_package_zip.py <staging-dir> <out.zip> [--symlink <name> <target>]
import os
import sys
import zipfile

staging, out = sys.argv[1], sys.argv[2]
symlink = None
if len(sys.argv) >= 6 and sys.argv[3] == '--symlink':
    symlink = (sys.argv[4], sys.argv[5])

with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as archive:
    for root, dirs, files in os.walk(staging):
        for name in sorted(files):
            full = os.path.join(root, name)
            rel = os.path.relpath(full, staging).replace(os.sep, '/')
            archive.write(full, rel)
        for name in sorted(dirs):
            full = os.path.join(root, name)
            rel = os.path.relpath(full, staging).replace(os.sep, '/') + '/'
            archive.writestr(rel, b'')
    if symlink is not None:
        name, target = symlink
        info = zipfile.ZipInfo(name)
        info.create_system = 3
        info.external_attr = (0o120777 << 16)  # S_IFLNK | 0777
        archive.writestr(info, target)

print('zip written:', out)
