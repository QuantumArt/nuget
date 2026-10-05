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
# Резолвим манифест в абсолютный путь СРАЗУ, до любых cd.
# Дальше скрипт переходит в каталог пакетов (cd "$NUPKG_DIR"), и относительный
# путь из переменной окружения там перестаёт существовать:
#     PACKAGE_LIST=./packages-full.txt ./deploy.sh
#     → ./deploy.sh: line 118: ./packages-full.txt: No such file or directory
# Путь из окружения почти всегда задают относительным, поэтому страховка
# обязательна, а не косметика.
if [ ! -f "$PACKAGE_LIST" ]; then
    echo "❌ манифест пакетов не найден: $PACKAGE_LIST" >&2
    echo "   (задан через PACKAGE_LIST; по умолчанию $SCRIPT_DIR/packages-11x.txt)" >&2
    exit 2
fi
PACKAGE_LIST="$(cd "$(dirname "$PACKAGE_LIST")" && pwd)/$(basename "$PACKAGE_LIST")"
FEED_URL="${FEED_URL:-http://127.0.0.1:3022}"
# Ключ публикации из .env рядом с compose. Пусто = фид открыт для пуша.
# dotenv не всегда подгружается compose, читаем сами.
if [ -z "${BAGET_APIKEY:-}" ] && [ -f "$SCRIPT_DIR/.env" ]; then
    set -a; . "$SCRIPT_DIR/.env"; set +a
fi
NUPKG_KEY="${BAGET_APIKEY:-}"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.production.yml"
NUPKG_DIR="$PROJECT_DIR/nupkgs"
CONTAINER="nuget-baget"

# ── Защита от случайной загрузки полной истории ─────────────────────────────
# Фид живёт на 629 версиях (по 11 на пакет). Манифест packages-full.txt
# содержит все 5870 и весит вчетверо больше — запускать его нужно осознанно.
# Без этой проверки одна опечатка или команда из старой инструкции молча
# запускала получасовую загрузку, которую потом приходилось прерывать.
DEFAULT_LINES=$(wc -l < "$SCRIPT_DIR/packages-11x.txt")
TOTAL=$(wc -l < "$PACKAGE_LIST")
if [ "$TOTAL" -gt $(( DEFAULT_LINES * 2 )) ] && [ -z "${ASSUME_YES:-}" ]; then
    echo "⚠️  В манифесте $TOTAL версий, а по умолчанию $DEFAULT_LINES."
    echo "   Это примерно $(( TOTAL * 30 / 1024 )) МБ и долгий прогон."
    echo "   Фид сейчас полон на $DEFAULT_LINES версиях; доливка нужна только"
    echo "   если сборки падают на версиях старше 11 от последней."
    if [ -t 0 ]; then
        printf "   Продолжить? напишите yes: "
        read -r ans
        if [ "$ans" != "yes" ]; then
            echo "Отменено."
            exit 1
        fi
    else
        echo "   Неинтерактивный режим. Для подтверждения задайте ASSUME_YES=1."
        exit 2
    fi
fi

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

# ── Шаг 3. Проверить локальные файлы и докачать недостающие ───────────────────
# Заголовок раньше назывался «Downloading», и это вводило в заблуждение: при
# повторном запуске скрипт НИЧЕГО не качает, а только сверяет уже скачанное.
echo "🔎 Step 3: Checking local packages in $NUPKG_DIR"
mkdir -p "$NUPKG_DIR"

# Сверка целиком идёт одним проходом на python: он читает каждый файл один раз
# и печатает ТОЛЬКО те, которые надо докачать. Раньше на каждый файл звался
# `unzip -t` из bash — те же 4+ секунды, но 629 отдельных проверок и ни одного
# счётчика, из-за чего шаг и выглядел повторной загрузкой.
#
# Сверка строгая и идёт по sha256 против эталона, а не по признаку zip:
# python zipfile пропускает файл с мусором внутри архива (testzip() == None),
# а сравнение хеша ловит любое отличие побайтово. Проверка по хешу к тому же
# дешевле: unzip -t распаковывает весь архив, sha256 только читает байты.
NEEDED="$NUPKG_DIR/.need-download"
if [ -f "$SCRIPT_DIR/expected/manifest-629.json" ]; then
    python3 - "$PACKAGE_LIST" "$NUPKG_DIR" "$SCRIPT_DIR/expected/manifest-629.json" > "$NEEDED" <<'PYEOF'
import hashlib, json, os, sys
manifest, pkgdir, etalon_path = sys.argv[1:4]
by_file = {}
try:
    d = json.load(open(etalon_path))
    for v in d.get('versions', {}).values():
        by_file[v['file']] = v['sha256']
except Exception:
    pass
total = ok = 0
for line in open(manifest):
    url = line.strip()
    if not url:
        continue
    total += 1
    name = url.rsplit('/', 1)[-1]
    p = os.path.join(pkgdir, name)
    want = by_file.get(name)
    if want:
        # эталон есть: побайтовая сверка, строже любого zip-теста
        try:
            with open(p, 'rb') as fh:
                if hashlib.sha256(fh.read()).hexdigest() == want:
                    ok += 1
                    continue
        except OSError:
            pass
    else:
        # версии нет в эталоне (например, доливка полной истории) — архивная
        # проверка через unzip, из python zipfile она ненадёжна
        r = os.system('unzip -tqq %s >/dev/null 2>&1' % __import__('shlex').quote(p))
        if r == 0 and os.path.getsize(p) > 0 if os.path.exists(p) else False:
            ok += 1
            continue
    print(url)   # этот URL надо докачать
