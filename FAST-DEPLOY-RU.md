# Быстрый деплой - Инструкция

## Проблема

Каждый `git push` вызывает полную пересборку Docker образа → **5-7 минут ожидания**.

## Решение

Умный деплой с проверкой изменений → **5-10 секунд** для изменений кода.

---

## Как это работает?

### 1. Проверка изменений

```bash
# Было:
git pull
docker compose up -d --build  # ВСЕГДА rebuild (~5-7 мин)

# Стало:
git fetch
if no_changes:
  exit  # Мгновенно
  
git pull
if только_код_изменился:
  docker compose restart  # 5-10 секунд
else:
  docker compose build    # 2-3 минуты
```

### 2. Кэширование Docker layers

- `package.json` не изменился → используется кэш node_modules
- Только код изменился → только код пересобирается
- Ничего не изменилось → деплой пропускается

### 3. Volume mounting (development)

В dev режиме код монтируется напрямую в контейнер:
- Git pull → файлы обновляются через volume
- Next.js hot reload подхватывает изменения
- Rebuild вообще не нужен!

---

## Установка

### Для новых проектов

Автоматически применяется при запуске `init.sh`.

### Для существующих проектов

```bash
# 1. Применить оптимизации ко всем проектам
cd /opt/webook_deploy_debian
sudo ./scripts/apply_optimizations.sh

# Скрипт спросит для каждого проекта:
# - Обновить deploy.sh? [Y/n]
# - Заменить Dockerfile? [y/N]  
# - Заменить docker-compose.yml? [y/N]
# - Создать .dockerignore? [Y/n]
# - Пересобрать образы для кэша? [y/N]
```

### Ручная установка (один проект)

```bash
cd /opt/linkify-dev

# 1. Обновить deploy.sh
cp /opt/webook_deploy_debian/scripts/deploy.template.sh ./deploy.sh
chmod +x deploy.sh

# 2. (Опционально) Заменить Dockerfile
cp /opt/webook_deploy_debian/scripts/Dockerfile.optimized ./Dockerfile
# ⚠ Проверь и адаптируй под свой проект!

# 3. (Опционально) Обновить docker-compose.yml
cp /opt/webook_deploy_debian/scripts/docker-compose.optimized.yml ./docker-compose.yml
# ⚠ Проверь порты и пути volumes!

# 4. Создать .dockerignore
cp /opt/webook_deploy_debian/scripts/.dockerignore.example ./.dockerignore

# 5. Первый build для создания кэша
docker compose build app-dev
```

---

## Тестирование

```bash
# 1. Сделай небольшое изменение в коде
cd /opt/linkify-dev
echo "// test" >> src/index.js

# 2. Закоммить и запушить
git add .
git commit -m "test: оптимизация деплоя"
git push

# 3. Проверь логи webhook
journalctl -u webhook-deploy.service -f

# Должно быть:
# [deploy] Changes detected - pulling...
# [deploy] ✓ Only source files changed - trying hot restart
# [deploy] Running QUICK RESTART: docker compose restart
# [deploy] Done in 8s  ← БЫСТРО!
```

---

## Сравнение скорости

### Сценарий 1: Изменение только кода (*.js, *.ts, *.jsx)

- **Было:** 5-7 минут (полный rebuild)
- **Стало:** 5-10 секунд (restart)
- **Ускорение:** **60x**

### Сценарий 2: Изменение package.json / dependencies

- **Было:** 5-7 минут
- **Стало:** 2-3 минуты (используется кэш других layers)
- **Ускорение:** 2-3x

### Сценарий 3: Повторный push без изменений

- **Было:** 5-7 минут (всё равно rebuild)
- **Стало:** мгновенно (exit до git pull)
- **Ускорение:** ∞

### Сценарий 4: Development с volume mounting

- **Было:** 5-7 минут на каждый push
- **Стало:** 5 секунд (hot reload, без rebuild)
- **Ускорение:** **80x**

---

## Что изменилось в файлах?

### deploy.sh (scripts/deploy.template.sh)

**Новая логика:**
1. Проверка коммитов: local vs remote
2. Если одинаковые → exit (нет изменений)
3. Анализ измененных файлов
4. Умный выбор: restart или build

### Dockerfile.optimized

**Multi-stage build:**
- Stage 1: Установка dependencies (кэшируется)
- Stage 2: Build приложения
- Stage 3: Production образ (только runtime)

**Результат:**
- Размер образа: 1.5GB → 200MB
- Время build при изменении кода: 5 мин → 1 мин

### docker-compose.optimized.yml

**Для development:**
```yaml
volumes:
  - ./src:/app/src:ro    # Код монтируется
  - ./pages:/app/pages:ro
```

**Для production:**
- Без volumes (запечатанный образ)
- Health checks
- Resource limits

### .dockerignore

Исключает из build context:
- `node_modules/` (экономия 1GB+)
- `.git/` 
- `.next/`, `build/`, `dist/`
- IDE файлы, логи, тесты

**Ускорение:** Передача контекста 2GB → 50MB = экономия 30 секунд.

---

## Мониторинг

```bash
# Время последних деплоев
journalctl -u webhook-deploy.service -n 100 | grep "Done in"

# Пример вывода:
# [deploy] Done in 7s   ← БЫСТРО (restart)
# [deploy] Done in 154s ← Медленно (rebuild после изменения package.json)
# [deploy] Done in 9s   ← БЫСТРО (restart)

# Размер образов
docker images | grep linkify

# Логи real-time
journalctl -u webhook-deploy.service -f
```

---

## Troubleshooting

### Проблема: Деплой всё равно медленный

**Решение:**
```bash
# Проверь, что deploy.sh обновлен
cd /opt/linkify-dev
head -n 20 deploy.sh | grep "BEFORE_COMMIT"

# Если не найдено → обнови
cp /opt/webook_deploy_debian/scripts/deploy.template.sh ./deploy.sh
```

### Проблема: Hot reload не работает

**Решение:**
```yaml
# В docker-compose.yml добавь
environment:
  - WATCHPACK_POLLING=true
  - CHOKIDAR_USEPOLLING=true
```

### Проблема: "Cannot find module" после restart

**Причина:** Новые зависимости добавлены, но build не был вызван.

**Решение:**
```bash
# Сделать полный rebuild
cd /opt/linkify-dev
docker compose build app-dev
docker compose up -d app-dev
```

---

## Дополнительные оптимизации

### Включить BuildKit (ускорение на 30-40%)

```bash
# В /etc/docker/daemon.json
{
  "features": {
    "buildkit": true
  }
}

sudo systemctl restart docker
```

### Использовать pnpm вместо npm

В Dockerfile:
```dockerfile
RUN npm install -g pnpm
RUN pnpm install --frozen-lockfile  # Быстрее на 2-3x
```

---

## Итоги

✅ **5-10 секунд** вместо 5-7 минут для изменений кода  
✅ Автоматическая проверка изменений  
✅ Кэширование Docker layers  
✅ Volume mounting для development  
✅ Multi-stage build для меньшего размера образа  

Подробности: `OPTIMIZATION.md`
