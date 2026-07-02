FROM ruby:3.4-slim

ENV DEBIAN_FRONTEND=noninteractive \
    HOME=/data/home \
    XDG_CONFIG_HOME=/data/config \
    XDG_DATA_HOME=/data/share \
    XDG_STATE_HOME=/data/state \
    XDG_CACHE_HOME=/data/cache \
    HIVEBOX_REPOS_DIR=/data/repos \
    HIVEBOX_WEB_APP_DIR=/app/web \
    RAILS_ENV=production

RUN apt-get update && apt-get install -y --no-install-recommends \
      asciinema build-essential ca-certificates curl ffmpeg git gh jq libyaml-dev nodejs npm tini tmux \
    && rm -rf /var/lib/apt/lists/*

# Agent CLIs in their own early layer: they are the largest download and
# change least often, so a source edit must not re-pull them.
RUN npm install -g @anthropic-ai/claude-code@2.1.118 @openai/codex@0.125.0 @mariozechner/pi@0.70.2

# The box pushes over https only — no SSH keys exist in the container. gh's
# credential helper turns the operator's Agents-page gh login into git push
# auth for every clone under /data/repos.
RUN git config --system credential."https://github.com".helper "!gh auth git-credential"

RUN useradd --create-home --home-dir /data/home --shell /bin/bash hive \
    && mkdir -p /data/home /data/repos /app \
    && chown -R hive:hive /data /app

WORKDIR /app
COPY --chown=hive:hive . /app
RUN bundle install --without development test \
    && gem build hive.gemspec \
    && gem install hive-cli-*.gem

# The hivebox web UI: a Rails app with its own bundle, served by `hive web`.
# Assets precompile at build time (propshaft + importmap — no node build);
# the dummy secret never reaches runtime.
WORKDIR /app/web
RUN bundle install \
    && SECRET_KEY_BASE=assets-build-dummy HIVEBOX_STORAGE_DIR=/tmp/assets-build \
       bin/rails assets:precompile \
    && rm -rf /tmp/assets-build \
    # Build steps run as root; the runtime user needs tmp/ + log/ writable
    # (Rails creates tmp/pids on every server boot).
    && mkdir -p tmp/pids log \
    && chown -R hive:hive /app/web/tmp /app/web/log
WORKDIR /app

COPY packaging/docker/entrypoint.sh /usr/local/bin/hivebox-entrypoint
RUN chmod 0755 /usr/local/bin/hivebox-entrypoint

USER hive
EXPOSE 4567
# deep=1 verifies the daemon child via its pidfile, not just the web tier —
# a crashlooping daemon must surface as an unhealthy container. start-period
# covers the supervisor's restart backoff so a single slow boot doesn't flap.
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s CMD ruby -rnet/http -e 'exit Net::HTTP.get_response(URI("http://127.0.0.1:4567/health?deep=1")).is_a?(Net::HTTPSuccess) ? 0 : 1'
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/hivebox-entrypoint"]
