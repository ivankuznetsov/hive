#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require_relative "release_selector"
require_relative "remote_identity"

def read_json(path, label)
  stat = File.lstat(path)
  raise HiveReleaseCandidate::Error, "#{label} is not a regular file" unless
    stat.file? && !stat.symlink? && stat.nlink == 1 && stat.uid == Process.uid

  JSON.parse(File.binread(path))
rescue Errno::ENOENT, Errno::EACCES, JSON::ParserError => e
  raise HiveReleaseCandidate::Error, "cannot read #{label}: #{e.message}"
end

begin
  command = ARGV.shift
  result = case command
  when "check"
    unless ARGV.length == 4
      raise HiveReleaseCandidate::UsageError,
            "usage: select_release_candidate.rb check SHA REPOSITORY VERSION CHECKS"
    end
    sha, repository, version, checks = ARGV
    HiveReleaseCandidate::ReleaseSelector.new(
      candidate_sha: sha, repository: repository, tag_version: version,
      checks: read_json(checks, "checks"), run: nil, jobs: nil, artifacts: nil
    ).check_identity
  when "select"
    unless ARGV.length == 7
      raise HiveReleaseCandidate::UsageError,
            "usage: select_release_candidate.rb select SHA REPOSITORY VERSION CHECKS RUN JOBS ARTIFACTS"
    end
    sha, repository, version, checks, run, jobs, artifacts = ARGV
    HiveReleaseCandidate::ReleaseSelector.new(
      candidate_sha: sha, repository: repository, tag_version: version,
      checks: read_json(checks, "checks"),
      run: read_json(run, "candidate run"),
      jobs: read_json(jobs, "candidate jobs"),
      artifacts: read_json(artifacts, "candidate artifacts")
    ).select
  when "verify"
    unless ARGV.length == 13
      raise HiveReleaseCandidate::UsageError,
            "usage: select_release_candidate.rb verify SHA REPOSITORY VERSION CHECKS RUN JOBS ARTIFACTS SELECTION EVIDENCE PRODUCER_RUN PRODUCER_ARTIFACT ORDINARY_RUN ACTION_LOCK"
    end
    sha, repository, version, checks, run, jobs, artifacts, selection,
      evidence, producer_run, producer_artifact, ordinary_run, action_lock = ARGV
    selector = HiveReleaseCandidate::ReleaseSelector.new(
      candidate_sha: sha, repository: repository, tag_version: version,
      checks: read_json(checks, "checks"),
      run: read_json(run, "candidate run"),
      jobs: read_json(jobs, "candidate jobs"),
      artifacts: read_json(artifacts, "candidate artifacts")
    )
    selector.verify(
      selection: read_json(selection, "candidate selection"),
      evidence: read_json(evidence, "terminal evidence"),
      producer_run: read_json(producer_run, "artifact producer run"),
      producer_artifact: read_json(producer_artifact, "candidate artifact"),
      ordinary_ci_run: read_json(ordinary_run, "ordinary CI run"),
      expected_action_lock_sha256: action_lock
    )
  when "digest"
    unless ARGV.length == 2
      raise HiveReleaseCandidate::UsageError,
            "usage: select_release_candidate.rb digest EXPECTED ARCHIVE"
    end
    { "digest" => HiveReleaseCandidate::ReleaseArchive.verify_digest!(*ARGV) }
  when "extract"
    unless ARGV.length == 2
      raise HiveReleaseCandidate::UsageError,
            "usage: select_release_candidate.rb extract ARCHIVE DESTINATION"
    end
    { "destination" => HiveReleaseCandidate::ReleaseArchive.extract_zip!(*ARGV) }
  when "candidate"
    unless ARGV.length == 4
      raise HiveReleaseCandidate::UsageError,
            "usage: select_release_candidate.rb candidate REPO_ROOT CANDIDATE_DIR SHA VERSION"
    end
    repo_root, candidate_dir, sha, version = ARGV
    HiveReleaseCandidate::ReleaseCandidateVerifier.new.call(
      repo_root: repo_root, candidate_dir: candidate_dir,
      candidate_sha: sha, tag_version: version
    )
  when "publication"
    unless ARGV.length == 3
      raise HiveReleaseCandidate::UsageError,
            "usage: select_release_candidate.rb publication SELECTED_ROOT SHA VERSION"
    end
    selected_root, sha, version = ARGV
    HiveReleaseCandidate::ReleasePublicationVerifier.new.call(
      selected_root: selected_root, candidate_sha: sha, tag_version: version
    )
  when "action-lock"
    unless ARGV.length.even? && !ARGV.empty?
      raise HiveReleaseCandidate::UsageError,
            "usage: select_release_candidate.rb action-lock WORKFLOW_PATH LOCAL_FILE [...]"
    end
    sources = ARGV.each_slice(2).to_h do |workflow_path, local_file|
      [ workflow_path, File.binread(local_file) ]
    end
    HiveReleaseCandidate::RemoteIdentity.action_lock(sources)
  else
    raise HiveReleaseCandidate::UsageError,
          "usage: select_release_candidate.rb (check|select|verify|digest|extract|candidate|publication|action-lock) ..."
  end
  puts JSON.generate(result)
rescue HiveReleaseCandidate::Error, KeyError, Errno::ENOENT, Errno::EACCES => e
  warn "release candidate selection failed: #{e.message}"
  exit(e.respond_to?(:exit_code) ? e.exit_code : 78)
end
