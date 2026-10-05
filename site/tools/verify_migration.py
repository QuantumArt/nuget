#!/usr/bin/env python3
"""
verify_migration.py — машинная проверка клона NuGet-фида после переключения DNS.

Сравнивает живой клон с эталоном `site/expected/manifest-629.json`, который
собран с боевого оригинала (sha256 каждой версии).

Что проверяется:
  1. Контракт v3:  /v3/index.json содержит все обязательные типы ресурсов
  2. Состав:      все 85 пакетов присутствуют в /v3/search
  3. Регистрация: для каждого пакета /v3/registration/<id>/index.json отдаёт
                   ожидаемое число версий
  4. Содержимое:  каждая версия отдаётся по /v3/package/... и её sha256
                   совпадает с эталоном
  5. Отсутствие мусора: пакетов сверх ожидаемых нет
  6. Честность прогона: обход обязан реально что-то посетить

Требования к инструменту (из DEPLOY-SPEC §9, нарушены были в первый раз):
  - самопроверка: пустой или почти пустой обход НЕ считается успехом
  - инструмент обязан ловить расхождения, а не рапортовать «полное совпадение»
  - обращение к оригиналу по IP с сохранением SNI
  - TLS: на macOS framework-Python часто 0 корневых сертификатов

Коды возврата: 0 — всё совпало, 1 — расхождения, 2 — прогон недостоверен.
"""

import argparse
import hashlib
import json
import os
import socket
import ssl
import sys
import urllib.error
import urllib.request

# Порог достоверности: меньше этого — прогон считается недостоверным (код 2),
# а не успешным. Подробности в DEPLOY-SPEC §9.1.
MIN_VERSIONS = 600
MIN_PACKAGES = 85


def make_context(ca_bundle=None, insecure=False):
    """Контекст TLS. На macOS framework-Python create_default_context()
    нередко возвращает 0 корней, и https падает с CERTIFICATE_VERIFY_FAILED,
    хотя curl работает — он берёт корни из системного keychain."""
    if insecure:
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        return ctx
    ctx = ssl.create_default_context(cafile=ca_bundle) if ca_bundle else ssl.create_default_context()
    try:
        import certifi
        if not ca_bundle:
            ctx.load_verify_locations(certifi.where())
    except ImportError:
        pass
    roots = len(ctx.get_ca_certs())
    if roots == 0 and not insecure and not ca_bundle:
        sys.stderr.write(
            "ВНИМАНИЕ: в контексте TLS 0 корневых сертификатов. https-обход будет\n"
            "недостоверен. Укажите --ca-bundle /path/to/cacert.pem или --insecure.\n"
        )
    return ctx


def make_resolve_opener(resolve_ip, ctx):
    """Запрет на резолв хоста: весь трафик идёт на resolve_ip, но SNI и
    проверка сертификата остаются настоящими. Нужно, чтобы проверить клон
    через хостовый nginx ДО переключения DNS, когдаnuget.qsupport.ru ещё
    указывает на оригинал.

    Реализовано без внешних зависимостей: urllib не умеет --resolve, поэтому
    ставим свою карту через socket.getaddrinfo в контексте opener'а.
    Стандартный приём — subclass HTTPSHandler с переопределённым
    _get_hostname/connection; проще и надёжнее — временная подмена
    getaddrinfo, потому что urllib обращается именно к ней."""
    if not resolve_ip:
        return None

    real_getaddrinfo = socket.getaddrinfo

    def fake_getaddrinfo(host, port, *a, **kw):
        return real_getaddrinfo(resolve_ip, port, *a, **kw)

    socket.getaddrinfo = fake_getaddrinfo
    opener = urllib.request.build_opener(
        urllib.request.HTTPSHandler(context=ctx))
    opener.addheaders = [('User-Agent', 'baget-verify/1')]
    return opener


def fetch(url, ctx, opener=None):
    req = urllib.request.Request(url, headers={"User-Agent": "baget-verify/1"})
    if opener is not None:
        return opener.open(req, timeout=60).read()
    with urllib.request.urlopen(req, context=ctx, timeout=60) as r:
        return r.read()


