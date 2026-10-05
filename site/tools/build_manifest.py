#!/usr/bin/env python3
"""
build_manifest.py — собрать эталон миграции из локально скачанных nupkg.

Эталон (`site/expected/manifest-629.json`) — это контракт приёмки деплоя:
список пакетов и sha256 каждой версии. `verify_migration.py` сверяет живой
клон с ним.

КРИТИЧНО, проверка целостности тут строгая и только внешним unzip:

    python zipfile на файл с мусором ВНУТРИ архива отвечает testzip() == None
    и считает его годным. unzip -t такой файл отвергает кодом 1.

Первая версия этого скрипта доверяла python zipfile, и в эталон попал
испорченный seleniumextension.1.0.12 (8 388 239 лишних байт внутри архива,
после двух параллельных curl в один файл). Эталон разошёлся с клоном, хотя
клон был прав. Именно этот случай и заставил проверку ужесточить.

Использование:
    python3 site/tools/build_manifest.py \\
        --packages site/packages-11x.txt \\
        --nupkgs nupkgs \\
        --out site/expected/manifest-629.json
"""

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys

URL_RE = re.compile(
    r'https://nuget\.qsupport\.ru/v3/package/([^/]+)/([^/]+)/([^/]+)\.nupkg$')


def strict_zip_ok(path):
    """Годен ли архив. Только unzip: python zipfile слишком доверчив."""
    try:
        r = subprocess.run(['unzip', '-tqq', path],
                           stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL,
                           timeout=300)
        return r.returncode == 0
    except FileNotFoundError:
        sys.stderr.write("unzip не найден — строгую проверку выполнить нельзя.\n")
        sys.exit(2)


def parse_filename(stem):
    """<id>.<version>.nupkg -> (id, version). Версия начинается с первого
    сегмента, начинающегося с цифры; идентификаторы содержат точки."""
    parts = stem.split('.')
    for i, seg in enumerate(parts):
        if seg and seg[0].isdigit():
            return '.'.join(parts[:i]).lower(), '.'.join(parts[i:]).lower()
    return None, None


def main():
    ap = argparse.ArgumentParser()
    here = os.path.dirname(os.path.abspath(__file__))
    site_dir = os.path.dirname(here)
    ap.add_argument('--packages', default=os.path.join(site_dir, 'packages-11x.txt'))
    ap.add_argument('--nupkgs', default=os.path.join(site_dir, '..', 'nupkgs'))
    ap.add_argument('--out', default=os.path.join(site_dir, 'expected', 'manifest-629.json'))
    args = ap.parse_args()

    expected = {}
    for line in open(args.packages):
        u = line.strip()
        if not u:
            continue
        m = URL_RE.match(u)
        if m:
            expected[(m.group(1).lower(), m.group(2).lower())] = os.path.basename(u)
    print(f'ожидается по манифесту: {len(expected)} версий')

    records, corrupt = {}, []
    for name in sorted(os.listdir(args.nupkgs)):
        if not name.endswith('.nupkg'):
            continue
        path = os.path.join(args.nupkgs, name)
        pid, ver = parse_filename(name[:-len('.nupkg')])
        if pid is None:
            corrupt.append((name, 'не разобрано имя файла'))
            continue
        if not strict_zip_ok(path):
            corrupt.append((name, 'unzip -t отверг архив'))
            continue
        data = open(path, 'rb').read()
        records[(pid, ver)] = {
            'id': pid, 'version': ver, 'file': name,
            'sha256': hashlib.sha256(data).hexdigest(),
            'size': len(data),
        }

    print(f'годных файлов: {len(records)} | отвергнуто: {len(corrupt)}')
    for n, why in corrupt:
        print(f'  ✗ {n} — {why}')

    missing = sorted(set(expected) - set(records))
    extra = sorted(set(records) - set(expected))
    if missing:
        print(f'✗ есть в манифесте, но нет файла: {len(missing)} {missing[:5]}')
    if extra:
        print(f'✗ есть файл, но нет в манифесте: {len(extra)} {extra[:5]}')

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, 'w') as f:
        json.dump({
            'count': len(records),
            'packages': sorted({r['id'] for r in records.values()}),
            'versions': {
                f"{r['id']}/{r['version']}": {
                    'sha256': r['sha256'], 'size': r['size'], 'file': r['file'],
                } for r in records.values()
            },
        }, f, indent=1, sort_keys=True)
    print(f'записано: {args.out}')

    # Эталон, в котором есть битые версии, опаснее отсутствующего:
    # проверка потом будет сравнивать клон с заведомо неверным значением.
    return 1 if (corrupt or missing or extra) else 0


if __name__ == '__main__':
    sys.exit(main())
