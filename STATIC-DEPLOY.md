# Static Files Deployment

Инструкция для деплоя статических сайтов (HTML/CSS/JS) через webhook.

---

## Как это работает?

1. **Git push** → GitHub webhook → `webhook.js`
2. `webhook.js` → запускает `deploy.sh` в папке проекта
3. `deploy.sh`:
   - Проверяет изменения (git fetch)
   - Если изменений нет → выходит мгновенно
   - Если есть → делает git pull
   - Перезапускает Python HTTP сервер
4. Cloudflare Tunnel раздаёт файлы через http://localhost:PORT

**Время деплоя:** ~2-5 секунд (только git pull + restart)

---

## Настройка нового статического проекта

### 1. Через init.sh (автоматически)

```bash
cd /opt/webook_deploy_debian
./scripts/init.sh

# В wizard:
# - Project name: staticpage
# - Git URL: git@github.com:USER/staticpage.git
# - Branch: main
# - WorkDir: /opt/staticpage
# - Project type: 2 (Static files)  ← ВАЖНО!
# - Subdomain: static
# - Port: 3005
```

### 2. Вручную

**Структура репозитория:**
```
staticpage/
├── index.html
├── style.css
├── script.js
└── assets/
    └── logo.png
```

**Шаги:**

```bash
# 1. Склонировать репозиторий
cd /opt
git clone git@github.com:USER/staticpage.git

# 2. Скопировать deploy скрипт
cp /opt/webook_deploy_debian/scripts/deploy-static.template.sh /opt/staticpage/deploy.sh
chmod +x /opt/staticpage/deploy.sh

# 3. Исправить владельца
chown -R webuser:webuser /opt/staticpage

# 4. Добавить в config/projects.json
```

**projects.json:**
```json
{
  "name": "staticpage",
  "gitUrl": "git@github.com:USER/staticpage.git",
  "repo": "USER/staticpage",
  "branch": "main",
  "workDir": "/opt/staticpage",
  "deployScript": "/opt/staticpage/deploy.sh",
  "deployArgs": ["3005"],
  "cloudflare": {
    "enabled": true,
    "rootDomain": "linkify.cloud",
    "subdomain": "static",
    "localPort": 3005,
    "localPath": "/",
    "protocol": "http",
    "tunnelName": "linkify.cloud"
  }
}
```

**5. Перезапустить webhook:**
```bash
systemctl restart webhook-deploy
```

---

## Как работает deploy-static.template.sh

```bash
#!/bin/bash
set -e

PORT="${1:-3000}"  # Порт из deployArgs

# 1. Проверка изменений
git fetch
if [ текущий_commit == удалённый_commit ]; then
  exit 0  # Нет изменений - мгновенный выход
fi

# 2. Git pull
git pull --ff-only

# 3. Перезапуск сервера
kill старый_процесс
python3 -m http.server $PORT &

echo "✓ Static server running on port $PORT"
```

**Оптимизации:**
- ✅ Проверка изменений перед pull (instant skip если нет изменений)
- ✅ PID файл для корректной остановки старого сервера
- ✅ Fallback kill по порту
- ✅ Логирование в `server.log`

---

## Управление

### Проверить статус:
```bash
# Логи webhook
journalctl -u webhook-deploy.service -f

# Логи статического сервера
tail -f /opt/staticpage/server.log

# Проверить процесс
ps aux | grep "python3 -m http.server"

# Проверить порт
ss -tlnp | grep 3005
```

### Ручной деплой:
```bash
cd /opt/staticpage
./deploy.sh 3005
```

### Остановить сервер:
```bash
# Найти PID
cat /opt/staticpage/.server.pid

# Остановить
kill $(cat /opt/staticpage/.server.pid)

# Или по порту
pkill -f "python3 -m http.server 3005"
```

---

## Troubleshooting

### Сервер не запускается
```bash
# Проверь права
ls -la /opt/staticpage/deploy.sh
# Должно быть: -rwxr-xr-x webuser webuser

# Исправь
chmod +x /opt/staticpage/deploy.sh
chown -R webuser:webuser /opt/staticpage
```

### Webhook не видит изменения
```bash
# Проверь git
cd /opt/staticpage
git status
git fetch
git log -1

# Проверь webhook config
cat /opt/webook_deploy_debian/config/projects.json | jq '.projects[] | select(.name=="staticpage")'
```

### Порт занят
```bash
# Найти процесс на порту
lsof -i :3005

# Убить
kill -9 <PID>

# Или в deploy.sh изменить порт
./deploy.sh 3006
```

---

## Альтернативы Python HTTP серверу

### Node.js serve
```bash
npm install -g serve

# В deploy.sh замени:
# python3 -m http.server $PORT
# на:
# serve -l $PORT .
```

### Nginx в Docker
```yaml
# docker-compose.yml
services:
  static:
    image: nginx:alpine
    ports:
      - "3005:80"
    volumes:
      - ./:/usr/share/nginx/html:ro
```

---

## Сравнение с Docker деплоем

| Характеристика | Static (Python) | Docker (Next.js) |
|----------------|-----------------|------------------|
| Время деплоя | **2-5 сек** | 5-10 сек (restart) / 2-3 мин (rebuild) |
| Размер | ~0 MB (только файлы) | 200 MB - 1.5 GB |
| Требования | Python 3 (встроен) | Docker + образ |
| Сложность | Простейший | Средняя |
| Hot reload | ❌ (нужен restart) | ✅ (в dev режиме) |
| Production | ✅ Подходит для простых сайтов | ✅ Для любых приложений |

---

## Best Practices

1. **Используй .gitignore:**
```
server.log
.server.pid
*.pyc
__pycache__/
```

2. **Минимизируй файлы:**
   - Сжимай изображения
   - Минифицируй CSS/JS
   - Используй CDN для библиотек

3. **Кэширование:**
   - Добавь версионирование в URLs (`style.css?v=1.0`)
   - Используй Cloudflare Page Rules для кэширования

4. **Мониторинг:**
```bash
# Добавь в crontab проверку что сервер жив
*/5 * * * * pgrep -f "python3 -m http.server 3005" || /opt/staticpage/deploy.sh 3005
```

---

## Примеры использования

**Landing page:**
```
/opt/landing/
├── index.html
├── css/style.css
├── js/main.js
└── images/
```

**Документация:**
```
/opt/docs/
├── index.html
├── api.html
├── guide.html
└── assets/
```

**Portfolio:**
```
/opt/portfolio/
├── index.html
├── projects/
│   ├── project1.html
│   └── project2.html
└── styles/
```

Деплой работает одинаково для всех - просто `git push`.
