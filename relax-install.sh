#!/usr/bin/env bash
set -euo pipefail

# Relaxed Mastodon local installer (Ubuntu) using Docker from snap.
# Works whether source came from git clone OR ZIP download.
#
# Goal:
#   chmod +x relax-install.sh && ./relax-install.sh
#   -> open https://localhost:8443/explore

APP_DIR="${APP_DIR:-$(pwd)}"
HTTPS_HOST_PORT="${HTTPS_HOST_PORT:-8443}"
HTTP_HOST_PORT="${HTTP_HOST_PORT:-8080}"

DB_NAME="${DB_NAME:-mastodon_development}"
DB_USER="${DB_USER:-mastodon}"
DB_PASS="${DB_PASS:-mastodon}"
LOCAL_DOMAIN="${LOCAL_DOMAIN:-localhost}"

cd "$APP_DIR" 2>/dev/null || { echo "ERROR: APP_DIR not found: $APP_DIR"; exit 1; }

# No .git requirement: support ZIP source
if [[ ! -f "package.json" ]] || [[ ! -f "Gemfile" ]]; then
  echo "ERROR: This folder does not look like Mastodon root (missing package.json or Gemfile): $APP_DIR"
  exit 1
fi

echo "==> [1/10] Install Docker via snap (if needed)"
if ! command -v docker >/dev/null 2>&1; then
  sudo snap install docker
else
  sudo snap install docker || true
fi

echo "==> [2/10] Start Docker service"
sudo snap start docker || true
sudo snap services docker || true
sudo usermod -aG docker "$USER" || true

# same shell may still need sudo docker
DOCKER="docker"
if ! docker info >/dev/null 2>&1; then
  DOCKER="sudo docker"
fi

echo "==> [3/10] Write docker-compose.dev.yml"
cat > docker-compose.dev.yml <<EOF
services:
  db:
    image: postgres:16
    environment:
      POSTGRES_USER: ${DB_USER}
      POSTGRES_PASSWORD: ${DB_PASS}
      POSTGRES_DB: ${DB_NAME}
    volumes:
      - pgdata:/var/lib/postgresql/data
    restart: unless-stopped

  redis:
    image: redis:7-alpine
    restart: unless-stopped

  web:
    image: ghcr.io/mastodon/mastodon:latest
    env_file:
      - .env.production
    depends_on:
      - db
      - redis
    command: bash -lc "bundle exec rails db:prepare && bundle exec puma -C config/puma.rb"
    restart: unless-stopped

  sidekiq:
    image: ghcr.io/mastodon/mastodon:latest
    env_file:
      - .env.production
    depends_on:
      - db
      - redis
    command: bundle exec sidekiq
    restart: unless-stopped

  streaming:
    image: ghcr.io/mastodon/mastodon:latest
    env_file:
      - .env.production
    depends_on:
      - db
      - redis
    command: node ./streaming/index.js
    restart: unless-stopped

  caddy:
    image: caddy:2
    ports:
      - "${HTTPS_HOST_PORT}:443"
      - "${HTTP_HOST_PORT}:80"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    depends_on:
      - web
      - streaming
    restart: unless-stopped

volumes:
  pgdata:
  caddy_data:
  caddy_config:
EOF

echo "==> [4/10] Write Caddyfile"
cat > Caddyfile <<'EOF'
{
  auto_https disable_redirects
}

