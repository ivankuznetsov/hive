#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "proof"

abort "usage: attest.rb CANDIDATE_SHA WORKFLOW_REVISION REPOSITORY RUN_ID RUN_ATTEMPT ARTIFACT_DIR EVIDENCE_DIR CREATOR_EVIDENCE_DIR OUTPUT_DIR" unless ARGV.length == 9

begin
  result = HiveLiveAgentProof::Attestor.new(
    candidate_sha: ARGV[0], workflow_revision: ARGV[1], repository: ARGV[2], run_id: ARGV[3],
    run_attempt: ARGV[4], artifact_dir: ARGV[5], evidence_dir: ARGV[6],
    creator_evidence_dir: ARGV[7], output_dir: ARGV[8]
  ).call
  puts JSON.generate("attestation_sha256" => result.fetch("sha256"), "path" => result.fetch("path"))
rescue HiveLiveAgentProof::Error => e
  warn "live-agent attestation failed: #{e.message}"
  exit 1
end
