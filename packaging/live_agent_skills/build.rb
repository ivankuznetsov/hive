#!/usr/bin/env ruby
# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "hive"
require "hive/agent_skills/canonical_skill"
require_relative "proof"

abort "usage: build.rb CANDIDATE_SHA GEM SOURCE_ARCHIVE OUTPUT_DIR" unless ARGV.length == 4

begin
  manifest = HiveLiveAgentProof::Builder.new(
    candidate_sha: ARGV[0], gem_path: ARGV[1], source_archive: ARGV[2], output_dir: ARGV[3],
    canonical: Hive::AgentSkills::CanonicalSkill.new
  ).call
  puts JSON.generate(manifest)
rescue HiveLiveAgentProof::Error => e
  warn "live-agent artifact build failed: #{e.message}"
  exit 1
end
