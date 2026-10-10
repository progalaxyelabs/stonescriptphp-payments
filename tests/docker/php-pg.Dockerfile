# php:8.3-cli plus the pgsql PDO driver, for the real-SQL PHP tests:
#   docker build -t payments-php-pg -f tests/docker/php-pg.Dockerfile tests/docker
FROM php:8.3-cli
RUN apt-get update && apt-get install -y --no-install-recommends libpq-dev \
    && docker-php-ext-install pdo_pgsql pgsql \
    && rm -rf /var/lib/apt/lists/*
