#!/usr/bin/env bash
#
# purge_mirror_cache.sh — освободить диск и почистить базу от кэша зеркала
# (публичных пакетов), НЕ трогая наши 85 внутренних пакетов.
#
# Контекст: том /root/nuget/baget-data разросся до 54 ГБ. Причина — зеркало
# nuget.org: BaGet при каждом обращении к пакету, которого нет локально,
# скачивает его с nuget.org и индексирует ЛОКАЛЬНО (PackageService.MirrorAsync).
# То есть каждый уникальный публичный (id, version) навсегда остаётся на диске.
# Зеркало выключено 2026-10-27 — см. DEPLOY.md.
#
# Что делает:
#   1. берёт список 85 внутренних id (packages-full.txt + сверка с манифестом);
#   2. находит КЭШ ЗЕРКАЛА — объединение двух множеств:
#        а) каталоги в томе, которых нет в списке;
#        б) id в базе (Packages/PackageDependencies), которых нет в списке —
#           это ПРИЗРАКИ: строки остались, а файлов уже нет. По каталогам их
#           не видно, поэтому без (б) они оставались в базе и отдавали 500
#           (строка есть → BaGet ищет файл → File.Open бросает исключение);
#   3. (--apply) удаляет каталоги кэша;
#   4. (--apply-db) вычищает из SQLite записи кэша;
#   5. (--vacuum) сжимает файл БД.
#
# По умолчанию — ТОЛЬКО ОТЧЁТ, ничего не удаляется.
#
#   bash purge_mirror_cache.sh                 # отчёт
#   bash purge_mirror_cache.sh --apply         # удалить файлы кэша
#   bash purge_mirror_cache.sh --apply-db      # + записи из БД
#   bash purge_mirror_cache.sh --apply-db --vacuum
#   bash purge_mirror_cache.sh --apply-db --vacuum --yes   # без вопросов
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
ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --apply)    APPLY=1 ;;
    --apply-db) APPLY=1; PRUNE_DB=1 ;;
    --vacuum)   VACUUM=1 ;;
    --yes|-y)   ASSUME_YES=1 ;;
    *) echo "Неизвестный аргумент: $arg (доступно: --apply, --apply-db, --vacuum, --yes)"; exit 2 ;;
  esac
done

[ -d "$STORE" ] || { echo "❌ каталог хранилища не найден: $STORE"; exit 1; }
[ -f "$URLS" ] || { echo "❌ список URL не найден: $URLS"; exit 1; }

# ── Подтверждение ───────────────────────────────────────────────────────────
# Ответ читаем так, чтобы пережил вставку из буфера обмена: у текста,
# скопированного откуда-то, часто остаётся \r (CRLF) и пробелы. Раньше
# "yes\r" не равнялось "yes" и скрипт тихо отменял удаление.
# Если stdin не терминал (скрипт вставлен в конвейер) — вопрос задавать
# некому, поэтому без --yes отменяем.
confirm() {
    local prompt="$1" ans=""
    echo "$prompt"
    if [ ! -t 0 ]; then
        echo "   stdin не терминал: для запуска без вопроса добавь --yes"
        return 1
    fi
    printf '%s ' "$prompt (yes/NO): "
    IFS= read -r ans || true
    ans="${ans//$'\r'/}"
    ans="$(printf '%s' "$ans" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
    [ "$ans" = "yes" ]
}

echo "══════════════════════════════════════════════════════════════"
echo " Том:      $VOLUME"
echo " Хранилище: $STORE"
echo " Режим:    $([ "$APPLY" = 1 ] && echo 'ПРИМЕНЯТЬ' || echo 'только отчёт')"
echo "══════════════════════════════════════════════════════════════"
echo

# ── 1. Внутренние id ────────────────────────────────────────────────────────
# Источник: URL из packages-full.txt — там id стоит сразу после /package/.
# Второй источник: эталонный манифест. Если расходятся — берём объединение.
KEEP=/tmp/nuget-keep-ids.txt
grep -o 'package/[^/]*' "$URLS" | sed 's|^package/||' | tr 'A-Z' 'a-z' | sort -u > "$KEEP"
echo "   внутренних id из $URLS: $(grep -c . "$KEEP" || true)"

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
    echo "   ⚠️  источники РАСХОДЯТСЯ — берём объединение (безопаснее)"
    cat "$KEEP" /tmp/nuget-manifest-ids.txt | sort -u > "$KEEP.tmp" && mv "$KEEP.tmp" "$KEEP"
  fi
fi
KEEP_COUNT=$(grep -c . "$KEEP" || true)
echo