https://localhost {
  tls internal

  @api path /api/v1/streaming* /api/v1/streaming/* /streaming* /streaming/*
  reverse_proxy @api streaming:4000
  reverse_proxy web:3000
}
EOF

echo "==> [5/10] Write .env.production.example"
cat > .env.production.example <<EOF
LOCAL_DOMAIN=${LOCAL_DOMAIN}

SECRET_KEY_BASE=replace_me
OTP_SECRET=replace_me
ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=replace_me
ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=replace_me
ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=replace_me

DB_HOST=db
DB_PORT=5432
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASS=${DB_PASS}

REDIS_HOST=redis
REDIS_PORT=6379

RAILS_ENV=production
NODE_ENV=production
EOF

echo "==> [6/10] Ensure .env.production exists"
if [[ ! -f .env.production ]]; then
  cp .env.production.example .env.production
fi

# fill placeholders if present
if grep -q '^SECRET_KEY_BASE=replace_me' .env.production; then
  sed -i "s|^SECRET_KEY_BASE=.*|SECRET_KEY_BASE=$(openssl rand -hex 64)|" .env.production
fi
if grep -q '^OTP_SECRET=replace_me' .env.production; then
  sed -i "s|^OTP_SECRET=.*|OTP_SECRET=$(openssl rand -hex 64)|" .env.production
fi

# ensure required lines exist
grep -q '^LOCAL_DOMAIN=' .env.production || echo "LOCAL_DOMAIN=${LOCAL_DOMAIN}" >> .env.production
grep -q '^DB_HOST=' .env.production || echo "DB_HOST=db" >> .env.production
grep -q '^DB_PORT=' .env.production || echo "DB_PORT=5432" >> .env.production
grep -q '^DB_NAME=' .env.production || echo "DB_NAME=${DB_NAME}" >> .env.production
grep -q '^DB_USER=' .env.production || echo "DB_USER=${DB_USER}" >> .env.production
grep -q '^DB_PASS=' .env.production || echo "DB_PASS=${DB_PASS}" >> .env.production
grep -q '^REDIS_HOST=' .env.production || echo "REDIS_HOST=redis" >> .env.production
grep -q '^REDIS_PORT=' .env.production || echo "REDIS_PORT=6379" >> .env.production
grep -q '^RAILS_ENV=' .env.production || echo "RAILS_ENV=production" >> .env.production
grep -q '^NODE_ENV=' .env.production || echo "NODE_ENV=production" >> .env.production

echo "==> [7/10] Start db/redis"
$DOCKER compose -f docker-compose.dev.yml up -d db redis

echo "==> [8/10] Generate Active Record encryption keys (if missing)"
need_keys=0
grep -q '^ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=' .env.production || need_keys=1
grep -q '^ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=' .env.production || need_keys=1
grep -q '^ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=' .env.production || need_keys=1
grep -q '^ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=replace_me' .env.production && need_keys=1

if [[ "$need_keys" -eq 1 ]]; then
  ENC_OUT="$($DOCKER compose -f docker-compose.dev.yml run --rm web bundle exec rails db:encryption:init)"
  echo "$ENC_OUT"

  AR_DET="$(echo "$ENC_OUT" | awk -F= '/ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=/{print $2}' | tail -n1)"
  AR_SALT="$(echo "$ENC_OUT" | awk -F= '/ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=/{print $2}' | tail -n1)"
  AR_PRI="$(echo "$ENC_OUT" | awk -F= '/ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=/{print $2}' | tail -n1)"

  [[ -n "$AR_DET" && -n "$AR_SALT" && -n "$AR_PRI" ]] || { echo "ERROR: failed parsing encryption keys"; exit 1; }

  if grep -q '^ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=' .env.production; then
    sed -i "s|^ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=.*|ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=${AR_DET}|" .env.production
  else
    echo "ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=${AR_DET}" >> .env.production
  fi

  if grep -q '^ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=' .env.production; then
    sed -i "s|^ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=.*|ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=${AR_SALT}|" .env.production
  else
    echo "ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=${AR_SALT}" >> .env.production
  fi

  if grep -q '^ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=' .env.production; then
    sed -i "s|^ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=.*|ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=${AR_PRI}|" .env.production
  else
    echo "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=${AR_PRI}" >> .env.production
  fi
fi

echo "==> [9/10] Start full stack"
$DOCKER compose -f docker-compose.dev.yml up -d

echo "==> [10/10] Prepare database"
$DOCKER compose -f docker-compose.dev.yml run --rm web bundle exec rails db:prepare || true

echo
echo "✅ Setup complete."
echo "Open: https://localhost:${HTTPS_HOST_PORT}/explore"
echo
echo "Check status:"
echo "  $DOCKER compose -f docker-compose.dev.yml ps"
echo "  $DOCKER compose -f docker-compose.dev.yml logs -f web"
echo
echo "Security note:"
echo "  - Commit: relax-install.sh, docker-compose.dev.yml, Caddyfile, .env.production.example"
echo "  - Do NOT commit: .env.production"
