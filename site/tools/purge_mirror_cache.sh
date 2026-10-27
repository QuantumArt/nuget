#!/usr/bin/env bash
#
# purge_mirror_cache.sh — освободить диск, вычистив кэш зеркала из тома BaGet.
#
# Контекст: том /root/nuget/baget-data разросся до десятков гигабайт. Причина —
# зеркало nuget.org: BaGet при каждом обращении к пакету, которого нет локально,
# скачивает его с nuget.org и индексирует ЛОКАЛЬНО (PackageService.MirrorAsync).
# То есть каждый уникальный публичный (id, version) навсегда остаётся на диске.
#
# Что делает:
#   1. берёт список 85 внутренних id (из packages-full.txt и манифеста);
#   2. находит в томе всё, чего в списке нет, — это кэш зеркала;
#   3. (--apply) удаляет эти каталоги;
#   4. (--apply-db) вычищает из SQLite записи кэша (Packages, PackageDependencies);
#   5. (--vacuum) сжимает файл БД после чистки.
#
# По умолчанию — ТОЛЬКО ОТЧЁТ, ничего не удаляется.
#
#   bash purge_mirror_cache.sh              # отчёт
#   bash purge_mirror_cache.sh --apply      # удалить файлы кэша
#   bash purge_mirror_cache.sh --apply-db   # + записи из БД
#   bash purge_mirror_cache.sh --apply-db --vacuum
#
set -euo pipefail

VOLUME="${VOLUME:-/root/nuget/baget-data}"
SITE="${SITE:-/root/nuget/site}"
STORE="$VOLUME/packages/packages"
DB="$VOLUME/baget.db"
MANIFEST="$SITE/expected/manifest-full.json"
URLS="$SITE/packages-full.txt"

APPLY=0
PRUNE_DB=0
VACUUM=0
for arg in "$@"; do
  case "$arg" in
    --apply)    APPLY=1 ;;
    --apply-db) APPLY=1; PRUNE_DB=1 ;;
    --vacuum)   VACUUM=1 ;;
    *) echo "Неизвестный аргумент: $arg (доступно: --apply, --apply-db, --vacuum)"; exit 2 ;;
  esac
done

[ -d "$STORE" ] || { echo "❌ каталог хранилища не найден: $STORE"; exit 1; }
[ -f "$URLS" ] || { echo "❌ список URL не найден: $URLS"; exit 1; }

echo "══════════════════════════════════════════════════════════════"
echo " Том:      $VOLUME"
echo " Хранилище: $STORE"
echo " Режим:    $([ "$APPLY" = 1 ] && echo 'ПРИМЕНЯТЬ' || echo 'только отчёт')"
echo "══════════════════════════════════════════════════════════════"
echo

# ── 1. Внутренние id ────────────────────────────────────────────────────────
# Источник: URL из packages-full.txt — там id стоит сразу после /package/.
# Второй источник: эталонный манифест. Если расходятся — стоп, дальше не идём.
KEEP=/tmp/nuget-keep-ids.txt
grep -o 'package/[^/]*' "$URLS" | sed 's|^package/||' | tr 'A-Z' 'a-z' | sort -u > "$KEEP"
echo "   внутренних id из $URLS: $(wc -l < "$KEEP" | tr -d ' ')"

if [ -f "$MANIFEST" ]; then
  python3 - "$MANIFEST" /tmp/nuget-manifest-ids.txt <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
ids = sorted({str(i).lower() for i in m['packages']})
open(sys.argv[2], 'w').write('\n'.join(ids) + '\n')
print(f"   внутренних id из манифеста: {len(ids)}")
PY
  if diff -q "$KEEP" /tmp/nuget-manifest-ids.txt >/dev/null 2>&1; then
    echo "   ✓ оба источника совпадают"
  else
    echo "   ⚠️  источники РАСХОДЯТСЯ — проверь вручную:"
    diff "$KEEP" /tmp/nuget-manifest-ids.txt | head -20
    echo "   Продолжаем по объединению (безопаснее — больше id в whitelist)."
    cat "$KEEP" /tmp/nuget-manifest-ids.txt | sort -u > "$KEEP.tmp" && mv "$KEEP.tmp" "$KEEP"
  fi
fi
echo

