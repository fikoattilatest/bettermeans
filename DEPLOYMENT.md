# BetterMeans — Deployment & Compatibility Guide

BetterMeans is a ~2012 Redmine fork running on **Ruby 1.8.7-p370 / Rails 2.3.14**.
Getting it to run in 2026 means rebuilding a toolchain that predates almost
everything modern (TLS SNI, RubyGems-by-default, modern PostgreSQL). This file
records *why* each fix exists and gives a repeatable deploy procedure.

Live deploy: https://web-production-106ed.up.railway.app/login — login `admin` / `adminadmin`.

---

## 1. The core lesson

**Match the app's contemporary infrastructure instead of patching the app to fit
modern infrastructure.** The single most important decision was using
**PostgreSQL 9.6** (the version this code expects) rather than a modern Postgres.
Modern PG (12/13/18) breaks Rails 2.3 in a *series* of small ways
(`client_min_messages='panic'`, `pg_attrdef.adsrc`, scram-sha-256 auth, …); each
patch just revealed the next failure. Switching the DB engine to 9.6 fixed the
whole class at once.

Secondary lessons:
- **Don't hide errors.** The deploy was stuck for hours because the entrypoint
  did `... 2>/dev/null`. Surfacing the real error solved each step in minutes.
- **`config/initializers` is too late to monkeypatch the DB adapter** — a plugin
  opens the first DB connection during `load_plugins`, *before* initializers run.
  Patch the gem source at build time instead.

---

## 2. Why the old code is hard to run

| Constraint | Consequence |
|---|---|
| Ruby 1.8.7 needs OpenSSL 1.0 | Must build on `debian:jessie` (last Debian with OpenSSL 1.0) |
| Ruby 1.8.7 can't be built natively on Windows | Everything runs in a Linux container |
| Ruby 1.8.7 ships **no RubyGems** | Install RubyGems 1.8.25 from source |
| Ruby 1.8.7 `Net::HTTP` has **no SNI** | Can't reach `rubygems.org`; pre-fetch gems with `curl` into `vendor/cache`, then bundle offline |
| jessie apt repos are archived / keys expired | `Check-Valid-Until=false`, `AllowUnauthenticated`, `--force-yes` |
| `pg` gem 0.14.1 links jessie libpq 9.4 (md5 only) | DB must use md5 auth → Postgres ≤ 9.6 (PG10+ defaults to scram-sha-256) |
| Rails 2.3 predates PG 10–13 | Hardcoded `client_min_messages='panic'` and `pg_attrdef.adsrc` break on modern PG |

---

## 3. All changes & fixes (what lives in the repo)

### Build (`Dockerfile`)
- Base `debian:jessie`; rewrite apt sources to `archive.debian.org`; add
  `Acquire::Check-Valid-Until "false"` + `APT::Get::AllowUnauthenticated "true"`;
  install with `--force-yes`.
- Compile **Ruby 1.8.7-p370** from `cache.ruby-lang.org`.
- Install **RubyGems 1.8.25** from source and **Bundler 1.3.5** from a local `.gem`.
- **Offline gems:** `grep` the gem list out of `Gemfile.lock` and `curl` each into
  `vendor/cache`, then `bundle install --deployment --without test development`
  (Bundler 1.3.5 has no `--jobs`).
- **RMagick 2.13.1** fix: symlink `*-config` scripts into `/usr/bin` and create
  unversioned `libMagickCore/Wand/++.so` symlinks, then `ldconfig`. (RMagick
  **2.13.4 does NOT work** on Ruby 1.8.7 — its `extconf.rb` uses 1.9 named-capture
  regex.)
- **PG-adapter patch:** `sed` the installed `activerecord-2.3.14`
  `postgresql_adapter.rb` to change `client_min_messages 'panic'` → `'warning'`
  (build fails loudly if the line moves). Belt-and-suspenders; only matters if run
  against PG 9.6+.
- `COPY config/database.yml.railway config/database.yml`.
- `CMD` in **shell form** so Railway's `${PORT}` expands at runtime:
  `bundle exec ruby script/server -e production -p ${PORT:-3000} -b 0.0.0.0`.

### Database config (`config/database.yml.railway` → `database.yml`)
- ERB, env-driven. Prefers `DATABASE_URL`, falls back to
  `PGHOST/PGPORT/PGUSER/PGPASSWORD/PGDATABASE`.
- `adapter: postgresql`, `min_messages: warning`.

### Entrypoint (`docker-entrypoint.sh`)
- All inline Ruby is **1.8.7-safe** (hash-rockets `:k => v`, never `k:`).
- Waits for Postgres with a **bounded** retry loop that **prints the real error**
  and a `getent` DNS check (no `2>/dev/null`).
- `rake db:create`; on a fresh DB (no `users` table) runs **`db:schema:load` +
  `db:seed`** — **never `db:migrate`** (Rails 2.3 + PG aborts migrate-from-zero
  with "schema_migrations already exists"; `schema.rb` is already at the latest
  version).

### Application code
- `app/controllers/application_controller.rb`: `require 'ruby-debug'` wrapped in
  `begin/rescue LoadError`; SSL redirect skipped when `DISABLE_SSL` is set.
- `app/models/project.rb`: fleximage uses local `public/fleximages` unless
  `S3_LOGO_BUCKET` is set.
- `config/initializers/aws_s3.rb`: **removed hardcoded AWS keys**; only connects
  if `S3_ACCESS_KEY_ID` / `S3_SECRET_ACCESS_KEY` are present. (Old keys are still
  in git history — rotate them if they were ever real.)
