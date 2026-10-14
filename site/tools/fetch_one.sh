#!/bin/sh
# Скачивание одной версии пакета с боевого оригинала (nugetold).
# Вызывается по одному URL из манифеста, xargs -n 1 -P N.
#
# TLS проверяется полностью: URL и SNI — nuget.qsupport.ru (сертификат
# боевого сервера имеет именно этот CN), адрес закреплён через --resolve,
# а маршрутизация на переехавший сервер делается заголовком Host.
# Ключ -k здесь НЕ используется и не нужен.
cd /Users/anisimovs/Projects/nuget/nupkgs-full || exit 1

u="$1"
f=$(basename "$u")
[ -s "$f" ] && exit 0

p="${u#*nuget.qsupport.ru}"

# Качаем во временный файл и переименовываем только после успешной проверки:
# прерванная закачка не должна оставить файл правильного размера с битым
# содержимым (такое уже случалось с SeleniumExtension).
if curl -sS -f --max-time 900 --retry 3 --retry-delay 2 \
     --resolve nuget.qsupport.ru:443:91.216.147.7 \
     -H "Host: nugetold.qsupport.ru" \
     -o "$f.part" "https://nuget.qsupport.ru${p}"
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