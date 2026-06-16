# =============================================================================
# BetterMeans - Ruby 1.8.7-p370 + Rails 2.3.14
#
# Uses debian:jessie (archive repos) — the last Debian release with OpenSSL 1.0,
# which is required to compile Ruby 1.8.7 from source.
# =============================================================================

FROM debian:jessie

# Point to archive.debian.org since jessie is EOL, and disable the
# Valid-Until check (jessie's archived Release files are long expired).
RUN sed -i 's|http://deb.debian.org|http://archive.debian.org|g' /etc/apt/sources.list && \
    sed -i 's|http://security.debian.org|http://archive.debian.org|g' /etc/apt/sources.list && \
    sed -i '/jessie-updates/d' /etc/apt/sources.list && \
    printf 'Acquire::Check-Valid-Until "false";\nAPT::Get::AllowUnauthenticated "true";\n' > /etc/apt/apt.conf.d/99archive

# --force-yes: jessie's signing keys are expired, so packages can't be
# authenticated. Allowed deliberately for this archived, pinned distro.
RUN apt-get update && apt-get install -y --force-yes --no-install-recommends \
    build-essential \
    curl \
    wget \
    git \
    # Ruby build deps
    libssl-dev \
    libreadline-dev \
    zlib1g-dev \
    # PostgreSQL client lib (production DB)
    libpq-dev \
    # MySQL client lib (kept in case mysql2 gem resolves)
    libmysqlclient-dev \
    # ImageMagick for fleximage gem
    imagemagick \
    libmagickwand-dev \
    libmagickcore-dev \
    # Misc
    libxml2-dev \
    libxslt1-dev \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Compile Ruby 1.8.7-p370 from source
# ---------------------------------------------------------------------------
ENV RUBY_VERSION=1.8.7-p370
RUN wget -q "https://cache.ruby-lang.org/pub/ruby/1.8/ruby-${RUBY_VERSION}.tar.gz" \
    && tar xzf "ruby-${RUBY_VERSION}.tar.gz" \
    && cd "ruby-${RUBY_VERSION}" \
    && ./configure --prefix=/usr/local --enable-shared --with-openssl-dir=/usr \
    && make -j"$(nproc)" \
    && make install \
    && cd / \
    && rm -rf "ruby-${RUBY_VERSION}" "ruby-${RUBY_VERSION}.tar.gz"

# ---------------------------------------------------------------------------
# Install RubyGems 1.8.25 + Bundler 1.3.5.
# Ruby 1.8.7 ships NO RubyGems, so it must be installed from source before the
# `gem` command exists. Everything is fetched with wget/curl (modern TLS+SNI)
# because Ruby 1.8.7's own Net::HTTP cannot negotiate TLS with rubygems.org.
# ---------------------------------------------------------------------------
RUN wget --no-check-certificate -q "https://rubygems.org/rubygems/rubygems-1.8.25.tgz" \
    && tar xzf rubygems-1.8.25.tgz \
    && (cd rubygems-1.8.25 && ruby setup.rb --no-ri --no-rdoc) \
    && rm -rf rubygems-1.8.25 rubygems-1.8.25.tgz \
    && wget --no-check-certificate -q "https://rubygems.org/downloads/bundler-1.3.5.gem" \
    && gem install --local bundler-1.3.5.gem --no-rdoc --no-ri \
    && rm -f bundler-1.3.5.gem

# ---------------------------------------------------------------------------
# Application
# ---------------------------------------------------------------------------
ENV RAILS_ENV=production \
    RACK_ENV=production

WORKDIR /app

# Install gems first (layer-cached until Gemfile changes).
COPY Gemfile Gemfile.lock ./

# Pre-fetch every locked rubygems.org gem into vendor/cache with curl (it does
# the TLS+SNI that Ruby 1.8.7 can't), so the offline bundle install below never
# has to reach rubygems.org. The lone git gem (comma) is skipped here and gets
# cloned by bundler via git, which uses libcurl and works fine.
RUN mkdir -p vendor/cache \
    && grep -E '^    [a-zA-Z0-9_.-]+ \([0-9]' Gemfile.lock \
       | grep -vE '^    comma ' \
       | sed -E 's/^    ([a-zA-Z0-9_.-]+) \(([^)]+)\).*/\1 \2/' \
       | while read name version; do \
           echo "caching ${name}-${version}.gem"; \
           curl -fsSLk --retry 3 -o "vendor/cache/${name}-${version}.gem" \
             "https://rubygems.org/downloads/${name}-${version}.gem" \
             || echo "  skip ${name}-${version} (excluded group or unavailable)"; \
         done

# RMagick 2.13.1 needs `Magick-config` on PATH AND unversioned ImageMagick libs
# (-lMagickCore / -lMagickWand / -lMagick++). Debian's IM6 hides the config
# scripts under a versioned libdir and names its libs *-6.Q16.so, so expose both:
#   1. symlink the *-config scripts into /usr/bin (NOT /usr/local — that sits next
#      to Ruby and makes RMagick mis-detect a "partial installation").
#   2. add unversioned .so symlinks next to the versioned libs.
RUN set -e; \
    ln -sf /usr/lib/*/ImageMagick-*/bin-Q16/*-config /usr/bin/; \
    for libdir in /usr/lib/*/; do \
      for base in libMagickCore libMagickWand libMagick++; do \
        v="$(ls ${libdir}${base}-*.so 2>/dev/null | head -n1 || true)"; \
        if [ -n "$v" ]; then ln -sf "$v" "${libdir}${base}.so"; fi; \
      done; \
    done; \
    ldconfig; \
    Magick-config --version

# test + development groups are excluded, so only pg (in :production) and the
# default-group gems install — no mysql2/sqlite3/ruby-debug native compiles.
RUN bundle install --deployment --without test development

# Rails 2.3's PG adapter hardcodes client_min_messages='panic' in
# set_standard_conforming_strings (run on every connection). PostgreSQL 9.6+
# removed that value, so every connection raises on modern Postgres (Railway
# runs 13+). Patch the gem source directly so it's correct as loaded — no
# initializer load-order to get wrong. Build fails loudly if the line moves.
RUN set -e; \
    f="$(find /app/vendor/bundle -path '*activerecord-2.3.14/lib/active_record/connection_adapters/postgresql_adapter.rb' | head -n1)"; \
    test -n "$f"; \
    grep -q "client_min_messages, 'panic'" "$f"; \
    sed -i "s/client_min_messages, 'panic'/client_min_messages, 'warning'/" "$f"; \
    grep -q "client_min_messages, 'warning'" "$f"; \
    echo "Patched panic->warning in $f"

COPY . .

# Provide a database.yml driven by env vars.
COPY config/database.yml.railway config/database.yml

COPY docker-entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 3000

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
# Shell form so ${PORT} (injected by Railway) is expanded at runtime; defaults
# to 3000 for local docker-compose where PORT is unset.
CMD bundle exec ruby script/server -e production -p ${PORT:-3000} -b 0.0.0.0
