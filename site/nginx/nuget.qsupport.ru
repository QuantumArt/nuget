# ─── nuget.qsupport.ru — host nginx server block ─────────────────────────────
# Путь на VPS: /etc/nginx/sites-available/nuget.qsupport.ru
# Активация: ln -s /etc/nginx/sites-available/nuget.qsupport.ru \
#                /etc/nginx/sites-enabled/nuget.qsupport.ru
#
# ВАЖНО про сертификат: общий SAN-сертификат этого VPS — ts.sqlhub.pro —
# покрывает только *.sqlhub.pro и для этого домена НЕ подходит.
# Нужен отдельный сертификат, выпущенный ДО переключения DNS
# (см. DEPLOY.md, шаг 1). Cloudflare DNS-01, тот же credentials-файл.
#
# Как у izida/prodamus/sidus/downloads: только HTTPS-блок, без явного редиректа
# с 80 — домены на этом VPS проксируются через Cloudflare, которая отдаёт
# HTTPS на edge.
#
# ⚠️  Домен боевой. Переключение A-записи переводит реальные сборки
# QuantumArt с оригинала на клон. Откат — вернуть A-запись на 91.216.147.7.

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name nuget.qsupport.ru;

    ssl_certificate     /etc/letsencrypt/live/nuget.qsupport.ru/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/nuget.qsupport.ru/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    # NuGet-клиент (dotnet restore) шлёт Range-запросы и ждёт точные коды.
    # Кэшировать .nupkg дорого и опасно — отдаём как есть, без буферизации.
    client_max_body_size 512m;

    location / {
        proxy_pass http://127.0.0.1:3022;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # Аплоад пакетов (nuget push) идёт на /api/v2/package и может быть
        # крупным. Поэтому таймауты выше дефолтных, иначе 60s рвут заливку
        # 20-МБ SeleniumExtension.
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
        proxy_request_buffering off;
    }

    access_log /var/log/nginx/nuget.qsupport.ru.access.log;
    error_log  /var/log/nginx/nuget.qsupport.ru.error.log;
}
