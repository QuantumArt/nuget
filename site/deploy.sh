#!/usr/bin/env bash
#
# Деплой локального клона NuGet-фида (BaGet) на VPS timeweb.
#
# Что делает:
#   1. стягивает сам себя из GitHub (с обходом глобального credential store)
#   2. поднимает контейнер BaGet
#   3. скачивает nupkg-файлы с ИСХОДНОГО фида и заливает их в клон
#   4. проверяет, что фид отвечает
#
# ВАЖНО, про DNS и почему скрипт не зациклится сам на себе:
#   Домен nuget.qsupport.ru — боевой. После переключения A-записи на этот VPS
#   он начнёт указывать на КЛОН, и наивный загрузчик скачал бы пакеты у самого
#   себя. Поэтому источник адресуется не по домену, а через
#   `curl --resolve <хост>:443:<IP оригинала>`: имя и SNI остаются настоящими
#   (сертификат валиден, TLS-сверка проходит), а адрес — закреплён за
#   оригиналом 91.216.147.7. Поэтому deploy.sh безопасно запускать и ДО, и
#   ПОСЛЕ переключения DNS.
#
#   Почему нельзя просто обратиться к оригиналю по IP: его сертификат покрывает
#   ровно один SAN — nuget.qsupport.ru. Алиаса с валидным сертификатом на
#   91.216.147.7 нет: cluster.quantumart.ru отдаёт сертификат другого сервиса
#   (smart-widget.qsupport.ru) и NuGet API не отдаёт. Поэтому --resolve,
#   а не подмена хоста.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Источник .nupkg: имя для SNI + закреплённый IP оригинала. Именно эта пара
# делает скрипт идемпотентным относительно переключения DNS — см. шапку файла.
ORIGIN_HOST="${ORIGIN_HOST:-nuget.qsupport.ru}"
ORIGIN_IP="${ORIGIN_IP:-91.216.147.7}"
PACKAGE_LIST="${PACKAGE_LIST:-$SCRIPT_DIR/packages-11x.txt}"
FEED_URL="${FEED_URL:-http://127.0.0.1:3022}"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.production.yml"
NUPKG_DIR="$PROJECT_DIR/nupkgs"
CONTAINER="nuget-baget"

cd "$SCRIPT_DIR"

echo "🚀 Starting NuGet feed deploy..."
echo "   origin: $ORIGIN_HOST (pinned to $ORIGIN_IP)"
echo "   package list: $(basename "$PACKAGE_LIST") ($(wc -l < "$PACKAGE_LIST") версий)"
echo

# ── Шаг 1. Обновить код из репозитория ───────────────────────────────────────
# На этом VPS в /root/.gitconfig живёт credential.helper=store с токеном,
# созданным под ДРУГОЙ репозиторий. Git берёт первый ответивший helper, поэтому
# store перебивает локальный и приватный репозиторий получает 403.
# Лечится выбросом глобального конфига. Общий /root/.git-credentials НЕ трогаем —
# он обслуживает другие проекты на сервере.
if [ -z "${GH_TOKEN:-}" ]; then
    CREDS_FILE="$PROJECT_DIR/.credentials.env"
    if [ -f "$CREDS_FILE" ]; then
        set -a; . "$CREDS_FILE"; set +a
    fi
fi

if git rev-parse --git-dir >/dev/null 2>&1; then
    echo "📥 Step 1: Pulling latest changes..."
    # Репозиторий публичный, поэтому токен не обязателен. Но глобальный
    # credential.helper=store на этом VPS отдаёт токен ДРУГОГО репозитория и
    # перебивает всё, включая анонимный доступ. Общий /root/.git-credentials
    # не трогаем — он обслуживает другие проекты.
    if [ -n "${GH_TOKEN:-}" ]; then
        GH_HELPER='!f() { echo username=x-access-token; echo password="$GH_TOKEN"; }; f'
        PULL_CMD=(git -c credential.helper="$GH_HELPER")
    else
        echo "   (токена нет — тянем анонимно, репозиторий публичный)"
        PULL_CMD=(git -c credential.helper=)
    fi
    if GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
        "${PULL_CMD[@]}" pull --ff-only; then
        echo "   ok"
    else
        # Публичный репозиторий отдаёт 403, только если сработал чужой store.
        # Не повод падать: дальше всё работает из текущей рабочей копии.
        echo "   ⚠️  pull не удался, деплою из текущей рабочей копии"
        echo "      (проверь авторизацию по DEPLOY-SPEC §3.3, если нужен свежий код)"
    fi
