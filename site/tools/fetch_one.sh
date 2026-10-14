#!/bin/sh
# Скачивание одной версии пакета с боевого оригинала.
#
# Вызывается по одному URL: deploy.sh через xargs -P N, либо вручную при
# разборе неудачных загрузок. Ничего не печатает при успехе — при неудаче
# печатает FAIL/BAD и возвращает ненулевой код.
#
# Параметры берутся из окружения, чтобы одна копия работала и на VPS, и
# локально:
#   PACKAGE_DIR       куда класть (по умолчанию — нет, скрипт требует его)
#   ORIGIN_HOST       имя для URL и SNI: по нему сверяется сертификат
#   ORIGIN_IP         адрес, закреплённый через --resolve
#   ORIGIN_ROUTE_HOST имя vhost'а для заголовка Host
#
# TLS проверяется полностью, ключ -k не используется: URL и SNI остаются
# настоящими (сертификат боевого сервера имеет CN=nuget.qsupport.ru), адрес
# закреплён, а маршрутизация на переехавший сервер идёт через Host.

: "${PACKAGE_DIR:?нужно задать PACKAGE_DIR}"
ORIGIN_HOST="${ORIGIN_HOST:-nuget.qsupport.ru}"
ORIGIN_IP="${ORIGIN_IP:-91.216.147.7}"
ORIGIN_ROUTE_HOST="${ORIGIN_ROUTE_HOST:-nugetold.qsupport.ru}"

cd "$PACKAGE_DIR" || exit 1

u="$1"
[ -n "$u" ] || exit 1

f=$(basename "$u")
[ -s "$f" ] && exit 0            # уже скачан

p="${u#*${ORIGIN_HOST}}"

# Запись во временный файл и переименование ТОЛЬКО после успешной проверки:
# прерванная закачка не должна оставить файл правильного размера с битым
# содержимым. Так уже портились seleniumextension 1.0.12 и 1.0.13 — две
# записи в один путь смешались, размер сошёлся, CRC нет.
if curl -sS -f --max-time 900 --retry 3 --retry-delay 2 \
     --resolve "${ORIGIN_HOST}:443:${ORIGIN_IP}" \
     -H "Host: ${ORIGIN_ROUTE_HOST}" \
     -o "$f.part" "https://${ORIGIN_HOST}${p}"
then
    if unzip -tqq "$f.part" >/dev/null 2>&1; then
        mv -f "$f.part" "$f"
    else
        echo "BAD $f"
        rm -f "$f.part"
        exit 1
    fi
else
    echo "FAIL $f"
    rm -f "$f.part"
    exit 1
fi