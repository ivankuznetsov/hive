#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "proof"

abort "usage: verify.rb PROOF_DIR CANDIDATE_SHA WORKFLOW_REVISION REPOSITORY RUN_ID RUN_ATTEMPT ATTESTATION_SHA256" unless ARGV.length == 7

begin
  result = HiveLiveAgentProof::Verifier.new(
    proof_dir: ARGV[0], candidate_sha: ARGV[1], workflow_revision: ARGV[2], repository: ARGV[3],
    run_id: ARGV[4], run_attempt: ARGV[5], attestation_sha256: ARGV[6]
  ).call
  puts JSON.generate(result)
rescue HiveLiveAgentProof::Error, KeyError => e
  warn "live-agent release proof failed: #{e.message}"
  exit 1
end
