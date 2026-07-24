require "digest"
require "fileutils"
require "json"
require "open3"
require "pathname"
require "rubygems/package"
require "tmpdir"
require "zlib"

module HiveLiveAgentProof
  SCHEMA_VERSION = 1
  WORKFLOW_PATH = ".github/workflows/live-agent-skills.yml".freeze
  PLATFORMS = %w[openclaw claude codex pi].freeze
  INVOCATIONS = {
    "openclaw" => "/hive",
    "claude" => "/hive",
    "codex" => "$hive",
    "pi" => "/skill:hive"
  }.freeze
  NATIVE_ACTIVATION_KINDS = {
    "openclaw" => "openclaw-skills-info",
    "claude" => "claude-system-init-skill",
    "codex" => "codex-structured-skill-access",
    "pi" => "pi-rpc-command"
  }.freeze
  STATUS_ARGV = [ "status", "--operational", "--json" ].freeze
  WATCH_ARGV = [
    "watch", "proof:live-agent-skill", "--until", "settled",
    "--timeout", "20", "--max-events", "5", "--interval", "1", "--json-lines"
  ].freeze
  OBSERVATION_COMMANDS = [ STATUS_ARGV, WATCH_ARGV ].freeze
  WORKFLOW_CREATOR_REQUEST =
    "Create a three-stage editorial workflow that researches, drafts, and requires approval before publishing.".freeze
  WORKFLOW_CREATOR_PROMPT = <<~PROMPT.freeze
    /hive
    #{WORKFLOW_CREATOR_REQUEST}
    Use the installed Hive workflow-creator capability in this initialized project.
    This is creation-only: validate the result, report the defaults, and do not create or run a task.
  PROMPT
  WORKFLOW_CREATOR_TASK_REQUEST = "Research and draft the launch announcement for approval.".freeze
  WORKFLOW_CREATOR_TASK_KEY = "workflow-creator-proof:editorial:live-proof".freeze
  WORKFLOW_CREATOR_TASK_SLUG = "editorial-live-proof".freeze
  WORKFLOW_CREATOR_TASK_PROMPT = <<~PROMPT.freeze
    /hive
    Use the validated editorial workflow to create and run one task for:
    "#{WORKFLOW_CREATOR_TASK_REQUEST}"
    Use idempotency key #{WORKFLOW_CREATOR_TASK_KEY}. In this exact order: create the task,
    run its first stage once, repeat the same creation command once to prove the retry is a no-op,
    then query operational status. Do not publish or perform any other external action.
  PROMPT
  WORKFLOW_CREATOR_TASK_NEW_ARGV = [
    "new", "workflow-creator-proof", "--workflow", "editorial",
    "--idempotency-key", WORKFLOW_CREATOR_TASK_KEY, "--json", WORKFLOW_CREATOR_TASK_REQUEST
  ].freeze
  WORKFLOW_CREATOR_COMMANDS = [
    [ "version" ],
    [ "workflow", "list", "--json" ],
    [ "workflow", "new", "editorial", "--json" ],
    [ "workflow", "validate", "editorial", "--json" ],
    [ "workflow", "commit", "editorial" ],
    WORKFLOW_CREATOR_TASK_NEW_ARGV,
    [ "run", WORKFLOW_CREATOR_TASK_SLUG ],
    WORKFLOW_CREATOR_TASK_NEW_ARGV,
    [ "status", "--operational", "--json" ]
  ].freeze
  WORKFLOW_CREATOR_FILES = [
    ".hive-state/workflows/editorial.yml",
    ".hive-state/workflows/editorial/draft.md",
    ".hive-state/workflows/editorial/research.md"
  ].freeze
  SAFE_SHA = /\A[0-9a-f]{40}\z/.freeze
  SAFE_REPOSITORY = /\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/.freeze
  SECRET_PATTERNS = [
    /sk-ant-[A-Za-z0-9_-]{12,}/,
    /sk-(?:proj-)?[A-Za-z0-9_-]{20,}/,
    /gh[opsu]_[A-Za-z0-9]{20,}/,
    /github_pat_[A-Za-z0-9_]{20,}/,
    /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/
  ].freeze

  class Error < StandardError; end

  module_function

  def read_json(path)
    JSON.parse(File.read(path))
  rescue JSON::ParserError, Errno::ENOENT, Errno::EACCES => e
    raise Error, "cannot read JSON #{path}: #{e.message}"
  end

  def write_json(path, value)
    FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
    File.open(path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
      file.write(JSON.pretty_generate(value))
      file.write("\n")
    end
  end

  def sha256(path)
    Digest::SHA256.file(path).hexdigest
  end

  def validate_sha!(value, label)
    value = value.to_s.downcase
    raise Error, "#{label} must be a full 40-character commit SHA" unless SAFE_SHA.match?(value)

    value
  end

  def validate_repository!(value)
    value = value.to_s
    raise Error, "repository must be owner/name" unless SAFE_REPOSITORY.match?(value)

    value
  end

  def relative_file!(root, relative)
    raise Error, "unsafe artifact path #{relative.inspect}" unless relative.is_a?(String)

    clean = Pathname.new(relative).cleanpath
    raise Error, "unsafe artifact path #{relative.inspect}" if clean.absolute? || clean.each_filename.include?("..")

    path = File.join(root, clean.to_s)
    raise Error, "missing artifact #{relative}" unless File.file?(path) && !File.symlink?(path)

    path
  end

  def verify_file_record!(root, relative, record)
    path = relative_file!(root, relative)
    expected_keys = %w[sha256 size]
    unless record.is_a?(Hash) && record.keys.sort == expected_keys
      raise Error, "artifact record for #{relative} must contain sha256 and size"
    end
    actual_digest = sha256(path)
    actual_size = File.size(path)
    raise Error, "digest mismatch for #{relative}" unless record.fetch("sha256") == actual_digest
    raise Error, "size mismatch for #{relative}" unless record.fetch("size") == actual_size

    path
  end

  def secret_findings(text, exact_secrets: [])
    findings = SECRET_PATTERNS.filter_map do |pattern|
      "pattern:#{pattern.source}" if pattern.match?(text)
    end
    exact_secrets.each_with_index do |secret, index|
      next if secret.to_s.empty?

      findings << "exact-secret:#{index}" if text.include?(secret)
    end
    findings
  end

  def valid_native_activation?(platform, value)
    value.is_a?(Hash) && value.keys.sort == %w[invocation kind] &&
      value["kind"] == NATIVE_ACTIVATION_KINDS.fetch(platform) &&
      value["invocation"] == INVOCATIONS.fetch(platform)
  end

  class Builder
    def initialize(candidate_sha:, gem_path:, source_archive:, output_dir:, canonical:)
      @candidate_sha = HiveLiveAgentProof.validate_sha!(candidate_sha, "candidate_sha")
      @gem_path = File.expand_path(gem_path)
      @source_archive = File.expand_path(source_archive)
      @output_dir = File.expand_path(output_dir)
      @canonical = canonical
    end

    def call
      ensure_input!(@gem_path, "gem")
      ensure_input!(@source_archive, "source archive")
      if File.exist?(@output_dir) && !File.directory?(@output_dir)
        raise Error, "candidate output is not a directory: #{@output_dir}"
      end
      FileUtils.mkdir_p(@output_dir, mode: 0o700)
      unless Dir.empty?(@output_dir)
        raise Error, "candidate output must be empty: #{@output_dir}"
      end

      gem_name = File.basename(@gem_path)
      source_name = "hive-source-#{@candidate_sha}.tar.gz"
      skill_name = "hive-agent-skills-#{@candidate_sha}.tar.gz"
      FileUtils.cp(@gem_path, File.join(@output_dir, gem_name), preserve: false)
      FileUtils.cp(@source_archive, File.join(@output_dir, source_name), preserve: false)
      build_skill_archive(File.join(@output_dir, skill_name))

      files = [ gem_name, skill_name, source_name ].sort.to_h do |name|
        path = File.join(@output_dir, name)
        [ name, { "sha256" => HiveLiveAgentProof.sha256(path), "size" => File.size(path) } ]
      end
      manifest = {
        "schema" => "hive-live-agent-candidate-artifacts",
        "schema_version" => SCHEMA_VERSION,
        "candidate_sha" => @candidate_sha,
        "hive_version" => Hive::VERSION,
        "skill_version" => @canonical.version,
        "canonical_digest" => @canonical.canonical_digest,
        "files" => files
      }
      HiveLiveAgentProof.write_json(File.join(@output_dir, "artifact-manifest.json"), manifest)
      manifest
    end

    private

    def ensure_input!(path, label)
      raise Error, "#{label} is not a regular file: #{path}" unless File.file?(path) && !File.symlink?(path)
    end

    def build_skill_archive(destination)
      Dir.mktmpdir("hive-agent-skills") do |stage|
        PLATFORMS.each do |platform|
          projection = @canonical.render(platform)
          projection.files.each do |relative, content|
            path = File.join(stage, platform, "hive", relative)
            FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
            File.open(path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| file.write(content) }
          end
        end
        epoch = Time.at(0)
        Dir.glob(File.join(stage, "**", "*"), File::FNM_DOTMATCH).sort.reverse_each do |path|
          next if [ ".", ".." ].include?(File.basename(path))

          File.utime(epoch, epoch, path)
        end
        command = [
          "tar", "--sort=name", "--owner=0", "--group=0", "--numeric-owner",
          "--mtime=@0", "-czf", destination, "-C", stage, "."
        ]
        _stdout, stderr, status = Open3.capture3(*command)
        raise Error, "cannot build deterministic skill archive: #{stderr.strip}" unless status.success?
      end
    end
  end

  # Verifies the release candidate without invoking an external model. The
  # manifest binds the exact gem/source/skill bytes to one commit, while the
  # archive check independently renders every supported projection and compares
  # it with the packaged payload.
  class CandidateVerifier
    MANIFEST_NAME = "artifact-manifest.json".freeze

    def initialize(candidate_dir:, candidate_sha:, expected_hive_version:, canonical:)
      @candidate_dir = File.expand_path(candidate_dir)
      @candidate_sha = HiveLiveAgentProof.validate_sha!(candidate_sha, "candidate_sha")
      @expected_hive_version = expected_hive_version.to_s
      @canonical = canonical
      raise Error, "expected Hive version must not be empty" if @expected_hive_version.empty?
    end

    def call
      manifest = validate_manifest!
      files = manifest.fetch("files")
      gem_name = "hive-cli-#{@expected_hive_version}.gem"
      skill_name = "hive-agent-skills-#{@candidate_sha}.tar.gz"
      source_name = "hive-source-#{@candidate_sha}.tar.gz"
      validate_skill_archive!(HiveLiveAgentProof.relative_file!(@candidate_dir, skill_name))

      {
        "gem" => HiveLiveAgentProof.relative_file!(@candidate_dir, gem_name),
        "skills" => HiveLiveAgentProof.relative_file!(@candidate_dir, skill_name),
        "source" => HiveLiveAgentProof.relative_file!(@candidate_dir, source_name),
        "platforms" => PLATFORMS.dup,
        "manifest" => manifest,
        "files" => files
      }
    end

    private

    def validate_manifest!
      unless File.directory?(@candidate_dir) && !File.symlink?(@candidate_dir)
        raise Error, "candidate directory is not a regular directory: #{@candidate_dir}"
      end

      manifest = HiveLiveAgentProof.read_json(File.join(@candidate_dir, MANIFEST_NAME))
      required = %w[canonical_digest candidate_sha files hive_version schema schema_version skill_version]
      raise Error, "artifact manifest fields are invalid" unless manifest.is_a?(Hash) && manifest.keys.sort == required.sort
      unless manifest["schema"] == "hive-live-agent-candidate-artifacts" &&
             manifest["schema_version"] == SCHEMA_VERSION && manifest["candidate_sha"] == @candidate_sha
        raise Error, "artifact manifest identity does not match candidate"
      end
      unless manifest["hive_version"] == @expected_hive_version
        raise Error, "artifact manifest Hive version does not match #{@expected_hive_version}"
      end
      unless manifest["skill_version"] == @canonical.version &&
             manifest["canonical_digest"] == @canonical.canonical_digest
        raise Error, "artifact manifest canonical skill identity does not match source"
      end

      expected_names = [
        "hive-cli-#{@expected_hive_version}.gem",
        "hive-agent-skills-#{@candidate_sha}.tar.gz",
        "hive-source-#{@candidate_sha}.tar.gz"
      ].sort
      files = manifest["files"]
      unless files.is_a?(Hash) && files.keys.sort == expected_names
        raise Error, "artifact manifest files do not match the exact release candidate"
      end
      actual_names = Dir.children(@candidate_dir).sort
      unless actual_names == (expected_names + [ MANIFEST_NAME ]).sort
        raise Error, "candidate directory contains unmanifested artifacts"
      end
      files.each { |name, record| HiveLiveAgentProof.verify_file_record!(@candidate_dir, name, record) }

      manifest
    end

    def validate_skill_archive!(path)
      expected = PLATFORMS.each_with_object({}) do |platform, files|
        @canonical.render(platform).files.each do |relative, content|
          files["#{platform}/hive/#{relative}"] = content
        end
      end
      actual = read_skill_archive(path)
      unless actual.keys.sort == expected.keys.sort
        raise Error, "skill archive projection file set does not match canonical source"
      end
      expected.each do |name, content|
        unless Digest::SHA256.hexdigest(actual.fetch(name)) == Digest::SHA256.hexdigest(content)
          raise Error, "skill archive projection differs from canonical source: #{name}"
        end
      end
    end

    def read_skill_archive(path)
      files = {}
      Zlib::GzipReader.open(path) do |gzip|
        Gem::Package::TarReader.new(gzip) do |tar|
          tar.each do |entry|
            name = entry.full_name.sub(%r{\A\./}, "")
            next if name.empty? || entry.directory?

            clean = Pathname.new(name).cleanpath
            if clean.absolute? || clean.each_filename.include?("..") || !entry.file?
              raise Error, "skill archive contains an unsafe entry: #{name}"
            end
            clean_name = clean.to_s
            raise Error, "skill archive contains duplicate entry: #{clean_name}" if files.key?(clean_name)

            files[clean_name] = entry.read
          end
        end
      end
      files
    rescue Zlib::GzipFile::Error, Gem::Package::TarInvalidError, EOFError => e
      raise Error, "cannot read skill archive: #{e.message}"
    end
  end

  class Attestor
    def initialize(candidate_sha:, workflow_revision:, repository:, run_id:, run_attempt:,
                   artifact_dir:, evidence_dir:, creator_evidence_dir:, output_dir:)
      @candidate_sha = HiveLiveAgentProof.validate_sha!(candidate_sha, "candidate_sha")
      @workflow_revision = HiveLiveAgentProof.validate_sha!(workflow_revision, "workflow_revision")
      @repository = HiveLiveAgentProof.validate_repository!(repository)
      @run_id = Integer(run_id, 10)
      @run_attempt = Integer(run_attempt, 10)
      @artifact_dir = File.expand_path(artifact_dir)
      @evidence_dir = File.expand_path(evidence_dir)
      @creator_evidence_dir = File.expand_path(creator_evidence_dir)
      @output_dir = File.expand_path(output_dir)
      raise Error, "run_id and run_attempt must be positive" unless @run_id.positive? && @run_attempt.positive?
    rescue ArgumentError
      raise Error, "run_id and run_attempt must be positive integers"
    end

    def call
      manifest = validate_artifacts!
      evidence = validate_evidence!(manifest)
      creator_evidence = validate_creator_evidence!(manifest)
      raise Error, "proof output already exists: #{@output_dir}" if File.exist?(@output_dir)
      FileUtils.mkdir_p(File.join(@output_dir, "artifacts"), mode: 0o700)
      FileUtils.mkdir_p(File.join(@output_dir, "evidence"), mode: 0o700)

      manifest.fetch("files").each_key do |name|
        FileUtils.cp(File.join(@artifact_dir, name), File.join(@output_dir, "artifacts", name), preserve: false)
      end
      FileUtils.cp(File.join(@artifact_dir, "artifact-manifest.json"),
                   File.join(@output_dir, "artifacts", "artifact-manifest.json"), preserve: false)
      evidence.each do |platform, row|
        HiveLiveAgentProof.write_json(File.join(@output_dir, "evidence", "#{platform}.json"), row)
      end
      HiveLiveAgentProof.write_json(
        File.join(@output_dir, "evidence", "openclaw-workflow-creator.json"),
        creator_evidence
      )

      attestation = {
        "schema" => "hive-live-agent-skills-attestation",
        "schema_version" => SCHEMA_VERSION,
        "candidate_sha" => @candidate_sha,
        "workflow" => {
          "path" => WORKFLOW_PATH,
          "revision" => @workflow_revision,
          "event" => "workflow_dispatch",
          "repository" => @repository,
          "run_id" => @run_id,
          "run_attempt" => @run_attempt
        },
        "artifacts" => manifest,
        "platforms" => PLATFORMS.to_h { |platform| [ platform, evidence.fetch(platform) ] },
        "workflow_creator" => creator_evidence,
        "secret_scan" => {
          "status" => "passed",
          "scanner" => "hive-live-agent-proof/v1",
          "files_scanned" => PLATFORMS.length + 2
        }
      }
      attestation_path = File.join(@output_dir, "attestation.json")
      HiveLiveAgentProof.write_json(attestation_path, attestation)
      findings = HiveLiveAgentProof.secret_findings(File.read(attestation_path))
      raise Error, "attestation secret scan failed: #{findings.join(', ')}" unless findings.empty?

      digest = HiveLiveAgentProof.sha256(attestation_path)
      File.write(File.join(@output_dir, "attestation.sha256"), "#{digest}  attestation.json\n", mode: "w", perm: 0o600)
      { "attestation" => attestation, "sha256" => digest, "path" => attestation_path }
    end

    private

    def validate_artifacts!
      path = File.join(@artifact_dir, "artifact-manifest.json")
      manifest = HiveLiveAgentProof.read_json(path)
      required = %w[canonical_digest candidate_sha files hive_version schema schema_version skill_version]
      raise Error, "artifact manifest fields are invalid" unless manifest.keys.sort == required.sort
      unless manifest["schema"] == "hive-live-agent-candidate-artifacts" &&
             manifest["schema_version"] == SCHEMA_VERSION && manifest["candidate_sha"] == @candidate_sha
        raise Error, "artifact manifest identity does not match candidate"
      end
      files = manifest.fetch("files")
      raise Error, "artifact manifest files must contain gem, skills, and source" unless files.is_a?(Hash) && files.length == 3
      files.each { |name, record| HiveLiveAgentProof.verify_file_record!(@artifact_dir, name, record) }
      raise Error, "artifact manifest has no gem" unless files.keys.one? { |name| name.match?(/\Ahive-cli-[0-9].*\.gem\z/) }
      raise Error, "artifact manifest has no skill archive" unless files.key?("hive-agent-skills-#{@candidate_sha}.tar.gz")
      raise Error, "artifact manifest has no source archive" unless files.key?("hive-source-#{@candidate_sha}.tar.gz")

      manifest
    end

    def validate_evidence!(manifest)
      actual_names = Dir.glob(File.join(@evidence_dir, "*.json")).map { |path| File.basename(path, ".json") }.sort
      raise Error, "evidence platforms must be exactly #{PLATFORMS.join(', ')}" unless actual_names == PLATFORMS.sort

      PLATFORMS.to_h do |platform|
        path = File.join(@evidence_dir, "#{platform}.json")
        row = HiveLiveAgentProof.read_json(path)
        validate_evidence_row!(platform, row, manifest)
        findings = HiveLiveAgentProof.secret_findings(File.read(path))
        raise Error, "#{platform} evidence secret scan failed: #{findings.join(', ')}" unless findings.empty?
        [ platform, row ]
      end
    end

    def validate_evidence_row!(platform, row, manifest)
      unless row.is_a?(Hash) && row["schema"] == "hive-live-agent-skill-evidence" &&
             row["schema_version"] == SCHEMA_VERSION && row["platform"] == platform &&
             row["candidate_sha"] == @candidate_sha && row["result"] == "passed"
        raise Error, "#{platform} evidence identity or result is invalid"
      end
      unless row.dig("skill", "canonical_digest") == manifest["canonical_digest"] &&
             row.dig("skill", "skill_version") == manifest["skill_version"]
        raise Error, "#{platform} evidence canonical provenance mismatch"
      end
      unless HiveLiveAgentProof.valid_native_activation?(platform, row["native_activation"])
        raise Error, "#{platform} native activation evidence is invalid"
      end
      unless row.dig("secret_scan", "status") == "passed" && row.dig("cleanup", "status") == "passed"
        raise Error, "#{platform} evidence lacks secret-scan or cleanup proof"
      end
      commands = row["hive_commands"]
      unless commands == OBSERVATION_COMMANDS
        raise Error,
              "#{platform} must use exactly one operational status and one bounded native watch"
      end
    end

    def validate_creator_evidence!(manifest)
      actual_names = Dir.glob(File.join(@creator_evidence_dir, "*.json")).map { |path| File.basename(path) }
      unless actual_names == [ "openclaw-workflow-creator.json" ]
        raise Error, "workflow-creator evidence must contain exactly openclaw-workflow-creator.json"
      end

      path = File.join(@creator_evidence_dir, actual_names.fetch(0))
      row = HiveLiveAgentProof.read_json(path)
      unless row.is_a?(Hash) && row["schema"] == "hive-live-workflow-creator-evidence" &&
             row["schema_version"] == SCHEMA_VERSION && row["platform"] == "openclaw" &&
             row["candidate_sha"] == @candidate_sha && row["result"] == "passed"
        raise Error, "workflow-creator evidence identity or result is invalid"
      end
      unless row.dig("skill", "canonical_digest") == manifest["canonical_digest"] &&
             row.dig("skill", "skill_version") == manifest["skill_version"]
        raise Error, "workflow-creator evidence canonical provenance mismatch"
      end
      unless HiveLiveAgentProof.valid_native_activation?("openclaw", row["native_activation"])
        raise Error, "workflow-creator native activation evidence is invalid"
      end
      expected_prompt = Digest::SHA256.hexdigest(WORKFLOW_CREATOR_PROMPT)
      expected_task_prompt = Digest::SHA256.hexdigest(WORKFLOW_CREATOR_TASK_PROMPT)
      unless row["prompt_sha256"] == expected_prompt &&
             row["task_prompt_sha256"] == expected_task_prompt &&
             row["hive_commands"] == WORKFLOW_CREATOR_COMMANDS
        raise Error, "workflow-creator prompt or command sequence is invalid"
      end
      validate_creator_result!(row)
      unless row.dig("secret_scan", "status") == "passed" && row.dig("cleanup", "status") == "passed"
        raise Error, "workflow-creator evidence lacks secret-scan or cleanup proof"
      end
      findings = HiveLiveAgentProof.secret_findings(File.read(path))
      raise Error, "workflow-creator evidence secret scan failed: #{findings.join(', ')}" unless findings.empty?

      row
    end

    def validate_creator_result!(row)
      created = row["created_files"]
      unless created.is_a?(Array) && created.map { |record| record["path"] }.sort == WORKFLOW_CREATOR_FILES
        raise Error, "workflow-creator created files are incomplete"
      end
      unless created.all? { |record| record.keys.sort == %w[path sha256 size] &&
        record["sha256"].to_s.match?(/\A[0-9a-f]{64}\z/) && record["size"].to_i.positive? }
        raise Error, "workflow-creator created-file records are invalid"
      end

      validation = row["validation"]
      stages = validation.is_a?(Hash) ? validation["stages"] : nil
      outcomes = validation.is_a?(Hash) ? validation["human_outcomes"] : nil
      unless validation&.fetch("valid", false) == true &&
             stages == %w[research draft approval] &&
             validation["automatic_edges"] == [ %w[research draft], %w[draft approval] ] &&
             outcomes == [
               { "stage" => "approval", "name" => "approve", "complete" => true,
                 "artifact" => "draft.md", "to" => nil },
               { "stage" => "approval", "name" => "reject", "complete" => false,
                 "artifact" => nil, "to" => "draft" }
             ]
        raise Error, "workflow-creator normalized graph is invalid"
      end
      task = row["task"]
      unless row["creation_only_task_count"] == 0 && row["task_count"] == 1 &&
             task == {
               "slug" => WORKFLOW_CREATOR_TASK_SLUG,
               "workflow" => "editorial",
               "first_created" => true,
               "retry_created" => false,
               "run_count" => 1,
               "current_stage" => "1-research"
             } &&
             row["external_actions"] == []
        raise Error, "workflow-creator proof contains an unauthorized side effect"
      end
    end
  end

  class Verifier
    attr_reader :attestation

    def initialize(proof_dir:, candidate_sha:, workflow_revision:, repository:, run_id:, run_attempt:, attestation_sha256:)
      @proof_dir = File.expand_path(proof_dir)
      @candidate_sha = HiveLiveAgentProof.validate_sha!(candidate_sha, "candidate_sha")
      @workflow_revision = HiveLiveAgentProof.validate_sha!(workflow_revision, "workflow_revision")
      @repository = HiveLiveAgentProof.validate_repository!(repository)
      @run_id = Integer(run_id, 10)
      @run_attempt = Integer(run_attempt, 10)
      @expected_attestation_sha256 = attestation_sha256.to_s.downcase
      unless @expected_attestation_sha256.match?(/\A[0-9a-f]{64}\z/)
        raise Error, "attestation_sha256 must be a SHA-256 digest"
      end
      raise Error, "run_id and run_attempt must be positive" unless @run_id.positive? && @run_attempt.positive?
    rescue ArgumentError
      raise Error, "run_id and run_attempt must be positive integers"
    end

    def call
      path = HiveLiveAgentProof.relative_file!(@proof_dir, "attestation.json")
      actual_digest = HiveLiveAgentProof.sha256(path)
      raise Error, "attestation digest does not match trusted Check Run" unless actual_digest == @expected_attestation_sha256
      @attestation = HiveLiveAgentProof.read_json(path)
      validate_identity!
      manifest = @attestation.fetch("artifacts")
      artifact_root = File.join(@proof_dir, "artifacts")
      manifest.fetch("files").each do |name, record|
        HiveLiveAgentProof.verify_file_record!(artifact_root, name, record)
      end
      validate_platforms!(manifest)
      validate_workflow_creator!(manifest)
      findings = HiveLiveAgentProof.secret_findings(File.read(path))
      raise Error, "proof secret scan failed: #{findings.join(', ')}" unless findings.empty?

      gem_name = manifest.fetch("files").keys.find { |name| name.match?(/\Ahive-cli-[0-9].*\.gem\z/) }
      skill_name = "hive-agent-skills-#{@candidate_sha}.tar.gz"
      {
        "gem" => HiveLiveAgentProof.relative_file!(artifact_root, gem_name),
        "skills" => HiveLiveAgentProof.relative_file!(artifact_root, skill_name),
        "manifest" => File.join(artifact_root, "artifact-manifest.json")
      }
    end

    private

    def validate_identity!
      workflow = @attestation["workflow"]
      unless @attestation["schema"] == "hive-live-agent-skills-attestation" &&
             @attestation["schema_version"] == SCHEMA_VERSION &&
             @attestation["candidate_sha"] == @candidate_sha &&
             workflow.is_a?(Hash) && workflow["path"] == WORKFLOW_PATH &&
             workflow["event"] == "workflow_dispatch" && workflow["revision"] == @workflow_revision &&
             workflow["repository"] == @repository && workflow["run_id"] == @run_id &&
             workflow["run_attempt"] == @run_attempt
        raise Error, "attestation workflow or candidate identity mismatch"
      end
      unless @attestation.dig("secret_scan", "status") == "passed"
        raise Error, "attestation secret scan did not pass"
      end
    end

    def validate_platforms!(manifest)
      platforms = @attestation["platforms"]
      raise Error, "attestation platforms are incomplete" unless platforms.is_a?(Hash) && platforms.keys.sort == PLATFORMS.sort

      PLATFORMS.each do |platform|
        row = platforms.fetch(platform)
        unless row["platform"] == platform && row["result"] == "passed" &&
               row["candidate_sha"] == @candidate_sha && row.dig("secret_scan", "status") == "passed" &&
               row.dig("cleanup", "status") == "passed" &&
               row.dig("skill", "canonical_digest") == manifest["canonical_digest"]
          raise Error, "#{platform} attested evidence is incomplete"
        end
        unless HiveLiveAgentProof.valid_native_activation?(platform, row["native_activation"])
          raise Error, "#{platform} attested native activation evidence is invalid"
        end
      end
    end

    def validate_workflow_creator!(manifest)
      row = @attestation["workflow_creator"]
      unless row.is_a?(Hash) && row["schema"] == "hive-live-workflow-creator-evidence" &&
             row["platform"] == "openclaw" && row["candidate_sha"] == @candidate_sha &&
             row["result"] == "passed" && row.dig("skill", "canonical_digest") == manifest["canonical_digest"] &&
             row.dig("secret_scan", "status") == "passed" && row.dig("cleanup", "status") == "passed"
        raise Error, "workflow-creator attested evidence is incomplete"
      end
      unless HiveLiveAgentProof.valid_native_activation?("openclaw", row["native_activation"])
        raise Error, "workflow-creator attested native activation evidence is invalid"
      end
      unless row["prompt_sha256"] == Digest::SHA256.hexdigest(WORKFLOW_CREATOR_PROMPT) &&
             row["task_prompt_sha256"] == Digest::SHA256.hexdigest(WORKFLOW_CREATOR_TASK_PROMPT) &&
             row["hive_commands"] == WORKFLOW_CREATOR_COMMANDS &&
             row["creation_only_task_count"] == 0 && row["task_count"] == 1 &&
             row["task"].is_a?(Hash) && row["task"]["retry_created"] == false &&
             row["task"]["run_count"] == 1 && row["external_actions"] == []
        raise Error, "workflow-creator attested contract is invalid"
      end
    end
  end
end
