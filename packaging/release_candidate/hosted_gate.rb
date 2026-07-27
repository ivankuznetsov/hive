# frozen_string_literal: true

require "digest"
require "json"
require_relative "remote_identity"

module HiveReleaseCandidate
  class HostedGate
    RECEIPT_SCHEMA = "hive-release-candidate-gate-receipt"

    def call(name:, repository:, candidate_sha:, workflow_sha:, run_id:, run_attempt:,
             producer_run_id:, producer_run_attempt:, action_lock_sha256:,
             artifact_id:, artifact_digest:, request_id:, candidate_dir:,
             run_payload:, artifact_payload:)
      identity = RemoteIdentity.new(
        repository: repository, candidate_sha: candidate_sha,
        workflow_sha: workflow_sha, action_lock_sha256: action_lock_sha256
      )
      current_run_id = positive_integer(run_id, "current run ID")
      current_attempt = positive_integer(run_attempt, "current run attempt")
      producer_id = positive_integer(producer_run_id, "producer run ID")
      producer_attempt = positive_integer(producer_run_attempt, "producer run attempt")
      artifact = identity.verify_artifact!(
        artifact: artifact_payload, run_id: producer_id, run_attempt: producer_attempt
      )
      unless artifact.fetch("artifact_id") == positive_integer(artifact_id, "artifact ID") &&
             artifact.fetch("artifact_digest") == artifact_digest
        raise Error, "candidate artifact identity does not match the gate inputs"
      end

      normalized_run = normalize_run(run_payload)
      producer_request = request_id_from(normalized_run, candidate_sha)
      identity.verify_run!(
        run: normalized_run, request_id: producer_request,
        expected_attempt: producer_attempt
      )
      manifest = verify_manifest(candidate_dir, candidate_sha)
      filenames = expected_filenames(manifest)
      unless manifest.fetch("files").keys.sort == filenames.sort
        raise Error, "candidate manifest filenames do not match the exact expected set"
      end

      {
        "schema" => RECEIPT_SCHEMA,
        "schema_version" => SCHEMA_VERSION,
        "name" => name,
        "repository" => repository,
        "request_id" => request_id,
        "candidate_sha" => candidate_sha,
        "workflow_sha" => workflow_sha,
        "workflow_path" => RemoteIdentity::WORKFLOW_PATH,
        "run_id" => current_run_id,
        "run_attempt" => current_attempt,
        "producer_request_id" => producer_request,
        "producer_run_id" => producer_id,
        "producer_run_attempt" => producer_attempt,
        "action_lock_sha256" => action_lock_sha256,
        "artifact_id" => artifact.fetch("artifact_id"),
        "artifact_digest" => artifact.fetch("artifact_digest"),
        "artifact_name" => artifact.fetch("artifact_name"),
        "manifest_sha256" => Digest::SHA256.file(
          File.join(candidate_dir, "manifest.json")
        ).hexdigest,
        "manifest_filenames" => filenames
      }
    end

    private

    def normalize_run(run)
      return run unless run.is_a?(Hash) && run.key?("display_title")

      run.merge("name" => run["display_title"])
    end

    def request_id_from(run, candidate_sha)
      name = run.is_a?(Hash) ? run["name"].to_s : ""
      match = /\A#{Regexp.escape(RemoteIdentity::RUN_NAME_PREFIX)}(?<request>req-[a-z0-9]{6,48}):#{Regexp.escape(candidate_sha)}\z/.match(name)
      raise Error, "producer run-name is not bound to the candidate SHA" unless match

      match[:request]
    end

    def expected_filenames(manifest)
      version = manifest.fetch("hive_version")
      sha = manifest.fetch("candidate_sha")
      [
        "hive-cli-#{version}.gem",
        "hive-source-#{sha}.tar.gz",
        "hive-agent-skills-#{sha}.tar.gz",
        "hive-web-#{version}.tar.gz"
      ]
    end

    def verify_manifest(directory, candidate_sha)
      manifest_path = File.join(directory, "manifest.json")
      manifest = JSON.parse(File.binread(manifest_path))
      unless manifest.is_a?(Hash) &&
             manifest.keys.sort == %w[
               builder_revision candidate_sha canonical_digest files hive_version
               schema schema_version skill_version
             ].sort &&
             manifest["schema"] == "hive-release-candidate-artifacts" &&
             manifest["schema_version"] == SCHEMA_VERSION &&
             manifest["candidate_sha"] == candidate_sha &&
             manifest["files"].is_a?(Hash) &&
             manifest["files"].values.map { |row| row["kind"] }.sort ==
               %w[gem skills source web]
        raise Error, "candidate manifest identity is invalid"
      end
      expected = expected_filenames(manifest)
      unless manifest["files"].keys.sort == expected.sort &&
             Dir.children(directory).sort == (expected + [ "manifest.json" ]).sort
        raise Error, "candidate artifact filename set is invalid"
      end
      manifest["files"].each do |name, row|
        path = File.join(directory, name)
        stat = File.lstat(path)
        unless File.basename(name) == name && stat.file? && !stat.symlink? &&
               row.is_a?(Hash) && row["size"] == stat.size &&
               %w[gem skills source web].include?(row["kind"]) &&
               row["sha256"].to_s.match?(/\A[0-9a-f]{64}\z/) &&
               Digest::SHA256.file(path).hexdigest == row["sha256"]
          raise Error, "candidate artifact bytes are invalid: #{name}"
        end
      end
      manifest
    rescue Errno::ENOENT, JSON::ParserError => e
      raise Error, "cannot verify candidate manifest: #{e.message}"
    end

    def positive_integer(value, label)
      integer = value.is_a?(Integer) ? value : Integer(value, 10)
      raise Error, "#{label} must be positive" unless integer.positive?

      integer
    rescue ArgumentError, TypeError
      raise Error, "#{label} must be positive"
    end
  end
end

if $PROGRAM_NAME == __FILE__
  unless ARGV.length == 4
    warn "usage: ruby packaging/release_candidate/hosted_gate.rb RUN_JSON ARTIFACT_JSON CANDIDATE_DIR OUTPUT"
    exit 64
  end
  begin
    run_path, artifact_path, candidate_dir, output_path = ARGV
    result = HiveReleaseCandidate::HostedGate.new.call(
      name: ENV.fetch("GATE_NAME"),
      repository: ENV.fetch("GITHUB_REPOSITORY"),
      candidate_sha: ENV.fetch("CANDIDATE_SHA"),
      workflow_sha: ENV.fetch("WORKFLOW_SHA"),
      run_id: ENV.fetch("GITHUB_RUN_ID"),
      run_attempt: ENV.fetch("GITHUB_RUN_ATTEMPT"),
      producer_run_id: ENV.fetch("PRODUCER_RUN_ID"),
      producer_run_attempt: ENV.fetch("PRODUCER_RUN_ATTEMPT"),
      action_lock_sha256: ENV.fetch("ACTION_LOCK_SHA256"),
      artifact_id: ENV.fetch("ARTIFACT_ID"),
      artifact_digest: ENV.fetch("ARTIFACT_DIGEST"),
      request_id: ENV.fetch("REQUEST_ID"),
      candidate_dir: candidate_dir,
      run_payload: JSON.parse(File.binread(run_path)),
      artifact_payload: JSON.parse(File.binread(artifact_path))
    )
    File.open(output_path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
      file.write("#{JSON.pretty_generate(result)}\n")
    end
  rescue HiveReleaseCandidate::Error, JSON::ParserError, KeyError, Errno::EEXIST => e
    warn "hosted-gate: #{e.message}"
    exit 78
  end
end
