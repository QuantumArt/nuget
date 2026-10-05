# Локальный клон nuget.qsupport.ru

Оригинал — self-hosted **BaGet** (ASP.NET + React), запущенный на IIS/ARR.
Мы подняли тот же движок локально и перенесли в него последние версии пакетов.

## Что внутри

| | |
|---|---|
| Пакетов | 85 (все, что были на оригинале) |
| Версий | 629 — по 11 на пакет: последняя + 10 предыдущих |
| Вес | ~200 МБ |
| Движок | `loicsharma/baget:latest` (MIT) |

Полная история (5870 версий) не переносилась — по вашему решению.

## Запуск

```bash
cd /Users/anisimovs/Projects/nuget
docker run -d --name baget -p 5555:80 \
  -e "Storage:Type=FileSystem" \
  -e "Storage:Path=/var/baget/packages" \
  -e "Database:Type=Sqlite" \
  -e "Database:ConnectionString=Data Source=/var/baget/baget.db" \
  -v "$(pwd)/baget-data-v2:/var/baget" \
  loicsharma/baget:latest
```

Веб-интерфейс: <http://localhost:5555/>

Остановить: `docker rm -f baget`

## Подключить к проекту

`NuGet.Config`:

```xml
<configuration>
  <packageSources>
    <add key="local" value="http://localhost:5555/v3/index.json" />
  </packageSources>
</configuration>
```

## Две грабли, на которые ушла большая часть времени

**1. Ключ конфига — `Storage:Path`, а не `FileStorage:Path`.**

Официальный Docker-гайд BaGet даёт `-e FileStorage__Path=...`, и с таким
значением пакеты молча пишутся в `/app/packages` — внутрь слоя контейнера.
Том остаётся пустым, фид работает, но всё теряется при пересоздании.
В этой версии движка путь читается из секции `Storage`.

**2. SQLite-база тоже должна быть в томе.**

По умолчанию `Data Source=baget.db` — рядом с бинарём, то есть опять в слое.
Без явного пути индекс и метаданные не переживут `docker rm`.

**Побочный эффект:** BaGet сам дописывает `packages` к `Storage:Path`,
поэтому в томе реальный путь — `baget-data-v2/packages/packages/<id>/<version>/`.
Это нормально, данные на месте.

## Заливка пакетов

Фид отдаёт аутентификацию по пустому API-ключу (`ApiKey: ""` в appsettings),
так что заливка идёт без токена:

```bash
curl -X PUT -H "X-NuGet-ApiKey: " \
  -F "package=@path/to/pkg.nupkg" \
  http://localhost:5555/api/v2/package
```

`AllowPackageOverwrites: false` — повторная заливка той же версии вернёт ошибку,
это не проблема. Все исходники лежат в `nupkgs/`.

## Деплой на VPS

Полный runbook — **[`site/DEPLOY.md`](site/DEPLOY.md)**. Общая механика и все
серверные грабли — в `anisimovs/downloads:docs/DEPLOY-SPEC.md`.

```bash
cd site && ./deploy.sh
```

Домен `nuget.qsupport.ru` **боевой**: переключение DNS переводит реальные
сборки QuantumArt с оригинала (91.216.147.7) на клон (217.198.6.66).
Откат — вернуть A-запись, минуты.

⚠️ В клоне 629 версий вместо 5870. Если сборки пинят старые версии — перед
переключением перекачайте историю: `PACKAGE_LIST=./packages-full.txt ./deploy.sh`.
Подробности в разделе «Риск» в `site/DEPLOY.md`.

Манифесты: `site/packages-11x.txt` (629, по умолчанию) и
`site/packages-full.txt` (5870, вся история).

## Проверка целостности

```bash
cd nupkgs && python3 -c "
import zipfile, glob
bad=[f for f in glob.glob('*.nupkg')
     if not zipfile.is_zipfile(f)]
print('valid:', len(glob.glob('*.nupkg'))-len(bad), 'bad:', len(bad))
"
```

Обрезка файлов на середине — главная причина «битых» nupkg при переносе.
`SeleniumExtension 1.0.8–1.0.13` весит по 20+ МБ и требует увеличенного
`--max-time`; остальные пакеты в среднем 26 КБ и качаются мгновенно.
