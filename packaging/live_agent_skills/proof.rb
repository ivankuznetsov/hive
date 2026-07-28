require "digest"
require "fileutils"
require "json"
require "open3"
require "pathname"
require "rubygems/package"
require "tmpdir"
require "zlib"
require_relative "openclaw_creator_proof/installation_identity"

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
    The proof harness already verified the candidate with `hive version`; begin with
    `hive workflow list --json` and do not repeat `hive version`.
    For this creation-only phase, execute exactly these Hive commands once each and
    in this order, with no other Hive command:
    1. `hive workflow list --json`
    2. `hive workflow new editorial --json`
    3. `hive workflow validate editorial --json`
    4. `hive workflow commit editorial`
    Replace the neutral scaffold with the smallest complete accepted graph. Retain
    exactly these authored paths and no other file under the editorial instruction
    directory:
    - `.hive-state/workflows/editorial.yml`
    - `.hive-state/workflows/editorial/research.md`
    - `.hive-state/workflows/editorial/draft.md`
    Delete the blank scaffold's unused `README.md`, `honeycomb.yml`, and `work.md`;
    do not create substitutes or extra reference files. Validate the result, report
    the defaults, and do not create or run a task.
  PROMPT
  WORKFLOW_CREATOR_TASK_REQUEST = "Research and draft the launch announcement for approval.".freeze
  WORKFLOW_CREATOR_WORKFLOW = "editorial".freeze
  WORKFLOW_CREATOR_TASK_KEY = "workflow-creator-proof:editorial:live-proof".freeze
  WORKFLOW_CREATOR_RUN_PLACEHOLDER = "{created_slug}".freeze
  WORKFLOW_CREATOR_EXAMPLE_SLUG = "research-and-draft-the-launch-260728-abcd".freeze
  WORKFLOW_CREATOR_SAFE_SLUG = /\A[a-z][a-z0-9-]{0,63}\z/.freeze
  WORKFLOW_CREATOR_OPENCLAW_VERSION = "2026.7.1-beta.2".freeze
  WORKFLOW_CREATOR_OPENCLAW_INTEGRITY =
    "sha512-KYPBQnAfEb/9qrxlw/96a90mMQeKdAZdUABMROOue9Ph2oFbnDGezZjd5Bmw4WhRyzgyvHOHqHje/swGipC4xA==".freeze
  WORKFLOW_CREATOR_OPENCLAW_LOCK_SHA256 =
    "31994a60856f7a3d4db9a35b1d49951b17e9bb3642fa5e877774390a93410c15".freeze
  WORKFLOW_CREATOR_OPENCLAW_PACKAGE_COUNT = 306
  SKILL_ARCHIVE_FILE_LIMIT = 16 * 1024 * 1024
  SKILL_ARCHIVE_TOTAL_LIMIT = 64 * 1024 * 1024
  SKILL_ARCHIVE_ENTRY_LIMIT = 512
  SKILL_ARCHIVE_DIRECTORY_LIMIT = 64
  SKILL_ARCHIVE_DEPTH_LIMIT = 8
  SKILL_ARCHIVE_INODE_LIMIT = 256
  WORKFLOW_CREATOR_PROVIDER_ENV = {
    "openai" => "OPENAI_API_KEY",
    "openrouter" => "OPENROUTER_API_KEY"
  }.freeze
  WORKFLOW_CREATOR_TASK_PROMPT = <<~PROMPT.freeze
    /hive
    Use the validated editorial workflow to create and run one task for:
    "#{WORKFLOW_CREATOR_TASK_REQUEST}"
    Use idempotency key #{WORKFLOW_CREATOR_TASK_KEY}. Capture the slug from the first creation
    command's JSON and use exactly that slug to run its first stage once. Then repeat the same
    creation command once, require its JSON to return the same slug with created=false, and query
    operational status. Keep that exact order. Do not publish or perform any other external action.
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
    [ "run", WORKFLOW_CREATOR_RUN_PLACEHOLDER ],
    WORKFLOW_CREATOR_TASK_NEW_ARGV,
    [ "status", "--operational", "--json" ]
  ].freeze
  WORKFLOW_CREATOR_FILES = [
    ".hive-state/workflows/editorial.yml",
    ".hive-state/workflows/editorial/draft.md",
    ".hive-state/workflows/editorial/research.md"
  ].freeze
  WORKFLOW_CREATOR_DESCRIPTOR = {
    "id" => "editorial",
    "stages" => [
      {
        "name" => "research",
        "kind" => "agent",
        "state_file" => "research.md",
        "instruction" => "editorial/research.md",
        "permissions" => "yolo"
      },
      {
        "name" => "draft",
        "kind" => "agent",
        "state_file" => "draft.md",
        "instruction" => "editorial/draft.md",
        "permissions" => "yolo"
      },
      {
        "name" => "approval",
        "kind" => "human",
        "state_file" => "approval.md",
        "input" => "draft.md",
        "outcomes" => {
          "approve" => {
            "complete" => true,
            "artifact" => "draft.md"
          },
          "reject" => {
            "to" => "draft"
          }
        }
      }
    ]
  }.freeze
  WORKFLOW_CREATOR_DESCRIPTOR_SHA256 =
    Digest::SHA256.hexdigest(JSON.generate(WORKFLOW_CREATOR_DESCRIPTOR)).freeze
  WORKFLOW_CREATOR_STAGE_FILE = "research.md".freeze
  WORKFLOW_CREATOR_STAGE_INSTRUCTION =
    ".hive-state/workflows/editorial/research.md".freeze
  WORKFLOW_CREATOR_STAGE_INSTRUCTION_MAX_BYTES = 64 * 1024
  WORKFLOW_CREATOR_STAGE_MARKER = "<!-- COMPLETE -->".freeze
  WORKFLOW_CREATOR_STAGE_OUTPUT = <<~MARKDOWN.freeze
    # Launch research

    The launch announcement should state the audience, intended outcome,
    supporting evidence, and approval boundary before drafting.

    <!-- COMPLETE -->
  MARKDOWN
  WORKFLOW_CREATOR_STAGE_OUTPUT_SHA256 =
    Digest::SHA256.hexdigest(WORKFLOW_CREATOR_STAGE_OUTPUT).freeze
  WORKFLOW_CREATOR_FIXTURE_EXECUTION_KIND = "deterministic_fixture".freeze
  WORKFLOW_CREATOR_FIXTURE_MODEL_LOOP = "not_exercised".freeze
  WORKFLOW_CREATOR_DRIVER_PATH =
    File.expand_path("openclaw_native_tools.mjs", __dir__).freeze
  WORKFLOW_CREATOR_DRIVER_SHA256 =
    Digest::SHA256.file(WORKFLOW_CREATOR_DRIVER_PATH).hexdigest.freeze
  WORKFLOW_CREATOR_POLICY_SURFACES = %w[
    workspace_filesystem outside_sibling_write_edit_apply_patch
    exec_allowlist_and_shell_composition configured_tool_inventory
  ].freeze
  WORKFLOW_CREATOR_OUTSIDE_READ_CAVEAT =
    "OpenClaw beta.2 may admit configured read-only skill roots outside the workspace".freeze
  WORKFLOW_CREATOR_SOCKET_LIMITATION =
    "socket snapshots retain unattributed observations; destination identity " \
    "and authorization are not adjudicated".freeze
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

  def workflow_creator_commands(task_slug)
    slug = task_slug.to_s
    raise Error, "workflow-creator task slug is invalid" unless WORKFLOW_CREATOR_SAFE_SLUG.match?(slug)

    WORKFLOW_CREATOR_COMMANDS.map do |argv|
      argv == [ "run", WORKFLOW_CREATOR_RUN_PLACEHOLDER ] ? [ "run", slug ] : argv.dup
    end
  end

  def valid_workflow_creator_commands?(commands, task_slug:)
    commands == workflow_creator_commands(task_slug)
  rescue Error
    false
  end

  def valid_creator_runtime_evidence?(row)
    provider = row["provider"]
    provider_name = provider.is_a?(Hash) ? provider["name"] : nil
    expected_credential = WORKFLOW_CREATOR_PROVIDER_ENV[provider_name]
    executables = row["executables"]
    candidate = executables.is_a?(Hash) ? executables["candidate"] : nil
    gateway = executables.is_a?(Hash) ? executables["audit_gateway"] : nil
    openclaw = executables.is_a?(Hash) ? executables["openclaw"] : nil
    stage_fixture = executables.is_a?(Hash) ? executables["nested_stage_fixture"] : nil
    processes = row["processes"]
    teardown = row["teardown"]
    path_prepend = row.dig("openclaw_configuration", "path_prepend")

    expected_credential &&
      valid_openclaw_package_evidence?(row["openclaw_package"]) &&
      provider["model"].to_s.start_with?("#{provider_name}/") &&
      provider["credential_environment"] == expected_credential &&
      valid_executable_record?(candidate) &&
      valid_executable_record?(gateway) &&
      valid_gateway_runtime_bundle?(gateway["runtime_bundle"]) &&
      valid_executable_record?(openclaw) &&
      valid_executable_record?(stage_fixture) &&
      openclaw["version"].to_s.match?(
        /\AOpenClaw #{Regexp.escape(WORKFLOW_CREATOR_OPENCLAW_VERSION)} \(.+\)\z/
      ) &&
      executables.keys.sort == %w[
        audit_gateway candidate nested_stage_fixture openclaw
      ] &&
      [ candidate, gateway, openclaw, stage_fixture ].map {
        |record| record["realpath"]
      }.uniq.length == 4 &&
      path_prepend == [ File.dirname(gateway["realpath"]) ] &&
      row.dig("openclaw_configuration", "sha256").to_s.match?(/\A[0-9a-f]{64}\z/) &&
      row.dig("openclaw_configuration", "approvals_sha256").to_s.match?(
        /\A[0-9a-f]{64}\z/
      ) &&
      valid_creator_effect_policy?(row["effect_policy"], gateway: gateway) &&
      valid_creator_effect_observations?(
        row["effect_observations"], process_count: processes&.length
      ) &&
      row["unauthorized_effects_observed"] == [] &&
      row["external_actions"] == row["unauthorized_effects_observed"] &&
      valid_external_actions_scope?(row["external_actions_scope"]) &&
      processes.is_a?(Array) && !processes.empty? &&
      processes.all? { |process|
        process["timed_out"] == false &&
          process["interrupted"] == false &&
          process.dig("teardown", "status") == "passed" &&
          process.dig("teardown", "reaped") == true &&
          process.dig("teardown", "readers") == "complete" &&
          process.dig("teardown", "writer") == "complete" &&
          process.dig("teardown", "descendants") == "none" &&
          process.dig("teardown", "containment") == "linux_child_subreaper" &&
          process.dig("network", "status") == "observed" &&
          process.dig("network", "sample_count").is_a?(Integer) &&
          process.dig("network", "sample_count").positive? &&
          process.dig("network", "sockets").is_a?(Array)
      } &&
      teardown.is_a?(Hash) && teardown["status"] == "passed" &&
      teardown["reaped"] == true && teardown["descendants"] == "none" &&
      teardown["containment"] == "linux_child_subreaper"
  rescue TypeError
    false
  end

  def valid_gateway_runtime_bundle?(record)
    return false unless record.is_a?(Hash) &&
                        record.keys.sort == %w[
                          config_sha256 files manifest_sha256 schema schema_version
                        ] &&
                        record["schema"] == "hive-openclaw-audit-gateway-runtime" &&
                        record["schema_version"] == 1 &&
                        record["config_sha256"].to_s.match?(/\A[0-9a-f]{64}\z/) &&
                        record["manifest_sha256"].to_s.match?(/\A[0-9a-f]{64}\z/)

    files = record["files"]
    return false unless files.is_a?(Array) &&
                        files.all? { |row|
                          row.is_a?(Hash) &&
                            row.keys.sort == %w[name sha256] &&
                            row["sha256"].to_s.match?(/\A[0-9a-f]{64}\z/)
                        } &&
                        files.map { |row| row["name"] }.sort == %w[
                          attempt_ledger.rb bounded_regular_reader.rb candidate_executor.rb
                          candidate_identity.rb installation_identity.rb main.rb result_ledger.rb
                          task_binding.rb
                        ]

    payload = {
      "config_sha256" => record.fetch("config_sha256"),
      "files" => files
    }
    Digest::SHA256.hexdigest(JSON.generate(payload)) == record["manifest_sha256"]
  end

  def valid_creator_descriptor_evidence?(record)
    record.is_a?(Hash) &&
      record.keys.sort == %w[
        agent_model_inheritance normalized_sha256 path sha256
      ] &&
      record["path"] == ".hive-state/workflows/editorial.yml" &&
      record["sha256"].to_s.match?(/\A[0-9a-f]{64}\z/) &&
      record["normalized_sha256"] == WORKFLOW_CREATOR_DESCRIPTOR_SHA256 &&
      record["agent_model_inheritance"] == "project"
  end

  def valid_creator_stage_execution?(record, task_slug:, fixture:)
    return false unless record.is_a?(Hash) &&
                        fixture.is_a?(Hash) &&
                        record.keys.sort == %w[
                          argv_sha256 artifact execution_kind fixture instruction model_loop
                          prompt_sha256 provider provider_version stage task_slug
                        ] &&
                        record["provider"] == "claude" &&
                        record["provider_version"] == "2.1.118" &&
                        record["execution_kind"] ==
                          WORKFLOW_CREATOR_FIXTURE_EXECUTION_KIND &&
                        record["model_loop"] == WORKFLOW_CREATOR_FIXTURE_MODEL_LOOP &&
                        record["stage"] == "research" &&
                        record["task_slug"] == task_slug &&
                        WORKFLOW_CREATOR_SAFE_SLUG.match?(task_slug.to_s) &&
                        record["prompt_sha256"].to_s.match?(/\A[0-9a-f]{64}\z/) &&
                        record["argv_sha256"].to_s.match?(/\A[0-9a-f]{64}\z/)

    artifact = record["artifact"]
    fixture_receipt = record["fixture"]
    instruction = record["instruction"]
    artifact.is_a?(Hash) &&
      artifact.keys.sort == %w[changed marker path sha256 size] &&
      artifact["path"] == WORKFLOW_CREATOR_STAGE_FILE &&
      artifact["sha256"] == WORKFLOW_CREATOR_STAGE_OUTPUT_SHA256 &&
      artifact["size"] == WORKFLOW_CREATOR_STAGE_OUTPUT.bytesize &&
      artifact["marker"] == "complete" &&
      artifact["changed"] == true &&
      instruction.is_a?(Hash) &&
      instruction.keys.sort == %w[path sha256 size] &&
      instruction["path"] == WORKFLOW_CREATOR_STAGE_INSTRUCTION &&
      instruction["sha256"].to_s.match?(/\A[0-9a-f]{64}\z/) &&
      instruction["size"].is_a?(Integer) &&
      instruction["size"].positive? &&
      instruction["size"] <= WORKFLOW_CREATOR_STAGE_INSTRUCTION_MAX_BYTES &&
      fixture_receipt.is_a?(Hash) &&
      fixture_receipt.keys.sort == %w[invocation_count receipt_sha256 sha256] &&
      fixture_receipt["sha256"] == fixture["sha256"] &&
      fixture_receipt["receipt_sha256"].to_s.match?(/\A[0-9a-f]{64}\z/) &&
      fixture_receipt["invocation_count"] == 1
  end

  def valid_creator_effect_policy?(record, gateway:)
    record.is_a?(Hash) &&
      record.keys.sort == %w[
        allowed_executables allowed_tools approvals_sha256 configuration_sha256
        driver_sha256 monitored_surfaces native_tool_receipt_sha256 outside_read_caveat
        proof_mode runtime_source status
      ] &&
      record["status"] == "enforced" &&
      record["allowed_tools"] == %w[read write edit apply_patch exec] &&
      record["allowed_executables"] == [ gateway["realpath"] ] &&
      %w[openclaw-exact-runtime public-export-contract-fixture].include?(
        record["runtime_source"]
      ) &&
      record["proof_mode"] == "direct_native_tool_surface" &&
      record["driver_sha256"] == WORKFLOW_CREATOR_DRIVER_SHA256 &&
      record["native_tool_receipt_sha256"].to_s.match?(/\A[0-9a-f]{64}\z/) &&
      record["monitored_surfaces"] == WORKFLOW_CREATOR_POLICY_SURFACES &&
      record["outside_read_caveat"].is_a?(Hash) &&
      record["outside_read_caveat"].keys.sort ==
        %w[caveat global_denial_claimed ordinary_sibling_decision] &&
      record.dig("outside_read_caveat", "caveat") ==
        WORKFLOW_CREATOR_OUTSIDE_READ_CAVEAT &&
      record.dig("outside_read_caveat", "global_denial_claimed") == false &&
      %w[succeeded denied].include?(
        record.dig("outside_read_caveat", "ordinary_sibling_decision")
      ) &&
      record["configuration_sha256"].to_s.match?(/\A[0-9a-f]{64}\z/) &&
      record["approvals_sha256"].to_s.match?(/\A[0-9a-f]{64}\z/)
  end

  def valid_creator_effect_observations?(record, process_count:)
    record.is_a?(Hash) &&
      record.keys.sort == %w[
        authoring filesystem_mutation_count filesystem_observation_count
        filesystem_receipt_sha256 negative_control_count network_observation_count
        network_observations network_socket_count policy_sha256 status
      ] &&
      record["status"] == "observed" &&
      record["policy_sha256"].to_s.match?(/\A[0-9a-f]{64}\z/) &&
      record["filesystem_receipt_sha256"].to_s.match?(/\A[0-9a-f]{64}\z/) &&
      record["filesystem_observation_count"] == 2 &&
      record["filesystem_mutation_count"].is_a?(Integer) &&
      record["filesystem_mutation_count"].positive? &&
      record["negative_control_count"] == 7 &&
      valid_creator_authoring_evidence?(record["authoring"]) &&
      process_count.is_a?(Integer) && process_count.positive? &&
      record["network_observation_count"] == process_count &&
      record["network_socket_count"].is_a?(Integer) &&
      record["network_socket_count"] >= 0 &&
      valid_creator_network_observations?(
        record["network_observations"], count: record["network_socket_count"]
      )
  end

  def valid_creator_network_observations?(rows, count:)
    agent_windows = %w[workflow_creation task_creation]
    rows.is_a?(Array) && rows.length == count && rows.all? do |row|
      next false unless row.is_a?(Hash)

      expected = agent_windows.include?(row["window"]) ?
        "unattributed_agent_window" : "unattributed_process_window"
      row.keys.sort == %w[classification kind operation protocol remote state window] &&
        row["classification"] == expected &&
        row["kind"] == "network" &&
        row["operation"] == "connection" &&
        %w[tcp4 tcp6 udp4 udp6].include?(row["protocol"]) &&
        %w[remote state window].all? {
          |key| row[key].is_a?(String) && !row[key].empty? && row[key].bytesize <= 256
        }
    end
  end

  def valid_creator_authoring_evidence?(record)
    record.is_a?(Hash) &&
      record.keys.sort == %w[driver_sha256 model_loop proof_mode receipt_sha256] &&
      record["driver_sha256"].to_s.match?(/\A[0-9a-f]{64}\z/) &&
      (
        (
          record["proof_mode"] == "direct_native_tool_surface" &&
          record["model_loop"] == "not_exercised" &&
          record["receipt_sha256"].to_s.match?(/\A[0-9a-f]{64}\z/)
        ) ||
        (
          record["proof_mode"] == "credentialed_openclaw_agent" &&
          record["model_loop"] == "executed" &&
          record["receipt_sha256"].nil?
        )
      )
  end

  def valid_external_actions_scope?(record)
    record.is_a?(Hash) &&
      record.keys.sort == %w[
        derivation global_effect_absence_claimed limitations monitored_surfaces
        network_authorization observed_unadjudicated_surfaces
      ] &&
      record["derivation"] == "scoped_policy_and_filesystem_observations" &&
      record["network_authorization"] == "unverified" &&
      record["observed_unadjudicated_surfaces"] == [ "process_socket_snapshots" ] &&
      record["global_effect_absence_claimed"] == false &&
      record["monitored_surfaces"] ==
        [ *WORKFLOW_CREATOR_POLICY_SURFACES, "workspace_before_after_snapshots" ] &&
      !record["monitored_surfaces"].include?("process_socket_snapshots") &&
      record["limitations"] == [
        WORKFLOW_CREATOR_OUTSIDE_READ_CAVEAT,
        WORKFLOW_CREATOR_SOCKET_LIMITATION
      ]
  end

  def valid_openclaw_package_evidence?(record)
    record.is_a?(Hash) &&
      record.keys.sort == %w[
        integrity lock_sha256 package_count receipt_sha256 verified version
      ] &&
      record["version"] == WORKFLOW_CREATOR_OPENCLAW_VERSION &&
      record["integrity"] == WORKFLOW_CREATOR_OPENCLAW_INTEGRITY &&
      record["lock_sha256"] == WORKFLOW_CREATOR_OPENCLAW_LOCK_SHA256 &&
      record["receipt_sha256"].to_s.match?(/\A[0-9a-f]{64}\z/) &&
      record["package_count"] == WORKFLOW_CREATOR_OPENCLAW_PACKAGE_COUNT &&
      record["verified"] == true
  end

  def valid_executable_record?(record)
    record.is_a?(Hash) &&
      record["configured_path"].to_s.start_with?("/") &&
      record["realpath"].to_s.start_with?("/") &&
      record["sha256"].to_s.match?(/\A[0-9a-f]{64}\z/)
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

    def initialize(candidate_dir:, candidate_sha:, expected_hive_version:, canonical:,
                   archive_file_limit: SKILL_ARCHIVE_FILE_LIMIT,
                   archive_total_limit: SKILL_ARCHIVE_TOTAL_LIMIT,
                   archive_entry_limit: SKILL_ARCHIVE_ENTRY_LIMIT,
                   archive_directory_limit: SKILL_ARCHIVE_DIRECTORY_LIMIT,
                   archive_depth_limit: SKILL_ARCHIVE_DEPTH_LIMIT,
                   archive_inode_limit: SKILL_ARCHIVE_INODE_LIMIT)
      @candidate_dir = File.expand_path(candidate_dir)
      @candidate_sha = HiveLiveAgentProof.validate_sha!(candidate_sha, "candidate_sha")
      @expected_hive_version = expected_hive_version.to_s
      @canonical = canonical
      @archive_file_limit = Integer(archive_file_limit)
      @archive_total_limit = Integer(archive_total_limit)
      @archive_entry_limit = Integer(archive_entry_limit)
      @archive_directory_limit = Integer(archive_directory_limit)
      @archive_depth_limit = Integer(archive_depth_limit)
      @archive_inode_limit = Integer(archive_inode_limit)
      raise Error, "expected Hive version must not be empty" if @expected_hive_version.empty?
      unless [
        @archive_file_limit, @archive_total_limit, @archive_entry_limit,
        @archive_directory_limit, @archive_depth_limit, @archive_inode_limit
      ].all?(&:positive?)
        raise Error, "skill archive limits must be positive"
      end
    rescue ArgumentError, TypeError
      raise Error, "skill archive limits must be positive integers"
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
        record = actual.fetch(name)
        unless record["size"] == content.bytesize &&
               record["sha256"] == Digest::SHA256.hexdigest(content)
          raise Error, "skill archive projection differs from canonical source: #{name}"
        end
      end
    end

    def read_skill_archive(path)
      files = {}
      seen = {}
      materialized_directories = {}
      total_size = 0
      entry_count = 0
      file_count = 0
      Zlib::GzipReader.open(path) do |gzip|
        Gem::Package::TarReader.new(gzip) do |tar|
          tar.each do |entry|
            entry_count += 1
            if entry_count > @archive_entry_limit
              raise Error, "skill archive contains more than #{@archive_entry_limit} entries"
            end
            name = entry.full_name.sub(%r{\A\./}, "")
            next if name.empty? && entry.directory?

            clean = Pathname.new(name).cleanpath
            if name.empty? || clean.absolute? || clean.each_filename.include?("..")
              raise Error, "skill archive contains an unsafe entry: #{name}"
            end
            clean_name = clean.to_s
            if seen.key?(clean_name) ||
               (entry.directory? && materialized_directories.key?(clean_name))
              raise Error, "skill archive contains duplicate entry: #{clean_name}"
            end
            seen[clean_name] = entry.directory? ? "directory" : "file"
            depth = clean.each_filename.count
            if depth > @archive_depth_limit
              raise Error, "skill archive entry exceeds depth #{@archive_depth_limit}: #{clean_name}"
            end
            parts = clean.each_filename.to_a
            parent_limit = entry.directory? ? parts.length : parts.length - 1
            parent_limit.times do |index|
              directory = parts.first(index + 1).join("/")
              if seen[directory] == "file"
                raise Error, "skill archive path conflicts with a file: #{directory}"
              end
              materialized_directories[directory] = true
            end
            directory_count = materialized_directories.length
            if directory_count > @archive_directory_limit
              raise Error,
                    "skill archive materializes more than #{@archive_directory_limit} directories"
            end
            if entry.directory?
              next
            end
            unless entry.file?
              raise Error, "skill archive contains an unsafe entry: #{clean_name}"
            end
            if materialized_directories.key?(clean_name)
              raise Error, "skill archive file conflicts with a directory: #{clean_name}"
            end
            file_count += 1
            if directory_count + file_count > @archive_inode_limit
              raise Error, "skill archive materializes more than #{@archive_inode_limit} inodes"
            end

            size = Integer(entry.header.size)
            if size > @archive_file_limit
              raise Error, "skill archive entry exceeds #{@archive_file_limit} bytes: #{clean_name}"
            end
            total_size += size
            if total_size > @archive_total_limit
              raise Error, "skill archive expands beyond #{@archive_total_limit} bytes"
            end
            files[clean_name] = digest_archive_entry(entry, size, clean_name)
          end
        end
      end
      files
    rescue Zlib::GzipFile::Error, Gem::Package::TarInvalidError, EOFError,
           ArgumentError, RangeError, IOError => e
      raise Error, "cannot read skill archive: #{e.message}"
    end

    def digest_archive_entry(entry, expected_size, name)
      digest = Digest::SHA256.new
      bytes_read = 0
      while bytes_read < expected_size
        chunk = entry.read([ 16 * 1024, expected_size - bytes_read ].min)
        if chunk.nil? || chunk.empty?
          raise Error, "skill archive entry is truncated: #{name}"
        end

        digest.update(chunk)
        bytes_read += chunk.bytesize
      end
      { "sha256" => digest.hexdigest, "size" => bytes_read }
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
      WorkflowCreatorContract.validate!(
        row: row, manifest: manifest, candidate_sha: @candidate_sha
      )
      findings = HiveLiveAgentProof.secret_findings(File.read(path))
      raise Error, "workflow-creator evidence secret scan failed: #{findings.join(', ')}" unless findings.empty?

      row
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
      WorkflowCreatorContract.validate!(
        row: row, manifest: manifest, candidate_sha: @candidate_sha
      )
    end
  end
end

require_relative "workflow_creator_contract"
