FROM ruby:3.4-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      git \
      libffi-dev \
      libyaml-dev \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY Gemfile Gemfile.lock hive.gemspec /app/
COPY lib/hive/version.rb /app/lib/hive/version.rb
COPY components/agent-cli-runtime/agent-cli-runtime.gemspec /app/components/agent-cli-runtime/
COPY components/agent-cli-runtime/lib /app/components/agent-cli-runtime/lib
RUN bundle install --jobs 4
COPY . /app

ENV HIVE_SKIP_LLM_WIKI_SCHEDULER=1 \
    HIVE_SKIP_LLM_WIKI_SYSTEMCTL=1 \
    HIVE_SKIP_LLM_WIKI_POST_COMMIT=1