fi

# ── Шаг 2. Поднять контейнер ────────────────────────────────────────────────
echo "🐳 Step 2: Starting BaGet container..."
docker compose -f "$COMPOSE_FILE" up -d
docker compose -f "$COMPOSE_FILE" ps

echo "   ждём готовности фида..."
for i in $(seq 1 40); do
    if curl -sf -o /dev/null "$FEED_URL/v3/index.json"; then
        echo "   фид отвечает после ${i}s"
        break
    fi
    if [ "$i" -eq 40 ]; then
        echo "❌ Фид не поднялся за 40s. Логи:"
        docker logs --tail 50 "$CONTAINER"
        exit 1
    fi
    sleep 1
done

# ── Шаг 3. Скачать пакеты с исходного фида ───────────────────────────────────
echo "⬇️  Step 3: Downloading packages from $ORIGIN_HOST (pinned to $ORIGIN_IP)"
mkdir -p "$NUPKG_DIR"
cd "$NUPKG_DIR"

# Манифест уже содержит готовые URL к .nupkg — регистрацию перебирать не нужно.
# Источник отдаёт nupkg анонимно, без токена.
TOTAL=$(wc -l < "$PACKAGE_LIST")
GOT=0
while IFS= read -r url; do
    [ -n "$url" ] || continue
    f="$(basename "$url")"
    # Проверка СТРОГАЯ и только unzip: python zipfile доверчив и пропускает
    # файл с мусором внутри архива (testzip() вернёт None). unzip -t такой
    # файл отвергает кодом 1. Не заменяй unzip на python -m zipfile.
    if [ -s "$f" ] && unzip -tqq "$f" >/dev/null 2>&1; then
        GOT=$((GOT+1))
        continue
    fi
    # Хост из манифеста не используем: вместо него ставим ORIGIN_HOST, а адрес
    # закрепляем через --resolve на ORIGIN_IP. Путь после /v3/package/ одинаков.
    path="${url#*nuget.qsupport.ru}"
    # Качаем во временный файл и переименовываем атомарно.
    #
    # Почему не прямо в "$f": если закачку прервать и запустить заново, не
    # успев удалить старый файл, ИЛИ если два curl пишут в один путь
    # (прерванная фоновая задача не всегда умирает), получается файл с
    # мусором ВНУТРИ архива. Такой файл:
    #   - проходит python zipfile (testzip() == None, архив «читается»),
    #   - но не проходит unzip -t (код возврата 1).
    # Именно так был испорчен seleniumextension.1.0.12 на 8 388 239 байт.
    # Поэтому проверка строгая — на unzip, не на python.
    #
    # --max-time 900: SeleniumExtension 1.0.8–1.0.13 весит по 20+ МБ и на
    # дефолтных 30s curl стабильно обрывается, оставляя обрезанный zip.
    # Остальные пакеты в среднем 26 КБ.
    if curl -sS -f --max-time 900 --retry 3 --retry-delay 2 \
        --resolve "$ORIGIN_HOST:443:$ORIGIN_IP" \
        -o "$f.part" "https://${ORIGIN_HOST}${path}"; then
        if unzip -tqq "$f.part" >/dev/null 2>&1; then
            mv -f "$f.part" "$f"
        else
            echo "   ⚠️  битый архив, удаляю: $f"
            rm -f "$f.part"
        fi
        GOT=$((GOT+1))
    else
        echo "   ❌ не скачался: $f"
        rm -f "$f.part"
    fi
    [ $((GOT % 25)) -eq 0 ] && echo "   ... $GOT / $TOTAL"