# ── 2. Что и сколько занимает ──────────────────────────────────────────────
echo "─── Том, верхний уровень ───"
du -sh "$VOLUME"/* 2>/dev/null | sort -h
echo
echo "─── Файлы БД ───"
ls -la "$DB"* 2>/dev/null || echo "(нет файла БД)"
echo

# ── 3. Каталоги-кэша зеркала ────────────────────────────────────────────────
MIRROR=/tmp/nuget-mirror-ids.txt
: > "$MIRROR"
while IFS= read -r d; do
  name="$(basename "$d")"
  [ -n "$name" ] || continue
  grep -qx -- "$name" "$KEEP" || echo "$name" >> "$MIRROR"
done < <(find "$STORE" -mindepth 1 -maxdepth 1 -type d | sort)

MIRROR_COUNT=$(grep -c . "$MIRROR" || true)
KEEP_COUNT=$(grep -c . "$KEEP" || true)
TOTAL_DIRS=$(find "$STORE" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
echo "─── Хранилище пакетов ───"
echo "   каталогов всего:            $TOTAL_DIRS"
echo "   наших (в whitelist):        $KEEP_COUNT"
echo "   кэш зеркала (кандидаты):    $MIRROR_COUNT"
echo

if [ "$MIRROR_COUNT" -gt 0 ]; then
  echo "─── Кэш зеркала: топ-20 по размеру ───"
  : > /tmp/nuget-mirror-size.txt
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    s=$(du -sm "$STORE/$id" 2>/dev/null | cut -f1)
    echo "${s:-0}	$id"
  done < "$MIRROR" | sort -n > /tmp/nuget-mirror-size.txt
  tail -20 /tmp/nuget-mirror-size.txt | awk -F'\t' '{printf "   %6s МБ  %s\n", $1, $2}'
  echo
  MIRROR_MB=$(awk -F'\t' '{s+=$1} END {print s+0}' /tmp/nuget-mirror-size.txt)
  echo "─── ИТОГО кэш зеркала: ${MIRROR_MB} МБ ($(awk -v m="$MIRROR_MB" 'BEGIN{printf "%.1f", m/1024}') ГБ) ───"
fi
echo

# ── 4. Состояние БД ─────────────────────────────────────────────────────────
if [ -f "$DB" ]; then
  echo "─── SQLite: таблицы и размеры ───"
  python3 - "$DB" "$MIRROR" <<'PY'
import os, sqlite3, sys
db, mirror = sys.argv[1], sys.argv[2]
bad = {l.strip().lower() for l in open(mirror) if l.strip()}
print(f"   размер файла БД: {os.path.getsize(db)/1048576:.1f} МБ")
con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
for t in [r[0] for r in con.execute("select name from sqlite_master where type='table' order by name")]:
    cols = [r[1] for r in con.execute(f'pragma table_info("{t}")')]
    n = con.execute(f'select count(*) from "{t}"').fetchone()[0]
    extra = ""
    if 'id' in cols and bad:
        ph = ",".join("?" * len(bad))
        hits = con.execute(f'select count(*) from "{t}" where lower(id) in ({ph})', tuple(bad)).fetchone()[0]
        extra = f", из них кэш зеркала {hits}"
    print(f"   {t}: {n} строк{extra}")
con.close()
PY
  echo
fi

if [ "$APPLY" = 0 ]; then
  echo "Это был ОТЧЁТ. Ничего не изменено."
  echo "Удалить кэш:      bash purge_mirror_cache.sh --apply"
  echo "Удалить + БД:     bash purge_mirror_cache.sh --apply-db"
  exit 0
fi

# ── 5. Удаление файлов кэша ────────────────────────────────────────────────
echo "════════ УДАЛЕНИЕ кэша зеркала ════════"
echo "Удаляются ТОЛЬКО каталоги вне whitelist (наши $KEEP_COUNT пакетов не трогаем)."
echo
read -r -p "Удалить файлы кэша? (yes/NO): " ans
[ "$ans" = "yes" ] || { echo "Отменено."; exit 1; }

DELETED=0
while IFS= read -r id; do
  [ -n "$id" ] || continue
  rm -rf -- "${STORE:?}/$id"
  DELETED=$((DELETED+1))
  if [ $((DELETED % 500)) -eq 0 ]; then echo "   ... удалено $DELETED"; fi
done < "$MIRROR"
echo "   удалено каталогов: $DELETED"
echo

# ── 6. Чистка БД ────────────────────────────────────────────────────────────
if [ "$PRUNE_DB" = 1 ] && [ -f "$DB" ]; then
  echo "════════ Чистка записей SQLite ════════"
  read -r -p "Вычистить из БД записи кэша зеркала? (yes/NO): " ans2
  if [ "$ans2" = "yes" ]; then
    python3 - "$DB" "$MIRROR" <<'PY'
import sqlite3, sys
db, mirror = sys.argv[1], sys.argv[2]
bad = {l.strip().lower() for l in open(mirror) if l.strip()}
if not bad:
    print("   нечего чистить"); raise SystemExit
con = sqlite3.connect(db)
con.execute("pragma foreign_keys=on")
ph = ",".join("?" * len(bad))
for t in [r[0] for r in con.execute("select name from sqlite_master where type='table'")]:
    cols = [r[1] for r in con.execute(f'pragma table_info("{t}")')]
    if 'id' not in cols:
        continue
    cur = con.execute(f'delete from "{t}" where lower(id) in ({ph})', tuple(bad))
    if cur.rowcount:
        print(f"   {t}: удалено {cur.rowcount}")
con.commit()
con.close()
print("   БД сохранена")
PY
  else
    echo "   пропущено"
  fi
  echo
fi

# ── 7. VACUUM ───────────────────────────────────────────────────────────────
if [ "$VACUUM" = 1 ] && [ -f "$DB" ]; then
  echo "════════ Сжатие БД (VACUUM) ════════"
  echo "Нужно свободное место, равное размеру БД. Если не хватит — будет ошибка,"
  echo "тогда переходите к пересозданию БД (см. ответ)."
  read -r -p "Сжать БД? (yes/NO): " ans3
  if [ "$ans3" = "yes" ]; then
    python3 - "$DB" <<'PY'
import os, sqlite3, sys
db = sys.argv[1]
before = os.path.getsize(db)/1048576
con = sqlite3.connect(db)
con.execute("pragma journal_mode=DELETE")
con.execute("vacuum")
con.close()
after = os.path.getsize(db)/1048576
print(f"   БД: {before:.1f} МБ → {after:.1f} МБ")
PY
  else
    echo "   пропущено"
  fi
  echo
fi

echo "════════ Готово ════════"
df -h / | tail -1
du -sh "$VOLUME" 2>/dev/null
echo
echo "Проверка фида:"
echo "  curl -s -o /dev/null -w '%{http_code}\\n' https://nuget.qsupport.ru/v3/package/qa.dotnetcore.caching/3.1.8/qa.dotnetcore.caching.3.1.8.nupkg"
echo "  python3 $SITE/tools/verify_migration.py --feed http://127.0.0.1:3022"
