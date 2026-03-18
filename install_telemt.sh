#!/bin/bash

# Проверка на права root
if [[ $EUID -ne 0 ]]; then
   echo "Ошибка: Этот скрипт должен быть запущен от имени root (используйте sudo)"
   exit 1
fi

echo "--- Начинаю установку TeleMT ---"

# Настройки (можно изменить здесь)
PORT=443
DOMAIN="vkusvill.ru"
API_PORT=9091

# 0. Проверка занятости портов
echo "Проверка доступности портов..."
if lsof -Pi :$PORT -sTCP:LISTEN -t >/dev/null ; then
    echo "ОШИБКА: Порт $PORT уже занят другим процессом!"
    echo "Список процессов на порту $PORT:"
    netstat -lnp | grep ":$PORT "
    exit 1
fi

if lsof -Pi :$API_PORT -sTCP:LISTEN -t >/dev/null ; then
    echo "ОШИБКА: Порт API $API_PORT уже занят!"
    exit 1
fi

# 1. Установка системных зависимостей
echo "Обновление пакетов и установка инструментов..."
apt-get update && apt-get install -y curl jq openssl wget lsof procps

# 2. Скачивание и установка бинарного файла
echo "Загрузка последней версии TeleMT..."
ARCH=$(uname -m)
LIBC=$(ldd --version 2>&1 | grep -iq musl && echo musl || echo gnu)
URL="https://github.com/telemt/telemt/releases/latest/download/telemt-$ARCH-linux-$LIBC.tar.gz"

wget -qO- "$URL" | tar -xz
if [ ! -f ./telemt ]; then
    echo "Ошибка: Не удалось скачать или распаковать файл."
    exit 1
fi

mv telemt /bin/telemt
chmod +x /bin/telemt
echo "Программа установлена в /bin/telemt"

# 3. Генерация секрета
SECRET=$(openssl rand -hex 16)
USER_NAME="user_$(date +%s)"
echo "Сгенерирован секретный ключ: $SECRET"

# 4. Создание пользователя и структуры папок
id -u telemt &>/dev/null || useradd -d /opt/telemt -m -r -U telemt
mkdir -p /etc/telemt

# 5. Создание конфигурации (TOML)
cat <<EOF > /etc/telemt/telemt.toml
[general]
use_middle_proxy = false

[general.modes]
classic = false
secure = false
tls = true

[server]
port = $PORT

[server.api]
enabled = true
listen = "127.0.0.1:$API_PORT"

[censorship]
tls_domain = "$DOMAIN"

[access.users]
"$USER_NAME" = "$SECRET"
EOF

chown -R telemt:telemt /etc/telemt
echo "Конфигурация сохранена в /etc/telemt/telemt.toml"

# 6. Создание Systemd службы
cat <<EOF > /etc/systemd/system/telemt.service
[Unit]
Description=Telemt Proxy Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=telemt
Group=telemt
WorkingDirectory=/opt/telemt
ExecStart=/bin/telemt /etc/telemt/telemt.toml
Restart=on-failure
LimitNOFILE=65536
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

# 7. Запуск и активация
echo "Запуск службы..."
systemctl daemon-reload
systemctl enable telemt
systemctl restart telemt

# 8. Финальная проверка и выдача ссылок
echo "-------------------------------------------------------"
echo "Ожидание запуска API (5 сек)..."
sleep 5

if systemctl is-active --quiet telemt; then
    echo "Telemt успешно запущен!"
    echo "Ваши ссылки для Telegram:"
    curl -s http://127.0.0.1:$API_PORT/v1/users | jq
else
    echo "Ошибка: Служба не смогла запуститься. Проверьте логи: journalctl -u telemt"
fi
echo "-------------------------------------------------------"