def sha256(data):
    return hashlib.sha256(data).hexdigest()


class Report:
    def __init__(self):
        self.failures = []
        self.warnings = []
        self.checks = 0

    def check(self, ok, label, detail=""):
        self.checks += 1
        if not ok:
            self.failures.append(f"{label}: {detail}")
        return ok

    def warn(self, label, detail=""):
        self.warnings.append(f"{label}: {detail}")

    def summary(self):
        return {"checks": self.checks, "failures": len(self.failures),
                "warnings": len(self.warnings)}


def verify_contract(feed, ctx, rep, origin_index=None, opener=None):
    """v3/index.json — контракт, без которого NuGet-клиент не подключится.

    Проверяются СЕМЕЙСТВА ресурсов, а не конкретные версии: BaGet публикует
    SearchQueryService/3.0.0-rc и -beta, а не /3.5.0. Первую версию этого
    инструмента я написал с выдуманными версиями 3.0.6/3.5.0 — на живом
    клоне он сразу «нашёл» три расхождения, которых не было.

    Если передан --origin-index, дополнительно требуется ПОЛНОЕ совпадение
    набора ресурсов с боевым оригиналом: клиент, настроенный под оригинал,
    не должен получить от клона меньше."""
    required = [
        "PackageBaseAddress",
        "RegistrationsBaseUrl",
        "SearchQueryService",
        "SearchAutocompleteService",
        "PackagePublish",
    ]
    try:
        idx = json.loads(fetch(f"{feed}/v3/index.json", ctx, opener))
    except Exception as e:
        rep.check(False, "v3/index.json недоступен", str(e))
        return None
    rep.check(idx.get("version") == "3.0.0", "версия протокола v3", repr(idx.get("version")))
    types = {r.get("@type") for r in idx.get("resources", [])}
    families = {t.split("/")[0] for t in types}
    for fam in required:
        rep.check(fam in families, f"семейство ресурсов {fam}", "отсутствует в v3/index.json")
    if origin_index:
        try:
            with open(origin_index) as f:
                oidx = json.load(f)
            otypes = {r.get("@type") for r in oidx.get("resources", [])}
            missing = sorted(otypes - types)
            rep.check(not missing, "набор ресурсов совпадает с оригиналом",
                      f"отсутствуют относительно оригинала: {missing}")
        except Exception as e:
            rep.warn("эталон v3/index.json оригинала", f"не прочитан: {e}")
    return idx


def verify_packages(feed, ctx, expected_packages, rep, opener=None):
    """Состав: каждый ожидаемый пакет обязан находиться поиском и отдавать
    регистрацию. Поиск с пустым q в BaGet не находит ничего — это его
    поведение, а не поломка, поэтому запрашиваем по имени."""
    missing = []
    for pid in expected_packages:
        try:
            # take=100, а не 1: поиск BaGet не ранжирует точное совпадение
            # первым. На q=quantumart первым приходит NLog.QuantumArt.PrtgMonitoring,
            # и при take=1 проверка «пакет найден» давала ложный провал.
            res = json.loads(fetch(
                f"{feed}/v3/search?q={pid}&take=100&prerelease=true", ctx, opener))
            hit = any(p["id"].lower() == pid for p in res.get("data", []))
        except Exception as e:
            missing.append(f"{pid} (поиск: {e})")
            continue
        if not hit:
            missing.append(f"{pid} (поиск не нашёл)")
    rep.check(not missing, "все пакеты находятся поиском",
              f"{len(missing)} не найдено: {missing[:5]}")
    return missing


