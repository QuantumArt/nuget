#!/usr/bin/env bash
# Диагностика VPS: высокий CPU systemd-journald + 500 на nuget.qsupport.ru
#
# Запуск на VPS:  bash diag_vps.sh
# Ничего не меняет, только читает. Можно запускать сколько угодно раз.
#
# Порядок разделов — от дешёвого к дорогому, каждый блок самодостаточен.

set -u

hr() { printf '\n════════ %s ════════\n' "$1"; }

hr "1. Общая картина (uptime, load, память)"
uptime
free -h 2>/dev/null || true

hr "2. ТОП процессов по CPU"
ps -eo pid,ppid,pcpu,pmem,rss,etimes,comm --sort=-pcpu 2>/dev/null | head -15

hr "3. Журнал: сколько строк за окна времени"
for w in "2 min ago" "15 min ago" "1 hour ago" "24 hours ago"; do
  printf '%-12s ' "$w"
  journalctl --since "$w" --no-pager 2>/dev/null | wc -l
done
journalctl --disk-usage 2>/dev/null

hr "4. Журнал: ТОП писателей по unit"
journalctl --since "15 min ago" --no-pager -o json 2>/dev/null \
  | grep -o '"_SYSTEMD_UNIT":"[^"]*"' | sort | uniq -c | sort -rn | head -12

hr "5. Журнал: ТОП повторяющихся сообщений (числа и hex замаскированы)"
journalctl --since "15 min ago" --no-pager -o cat 2>/dev/null \
  | sed 's/0x[0-9a-fA-F]\{4,\}/0xHEX/g; s/[0-9]\{3,\}/N/g' \
  | sort | uniq -c | sort -rn | head -12

hr "6. Журнал: последние 40 строк (что сыпется прямо сейчас)"
journalctl --since "3 min ago" --no-pager -o short-iso 2>/dev/null | tail -40

hr "7. Журнал: audit-события (отдельный транспорт, часто и есть спам)"
printf 'audit строк: '
journalctl --since "15 min ago" _TRANSPORT=audit --no-pager 2>/dev/null | wc -l
printf 'kernel строк: '
journalctl --since "15 min ago" _TRANSPORT=kernel --no-pager 2>/dev/null | wc -l

hr "8. journald: конфиг, хранилище, счётчики"
grep -vE '^\s*#|^\s*$' /etc/systemd/journald.conf 2>/dev/null || echo "(нет /etc/systemd/journald.conf)"
systemctl show systemd-journald -p ActiveState -p SubState -p CPUUsageNSec -p RuntimeMaxUSec -p TasksCurrent 2>/dev/null
echo "--- persistent dir ---"
ls -la /var/log/journal 2>/dev/null || echo "/var/log/journal НЕТ: Storage=auto → журнал в памяти (/run/log/journal), при нехватке RAM он и упирается"
ls -la /run/log/journal 2>/dev/null | head -5
echo "--- файлы журнала и их размеры ---"
find /var/log/journal /run/log/journal -name '*.journal' -o -name '*.journal~' 2>/dev/null | head -20 | while read -r f; do ls -la "$f"; done

hr "9. Диск и inode (заполненный диск → journald и SQLite ломаются)"
df -h 2>/dev/null
echo "--- inode ---"
df -i 2>/dev/null
echo "--- крупнейшие потребители в /var ---"
du -xh -d 2 /var 2>/dev/null | sort -h | tail -12

hr "10. Docker: контейнеры, рестарты, драйверы логов"
docker ps -a --format '{{.Names}}\t{{.Status}}' 2>/dev/null
echo "--- детально: log-driver / restarts / oom / health ---"
docker ps -aq 2>/dev/null | xargs -r docker inspect --format \
  '{{.Name}} driver={{.HostConfig.LogConfig.Type}} restarts={{.RestartCount}} status={{.State.Status}} oom={{.State.OOMKilled}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' 2>/dev/null
echo "--- потребление ресурсов контейнерами ---"
docker stats --no-stream --format '{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.BlockIO}}' 2>/dev/null

hr "11. Логи BaGet: последние 150 строк (здесь и исключение, из-за которого 500)"
docker logs nuget-baget --tail 150 2>&1 | tail -150

hr "12. nginx: ошибки по нашему домену"
tail -40 /var/log/nginx/nuget.qsupport.ru.error.log 2>/dev/null || echo "(нет файла /var/log/nginx/nuget.qsupport.ru.error.log)"
echo "--- последние ответы 5xx в access-логе ---"
grep -E ' 5[0-9][0-9] ' /var/log/nginx/nuget.qsupport.ru.access.log 2>/dev/null | tail -15 || echo "(нет доступа к access-логу)"

hr "13. Ядро: OOM-kill, ошибки диска, I/O"
dmesg -T 2>/dev/null | tail -40 || echo "(dmesg недоступен без root)"

hr "14. Упавшие systemd-юниты и таймеры"
systemctl list-units --type=service --state=failed --no-pager 2>/dev/null
systemctl list-timers --no-pager 2>/dev/null | head -15

hr "15. Профиль journald в реальном времени (5 сэмплов по 1 c)"
JPID=$(pidof systemd-journald 2>/dev/null)
echo "pid systemd-journald = ${JPID:-не найден}"
if [ -n "${JPID:-}" ]; then
  top -b -d 1 -n 5 -p "$JPID" 2>/dev/null | tail -12
fi

echo
echo "════════ КОНЕЦ ════════"
