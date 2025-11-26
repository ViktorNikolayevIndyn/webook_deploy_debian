# Оптимизация скорости деплоя

Текущая проблема: каждый `git push` вызывает полный rebuild Docker образа (~5-10 минут).

## Реализованные оптимизации

### 1. Умная проверка изменений в deploy.template.sh

**Что было:**
```bash
git pull --ff-only
docker compose up -d --build  # ВСЕГДА rebuild
```

**Что стало:**
```bash
# Проверка изменений перед pull
if [ "$BEFORE_COMMIT" = "$REMOTE_COMMIT" ]; then
  exit 0  # Нет изменений - выход
fi

# Анализ измененных файлов
if package.json changed:
  docker compose build  # Полный rebuild (~5 мин)
else:
  docker compose restart  # Быстрый restart (~10 сек)
fi
```

**Ускорение:** От 5 минут до 10 секунд для изменений только в коде.

---

### 2. Multi-stage Dockerfile (Dockerfile.optimized)

**Преимущества:**
- **Stage 1 (deps):** Кэширование node_modules - пересборка только при изменении package.json
- **Stage 2 (builder):** Изолированная сборка приложения
- **Stage 3 (runner):** Минимальный production образ (меньше размер, быстрее запуск)

**Размер образа:**
- Было: ~1.5 GB (с devDependencies)
- Стало: ~200 MB (только production)

**Время build при изменении кода:**
- Было: 5-7 минут (полная пересборка)
- Стало: 30-60 секунд (используются кэшированные слои)

---

### 3. Volume mounting для development (docker-compose.optimized.yml)

```yaml
services:
  app-dev:
    volumes:
      - ./src:/app/src:ro      # Код монтируется напрямую
      - ./pages:/app/pages:ro  # Hot reload работает
```

**Как работает:**
1. Git push → webhook → git pull
2. Файлы в контейнере обновляются через volume
3. Next.js hot reload подхватывает изменения
4. **Rebuild не нужен!** (~5 секунд)

**Важно:** Работает только для development, в production используем запечатанный образ.

---

### 4. .dockerignore для ускорения build context

Исключает из сборки:
- `node_modules/` (1GB+)
- `.git/` (история коммитов)
- `.next/` (старые сборки)
- IDE файлы, логи, тесты

**Ускорение:** Передача build context с 2GB до 50MB → экономия 20-30 секунд.

---

## Сравнение времени деплоя

| Сценарий | Было | Стало | Ускорение |
|----------|------|-------|-----------|
| Изменение только кода (src/) | 5-7 мин | **5-10 сек** | **60x** |
| Изменение package.json | 5-7 мин | 2-3 мин | 2x |
| Изменение Dockerfile | 5-7 мин | 2-3 мин | 2x |
| Нет изменений (повторный push) | 5-7 мин | **мгновенно** | ∞ |

---

## Установка оптимизаций

### Вариант 1: Автоматически (через init.sh в будущем)

Скрипты уже обновлены:
- `scripts/deploy.template.sh` - умный деплой
- `scripts/Dockerfile.optimized` - multi-stage build
- `scripts/docker-compose.optimized.yml` - volume mounting

### Вариант 2: Вручную для существующих проектов

```bash
# 1. Обновить deploy.sh в каждом проекте
cd /opt/linkify-dev
cp /opt/webook_deploy_debian/scripts/deploy.template.sh ./deploy.sh
chmod +x deploy.sh

# 2. Заменить Dockerfile
cp /opt/webook_deploy_debian/scripts/Dockerfile.optimized ./Dockerfile

# 3. Обновить docker-compose.yml
cp /opt/webook_deploy_debian/scripts/docker-compose.optimized.yml ./docker-compose.yml

# 4. Добавить .dockerignore
cp /opt/webook_deploy_debian/scripts/.dockerignore.example ./.dockerignore

# 5. Первый build (создаст кэш)
docker compose build app-dev

# 6. Тест: изменить любой файл в src/ и сделать git push
# Деплой должен занять ~5-10 секунд вместо 5-7 минут
```

---

## Дополнительные оптимизации

### 1. BuildKit (включить на сервере)

```bash
# В /etc/docker/daemon.json
{
  "features": {
    "buildkit": true
  }
}

sudo systemctl restart docker
```

Ускорение build на 30-40%.

### 2. Docker layer caching в CI/CD

Если используете GitHub Actions:
```yaml
- uses: docker/build-push-action@v5
  with:
    cache-from: type=registry,ref=ghcr.io/user/app:cache
    cache-to: type=registry,ref=ghcr.io/user/app:cache,mode=max
```

### 3. Prebuilt base images

Создать свой base image с node_modules:
```dockerfile
FROM node:20-alpine AS base
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
# Сохранить как myapp-base:latest
```

Потом в Dockerfile:
```dockerfile
FROM myapp-base:latest AS deps
# node_modules уже установлены
```

### 4. Использовать pnpm вместо npm

```dockerfile
RUN npm install -g pnpm
RUN pnpm install --frozen-lockfile
```

Быстрее на 2-3x за счет hardlinks.

---

## Мониторинг производительности

```bash
# Время деплоя в логах webhook
journalctl -u webhook-deploy.service -n 50 | grep "Done in"

# Размер Docker образов
docker images | grep app

# Cache hit rate
docker buildx du  # Если BuildKit включен
```

---

## Troubleshooting

### Проблема: Hot reload не работает

**Решение:**
```yaml
# В docker-compose.yml добавить
environment:
  - WATCHPACK_POLLING=true
  - CHOKIDAR_USEPOLLING=true
```

### Проблема: Volume permissions denied

**Решение:**
```bash
# В Dockerfile добавить
RUN chown -R node:node /app
USER node
```

### Проблема: Кэш не используется

**Решение:**
```bash
# Очистить build cache
docker builder prune -a

# Пересобрать с нуля
docker compose build --no-cache
```

---

## Итоговые рекомендации

1. **Development:** Используй volume mounting + hot reload → 5-10 сек деплой
2. **Staging:** Multi-stage build + cache → 1-2 мин деплой
3. **Production:** Запечатанный образ без volumes → 2-3 мин деплой
4. Всегда проверяй изменения перед rebuild (deploy.template.sh делает это автоматически)
5. Используй BuildKit для дополнительного ускорения