# ── 2. Что и сколько занимает ──────────────────────────────────────────────
echo "─── Том, верхний уровень ───"
du -sh "$VOLUME"/* 2>/dev/null | sort -h
echo
echo "─── Файлы БД ───"
ls -la "$DB"* 2>/dev/null || echo "(нет файла БД)"
echo

# ── 3. Кэш зеркала: каталоги на диске ───────────────────────────────────────
MIRROR=/tmp/nuget-mirror-ids.txt
: > "$MIRROR"
while IFS= read -r d; do
  name="$(basename "$d")"
  [ -n "$name" ] || continue
  grep -qx -- "$name" "$KEEP" || echo "$name" >> "$MIRROR"
done < <(find "$STORE" -mindepth 1 -maxdepth 1 -type d | sort)

DIR_COUNT=$(grep -c . "$MIRROR" || true)
TOTAL_DIRS=$(find "$STORE" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
echo "─── Хранилище пакетов ───"
echo "   каталогов всего:         $TOTAL_DIRS"
echo "   наших (в whitelist):     $KEEP_COUNT"
echo "   кэш зеркала (каталоги):  $DIR_COUNT"
echo

# ── 4. Кэш зеркала: призраки в базе ─────────────────────────────────────────
# id, которых нет в whitelist, но которые остались строками в базе: файлов
# по ним уже нет, а строки есть. По каталогам они не видны.
PHANTOM=/tmp/nuget-phantom-ids.txt
: > "$PHANTOM"
if [ -f "$DB" ]; then
  python3 - "$DB" "$KEEP" "$PHANTOM" <<'PY'
import sqlite3, sys
db, keep_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
keep = {l.strip().lower() for l in open(keep_path) if l.strip()}
ids = set()
try:
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    for t in [r[0] for r in con.execute("select name from sqlite_master where type='table'")]:
        cols = [r[1] for r in con.execute(f'pragma table_info("{t}")')]
        # Имя колонки в базе — "Id" (с заглавной), поэтому ищем без учёта
        # регистра. Раньше проверка 'id' не в cols проходила мимо всех
        # таблиц, и записи из базы не удалялись ВООБЩЕ.
        colmap = {c.lower(): c for c in cols}
        if 'id' not in colmap:
            continue
        ids |= {(r[0] or '').lower() for r in con.execute(f'select distinct "{colmap["id"]}" from "{t}"')}
    con.close()
except Exception as e:
    print(f"   ⚠️ не удалось прочитать БД: {e}")
with open(out_path, 'w') as f:
    for i in sorted(x for x in ids if x and x not in keep):
        f.write(i + "\n")
print(f"   id в базе вне whitelist (призраки): {len([x for x in ids if x and x.lower() not in keep])}")
PY
  # призраки добавляем к общему списку кэша
  cat "$PHANTOM" >> "$MIRROR"
  sort -u "$MIRROR" -o "$MIRROR"
fi
MIRROR_COUNT=$(grep -c . "$MIRROR" || true)
PHANTOM_COUNT=$(grep -c . "$PHANTOM" || true)
echo "   всего к удалению (каталоги + призраки): $MIRROR_COUNT"
echo

if [ "$DIR_COUNT" -gt 0 ]; then
  echo "─── Кэш зеркала на диске: топ-20 по размеру ───"
  : > /tmp/nuget-mirror-size.txt
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    [ -d "$STORE/$id" ] || continue
    s=$(du -sm "$STORE/$id" 2>/dev/null | cut -f1)
    echo "${s:-0}	$id"
  done < "$MIRROR" | sort -n > /tmp/nuget-mirror-size.txt
  tail -20 /tmp/nuget-mirror-size.txt | awk -F'\t' '{printf "   %6s МБ  %s\n", $1, $2}'
  MIRROR_MB=$(awk -F'\t' '{s+=$1} END {print s+0}' /tmp/nuget-mirror-size.txt)
  echo "   ИТОГО на диске: ${MIRROR_MB} МБ"
  echo
fi

if [ "$PHANTOM_COUNT" -gt 0 ]; then
  echo "─── Призраки в базе (строки без файлов), первые 20 ───"
  head -20 "$PHANTOM" | sed 's/^/   /'
  echo "   ... всего $PHANTOM_COUNT"
  echo
fi

# ── 5. Состояние БД ─────────────────────────────────────────────────────────
if [ -f "$DB" ]; then
  echo "─── SQLite: таблицы и размеры ───"
  python3 - "$DB" <<'PY'
import os, sqlite3, sys
db = sys.argv[1]
print(f"   размер файла БД: {os.path.getsize(db)/1048576:.1f} МБ")
con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
for t in [r[0] for r in con.execute("select name from sqlite_master where type='table' order by name")]:
    n = con.execute(f'select count(*) from "{t}"').fetchone()[0]
    print(f"   {t}: {n} строк")
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

# ── 6. Удаление каталогов ───────────────────────────────────────────────────
echo "════════ УДАЛЕНИЕ кэша зеркала ════════"
echo "Удаляются ТОЛЬКО id вне whitelist (наши $KEEP_COUNT пакетов не трогаем)."
echo
if [ "$ASSUME_YES" = 1 ] || confirm "Удалить файлы кэша?"; then
  DELETED=0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    [ -d "$STORE/$id" ] || continue
    rm -rf -- "${STORE:?}/$id"
    DELETED=$((DELETED+1))
    if [ $((DELETED % 500)) -eq 0 ]; then echo "   ... удалено $DELETED"; fi
  done < "$MIRROR"
  echo "   удалено каталогов: $DELETED"
else
  echo "   отменено"
  exit 1
fi
echo

# ── 7. Чистка БД ────────────────────────────────────────────────────────────
if [ "$PRUNE_DB" = 1 ] && [ -f "$DB" ]; then
  echo "════════ Чистка записей SQLite ════════"
  if [ "$ASSUME_YES" = 1 ] || confirm "Вычистить из БД записи кэша зеркала?"; then
    python3 - "$DB" "$MIRROR" <<'PY'
import sqlite3, sys
db, mirror = sys.argv[1], sys.argv[2]
bad = {l.strip().lower() for l in open(mirror) if l.strip()}
if not bad:
    print("   нечего чистить"); raise SystemExit

con = sqlite3.connect(db)
# Проверку внешних ключей выключаем на время правки: порядок удаления
# родителей и детей задаём сами (ниже), а SQLite по умолчанию не даёт
# удалить Packages, пока на него ссылаются PackageTypes /
# TargetFrameworks / PackageDependencies.
con.execute("pragma foreign_keys=off")
ph = ",".join("?" * len(bad))

def cols(t):
    return {c.lower(): c for c in [r[1] for r in con.execute(f'pragma table_info("{t}")')]}

def tables():
    return [r[0] for r in con.execute(
        "select name from sqlite_master where type='table' and name not like 'sqlite_%'")]

pk_cols = cols("Packages")
id_col = pk_cols.get("id")
key_col = pk_cols.get("key", "Key")
if not id_col:
    print("   ❌ в Packages нет колонки Id — прерываюсь"); raise SystemExit(1)

keys = [r[0] for r in con.execute(
    f'select "{key_col}" from "Packages" where lower("{id_col}") in ({ph})', tuple(bad))]
print(f"   удаляем записей пакетов: {len(keys)}")
pk_ph = ",".join("?" * len(keys)) if keys else "NULL"

# ── Дети: удаляем по внешнему ключу на Packages ─────────────────────────────
for t in tables():
    if t == "Packages":
        continue
    c = cols(t)
    for fk in con.execute(f'pragma foreign_key_list("{t}")'):
        parent, child_col, parent_col = fk[2], fk[3], fk[4]
        if parent != "Packages" or child_col.lower() not in c:
            continue
        cur = con.execute(
            f'delete from "{t}" where "{c[child_col.lower()]}" in ({pk_ph})', tuple(keys))
        if cur.rowcount:
            print(f'   {t} (fk {child_col} -> {parent}.{parent_col}): удалено {cur.rowcount}')

# ── Родители ────────────────────────────────────────────────────────────────
cur = con.execute(f'delete from "Packages" where lower("{id_col}") in ({ph})', tuple(bad))
print(f'   Packages: удалено {cur.rowcount}')

# ── Сироты: строки детей, чей родитель уже не существует ──────────────────
for t in tables():
    if t == "Packages":
        continue
    c = cols(t)
    for fk in con.execute(f'pragma foreign_key_list("{t}")'):
        parent, child_col = fk[2], fk[3]
        if parent != "Packages" or child_col.lower() not in c:
            continue
        cur = con.execute(
            f'delete from "{t}" where "{c[child_col.lower()]}" is null or '
            f'"{c[child_col.lower()]}" not in (select "{key_col}" from "Packages")')
        if cur.rowcount:
            print(f'   {t}: удалено сирот {cur.rowcount}')

con.commit()
con.execute("pragma foreign_keys=on")
viol = list(con.execute("pragma foreign_key_check"))
print(f"   проверка внешних ключей: нарушений {len(viol)}")
if viol:
    for v in viol[:5]:
        print("   ⚠️", v)
con.close()
print("   БД сохранена")
PY
  else
    echo "   отменено"
  fi
  echo
fi

# ── 8. VACUUM ───────────────────────────────────────────────────────────────
if [ "$VACUUM" = 1 ] && [ -f "$DB" ]; then
  echo "════════ Сжатие БД (VACUUM) ════════"
  echo "Нужно свободное место, примерно равное размеру БД."
  if [ "$ASSUME_YES" = 1 ] || confirm "Сжать БД?"; then
    python3 - "$DB" <<'PY'
import os, sqlite3, sys
db = sys.argv[1]
before = os.path.getsize(db)/1048576
con = sqlite3.connect(db)
con.execute("pragma journal_mode=DELETE")
con.execute("vacuum")
con.close()
after = os.path.getsize(db)/1048576
print(f"   БД: {before:.1f} МБ -> {after:.1f} МБ")
PY
  else
    echo "   отменено"
  fi
  echo
fi

echo "════════ Готово ════════"
df -h / | tail -1
du -sh "$VOLUME" 2>/dev/null
echo
echo "Проверь фид:"
echo "  curl -s -o /dev/null -w '%{http_code}\\n' https://nuget.qsupport.ru/v3/package/qa.dotnetcore.caching/3.1.8/qa.dotnetcore.caching.3.1.8.nupkg"
echo "  python3 $SITE/tools/verify_migration.py --feed http://127.0.0.1:3022"