- `Gemfile`: `pg` in `group :production`; `ruby-debug`/`mysql2`/`sqlite3-ruby` in
  `group :development` (so the production image skips their native builds);
  `rmagick` left at 2.13.1.

### Infra-as-config
- `railway.toml`: `[build] builder="dockerfile"`; `[deploy] healthcheckPath="/login"`,
  `healthcheckTimeout=300`, `restartPolicyType="on_failure"`.
- `docker-compose.yml`: local `postgres:9.6` + web build (the local equivalent).
- `.gitattributes`: force **LF** on `*.sh`, `Dockerfile`, compose, `database.yml.railway`,
  `railway.toml` (a CRLF shebang breaks the entrypoint in Linux).

### Railway project settings (NOT in the repo — applied to the Railway project)
- Two services: **`web`** (Dockerfile builder) + **`db`**.
- **`db` image MUST be `postgres:9.6`** (`railway service source connect --image postgres:9.6 --service db`).
- **`db` var `PGDATA=/var/lib/postgresql/data/pgdata`** — a *subdirectory* of the
  volume mount, because the volume root contains `lost+found` and `initdb` refuses
  a non-empty data dir.
- `db` vars: `POSTGRES_USER=bettermeans`, `POSTGRES_PASSWORD=bettermeans`,
  `POSTGRES_DB=bettermeans_production`.
- `web` vars: `PGHOST=db.railway.internal`, `PGPORT=5432`, `PGUSER=bettermeans`,
  `PGPASSWORD=bettermeans`, `PGDATABASE=bettermeans_production`, `DISABLE_SSL=1`,
  `SECRET_TOKEN=<64+ hex>`. **Use the `PG*` vars, NOT `DATABASE_URL`** — pg 0.14.1
  cannot parse a `postgresql://` URI.
- Web→db talks over Railway's **IPv6 private network** (`db.railway.internal`
  resolves to an `fd12:…` AAAA record).

---

## 4. Step-by-step deploy guide (for an agent)

Prereqs: Docker Desktop (WSL2) for local; Railway CLI logged in (`railway login`);
repo cloned. On **Windows**, the Railway CLI mangles `/`-prefixed paths via MSYS —
prefix such commands with `MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'`.

### A. (Optional) Verify locally first
```bash
docker compose up -d --build          # serves http://localhost:3000, admin/adminadmin
docker compose down
```

### B. Create the Railway project + Postgres 9.6
```bash
railway init                          # or: railway link  (to an existing project)

# Create the DB service and force it to Postgres 9.6 (NOT 13+):
railway add --service db --variables "POSTGRES_USER=bettermeans" \
            --variables "POSTGRES_PASSWORD=bettermeans" \
            --variables "POSTGRES_DB=bettermeans_production"
railway service source connect --image postgres:9.6 --service db

# Point PGDATA at a subdir so initdb tolerates the volume's lost+found:
MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' \
  railway variables --set "PGDATA=/var/lib/postgresql/data/pgdata" -s db

# Give db a persistent volume:
railway service link db
MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' \
  railway volume add -m /var/lib/postgresql/data

railway redeploy -s db -y
# Wait until logs show: "database system is ready to accept connections"
railway logs -s db
```

### C. Create + configure the web service
```bash
railway add --service web             # then connect it to this repo OR deploy via CLI
# Set connection + app vars (PG*, not DATABASE_URL):
railway variables -s web \
  --set "PGHOST=db.railway.internal" --set "PGPORT=5432" \
  --set "PGUSER=bettermeans" --set "PGPASSWORD=bettermeans" \
  --set "PGDATABASE=bettermeans_production" \
  --set "DISABLE_SSL=1" \
  --set "SECRET_TOKEN=$(openssl rand -hex 64)"
# Generate a public domain (or use the dashboard):
railway domain
```

### D. Deploy web
```bash
railway up -s web --ci                # builds the Dockerfile and deploys
railway logs -s web                   # watch for the sequence below
```
Expected healthy sequence in the web logs:
```
PostgreSQL is ready.
Fresh database — loading schema (db:schema:load ...)...
Seeding default data...
WEBrick::HTTPServer#start: pid=... port=...
```

### E. Verify
```bash
curl -s -o /dev/null -w "%{http_code}\n" https://<your-domain>/login    # expect 200
```
Then log in with **admin / adminadmin**.

---

## 5. Troubleshooting cheat-sheet

| Symptom in logs | Cause | Fix |
|---|---|---|
| `...retrying` forever, db sees no connections | `DATABASE_URL` URI not parsed by pg 0.14.1, or wrong host | Use `PG*` vars; host is `<dbservice>.railway.internal` |
| `invalid value for parameter "client_min_messages": "panic"` | Modern PG removed `panic` | Use `postgres:9.6` (and/or the Dockerfile `sed` patch) |
| `column d.adsrc does not exist` | PG 12 removed `pg_attrdef.adsrc` | Use `postgres:9.6` |
| `initdb: directory ... is not empty / lost+found` | Volume root used directly as PGDATA | Set `PGDATA=<mount>/pgdata` |
| `password authentication failed` / scram errors | PG10+ scram vs libpq 9.4 md5 | Use `postgres:9.6` (md5) |
| entrypoint "bad interpreter" | CRLF line endings | `.gitattributes` forces LF on `*.sh` |
| RMagick `extconf.rb: undefined (?...) sequence` | rmagick 2.13.4 on Ruby 1.8.7 | Pin rmagick **2.13.1** |
