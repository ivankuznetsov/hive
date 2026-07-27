# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "pathname"
require "rubygems"
require "rubygems/package"
require "zlib"
require_relative "aggregate"
require_relative "artifacts"
require_relative "baseline_catalog"
require_relative "remote_identity"

module HiveReleaseCandidate
  # Pure validation for promoting one trusted remote candidate into a
  # separately-authorized tag release. GitHub API access remains in the
  # workflow; fixtures can exercise the complete identity contract here.
  class ReleaseSelector
    CHECK_NAME = "hive-release-candidate"
    CHECK_EXTERNAL_ID =
      /\Ahive-release-candidate:v1:([1-9][0-9]*):([1-9][0-9]*):([0-9a-f]{64})\z/
    EVIDENCE_ARTIFACT_DIGEST = /\Asha256:[0-9a-f]{64}\z/
    REQUIRED_RUN_JOBS = [
      "Validate protected candidate identity",
      "Candidate artifact identity",
      "Attest closed candidate evidence",
      "Trusted release candidate aggregate"
    ].freeze

    attr_reader :candidate_sha, :repository, :tag_version

    def initialize(candidate_sha:, repository:, tag_version:, checks:, run:, jobs:,
                   artifacts:)
      @candidate_sha = validate_sha(candidate_sha, "tag target")
      @repository = validate_repository(repository)
      @tag_version = validate_version(tag_version, "tag version")
      @checks = checks
      @run = run
      @jobs = jobs
      @artifacts = artifacts
    end

    def select
      check = check_identity
      run_id = check.fetch("evidence_run_id")
      run_attempt = check.fetch("evidence_run_attempt")
      evidence_sha256 = check.fetch("evidence_sha256")

      workflow_revision = validate_run!(
        run_id: run_id, run_attempt: run_attempt
      )
      validate_run_jobs!(run_id: run_id, run_attempt: run_attempt)
      artifact = select_evidence_artifact(
        run_id: run_id, run_attempt: run_attempt,
        workflow_revision: workflow_revision
      )
      {
        "repository" => repository,
        "candidate_sha" => candidate_sha,
        "tag_version" => tag_version,
        "workflow_path" => RemoteIdentity::WORKFLOW_PATH,
        "workflow_revision" => workflow_revision,
        "request_id" => request_id_from(@run),
        "evidence_run_id" => run_id,
        "evidence_run_attempt" => run_attempt,
        "evidence_sha256" => evidence_sha256,
        "evidence_artifact_id" => positive_integer(
          artifact["id"], "evidence artifact ID"
        ),
        "evidence_artifact_name" => artifact["name"],
        "evidence_artifact_digest" => artifact_digest(
          artifact["digest"], "evidence artifact"
        )
      }
    end

    def check_identity
      check = trusted_check
      match = CHECK_EXTERNAL_ID.match(check["external_id"].to_s)
      raise Error, "candidate Check Run external_id is invalid" unless match

      run_id = positive_integer(match[1], "evidence run ID")
      run_attempt = positive_integer(match[2], "evidence run attempt")
      expected_details = "https://github.com/#{repository}/actions/runs/#{run_id}"
      unless check["details_url"] == expected_details
        raise Error, "candidate Check Run details URL is invalid"
      end
      {
        "candidate_sha" => candidate_sha,
        "evidence_run_id" => run_id,
        "evidence_run_attempt" => run_attempt,
        "evidence_sha256" => match[3]
      }
    end

    def verify(selection:, evidence:, producer_run:, producer_artifact:,
               ordinary_ci_run:, expected_action_lock_sha256:)
      validate_selection!(selection)
      action_lock = validate_sha256(
        expected_action_lock_sha256, "expected action lock"
      )
      validate_evidence!(evidence, selection, action_lock)
      validate_producer!(
        producer_run, producer_artifact, evidence.fetch("artifact"),
        workflow_revision: selection.fetch("workflow_revision")
      )
      validate_ordinary_ci!(
        evidence.fetch("ordinary_ci"), ordinary_ci_run
      )

      selection.merge(
        "action_lock_sha256" => action_lock,
        "candidate_artifact_id" => evidence.dig("artifact", "id"),
        "candidate_artifact_name" => evidence.dig("artifact", "name"),
        "candidate_artifact_digest" => evidence.dig("artifact", "digest"),
        "candidate_artifact_producer_run_id" =>
          evidence.dig("artifact", "producer_run_id"),
        "candidate_artifact_producer_run_attempt" =>
          evidence.dig("artifact", "producer_run_attempt"),
        "ordinary_ci" => evidence.fetch("ordinary_ci")
      )
    end

    private

    def trusted_check
      rows = fetch_rows(@checks, "check_runs", "Check Run response")
      matches = rows.select do |check|
        check.is_a?(Hash) &&
          check["name"] == CHECK_NAME &&
          check["head_sha"].to_s.downcase == candidate_sha &&
          check["status"] == "completed" &&
          check["conclusion"] == "success" &&
          check.dig("app", "slug") == "github-actions"
      end
      unless matches.one?
        raise Error, "trusted candidate Check Run is absent or ambiguous"
      end

      matches.first
    end

    def validate_run!(run_id:, run_attempt:)
      raise Error, "candidate workflow run response is invalid" unless @run.is_a?(Hash)

      expected = {
        "id" => run_id,
        "run_attempt" => run_attempt,
        "path" => RemoteIdentity::WORKFLOW_PATH,
        "event" => "workflow_dispatch",
        "head_branch" => "main",
        "status" => "completed",
        "conclusion" => "success"
      }
      valid = expected.all? { |key, value| @run[key] == value } &&
        @run.dig("head_repository", "full_name") == repository
      unless valid
        raise Error,
              "candidate workflow run identity, attempt, branch, repository, or conclusion is invalid"
      end

      request_id_from(@run)
      validate_sha(@run["head_sha"], "workflow revision")
    end

    def validate_run_jobs!(run_id:, run_attempt:)
      rows = fetch_rows(@jobs, "jobs", "workflow jobs response")
      REQUIRED_RUN_JOBS.each do |name|
        matches = rows.select do |job|
          job.is_a?(Hash) && job["name"] == name &&
            job["run_id"] == run_id &&
            job["run_attempt"] == run_attempt &&
            job["status"] == "completed" &&
            job["conclusion"] == "success"
        end
        unless matches.one?
          raise Error, "required release-candidate job did not succeed exactly once: #{name}"
        end
      end
    end

    def select_evidence_artifact(run_id:, run_attempt:, workflow_revision:)
      rows = fetch_rows(@artifacts, "artifacts", "workflow artifacts response")
      name = "hive-release-candidate-evidence-#{run_id}-#{run_attempt}"
      matches = rows.select do |artifact|
        artifact.is_a?(Hash) &&
          artifact["name"] == name &&
          artifact["expired"] == false &&
          artifact.dig("workflow_run", "id") == run_id &&
          artifact.dig("workflow_run", "head_sha") == workflow_revision
      end
      unless matches.one?
        raise Error, "terminal evidence artifact is absent, ambiguous, expired, or substituted"
      end
      artifact_digest(matches.first["digest"], "evidence artifact")
      matches.first
    end

    def validate_selection!(selection)
      unless selection.is_a?(Hash) &&
             selection["repository"] == repository &&
             selection["candidate_sha"] == candidate_sha &&
             selection["tag_version"] == tag_version &&
             selection["workflow_path"] == RemoteIdentity::WORKFLOW_PATH &&
             RemoteIdentity::REQUEST_ID.match?(selection["request_id"].to_s) &&
             positive_integer?(selection["evidence_run_id"]) &&
             positive_integer?(selection["evidence_run_attempt"]) &&
             SAFE_SHA.match?(selection["workflow_revision"].to_s) &&
             /\A[0-9a-f]{64}\z/.match?(selection["evidence_sha256"].to_s) &&
             positive_integer?(selection["evidence_artifact_id"]) &&
             EVIDENCE_ARTIFACT_DIGEST.match?(
               selection["evidence_artifact_digest"].to_s
             )
        raise Error, "preselected candidate evidence identity is invalid"
      end
    end

    def validate_evidence!(evidence, selection, action_lock)
      unless evidence.is_a?(Hash) &&
             evidence["trust_scope"] == "trusted_remote" &&
             evidence["repository"] == repository &&
             evidence["candidate_sha"] == candidate_sha &&
             evidence["workflow_sha"] == selection["workflow_revision"] &&
             evidence["run_id"] == selection["evidence_run_id"] &&
             evidence["run_attempt"] == selection["evidence_run_attempt"] &&
             evidence["request_id"] == selection["request_id"] &&
             evidence["action_lock_sha256"] == action_lock &&
             evidence["scope_status"] == "passed" &&
             evidence["qa_status"] == "qa_ready" &&
             Array(evidence["blockers"]).empty?
        raise Error, "terminal candidate evidence is not trusted, exact, and qa_ready"
      end

      validate_effective_gates!(evidence)
      summary = evidence["summary"]
      required_count = Aggregate::REQUIRED_JOBS.size + 1
      unless summary.is_a?(Hash) &&
             summary["required"] == required_count &&
             summary["passed"] == required_count &&
             summary["failed"] == 0
        raise Error, "terminal candidate evidence summary is incomplete"
      end
      validate_provenance!(evidence)
    end

    def validate_effective_gates!(evidence)
      rows = evidence["effective_gate_set"]
      unless rows.is_a?(Array) &&
             rows.map { |row| row["name"] }.sort == Aggregate::REQUIRED_JOBS.sort &&
             rows.map { |row| row["name"] }.uniq.size == Aggregate::REQUIRED_JOBS.size
        raise Error, "terminal evidence required gate set is incomplete or duplicated"
      end
      artifact = evidence.fetch("artifact")
      rows.each do |row|
        valid = row.is_a?(Hash) &&
          row["status"] == "completed" &&
          row["conclusion"] == "success" &&
          positive_integer?(row["run_id"]) &&
          positive_integer?(row["run_attempt"]) &&
          row["candidate_sha"] == candidate_sha &&
          row["workflow_sha"] == evidence["workflow_sha"] &&
          row["workflow_path"] == RemoteIdentity::WORKFLOW_PATH &&
          row["action_lock_sha256"] == evidence["action_lock_sha256"] &&
          row["artifact_id"] == artifact["id"] &&
          row["artifact_digest"] == artifact["digest"] &&
          row["artifact_producer_run_id"] == artifact["producer_run_id"] &&
          row["artifact_producer_run_attempt"] == artifact["producer_run_attempt"]
        raise Error, "required gate identity is invalid: #{row['name']}" unless valid
      end
    end

    def validate_provenance!(evidence)
      provenance = evidence["provenance"]
      unless provenance.is_a?(Hash) &&
             provenance["run_id"] == evidence["run_id"] &&
             provenance["run_attempt"] == evidence["run_attempt"] &&
             Array(provenance["replacement_gates"]).all? do |name|
               Aggregate::REQUIRED_JOBS.include?(name)
             end
        raise Error, "terminal evidence attempt provenance is invalid"
      end
      replacement_names = Array(provenance["replacement_gates"])
      evidence.fetch("effective_gate_set").each do |row|
        current = replacement_names.include?(row["name"])
        valid = if current
                  row["run_id"] == evidence["run_id"] &&
                    row["run_attempt"] == evidence["run_attempt"]
                else
                  provenance.key?("source_run_id") &&
                    positive_integer?(row["run_id"]) &&
                    positive_integer?(row["run_attempt"])
                end
        raise Error, "effective gate attempt provenance is invalid: #{row['name']}" unless valid
      end
      return unless provenance.key?("source_run_id")

      unless positive_integer?(provenance["source_run_id"]) &&
             positive_integer?(provenance["source_run_attempt"]) &&
             RemoteIdentity::REQUEST_ID.match?(
               provenance["source_request_id"].to_s
             ) &&
             /\A[0-9a-f]{64}\z/.match?(
               provenance["source_evidence_sha256"].to_s
             ) &&
             provenance["selector"].is_a?(Hash)
        raise Error, "terminal evidence retry provenance is invalid"
      end
    end

    def validate_producer!(run, artifact, expected, workflow_revision:)
      unless expected.is_a?(Hash) &&
             positive_integer?(expected["id"]) &&
             EVIDENCE_ARTIFACT_DIGEST.match?(expected["digest"].to_s) &&
             expected["name"] ==
               "hive-release-candidate-#{expected['producer_run_id']}-#{expected['producer_run_attempt']}" &&
             positive_integer?(expected["producer_run_id"]) &&
             positive_integer?(expected["producer_run_attempt"])
        raise Error, "candidate artifact identity in evidence is invalid"
      end
      unless run.is_a?(Hash) &&
             run["id"] == expected["producer_run_id"] &&
             run["run_attempt"] == expected["producer_run_attempt"] &&
             run["head_sha"] == workflow_revision &&
             run["path"] == RemoteIdentity::WORKFLOW_PATH &&
             run["event"] == "workflow_dispatch" &&
             run["head_branch"] == "main" &&
             run["status"] == "completed" &&
             run.dig("head_repository", "full_name") == repository &&
             run["display_title"].to_s.match?(
               /\A#{Regexp.escape(RemoteIdentity::RUN_NAME_PREFIX)}req-[a-z0-9]{6,48}:#{candidate_sha}\z/
             )
        raise Error, "candidate artifact producer run identity is invalid"
      end
      unless artifact.is_a?(Hash) &&
             artifact["id"] == expected["id"] &&
             artifact["name"] == expected["name"] &&
             artifact["digest"] == expected["digest"] &&
             artifact["expired"] == false &&
             artifact.dig("workflow_run", "id") == expected["producer_run_id"] &&
             artifact.dig("workflow_run", "head_sha") == workflow_revision
        raise Error, "candidate artifact is absent, expired, or substituted"
      end
    end

    def validate_ordinary_ci!(ordinary, run)
      unless ordinary.is_a?(Hash) &&
             ordinary["repository"] == repository &&
             ordinary["head_sha"] == candidate_sha &&
             ordinary["workflow"] == Aggregate::ORDINARY_CI_WORKFLOW &&
             ordinary["app"] == "github-actions" &&
             ordinary["check_name"] == Aggregate::ORDINARY_CI_CHECK &&
             positive_integer?(ordinary["run_id"]) &&
             positive_integer?(ordinary["run_attempt"]) &&
             ordinary["status"] == "completed" &&
             ordinary["conclusion"] == "success"
        raise Error, "ordinary CI evidence identity is invalid"
      end
      matches = fetch_rows(@checks, "check_runs", "Check Run response").select do |check|
        check["name"] == Aggregate::ORDINARY_CI_CHECK &&
          check["head_sha"] == candidate_sha &&
          check.dig("app", "slug") == "github-actions" &&
          check["status"] == "completed" &&
          check["conclusion"] == "success" &&
          check["details_url"].to_s.match?(
            %r{\Ahttps://github\.com/#{Regexp.escape(repository)}/actions/runs/#{ordinary['run_id']}(?:/job/[1-9][0-9]*)?\z}
          )
      end
      unless matches.one? &&
             run.is_a?(Hash) &&
             run["id"] == ordinary["run_id"] &&
             run["run_attempt"] == ordinary["run_attempt"] &&
             run["head_sha"] == candidate_sha &&
             run["path"] == Aggregate::ORDINARY_CI_WORKFLOW &&
             run["head_branch"] == "main" &&
             run["status"] == "completed" &&
             run["conclusion"] == "success" &&
             run.dig("head_repository", "full_name") == repository
        raise Error, "ordinary CI run identity could not be reverified"
      end
    end

    def request_id_from(run)
      name = run["display_title"].to_s
      match = /\A#{Regexp.escape(RemoteIdentity::RUN_NAME_PREFIX)}(?<request>req-[a-z0-9]{6,48}):#{candidate_sha}\z/.match(name)
      raise Error, "candidate workflow run-name is not bound to the request and tag target" unless match

      match[:request]
    end

    def fetch_rows(payload, key, label)
      rows = payload.is_a?(Hash) ? payload[key] : nil
      raise Error, "#{label} is invalid" unless rows.is_a?(Array)

      rows
    end

    def validate_repository(value)
      normalized = value.to_s
      unless RemoteIdentity::REPOSITORY.match?(normalized)
        raise Error, "repository identity is invalid"
      end
      normalized
    end

    def validate_version(value, label)
      normalized = value.to_s
      parsed = Gem::Version.new(normalized)
      raise Error, "#{label} is not canonical" unless parsed.to_s == normalized

      normalized
    rescue ArgumentError
      raise Error, "#{label} is invalid"
    end

    def validate_sha(value, label)
      normalized = value.to_s.downcase
      raise Error, "#{label} must be a full SHA" unless SAFE_SHA.match?(normalized)

      normalized
    end

    def validate_sha256(value, label)
      normalized = value.to_s.downcase
      raise Error, "#{label} must be a SHA-256 digest" unless /\A[0-9a-f]{64}\z/.match?(normalized)

      normalized
    end

    def artifact_digest(value, label)
      normalized = value.to_s.downcase
      unless EVIDENCE_ARTIFACT_DIGEST.match?(normalized)
        raise Error, "#{label} has no trusted Actions digest"
      end
      normalized
    end

    def positive_integer(value, label)
      integer = value.is_a?(Integer) ? value : Integer(value, 10)
      raise Error, "#{label} must be positive" unless integer.positive?

      integer
    rescue ArgumentError, TypeError
      raise Error, "#{label} must be positive"
    end

    def positive_integer?(value)
      positive_integer(value, "identity") && true
    rescue Error
      false
    end
  end

  # Verifies server-supplied Actions archive digests before safely extracting
  # their contents. The destination must not exist.
  module ReleaseArchive
    module_function

    def verify_digest!(expected, path)
      digest = expected.to_s.downcase
      unless ReleaseSelector::EVIDENCE_ARTIFACT_DIGEST.match?(digest)
        raise Error, "expected Actions artifact digest is invalid"
      end
      stat = File.lstat(path)
      unless stat.file? && !stat.symlink? && stat.nlink == 1
        raise Error, "downloaded Actions artifact is not a regular file"
      end
      actual = "sha256:#{Digest::SHA256.file(path).hexdigest}"
      raise Error, "downloaded Actions artifact digest does not match the API" unless actual == digest

      actual
    rescue Errno::ENOENT, Errno::EACCES => e
      raise Error, "cannot verify downloaded Actions artifact: #{e.message}"
    end

    def extract_zip!(archive, destination)
      raise Error, "archive destination already exists" if File.exist?(destination) || File.symlink?(destination)

      listing, stderr, status = Open3.capture3("unzip", "-Z1", archive)
      raise Error, "cannot inspect Actions artifact: #{stderr.strip}" unless status.success?

      names = listing.lines(chomp: true)
      raise Error, "Actions artifact is empty" if names.empty?
      names.each { |name| validate_archive_name!(name) }
      metadata, metadata_stderr, metadata_status =
        Open3.capture3("zipinfo", "-l", archive)
      unless metadata_status.success?
        raise Error, "cannot inspect Actions artifact types: #{metadata_stderr.strip}"
      end
      modes = metadata.lines.filter_map do |line|
        line[/\A([bcdlps-][rwxStTs-]{9})\s/, 1]
      end
      unless modes.size == names.size && modes.all? { |mode| %w[- d].include?(mode[0]) }
        raise Error, "Actions artifact contains a link or special entry"
      end
      Dir.mkdir(destination, 0o700)
      _stdout, extract_stderr, extract_status = Open3.capture3(
        "unzip", "-nq", archive, "-d", destination
      )
      unless extract_status.success?
        raise Error, "cannot extract Actions artifact: #{extract_stderr.strip}"
      end
      assert_regular_tree!(destination)
      destination
    rescue Errno::ENOENT => e
      raise Error, "cannot extract Actions artifact: #{e.message}"
    end

    def validate_archive_name!(name)
      path = Pathname.new(name)
      components = path.each_filename.to_a
      if name.empty? || name.include?("\\") || path.absolute? ||
         components.empty? || components.include?("..") ||
         path.cleanpath.to_s != name.sub(%r{/\z}, "")
        raise Error, "unsafe Actions artifact entry: #{name.inspect}"
      end
    end

    def assert_regular_tree!(root)
      Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).each do |path|
        next if %w[. ..].include?(File.basename(path))

        stat = File.lstat(path)
        unless (stat.file? || stat.directory?) && !stat.symlink?
          raise Error, "Actions artifact extracted an unsafe entry"
        end
      end
    end
  end

  class ReleaseCandidateVerifier
    SOURCE_VERSION_PATH = "lib/hive/version.rb"
    BASELINE_PATH = "packaging/release_candidate/baselines.yml"

    def call(repo_root:, candidate_dir:, candidate_sha:, tag_version:)
      manifest = Artifacts.new(
        repo_root: repo_root, candidate_sha: candidate_sha,
        candidate_dir: candidate_dir
      ).verify!
      unless manifest["hive_version"] == tag_version
        raise Error, "candidate manifest version does not match the release tag"
      end
      expected = {
        "gem" => "hive-cli-#{tag_version}.gem",
        "source" => "hive-source-#{candidate_sha}.tar.gz",
        "skills" => "hive-agent-skills-#{candidate_sha}.tar.gz",
        "web" => "hive-web-#{tag_version}.tar.gz"
      }
      actual = manifest.fetch("files").to_h { |name, row| [ row.fetch("kind"), name ] }
      raise Error, "candidate manifest filenames do not match the release identity" unless actual == expected

      source = File.join(candidate_dir, expected.fetch("source"))
      selected = read_source_entries(source, [ SOURCE_VERSION_PATH, BASELINE_PATH ])
      source_version = selected.fetch(SOURCE_VERSION_PATH)
        .match(/\bVERSION\s*=\s*["']([^"']+)["']/)&.[](1)
      unless source_version == tag_version
        raise Error, "committed source version does not match the release tag"
      end
      baseline = BaselineCatalog.parse(
        selected.fetch(BASELINE_PATH), source: BASELINE_PATH
      ).latest_stable.version
      unless Gem::Version.new(tag_version) > Gem::Version.new(baseline)
        raise Error, "candidate version is not newer than its pinned latest-stable proof"
      end

      manifest.merge(
        "latest_stable_version" => baseline,
        "public_files" => %w[gem skills web].to_h do |kind|
          [ kind, actual.fetch(kind) ]
        end
      )
    end

    private

    def read_source_entries(path, wanted)
      found = {}
      Zlib::GzipReader.open(path) do |gzip|
        Gem::Package::TarReader.new(gzip) do |tar|
          tar.each do |entry|
            name = entry.full_name.sub(%r{\A\./}, "")
            validate_tar_name!(name)
            unless entry.file? || entry.directory?
              raise Error, "candidate source contains a link or special entry"
            end
            next unless wanted.include?(name)
            raise Error, "candidate source contains a duplicate #{name}" if found.key?(name)
            raise Error, "candidate source #{name} is not a regular file" unless entry.file?

            found[name] = entry.read
          end
        end
      end
      missing = wanted - found.keys
      raise Error, "candidate source omits #{missing.first}" unless missing.empty?

      found
    rescue Gem::Package::TarInvalidError, Zlib::GzipFile::Error, Errno::ENOENT => e
      raise Error, "cannot inspect candidate source archive: #{e.message}"
    end

    def validate_tar_name!(name)
      path = Pathname.new(name)
      components = path.each_filename.to_a
      normalized = name.sub(%r{/\z}, "")
      if name.empty? || name.include?("\\") || path.absolute? ||
         components.include?("..") || path.cleanpath.to_s != normalized
        raise Error, "candidate source contains an unsafe path"
      end
    end
  end

  class ReleasePublicationVerifier
    PUBLIC_KINDS = %w[gem skills web].freeze

    def call(selected_root:, candidate_sha:, tag_version:)
      unless SAFE_SHA.match?(candidate_sha.to_s)
        raise Error, "selected publication candidate SHA is invalid"
      end
      begin
        parsed_version = Gem::Version.new(tag_version.to_s)
      rescue ArgumentError
        raise Error, "selected publication version is invalid"
      end
      unless parsed_version.to_s == tag_version.to_s
        raise Error, "selected publication version is not canonical"
      end
      root = File.expand_path(selected_root)
      manifest_path = File.join(root, "proof", "manifest.json")
      manifest = JSON.parse(File.binread(manifest_path))
      unless manifest.is_a?(Hash) &&
             manifest["schema"] == Artifacts::MANIFEST_SCHEMA &&
             manifest["schema_version"] == SCHEMA_VERSION &&
             manifest["candidate_sha"] == candidate_sha &&
             manifest["hive_version"] == tag_version
        raise Error, "selected publication manifest identity is invalid"
      end
      files = manifest["files"]
      unless files.is_a?(Hash) &&
             files.values.map { |row| row["kind"] }.sort == Artifacts::KINDS.sort
        raise Error, "selected publication manifest artifact set is invalid"
      end
      expected = {
        "gem" => "hive-cli-#{tag_version}.gem",
        "skills" => "hive-agent-skills-#{candidate_sha}.tar.gz",
        "web" => "hive-web-#{tag_version}.tar.gz"
      }
      public_records = PUBLIC_KINDS.to_h do |kind|
        matches = files.select { |_name, row| row["kind"] == kind }
        raise Error, "selected publication #{kind} identity is ambiguous" unless matches.one?

        name, row = matches.first
        unless name == expected.fetch(kind) &&
               row.is_a?(Hash) &&
               row.keys.sort == %w[kind sha256 size] &&
               /\A[0-9a-f]{64}\z/.match?(row["sha256"].to_s) &&
               row["size"].is_a?(Integer) && row["size"].positive?
          raise Error, "selected publication #{kind} manifest record is invalid"
        end
        verify_public_file!(root, name, row)
        [ kind, row.merge("filename" => name) ]
      end
      dist = File.join(root, "dist")
      unless Dir.children(dist).sort == expected.values.sort
        raise Error, "selected publication contains missing or extra public bytes"
      end
      {
        "candidate_sha" => candidate_sha,
        "hive_version" => tag_version,
        "files" => public_records
      }
    rescue Errno::ENOENT, Errno::EACCES, JSON::ParserError => e
      raise Error, "cannot verify selected publication bytes: #{e.message}"
    end

    private

    def verify_public_file!(root, name, row)
      path = File.join(root, "dist", name)
      stat = File.lstat(path)
      unless stat.file? && !stat.symlink? && stat.nlink == 1 &&
             stat.uid == Process.uid &&
             stat.size == row["size"] &&
             Digest::SHA256.file(path).hexdigest == row["sha256"]
        raise Error, "selected publication bytes changed: #{name}"
      end
    end
  end
end