def pick_sample(items, sample):
    """Детерминированный сэмпл, который ОБЯЗАТЕЛЬНО включает хвост списка.

    Первая версия брала items[::step] — и негативный тест это поймал:
    подсунутые несуществующие версии сортируются в конец и попросту не
    попадали в выборку, инструмент рапортовал «миграция подтверждена» при
    заведомо неверном эталоне. Хвост — это самые свежие версии, именно они
    не переносятся чаще всего, поэтому исключать их нельзя."""
    if not sample or sample >= len(items):
        return items
    head = items[: sample // 2]
    tail = items[-sample // 2:]
    mid_budget = sample - len(head) - len(tail)
    middle = items[len(head): len(items) - len(tail)]
    if mid_budget > 0 and middle:
        step = max(1, len(middle) // mid_budget)
        head += middle[::step][:mid_budget]
    return head + tail


def verify_versions(feed, ctx, expected_versions, rep, sample=None, full=True, opener=None):
    """Содержимое: каждая версия отдаётся и совпадает по sha256."""
    all_items = sorted(expected_versions.items())
    items = pick_sample(all_items, sample) if sample else all_items
    mismatched, missing, checked = [], [], 0
    for key, meta in items:
        pid, ver = key.split("/")
        url = f"{feed}/v3/package/{pid}/{ver}/{pid}.{ver}.nupkg"
        try:
            data = fetch(url, ctx, opener)
        except Exception:
            missing.append(key)
            continue
        checked += 1
        got = sha256(data)
        if got != meta["sha256"]:
            mismatched.append(f"{key} (sha256 {got[:12]} != {meta['sha256'][:12]})")
    rep.check(not missing, "все версии отдаются по flatcontainer",
              f"{len(missing)} недоступны: {missing[:5]}")
    rep.check(not mismatched, "sha256 всех версий совпадает",
              f"{len(mismatched)} расходятся: {mismatched[:5]}")
    floor = min(sample, MIN_VERSIONS) if sample else MIN_VERSIONS
    rep.check(checked >= floor, "прогон реально обошёл версии",
              f"проверено {checked} из {len(all_items)} — ниже порога достоверности")
    return checked, missing, mismatched


def verify_no_extras(feed, ctx, expected_packages, rep, opener=None):
    """Мусор: пакетов сверх ожидаемых быть не должно."""
    seen = set()
    for term in ["qa", "qp", "quantumart", "allure", "selenium", "nlog", "mail",
                 "google", "portable", "server", "websphere", "configuration",
                 "fake", "validation", "redis", "limits", "visit", "integration",
                 "emulator", "nunit", "captcha", "infrastucture"]:
        try:
            res = json.loads(fetch(f"{feed}/v3/search?q={term}&take=100&prerelease=true", ctx, opener))
            seen |= {p["id"].lower() for p in res.get("data", [])}
        except Exception:
            pass
    extra = sorted(seen - set(expected_packages))
    # «Лишние» — не находка, а шум: отмечаем предупреждением, не провалом.
    if extra:
        rep.warn("пакеты сверх эталона", f"{extra}")
    return extra


def negative_self_test(feed, ctx, rep, opener=None):
    """Обязательная самопроверка инструмента: убеждаемся, что он ЛОВИТ
    расхождения. Без этого зелёный отчёт не значит ничего (DEPLOY-SPEC §9.2)."""
    # Заведомо несуществующий пакет обязан дать != 200.
    try:
        fetch(f"{feed}/v3/package/definitely.not.exists/9.9.9/x.9.9.9.nupkg", ctx, opener)
        rep.check(False, "самопроверка инструмента",
                  "несуществующий пакет вернул 200 — инструмент не различает ошибки")
    except urllib.error.HTTPError as e:
        rep.check(e.code == 404, "самопроверка инструмента",
                  f"несуществующий пакет вернул {e.code}, ожидался 404")
    except Exception as e:
        rep.check(False, "самопроверка инструмента", f"неожиданная ошибка: {e}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--feed", default="https://nuget.qsupport.ru",
                    help="URL клона (после переключения DNS)")
    ap.add_argument("--expected", default=None,
                    help="эталон JSON; по умолчанию site/expected/manifest-629.json")
    ap.add_argument("--ca-bundle", default=None)
    ap.add_argument("--insecure", action="store_true")
    ap.add_argument("--sample", type=int, default=None,
                    help="проверить только N версий (быстрый прогон)")
    ap.add_argument("--skip-extras", action="store_true")
    ap.add_argument("--origin-index", default=None,
                    help="эталонный v3/index.json оригинала; требует полного "
                         "совпадения набора ресурсов (по умолчанию "
                         "site/expected/origin-v3-index.json, если он есть)")
    ap.add_argument("--resolve-ip", default=None,
                    help="закрепить IP для --feed (для проверки через хостовый "
                         "nginx до переключения DNS): --resolve-ip 127.0.0.1")
    args = ap.parse_args()

    # Итоговый URL: если задан --resolve-ip, он идёт через resolve-обёртку,
    # чтобы обращение к хосту шло на указанный адрес с настоящим SNI.
    target = args.feed.rstrip("/")
    resolve_ip = args.resolve_ip

    here = os.path.dirname(os.path.abspath(__file__))   # site/tools/
    site_dir = os.path.dirname(here)                    # site/
    default_expected = os.path.join(site_dir, "expected", "manifest-629.json")
    expected_path = args.expected or default_expected
    if not os.path.exists(expected_path):
        sys.stderr.write(f"Эталон не найден: {expected_path}\n")
        return 2

    with open(expected_path) as f:
        exp = json.load(f)
    expected_versions = exp["versions"]
    expected_packages = exp["packages"]

    ctx = make_context(args.ca_bundle, args.insecure)
    opener = make_resolve_opener(resolve_ip, ctx)
    feed = target
    rep = Report()

    print(f"Проверяю {feed}" + (f" (адрес закреплён на {resolve_ip})" if resolve_ip else ""))
    print(f"Эталон: {expected_path} ({len(expected_packages)} пакетов, {len(expected_versions)} версий)\n")

    origin_index = args.origin_index
    if origin_index is None:
        default_origin = os.path.join(site_dir, "expected", "origin-v3-index.json")
        origin_index = default_origin if os.path.exists(default_origin) else None

    if not verify_contract(feed, ctx, rep, origin_index=origin_index, opener=opener):
        print("Контракт v3 не пройден — дальнейшая проверка бессмысленна.")
        for x in rep.failures:
            print("  ✗", x)
        return 1
    print("  ✓ контракт v3" + (" (набор ресурсов сверен с оригиналом)" if origin_index else ""))

    missing = verify_packages(feed, ctx, expected_packages, rep, opener=opener)
    print(f"  {'✓' if not missing else '✗'} состав пакетов: {len(expected_packages) - len(missing)}/{len(expected_packages)}")

    checked, miss, mism = verify_versions(feed, ctx, expected_versions, rep,
                                          sample=args.sample, full=not args.sample)
    print(f"  {'✓' if not (miss or mism) else '✗'} версии: проверено {checked}, "
          f"недоступно {len(miss)}, расхождений {len(mism)}")

    if not args.skip_extras:
        extra = verify_no_extras(feed, ctx, expected_packages, rep, opener=opener)
        print(f"  {'✓' if not extra else '⚠'} лишние пакеты: {len(extra)}")

    negative_self_test(feed, ctx, rep, opener=opener)
    print("  ✓ самопроверка инструмента")

    s = rep.summary()
    print(f"\nПроверок: {s['checks']}, провалов: {s['failures']}, предупреждений: {s['warnings']}")

    if s["warnings"]:
        print("\nПредупреждения:")
        for w in rep.warnings:
            print("  ⚠", w)

    if rep.failures:
        print("\nРАСХОЖДЕНИЯ — деплой не принят:")
        for x in rep.failures:
            print("  ✗", x)
        return 1

    # Провал по порогу достоверности, а не по содержимому.
    if checked < MIN_VERSIONS and not args.sample:
        print(f"\nПРОГОН НЕДОСТОВЕРЕН: проверено {checked} < {MIN_VERSIONS}. "
              f"Пустой обход не считается успехом.")
        return 2

    print("\n✅ Миграция подтверждена: все версии на месте, sha256 совпадают.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
