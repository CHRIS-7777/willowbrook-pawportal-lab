FROM ruby:3.2-slim-bookworm

RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential default-libmysqlclient-dev pkg-config \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY app/Gemfile ./
RUN bundle config set --local without 'development test' \
 && bundle install --jobs 4

COPY app/ ./
RUN useradd -u 1001 -m -s /bin/sh wbapp \
 && mkdir -p /app/log /app/public/uploads/pets /tmp/exports \
 && cp /app/data/portal.log.seed /app/log/portal.log \
 && chown -R wbapp:wbapp /app/log /app/public/uploads /tmp/exports

USER wbapp
ENV RACK_ENV=production PORT=8080
EXPOSE 8080
CMD ["bundle", "exec", "puma", "-b", "tcp://0.0.0.0:8080", "-t", "4:16", "-e", "production", "config.ru"]