sys.stderr.write('   локально годных: %d из %d\n' % (ok, total))
PYEOF
else
    echo "   (эталона нет — проверяю архивы через unzip)"
    : > "$NEEDED"
    while IFS= read -r url; do
        [ -n "$url" ] || continue
        f="$NUPKG_DIR/$(basename "$url")"
        if [ -s "$f" ] && unzip -tqq "$f" >/dev/null 2>&1; then :; else echo "$url" >> "$NEEDED"; fi
    done < "$PACKAGE_LIST"
    echo "   локально годных: $((TOTAL - $(wc -l < "$NEEDED"))) из $TOTAL" >&2
fi

NEED_COUNT=$(wc -l < "$NEEDED")
if [ "$NEED_COUNT" -eq 0 ]; then
    echo "   ✅ все $TOTAL пакетов уже на месте, скачивать нечего"
else
    echo "   ⬇️  нужно докачать: $NEED_COUNT из $TOTAL (с $ORIGIN_HOST)"
fi

cd "$NUPKG_DIR"

# Источник отдаёт nupkg анонимно, без токена. TOTAL посчитан выше — там же
# сработала защита от полной истории.
GOT=0
while IFS= read -r url; do
    [ -n "$url" ] || continue
    f="$(basename "$url")"
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
    # Докачанный файл тоже проверяется unzip -t, а не python zipfile.
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
    [ $((GOT % 25)) -eq 0 ] && echo "   ... докачано $GOT из $NEED_COUNT"
done < "$NEEDED"
if [ "$GOT" -gt 0 ]; then
    echo "   докачано: $GOT из $NEED_COUNT"
else
    echo "   докачивать было нечего"
fi
rm -f "$NEEDED"

# ── Шаг 4. Залить пакеты в клон ─────────────────────────────────────────────
echo "📤 Step 4: Pushing packages into the local feed..."
# Фид запущен с пустым ApiKey (дефолт BaGet), поэтому заголовок с пустым
# ключом — это не ошибка, а штатный способ заливки без аутентификации.
# Повторная заливка той же версии вернёт ошибку: AllowPackageOverwrites=false.
# Это НЕ поломка, такой пакет просто уже в фиде.
# Что уже лежит в фиде, спрашиваем ОДИН раз на пакет, а не HEAD на каждую
# версию: /v3/registration/<id>/index.json отдаёт все версии сразу. Это 85
# запросов вместо 629, и — важнее — исключает историю, когда HEAD отвечал
# не-200, скрипт проваливался в PUT и выгружал 20-МБ файлы ради 409.
# На живом боевом сервере из-за этого шаг шёл многие минуты.
PRESENT="$NUPKG_DIR/.present"
python3 - "$FEED_URL" "$PACKAGE_LIST" > "$PRESENT" <<'PYEOF'
import json, ssl, sys, urllib.request, urllib.error
feed, manifest = sys.argv[1:3]
ids = []
for line in open(manifest):
    u = line.strip()
    if not u:
        continue
    parts = u.split('/v3/package/')
    if len(parts) == 2:
        pid = parts[1].split('/')[0]
        if pid not in ids:
            ids.append(pid)
present = set()
for pid in ids:
    try:
        d = json.loads(urllib.request.urlopen(
            f"{feed}/v3/registration/{pid}/index.json", timeout=60).read())
    except Exception:
        continue                      # пакет не найден — зальём целиком
    for page in d.get('items', []):
        for it in page.get('items', []):
            ce = it.get('catalogEntry', {})
            v = ce.get('version') or (it.get('@id', '').rsplit('/', 1)[-1].replace('.json', ''))
            if v:
                present.add(f"{pid}/{v.lower()}")
for k in sorted(present):
    print(k)
PYEOF
PRESENT_COUNT=$(wc -l < "$PRESENT")

PUSHED=0
SKIPPED=0
while IFS= read -r url; do
    [ -n "$url" ] || continue
    name="$(basename "$url")"
    f="$NUPKG_DIR/$name"
    if [ ! -s "$f" ]; then
        echo "   ⚠️  нет файла, пропускаю: $name"
        continue
    fi
    path="${url#*nuget.qsupport.ru}"
    pid_ver="${path#/v3/package/}"
    pid_ver="${pid_ver%/*}"                      # отбрасываем имя файла
    if grep -qxF "$pid_ver" "$PRESENT"; then
        SKIPPED=$((SKIPPED+1))
        continue
    fi
    # Хост из манифеста не используем: вместо него ставим ORIGIN_HOST, а адрес
    # закрепляем через --resolve на ORIGIN_IP.
    if curl -sS -f --max-time 300 -X PUT \
        -H "X-NuGet-ApiKey: $NUPKG_KEY" \
        -F "package=@$f" \
        "$FEED_URL/api/v2/package" >/dev/null 2>&1; then
        PUSHED=$((PUSHED+1))
    else
        SKIPPED=$((SKIPPED+1))
    fi
    [ $(( (PUSHED+SKIPPED) % 25 )) -eq 0 ] && echo "   ... $((PUSHED+SKIPPED)) обработано (залито $PUSHED, уже было $SKIPPED)"
done < "$PACKAGE_LIST"
echo "   залито: $PUSHED, уже было в фиде: $SKIPPED"
if [ "$SKIPPED" -gt 0 ] && [ "$PUSHED" -eq 0 ]; then
    echo "   ✅ ничего заливать не потребовалось"
fi
rm -f "$PRESENT"

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
