#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "release_selector"

def read_json(path, label)
  unless File.file?(path) && !File.symlink?(path)
    raise HiveLiveAgentProof::Error, "#{label} is not a regular JSON file"
  end

  JSON.parse(File.read(path))
rescue JSON::ParserError => e
  raise HiveLiveAgentProof::Error, "#{label} is invalid JSON: #{e.message}"
end

begin
  command = ARGV.shift
  result = case command
  when "check"
    abort "usage: select_release_proof.rb check CANDIDATE_SHA REPOSITORY CHECKS_JSON" unless ARGV.length == 3
    candidate_sha, repository, checks_path = ARGV
    HiveLiveAgentProof::ReleaseSelector.new(
      candidate_sha: candidate_sha,
      repository: repository,
      checks: read_json(checks_path, "Check Run response")
    ).check_identity
  when "select"
    unless ARGV.length == 6
      abort "usage: select_release_proof.rb select CANDIDATE_SHA REPOSITORY CHECKS_JSON RUN_JSON JOBS_JSON ARTIFACTS_JSON"
    end
    candidate_sha, repository, checks_path, run_path, jobs_path, artifacts_path = ARGV
    HiveLiveAgentProof::ReleaseSelector.new(
      candidate_sha: candidate_sha,
      repository: repository,
      checks: read_json(checks_path, "Check Run response"),
      run: read_json(run_path, "proof run response"),
      jobs: read_json(jobs_path, "proof jobs response"),
      artifacts: read_json(artifacts_path, "proof artifacts response")
    ).select
  when "digest"
    abort "usage: select_release_proof.rb digest EXPECTED_SHA256 ARCHIVE" unless ARGV.length == 2
    expected, path = ARGV
    { "proof_artifact_digest" => HiveLiveAgentProof::ReleaseArchiveDigest.verify!(expected, path) }
  else
    abort "usage: select_release_proof.rb (check|select|digest) ..."
  end
  puts JSON.generate(result)
rescue HiveLiveAgentProof::Error => e
  warn "release proof selection failed: #{e.message}"
  exit 1
end
