#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require_relative "baseline_cache_materializer"

candidate_sha, cache_root = ARGV
unless ARGV.length == 2
  warn "usage: materialize_baseline_cache.rb CANDIDATE_SHA CACHE_ROOT"
  exit 64
end

begin
  result = HiveReleaseCandidate::BaselineCacheMaterializer.new(
    repo_root: File.expand_path("../..", __dir__),
    cache_root: cache_root,
    candidate_sha: candidate_sha
  ).call
  puts JSON.generate(result)
rescue HiveReleaseCandidate::Error => e
  warn "materialize-baseline-cache: #{e.message}"
  exit e.exit_code
end
