#!/usr/bin/env ruby
# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
require "hive"
require "hive/agent_skills/canonical_skill"
require_relative "proof"

abort "usage: verify_candidate.rb CANDIDATE_DIR CANDIDATE_SHA EXPECTED_HIVE_VERSION" unless ARGV.length == 3

begin
  result = HiveLiveAgentProof::CandidateVerifier.new(
    candidate_dir: ARGV[0],
    candidate_sha: ARGV[1],
    expected_hive_version: ARGV[2],
    canonical: Hive::AgentSkills::CanonicalSkill.new
  ).call
  puts JSON.generate(result.slice("gem", "skills", "source", "platforms"))
rescue HiveLiveAgentProof::Error => e
  warn "offline release candidate verification failed: #{e.message}"
  exit 1
end
