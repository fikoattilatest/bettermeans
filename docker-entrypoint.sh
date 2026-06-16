#!/bin/bash
set -e

# NOTE: all inline Ruby below MUST use 1.8.7 syntax (hash-rockets, no `key:`).
# DB connection prefers DATABASE_URL (Railway) and falls back to PG* (local).
pg_connect_rb="ENV['DATABASE_URL'].to_s != '' ? PG.connect(ENV['DATABASE_URL']) : PG.connect(:host => ENV['PGHOST'], :port => (ENV['PGPORT'] || 5432).to_i, :user => ENV['PGUSER'], :password => ENV['PGPASSWORD'], :dbname => ENV['PGDATABASE'])"

# One-time network diagnostics so a failed connection is debuggable from logs.
echo "=== DB connection diagnostics ==="
echo "DATABASE_URL set: $([ -n "$DATABASE_URL" ] && echo yes || echo no)"
echo "PGHOST=$PGHOST PGPORT=$PGPORT PGUSER=$PGUSER PGDATABASE=$PGDATABASE"
echo "Resolving $PGHOST ..."
getent hosts "$PGHOST" || echo "  (getent could not resolve $PGHOST)"
echo "================================="

# Wait for the database to be ready. Bounded loop: surface the real error and
# give up after ~2 min so the failure is visible rather than an endless retry.
echo "Waiting for PostgreSQL..."
attempt=0
max_attempts=60
until bundle exec ruby -e "require 'pg'; ($pg_connect_rb)"; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge "$max_attempts" ]; then
    echo "ERROR: could not connect to PostgreSQL after $max_attempts attempts."
    echo "Final resolution check for $PGHOST:"
    getent hosts "$PGHOST" || echo "  (still cannot resolve $PGHOST)"
    exit 1
  fi
  echo "  ...retrying ($attempt/$max_attempts)"
  sleep 2
done
echo "PostgreSQL is ready."

# Create the database if it does not exist yet (idempotent).
bundle exec rake db:create RAILS_ENV=production 2>/dev/null || true

# On a fresh DB (no users table) load the schema and seed; otherwise do nothing.
if bundle exec ruby -e "
  require 'pg'
  conn = $pg_connect_rb
  exit(conn.exec(\"SELECT COUNT(*) FROM information_schema.tables WHERE table_name='users'\").getvalue(0,0).to_i == 0 ? 0 : 1)
" 2>/dev/null; then
  echo "Fresh database — loading schema (db:schema:load, per schema.rb guidance)..."
  bundle exec rake db:schema:load RAILS_ENV=production
  echo "Seeding default data..."
  bundle exec rake db:seed RAILS_ENV=production || echo "(seeding failed or partial — continuing)"
else
  # db:migrate is intentionally NOT run: schema.rb already pins the DB to the
  # latest migration (20110330041648), and Rails 2.3's PG adapter aborts
  # db:migrate with "schema_migrations already exists" once the table is present.
  echo "Existing database — schema is at the frozen version; nothing to migrate."
fi

exec "$@"