done < "$PACKAGE_LIST"
echo "   скачано/проверено: $GOT из $TOTAL"

# ── Шаг 4. Залить пакеты в клон ─────────────────────────────────────────────
echo "📤 Step 4: Pushing packages into the local feed..."
# Фид запущен с пустым ApiKey (дефолт BaGet), поэтому заголовок с пустым
# ключом — это не ошибка, а штатный способ заливки без аутентификации.
# Повторная заливка той же версии вернёт ошибку: AllowPackageOverwrites=false.
# Это НЕ поломка, такой пакет просто уже в фиде.
PUSHED=0
SKIPPED=0
for f in "$NUPKG_DIR"/*.nupkg; do
    [ -f "$f" ] || continue
    if curl -sS -f --max-time 300 -X PUT \
        -H "X-NuGet-ApiKey: " \
        -F "package=@$f" \
        "$FEED_URL/api/v2/package" >/dev/null 2>&1; then
        PUSHED=$((PUSHED+1))
    else
        SKIPPED=$((SKIPPED+1))
    fi
    [ $(( (PUSHED+SKIPPED) % 25 )) -eq 0 ] && echo "   ... $((PUSHED+SKIPPED)) обработано (залито $PUSHED, уже было $SKIPPED)"
done
echo "   залито: $PUSHED, уже было в фиде: $SKIPPED"

# ── Шаг 5. Проверка ─────────────────────────────────────────────────────────
echo "🔍 Step 5: Verifying..."
STATUS=$(curl -s -o /dev/null -w '%{http_code}' "$FEED_URL/v3/index.json")
echo "   v3/index.json -> $STATUS"
# smoke-тест на скачивание реального пакета, а не только на код главной:
# главная отдаётся SPA-оболочкой даже при пустом фиде.
#
# Пакет берётся ПЕРВЫМ из манифеста, а не захардкоженным qa.core: на
# урезанном манифесте (например, из двух пакетов для проверки скрипта)
# захардкоженный qa.core даёт 404 и роняет прогон, хотя всё отработало.
SMOKE_ID=$(head -1 "$PACKAGE_LIST" | sed -E 's#.*/v3/package/([^/]+)/([^/]+)/.*#\1#')
SMOKE_VER=$(head -1 "$PACKAGE_LIST" | sed -E 's#.*/v3/package/([^/]+)/([^/]+)/.*#\2#')
SMOKE=$(curl -s -o /tmp/smoke.nupkg -w '%{http_code}' \
    "$FEED_URL/v3/package/${SMOKE_ID}/${SMOKE_VER}/${SMOKE_ID}.${SMOKE_VER}.nupkg")
if [ "$SMOKE" = "200" ] && unzip -tqq /tmp/smoke.nupkg >/dev/null 2>&1; then
    echo "   ✅ $SMOKE_ID $SMOKE_VER отдаётся валидным архивом"
else
    echo "   ❌ smoke-тест не прошёл для $SMOKE_ID $SMOKE_VER (код $SMOKE)"
    exit 1
fi
# 404 тоже проверяем: сломанный error_page иначе не заметен до первого
# запроса несуществующего пути.
NOTFOUND=$(curl -s -o /dev/null -w '%{http_code}' \
    "$FEED_URL/v3/package/definitely.not.exists/1.0.0/x.1.0.0.nupkg")
echo "   несуществующий пакет -> $NOTFOUND (ожидается 404)"

echo
echo "✅ Deploy complete. Feed: $FEED_URL"
echo "   Пакетов на диске: $(find "$PROJECT_DIR/baget-data" -name '*.nupkg' 2>/dev/null | wc -l)"
echo
echo "⚠️  Следующий шаг — переключение DNS (см. DEPLOY.md, шаг 4)."
echo "   Откат: вернуть A-запись nuget.qsupport.ru на 91.216.147.7"
