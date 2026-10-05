#!/usr/bin/env bash
#
# bootstrap.sh — развернуть NuGet-фид с нуля, БЕЗ оригинала.
#
# Отличие от deploy.sh: deploy.sh качает пакеты с боевого фида
# (nuget.qsupport.ru, закреплён на 91.216.147.7). bootstrap.sh берёт их
# из каталога packages/ этого же репозитория. Сети и оригинала не нужно.
#
# Когда пользоваться:
#   - оригинал на 91.216.147.7 выключен или больше недоступен;
#   - VPS переустановлен, данные потеряны;
#   - разворачиваете фид на новой машине с нуля.
#
# Что делает:
#   1. проверяет пакеты в packages/ по эталону (sha256)
#   2. поднимает контейнер BaGet
#   3. заливает пакеты в фид
#   4. прогоняет verify_migration.py
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
PACKAGE_DIR="${PACKAGE_DIR:-$PROJECT_DIR/packages}"
FEED_URL="${FEED_URL:-http://127.0.0.1:3022}"
# Ключ публикации из .env рядом с compose. Пусто = фид открыт для пуша.
# dotenv не всегда подгружается compose, читаем сами.
if [ -z "${BAGET_APIKEY:-}" ] && [ -f "$SCRIPT_DIR/.env" ]; then
    set -a; . "$SCRIPT_DIR/.env"; set +a
fi
NUPKG_KEY="${BAGET_APIKEY:-}"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.production.yml"
CONTAINER="nuget-baget"
ETALON="$SCRIPT_DIR/expected/manifest-629.json"

cd "$SCRIPT_DIR"

echo "🚀 Bootstrapping NuGet feed from packages/ (no origin needed)"
echo "   packages: $PACKAGE_DIR"
echo "   feed:     $FEED_URL"
echo

# ── Шаг 1. Проверить пакеты по эталону ДО запуска контейнера ────────────────
# Проверять надо до заливки: заливать битое и обнаруживать потом — значит
# оставить сломанный фид в проде до ручной диагностики.
echo "🔍 Step 1: Verifying packages against the etalon..."
if [ ! -f "$ETALON" ]; then
    echo "   ❌ эталон не найден: $ETALON"
    exit 1
fi
if [ ! -d "$PACKAGE_DIR" ]; then
    echo "   ❌ каталог пакетов не найден: $PACKAGE_DIR"
    echo "      В этом репозитории пакеты лежат в packages/ — проверьте, что"
    echo "      клонирование прошло целиком (git clone, а не git archive)."
    exit 1
fi

python3 - "$ETALON" "$PACKAGE_DIR" <<'EOF'
import hashlib, json, os, sys
etalon, pkgdir = sys.argv[1], sys.argv[2]
d = json.load(open(etalon))
missing, mismatch, corrupt = [], [], []
for key, v in d['versions'].items():
    p = os.path.join(pkgdir, v['file'])
    if not os.path.exists(p):
        missing.append(v['file']); continue
    if hashlib.sha256(open(p, 'rb').read()).hexdigest() != v['sha256']:
        mismatch.append(v['file'])
total = len(d['versions'])
print(f"   всего в эталоне: {total} | нет файла: {len(missing)} | хеш не совпал: {len(mismatch)}")
for f in missing[:5]:   print("   ✗ нет:", f)
for f in mismatch[:5]:  print("   ✗ хеш:", f)
if missing or mismatch:
    print("   Пакеты повреждены или недокачаны — НЕ поднимаем фид.")
    sys.exit(1)
print("   ✓ все пакеты совпадают с эталоном")
EOF

# ── Шаг 2. Поднять контейнер ────────────────────────────────────────────────
echo
echo "🐳 Step 2: Starting BaGet container..."
docker compose -f "$COMPOSE_FILE" up -d
echo "   ждём готовности фида..."
for i in $(seq 1 40); do
    if curl -sf -o /dev/null "$FEED_URL/v3/index.json"; then
        echo "   фид отвечает после ${i}s"
        break
    fi
    if [ "$i" -eq 40 ]; then
        echo "❌ Фид не поднялся за 40s. Логи:"
        docker compose -f "$COMPOSE_FILE" logs --tail 50
        exit 1
    fi
    sleep 1
done

# ── Шаг 3. Залить пакеты ───────────────────────────────────────────────────
echo
echo "📤 Step 3: Pushing packages..."
PUSHED=0
SKIPPED=0
# Идём ПО МАНИФЕСТУ, а не по файлам: путь в фиде берётся из URL, где id и
# версия уже разделены. Разбор имени файла не годится — идентификаторы NuGet
# содержат цифры (qp8.infrastucture распался бы на id='qp',
# ver='8.infrastucture.1.0.0'). Ассоциативный массив тоже не годится:
# declare -A требует bash 4, а на macOS /bin/bash — это 3.2, и скрипт падает
# уже в рантайме, тогда как bash -n проходит.
while IFS= read -r u; do
    [ -n "$u" ] || continue
    name="$(basename "$u")"
    path="${u#https://nuget.qsupport.ru}"
    f="$PACKAGE_DIR/$name"
    if [ ! -s "$f" ]; then
        echo "   ⚠️  нет файла, пропускаю: $name"
        continue
    fi
    # HEAD-ом: уже залитую версию не выгружаем заново.
    code=$(curl -s -o /dev/null -w '%{http_code}' -I --max-time 30 "$FEED_URL${path}")
    if [ "$code" = "200" ]; then SKIPPED=$((SKIPPED+1)); continue; fi
    if curl -sS -f --max-time 300 -X PUT -H "X-NuGet-ApiKey: $NUPKG_KEY" \
        -F "package=@$f" "$FEED_URL/api/v2/package" >/dev/null 2>&1; then
        PUSHED=$((PUSHED+1))
    else
        SKIPPED=$((SKIPPED+1))
    fi
    [ $(( (PUSHED+SKIPPED) % 50 )) -eq 0 ] && echo "   ... $((PUSHED+SKIPPED)) обработано"
done < "$SCRIPT_DIR/packages-11x.txt"
echo "   залито: $PUSHED, уже было: $SKIPPED"

# ── Шаг 4. Приёмка ──────────────────────────────────────────────────────────
echo
echo "✅ Step 4: Verifying the feed against the etalon..."
python3 "$SCRIPT_DIR/tools/verify_migration.py" --feed "$FEED_URL"
RC=$?

echo
if [ "$RC" -eq 0 ]; then
    echo "✅ Фид развёрнут с нуля и соответствует эталону."
    echo "   Оригинал на 91.216.147.7 больше не нужен."
    exit 0
else
    echo "❌ Приёмка не пройдена (код $RC). Фид не трогайте, разбирайтесь."
    exit "$RC"
fi
