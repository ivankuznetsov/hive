FROM ruby:3.4-slim

ENV DEBIAN_FRONTEND=noninteractive \
    HOME=/data/home \
    XDG_CONFIG_HOME=/data/config \
    XDG_DATA_HOME=/data/share \
    XDG_STATE_HOME=/data/state \
    XDG_CACHE_HOME=/data/cache \
    HIVEBOX_REPOS_DIR=/data/repos

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential ca-certificates curl git gh jq nodejs npm tini tmux \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --home-dir /data/home --shell /bin/bash hive \
    && mkdir -p /data/home /data/repos /app \
    && chown -R hive:hive /data /app

WORKDIR /app
COPY --chown=hive:hive . /app
RUN bundle install --without development test \
    && gem build hive.gemspec \
    && gem install hive-cli-*.gem

RUN npm install -g @anthropic-ai/claude-code@2.1.118 @openai/codex@0.125.0 @mariozechner/pi@0.70.2

COPY packaging/docker/entrypoint.sh /usr/local/bin/hivebox-entrypoint
RUN chmod 0755 /usr/local/bin/hivebox-entrypoint

USER hive
EXPOSE 4567
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s CMD ruby -rnet/http -e 'exit Net::HTTP.get_response(URI("http://127.0.0.1:4567/health")).is_a?(Net::HTTPSuccess) ? 0 : 1'
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/hivebox-entrypoint"]
