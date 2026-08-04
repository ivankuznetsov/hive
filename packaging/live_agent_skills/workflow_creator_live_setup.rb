# frozen_string_literal: true

require "base64"
require "digest"
require "fileutils"
require "find"
require "json"
require "open3"
require "pathname"
require "rubygems/package"
require "timeout"
require "zlib"
require_relative "proof"
require_relative "workflow_creator_live_runner"
require_relative "workflow_creator_openclaw_runtime"

module HiveLiveAgentProof
  class WorkflowCreatorLiveSetup
    class Error < StandardError; end

    MAX_IDENTITY_FILES = 512
    MAX_RUNTIME_FILES = 50_000
    MAX_FILE_BYTES = 268_435_456
    MAX_TOTAL_BYTES = 1_073_741_824
    NPM_REGISTRY = "https://registry.npmjs.org"
    CONFIGURATION_SCHEMA = "hive-live-openclaw-creator-configuration/v1"
    CANDIDATE_RUNTIME_SCHEMA = "hive-workflow-creator-candidate-runtime/v1"
    PROJECTION_SCHEMA = "hive-workflow-creator-openclaw-skill/v1"
    FIXTURE_RECEIPT = {
      "actions" => [], "run_count" => 1,
      "schema" => "hive-workflow-creator-first-stage-fixture", "schema_version" => 1,
      "stage" => "research", "status" => "passed"
    }.freeze
    PROVIDER_ENDPOINTS = {
      "openai" => "https://api.openai.com/v1",
      "openrouter" => "https://openrouter.ai/api/v1"
    }.freeze
    AUTHORITY = /\A(?:GH_|GITHUB_|GIT_|SSH_|CI_JOB_TOKEN\z|CI_DEPLOY_PASSWORD\z)/i
    CREDENTIAL = /(?:TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL|API_?KEY|PRIVATE_?KEY|AUTHORIZATION|COOKIE|SESSION)/i
    OPENCLAW_LOCAL_ENV = %w[HOME OPENCLAW_STATE_DIR OPENCLAW_CONFIG_PATH PATH LANG LC_ALL TERM TMPDIR
                             SHELL HIVE_LIVE_PROOF].freeze

    class << self
      def prepare!(**options) = new(**options).send(:prepare)
      private :new
    end

    def initialize(candidate_dir:, candidate_sha:, hive_version:, canonical:, candidate_runtime_root:,
                   candidate_hive:, ruby:, openclaw_runtime_root:, openclaw_entrypoint:, node:,
                   openclaw_lock:, openclaw_package:, output_root:, workspace_path:, bundle_directory:,
                   model:, provider:, transport:, correlation_id:, supervisor_options: {})
      @candidate_dir = absolute(candidate_dir)
      @candidate_sha = HiveLiveAgentProof.validate_sha!(candidate_sha, "candidate_sha")
      @hive_version = hive_version.to_s
      @canonical = canonical
      @output_root = absolute(output_root)
      @candidate_runtime = absolute(candidate_runtime_root)
      @candidate_hive = absolute(candidate_hive)
      @ruby = absolute(ruby)
      @openclaw_runtime = absolute(openclaw_runtime_root)
      @openclaw_entrypoint = absolute(openclaw_entrypoint)
      @node = absolute(node)
      @openclaw_lock = absolute(openclaw_lock)
      @openclaw_package = absolute(openclaw_package)
      @workspace = absolute(workspace_path)
      @bundle = absolute(bundle_directory)
      @model, @provider = model.to_s, provider.to_s
      @transport = WorkflowCreator::Values.capture(transport).value
      @correlation_id = correlation_id.to_s
      @supervisor_options = supervisor_options
      validate_roots!
    rescue StandardError => error
      raise Error, "workflow-creator live setup inputs are invalid: #{error.message}", cause: nil
    end

    def prepare
      verified = CandidateVerifier.new(
        candidate_dir: @candidate_dir, candidate_sha: @candidate_sha,
        expected_hive_version: @hive_version, canonical: @canonical
      ).call
      candidate, skill_source, fixture = build_candidate(verified)
      openclaw, configuration = build_openclaw(candidate.fetch("root"), skill_source)
      available_bytes, available_entries = filesystem_capacity(File.dirname(@workspace))
      archives = {
        "candidate-package" => archive_row(candidate.fetch("package"), available_bytes, available_entries),
        "openclaw-package" => archive_row(openclaw.fetch("package"), available_bytes, available_entries)
      }
      candidate_environment = candidate.fetch("environment")
      preparer = WorkspacePreparer.new(
        workspace: @workspace, skill_source:, candidate_executable: candidate.fetch("executable"),
        candidate_environment:, openclaw_executable: openclaw.fetch("executable"),
        projection_manifest_sha256: configuration.dig("skill", "projection_manifest_sha256")
      )
      observer = ExternalActionsObserver.new(
        workspace: @workspace, candidate_environment:, fixture_path: fixture,
        receipt_bytes: WorkflowCreator::Values.capture(FIXTURE_RECEIPT).canonical_bytes
      )
      {
        candidate_sha: @candidate_sha, model: @model, configuration_record: configuration.fetch("path"),
        execution_options: {
          candidate_sha: @candidate_sha, manifest: verified.fetch("manifest"), candidate:, openclaw:, archives:,
          workspace_path: @workspace, bundle_directory: @bundle, correlation_id: @correlation_id,
          supervisor_options: @supervisor_options
        },
        runtime_install_verifier: WorkflowCreatorOpenClawRuntime.method(:verify!),
        external_actions_observer: observer, workspace_preparer: preparer,
        skill_source:
      }
    rescue Error
      raise
    rescue StandardError => error
      raise Error, "workflow-creator live setup failed: #{error.class}: #{error.message}", cause: nil
    end

    def build_candidate(verified)
      root = create_identity_root("candidate-identity")
      skill_source, projection_sha = extract_projection(verified.fetch("skills"), root)
      package = copy_exact(verified.fetch("gem"), root, "packages/hive-cli-#{@hive_version}.gem", 0o600)
      ruby = copy_exact(@ruby, root, "runtime/ruby", 0o700)
      fixture = write_exact(root, "fixtures/first-stage-agent", first_stage_fixture_source, 0o700)
      runtime_manifest = capture_candidate_runtime
      manifest = write_exact(root, "runtime/candidate-runtime-manifest.json", runtime_manifest, 0o600)
      manifest_sha = Digest::SHA256.file(manifest).hexdigest
      guard = write_exact(root, "libexec/candidate-runtime-guard.rb", candidate_guard_source(manifest_sha), 0o600)
      executable = write_exact(root, "bin/hive", candidate_launcher_source, 0o700)
      lock = write_canonical(
        root, "runtime/runtime-lock.json",
        {
          "schema" => "hive-workflow-creator-candidate-lock", "schema_version" => 1,
          "candidate_sha" => @candidate_sha, "hive_version" => @hive_version,
          "package_sha256" => Digest::SHA256.file(package).hexdigest,
          "ruby_sha256" => Digest::SHA256.file(ruby).hexdigest,
          "runtime_manifest_sha256" => manifest_sha,
          "guard_sha256" => Digest::SHA256.file(guard).hexdigest,
          "fixture_sha256" => Digest::SHA256.file(fixture).hexdigest,
          "projection_manifest_sha256" => projection_sha
        }
      )
      gateway_root = File.join(root, "gateway")
      Dir.mkdir(gateway_root, 0o700)
      gateway = File.join(gateway_root, WorkflowCreatorGateway::WRAPPER_NAME)
      inventory = identity_inventory(root) + [ relative(root, gateway) ]
      inventory = inventory.sort
      raise Error if inventory.length > MAX_IDENTITY_FILES || inventory.uniq.length != inventory.length
      environment = {
        "PATH" => "/usr/bin:/bin", "HOME" => File.join(@workspace, ".hive-proof-home"),
        "HIVE_HOME" => File.join(@workspace, ".hive-proof-hive-home"),
        "GEM_HOME" => @candidate_runtime, "GEM_PATH" => @candidate_runtime,
        "HIVE_CLAUDE_BIN" => fixture, "HIVE_DAEMON_NO_AUTO_REEXEC" => "1",
        "HIVE_SKIP_LLM_WIKI_SCHEDULER" => "1", "HIVE_SKIP_LLM_WIKI_SYSTEMCTL" => "1",
        "HIVE_SKIP_LLM_WIKI_POST_COMMIT" => "1"
      }
      [
        {
          "root" => root, "inventory" => inventory, "audit_gateway" => gateway,
          "executable" => executable, "interpreter_or_launcher" => ruby,
          "lock" => lock, "package" => package, "environment" => environment
        },
        skill_source, fixture
      ]
    end

    def build_openclaw(candidate_root, skill_source)
      dependency = dependency_identity
      root = create_identity_root("openclaw-identity")
      node = copy_exact(@node, root, "runtime/node", 0o700)
      admit_node_version!(node, dependency.fetch("node_version"))
      lock = copy_exact(@openclaw_lock, root, "package-lock.json", 0o600)
      package = copy_exact(@openclaw_package, root, "packages/openclaw.tgz", 0o600)
      shell = write_exact(root, "security/hive-creator-shell",
                          WorkflowCreatorLiveRunner.shell_sanitizer_bytes, 0o700)
      launcher = write_exact(root, "bin/openclaw", openclaw_launcher_source, 0o700)
      launcher_sha = Digest::SHA256.file(launcher).hexdigest
      runtime = WorkflowCreatorOpenClawRuntime.capture!(
        root: @openclaw_runtime, launcher_sha256: launcher_sha
      ).value
      projection_manifest = File.join(skill_source, "projection-manifest.json")
      configuration = {
        "schema" => CONFIGURATION_SCHEMA, "schema_version" => 1,
        "candidate_sha" => @candidate_sha, "provider" => @provider, "model" => @model,
        "transport" => @transport, "dependency" => dependency,
        "tool_environment" => {
          "authority" => "shell_sanitized", "pass_env" => [],
          "shell" => {
            "path" => relative(root, shell), "sha256" => Digest::SHA256.file(shell).hexdigest,
            "size" => File.size(shell)
          }
        },
        "runtime_install" => runtime,
        "skill" => {
          "path" => relative(candidate_root, skill_source),
          "projection_manifest_sha256" => Digest::SHA256.file(projection_manifest).hexdigest
        }
      }
      configuration_path = write_canonical(root, "creator-configuration.json", configuration)
      inventory = identity_inventory(root)
      raise Error if inventory.length > MAX_IDENTITY_FILES
      openclaw = {
        "root" => root, "version" => dependency.fetch("version"), "inventory" => inventory,
        "executable" => launcher, "interpreter_or_launcher" => node,
        "lock" => lock, "package" => package
      }
      [ openclaw, configuration.merge("path" => configuration_path) ]
    end

    def dependency_identity
      bytes = safe_file(@openclaw_lock, 16 * 1_048_576)
      lock = JSON.parse(bytes)
      packages = lock.fetch("packages")
      root = packages.fetch("")
      package = packages.fetch("node_modules/openclaw")
      version = package.fetch("version")
      node_version = observed_version(@node)
      node_engine = package.dig("engines", "node")
      expected_integrity = "sha512-#{Base64.strict_encode64(Digest::SHA512.file(@openclaw_package).digest)}"
      resolved = "#{NPM_REGISTRY}/openclaw/-/openclaw-#{version}.tgz"
      valid = lock.fetch("lockfileVersion") == 3 && root.dig("dependencies", "openclaw") == version
      valid &&= root.dig("engines", "node") == node_version
      valid &&= node_engine.instance_of?(String) && !node_engine.empty?
      valid &&= package.values_at("resolved", "integrity") == [ resolved, expected_integrity ]
      raise Error unless valid
      lifecycle = packages.filter_map { |path, row| path unless path.empty? || row["hasInstallScript"] != true }.sort
      {
        "package" => "openclaw", "version" => version, "registry" => NPM_REGISTRY,
        "integrity" => expected_integrity, "lock_sha256" => Digest::SHA256.hexdigest(bytes),
        "package_count" => packages.length, "node_engine" => node_engine,
        "node_version" => node_version, "lifecycle_scripts" => lifecycle
      }
    rescue JSON::ParserError, KeyError, TypeError
      raise Error, "OpenClaw dependency identity is invalid", cause: nil
    end

    def extract_projection(archive, root)
      expected = @canonical.render("openclaw")
      prefix = "openclaw/hive/"
      files = {}
      Zlib::GzipReader.open(archive) do |gzip|
        Gem::Package::TarReader.new(gzip) do |tar|
          tar.each do |entry|
            name = entry.full_name.delete_prefix("./")
            next unless entry.file? && name.start_with?(prefix)
            files[name.delete_prefix(prefix)] = entry.read
          end
        end
      end
      mismatch = (files.keys | expected.files.keys).select do |path|
        files[path]&.b != expected.files[path]&.b
      end
      raise Error, "OpenClaw skill projection does not match canonical bytes" unless mismatch.empty?
      skill = File.join(root, "skill", "hive")
      files.sort.each { |path, bytes| write_exact(skill, path, bytes, 0o600) }
      manifest = WorkflowCreator::Values.capture(
        "schema" => PROJECTION_SCHEMA, "schema_version" => 1, "platform" => "openclaw",
        "invocation" => expected.invocation, "skill_version" => expected.skill_version,
        "canonical_digest" => expected.canonical_digest,
        "files" => files.keys.sort.map do |path|
          bytes = files.fetch(path)
          { "path" => path, "sha256" => Digest::SHA256.hexdigest(bytes), "size" => bytes.bytesize }
        end
      )
      path = write_exact(skill, "projection-manifest.json", manifest.canonical_bytes, 0o600)
      [ skill, Digest::SHA256.file(path).hexdigest ]
    rescue Zlib::GzipFile::Error, Gem::Package::TarInvalidError, EOFError
      raise Error, "OpenClaw skill projection is invalid", cause: nil
    end

    def capture_candidate_runtime
      records = scan_regular_tree(@candidate_runtime)
      entrypoint = relative(@candidate_runtime, @candidate_hive)
      raise Error unless records.any? { |row| row.fetch("path") == entrypoint }
      canonical_records = records.map do |row|
        { "mode" => row.fetch("mode"), "path" => row.fetch("path"),
          "sha256" => row.fetch("sha256"), "size" => row.fetch("size") }
      end
      JSON.generate(
        "entrypoint" => entrypoint, "files" => canonical_records,
        "schema" => CANDIDATE_RUNTIME_SCHEMA, "schema_version" => 1
      ) << "\n"
    end

    def scan_regular_tree(root)
      records = []
      total = 0
      Find.find(root) do |path|
        stat = File.lstat(path)
        if stat.directory?
          raise Error unless stat.uid == Process.uid && (stat.mode & 0o022).zero?
          next
        end
        raise Error unless stat.file? && !stat.symlink? && stat.uid == Process.uid && stat.nlink == 1
        raise Error unless (stat.mode & 0o022).zero? && stat.size.between?(0, MAX_FILE_BYTES)
        total += stat.size
        raise Error if total > MAX_TOTAL_BYTES
        records << {
          "path" => relative(root, path), "sha256" => Digest::SHA256.file(path).hexdigest,
          "size" => stat.size, "mode" => stat.mode & 0o777
        }
        raise Error if records.length > MAX_RUNTIME_FILES
      end
      raise Error if records.empty?
      records.sort_by { |row| row.fetch("path") }
    end

    def candidate_guard_source(manifest_sha)
      <<~RUBY
        # frozen_string_literal: true
        require "digest"
        require "find"
        require "json"
        root = File.realpath(File.expand_path("..", __dir__))
        runtime = File.realpath(File.join(root, "..", "candidate-runtime"))
        manifest_path = File.join(root, "runtime", "candidate-runtime-manifest.json")
        abort "candidate runtime manifest changed" unless Digest::SHA256.file(manifest_path).hexdigest == #{manifest_sha.dump}
        manifest = JSON.parse(File.binread(manifest_path))
        abort "candidate runtime manifest invalid" unless manifest.keys.sort == %w[entrypoint files schema schema_version]
        actual = []
        Find.find(runtime) do |path|
          stat = File.lstat(path)
          if stat.directory?
            abort "candidate runtime directory unsafe" unless stat.uid == Process.uid && (stat.mode & 0o022).zero?
            next
          end
          abort "candidate runtime member unsafe" unless stat.file? && !stat.symlink? && stat.uid == Process.uid && stat.nlink == 1 && (stat.mode & 0o022).zero?
          relative = path.delete_prefix("\#{runtime}/")
          actual << { "path" => relative, "sha256" => Digest::SHA256.file(path).hexdigest,
                      "size" => stat.size, "mode" => stat.mode & 0o777 }
        end
        actual.sort_by! { |row| row.fetch("path") }
        abort "candidate runtime changed" unless actual == manifest.fetch("files")
        hive = File.join(runtime, manifest.fetch("entrypoint"))
        ruby = File.join(root, "runtime", "ruby")
        exec ruby, hive, *ARGV
      RUBY
    end

    def candidate_launcher_source
      <<~'SH'
        #!/bin/sh
        set -eu
        hive_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
        exec "$hive_root/runtime/ruby" "$hive_root/libexec/candidate-runtime-guard.rb" "$@"
      SH
    end

    def first_stage_fixture_source
      receipt = WorkflowCreator::Values.capture(FIXTURE_RECEIPT).canonical_bytes
      escaped_receipt = receipt.bytes.map { |byte| format("\\%03o", byte) }.join
      <<~SH
        #!/bin/bash
        set -eu -o pipefail
        if [[ "\${1:-}" == "--version" ]]; then
          printf '%s (Claude Code)\\n' '2.1.118'
          exit 0
        fi
        mapfile -t hive_research_files < <(find "$PWD/.hive-state/stages/1-research" -mindepth 2 -maxdepth 2 -type f -name research.md -print | sort)
        [[ "\${#hive_research_files[@]}" -eq 1 ]] || { printf '%s\\n' 'fixture expected one research task' >&2; exit 64; }
        receipt="$PWD/.hive-state/workflow-creator-fixture-receipt.json"
        [[ ! -e "$receipt" ]] || { printf '%s\\n' 'fixture already executed' >&2; exit 64; }
        printf '%s\\n\\n<!-- COMPLETE -->\\n' '# Deterministic first-stage research' > "\${hive_research_files[0]}"
        printf '%b' #{escaped_receipt.dump} > "$receipt"
        printf '%s\\n' '{"type":"result","result":"deterministic first-stage fixture"}'
      SH
    end

    def openclaw_launcher_source
      entrypoint = relative(@openclaw_runtime, @openclaw_entrypoint)
      <<~SH
        #!/bin/sh
        set -eu
        openclaw_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
        runtime=$(CDPATH= cd -- "$openclaw_root/../openclaw-runtime" && pwd -P)
        exec "$openclaw_root/runtime/node" "$runtime/#{entrypoint}" "$@"
      SH
    end

    def validate_roots!
      raise Error if @hive_version.empty? || @correlation_id.empty?
      raise Error unless PROVIDER_ENDPOINTS.fetch(@provider) == @transport.fetch("endpoint")
      raise Error unless @model.start_with?("#{@provider}/")
      raise Error unless @transport.keys.sort == %w[ca endpoint proxy redirects]
      raise Error unless @transport.fetch("redirects") == "deny"
      raise Error unless File.directory?(@output_root) && private_directory?(@output_root)
      expected = [ File.join(@output_root, "candidate-runtime"), File.join(@output_root, "openclaw-runtime") ]
      raise Error unless [ @candidate_runtime, @openclaw_runtime ] == expected
      raise Error unless [ @candidate_runtime, @openclaw_runtime, @bundle ].all? { |path| private_directory?(path) }
      raise Error if File.exist?(@workspace) || File.symlink?(@workspace)
      [ @candidate_hive, @ruby, @openclaw_entrypoint, @node, @openclaw_lock, @openclaw_package ].each do |path|
        safe_file(path, 268_435_456)
      end
      relative(@candidate_runtime, @candidate_hive)
      relative(@openclaw_runtime, @openclaw_entrypoint)
    end

    def create_identity_root(name)
      root = File.join(@output_root, name)
      Dir.mkdir(root, 0o700)
      root
    rescue SystemCallError
      raise Error, "identity closure cannot be created", cause: nil
    end

    def copy_exact(source, root, relative_path, mode)
      bytes = safe_file(source, 268_435_456)
      write_exact(root, relative_path, bytes, mode)
    end

    def write_canonical(root, relative_path, value)
      write_exact(root, relative_path, WorkflowCreator::Values.capture(value).canonical_bytes, 0o600)
    end

    def write_exact(root, relative_path, bytes, mode)
      path = File.expand_path(relative_path, root)
      raise Error unless path.start_with?("#{File.expand_path(root)}/")
      FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, mode) { |file| file.write(bytes) }
      File.chmod(mode, path)
      path
    rescue SystemCallError
      raise Error, "identity closure member cannot be written", cause: nil
    end

    def identity_inventory(root)
      files = scan_regular_tree(root).map { |row| row.fetch("path") }
      raise Error if files.length > MAX_IDENTITY_FILES
      files
    end

    def safe_file(path, limit)
      stat = File.lstat(path)
      valid = stat.file? && !stat.symlink? && stat.uid == Process.uid && stat.nlink == 1
      valid &&= (stat.mode & 0o022).zero? && stat.size.between?(1, limit)
      raise Error unless valid
      bytes = File.binread(path)
      raise Error unless File.lstat(path).ino == stat.ino
      bytes
    rescue SystemCallError
      raise Error, "setup input is not a safe regular file", cause: nil
    end

    def private_directory?(path)
      stat = File.lstat(path)
      File.realpath(path) == path && stat.directory? && !stat.symlink? && stat.uid == Process.uid &&
        (stat.mode & 0o077).zero?
    rescue SystemCallError
      false
    end

    def observed_version(node)
      stdout, stderr, status = Open3.capture3({}, node, "--version", unsetenv_others: true)
      match = stdout.strip.match(/\Av(\d+\.\d+\.\d+)\z/)
      raise Error unless status.success? && stderr.empty? && match
      match[1]
    end

    def admit_node_version!(node, expected)
      raise Error unless observed_version(node) == expected
    end

    def filesystem_capacity(path)
      df = %w[/usr/bin/df /bin/df].find { |candidate| File.executable?(candidate) }
      raise Error unless df
      bytes = df_available(df, "-Pk", path) * 1024
      entries = df_available(df, "-Pi", path)
      raise Error unless bytes.positive? && entries.positive?
      [ bytes, entries ]
    end

    def df_available(df, flag, path)
      stdout, stderr, status = Open3.capture3({}, df, flag, path, unsetenv_others: true)
      fields = stdout.lines.last.to_s.split
      raise Error unless status.success? && stderr.empty? && fields.length >= 6
      Integer(fields.fetch(3), 10)
    end

    def archive_row(path, available_bytes, available_entries)
      { "path" => path, "available_bytes" => available_bytes, "available_entries" => available_entries }
    end

    def relative(root, path)
      root = File.realpath(root)
      path = File.expand_path(path)
      raise Error unless path.start_with?("#{root}/")
      value = WorkflowCreator::Values.capture(path.delete_prefix("#{root}/")).value
      raise Error unless WorkflowCreator::TextSafety.safe_relative_path?(value)
      value
    rescue WorkflowCreator::TextSafety::Error, SystemCallError
      raise Error, "setup path escapes its closure", cause: nil
    end

    def absolute(path)
      expanded = File.expand_path(path.to_s)
      raise Error if expanded.empty?
      expanded
    end

    class WorkspacePreparer
      def initialize(workspace:, skill_source:, candidate_executable:, candidate_environment:,
                     openclaw_executable:, projection_manifest_sha256:)
        @workspace, @skill_source, @candidate = workspace, skill_source, candidate_executable
        @openclaw = openclaw_executable
        @environment = WorkflowCreator::Values.capture(candidate_environment)
        @projection_sha = projection_manifest_sha256
        @git = %w[/usr/bin/git /bin/git].find { |path| File.executable?(path) }
        raise Error unless @git
      end

      def call(workspace:, candidate_environment:, openclaw_environment:, gateway_path:)
        raise Error unless workspace == @workspace
        raise Error unless WorkflowCreator::Values.capture(candidate_environment).canonical_bytes ==
                           @environment.canonical_bytes
        stat = File.lstat(workspace)
        raise Error unless stat.directory? && stat.uid == Process.uid && (stat.mode & 0o077).zero?
        manifest = File.join(@skill_source, "projection-manifest.json")
        raise Error unless Digest::SHA256.file(manifest).hexdigest == @projection_sha
        projection = admit_skill_projection!(manifest)
        destination = File.join(workspace, "skills", "hive")
        raise Error if File.exist?(destination) || File.symlink?(destination)
        materialize_skill!(destination, manifest, projection)
        FileUtils.mkdir_p([ @environment.value.fetch("HOME"), @environment.value.fetch("HIVE_HOME") ], mode: 0o700)
        write(File.join(workspace, ".gitignore"), proof_gitignore)
        write(File.join(workspace, "README.md"), "# Workflow creator live proof\n")
        git!(workspace, "init", "-b", "main")
        git!(workspace, "config", "user.name", "Hive Live Proof")
        git!(workspace, "config", "user.email", "hive-live-proof@example.invalid")
        git!(workspace, "add", "--", ".gitignore", "README.md")
        git!(workspace, "commit", "-m", "chore: initialize workflow creator proof")
        stdout, stderr, status = Open3.capture3(
          @environment.value, @candidate, "init", workspace, "--minimal", "--new-workflow", "proof-seed", "--json",
          chdir: workspace, unsetenv_others: true
        )
        raise Error unless status.success? && stderr.empty?
        init = JSON.parse(stdout)
        answers = init.fetch("answers")
        minimal = init.values_at("schema", "ok", "minimal") == [ "hive-init", true, true ]
        disabled = answers.values_at(
          "daemon_enabled", "babysitter_enabled", "daemon_autostart", "refactor_patrol_enabled",
          "adhoc_auto_fix"
        ) == [ false, false, false, false, false ]
        disabled &&= answers.fetch("patrol_mode") == "off"
        raise Error unless minimal && disabled
        raise Error unless File.file?(File.join(workspace, ".hive-state", "config.yml"))
        raise Error unless git_output(workspace, "remote").empty?
        approval = configure_openclaw!(openclaw_environment, gateway_path)
        WorkflowCreator::Values.capture(
          "schema" => "hive-workflow-creator-workspace-preparation", "schema_version" => 1,
          "status" => "prepared", "skill_manifest_sha256" => @projection_sha,
          "init_stdout_sha256" => Digest::SHA256.hexdigest(stdout),
          "git_head" => git_output(workspace, "rev-parse", "HEAD"),
          "openclaw_config_validation_sha256" => approval.fetch("config_validation_sha256"),
          "openclaw_effective_policy_sha256" => approval.fetch("effective_policy_sha256")
        ).value
      rescue StandardError => error
        raise Error, "workflow-creator workspace preparation failed: #{error.class}: #{error.message}", cause: nil
      end

      private

      def admit_skill_projection!(manifest_path)
        bytes = safe_skill_file(manifest_path)
        projection = WorkflowCreator::Values.capture(JSON.parse(bytes))
        raise Error unless bytes == projection.canonical_bytes
        row = projection.value
        raise Error unless row.keys.sort == %w[canonical_digest files invocation platform schema schema_version skill_version]
        raise Error unless row.values_at("schema", "schema_version", "platform") ==
                           [ PROJECTION_SCHEMA, 1, "openclaw" ]
        files = row.fetch("files")
        raise Error unless files.instance_of?(Array) && !files.empty?
        expected = files.map do |record|
          raise Error unless record.keys.sort == %w[path sha256 size]
          relative = record.fetch("path")
          path = File.expand_path(relative, @skill_source)
          raise Error unless path.delete_prefix("#{@skill_source}/") == relative
          content = safe_skill_file(path)
          raise Error unless record.values_at("sha256", "size") ==
                             [ Digest::SHA256.hexdigest(content), content.bytesize ]
          relative
        end
        actual = Dir.glob(File.join(@skill_source, "**", "*"), File::FNM_DOTMATCH).filter_map do |path|
          stat = File.lstat(path)
          raise Error if stat.symlink? || stat.uid != Process.uid || (stat.mode & 0o022).positive?
          next if stat.directory?
          path.delete_prefix("#{@skill_source}/")
        end
        raise Error unless actual.sort == (expected + [ "projection-manifest.json" ]).sort
        projection.value
      end

      def materialize_skill!(destination, manifest, projection)
        FileUtils.mkdir_p(destination, mode: 0o700)
        projection.fetch("files").each do |row|
          relative = row.fetch("path")
          target = File.join(destination, relative)
          FileUtils.mkdir_p(File.dirname(target), mode: 0o700)
          write(target, safe_skill_file(File.join(@skill_source, relative)))
        end
        write(File.join(destination, "projection-manifest.json"), safe_skill_file(manifest))
      end

      def safe_skill_file(path)
        stat = File.lstat(path)
        valid = stat.file? && !stat.symlink? && stat.uid == Process.uid && stat.nlink == 1
        valid &&= (stat.mode & 0o022).zero? && stat.size.between?(1, 1_048_576)
        raise Error unless valid
        bytes = File.binread(path)
        raise Error unless File.lstat(path).ino == stat.ino
        bytes
      end

      def configure_openclaw!(provided_environment, gateway_path)
        environment = credential_free_openclaw_environment(provided_environment)
        expected_gateway = File.join(@workspace, ".hive-openclaw", "bin", "hive")
        raise Error unless gateway_path == expected_gateway && File.symlink?(gateway_path)
        raise Error unless File.executable?(File.realpath(gateway_path))

        config_stdout = run_openclaw!(environment, "config", "validate")
        policy = approvals(gateway_path)
        request_path = File.join(@workspace, ".hive-openclaw", "approvals-request.json")
        write(request_path, WorkflowCreator::Values.capture(policy).canonical_bytes)
        run_openclaw!(
          environment, "approvals", "set", "--file", request_path, "--json",
          allowed_stderr: "Writing local approvals.\n"
        )
        snapshot = JSON.parse(run_openclaw!(environment, "approvals", "get", "--json"))
        effective = admit_effective_policy!(snapshot, policy)
        {
          "config_validation_sha256" => Digest::SHA256.hexdigest(config_stdout),
          "effective_policy_sha256" => Digest::SHA256.hexdigest(
            WorkflowCreator::Values.capture(effective).canonical_bytes
          )
        }
      rescue JSON::ParserError, SystemCallError, WorkflowCreator::Values::Error
        raise Error
      end

      def credential_free_openclaw_environment(environment)
        raw = environment.to_h.to_h { |key, value| [ key.to_s, value.to_s ] }
        raise Error if raw.empty?
        required = %w[HOME OPENCLAW_STATE_DIR OPENCLAW_CONFIG_PATH SHELL HIVE_LIVE_PROOF]
        raise Error unless required.all? { |key| raw.key?(key) }
        expected = {
          "HOME" => File.join(@workspace, ".hive-openclaw", "home"),
          "OPENCLAW_STATE_DIR" => File.join(@workspace, ".hive-openclaw"),
          "OPENCLAW_CONFIG_PATH" => File.join(@workspace, ".hive-openclaw", "openclaw.json"),
          "HIVE_LIVE_PROOF" => "1"
        }
        raise Error unless expected.all? { |key, value| raw[key] == value }
        local = OPENCLAW_LOCAL_ENV.to_h do |name|
          [ name, name == "PATH" ? "/usr/bin:/bin" : raw[name] ]
        end.compact
        raise Error if local.any? { |key, _value| AUTHORITY.match?(key) || CREDENTIAL.match?(key) }
        local
      end

      def approvals(gateway_path)
        {
          "version" => 1,
          "defaults" => {
            "security" => "deny", "ask" => "off", "askFallback" => "deny",
            "autoAllowSkills" => false
          },
          "agents" => {
            "main" => {
              "security" => "allowlist", "ask" => "off", "askFallback" => "deny",
              "autoAllowSkills" => false,
              "allowlist" => [
                { "id" => Digest::SHA256.hexdigest(gateway_path), "pattern" => gateway_path }
              ]
            }
          }
        }
      end

      def admit_effective_policy!(snapshot, expected)
        raise Error unless snapshot.fetch("exists") == true
        file = snapshot.fetch("file")
        main = file.dig("agents", "main")
        socket = file.fetch("socket")
        exact_file = file.keys.sort == %w[agents defaults socket version]
        exact_file &&= socket.instance_of?(Hash) && socket.keys.sort == %w[path token]
        exact_file &&= socket.fetch("path") == File.join(@workspace, ".hive-openclaw", "exec-approvals.sock")
        exact_file &&= /\A[A-Za-z0-9_-]{24,128}\z/.match?(socket.fetch("token"))
        exact_file &&= file.fetch("version") == 1 && file.fetch("defaults") == expected.fetch("defaults")
        exact_file &&= main == expected.dig("agents", "main")
        raise Error unless exact_file
        { "file" => expected }
      end

      def run_openclaw!(environment, *argv, allowed_stderr: "")
        stdin, stdout_io, stderr_io, waiter = Open3.popen3(
          environment, @openclaw, *argv, chdir: @workspace, unsetenv_others: true, pgroup: true
        )
        stdin.close
        stdout_reader = Thread.new { stdout_io.read(1_048_577) }
        stderr_reader = Thread.new { stderr_io.read(1_048_577) }
        status = Timeout.timeout(20) { waiter.value }
        stdout, stderr = [ stdout_reader, stderr_reader ].map { |reader| reader.value.to_s }
        raise Error unless status.success? && stderr == allowed_stderr && stdout.bytesize <= 1_048_576
        stdout
      rescue Timeout::Error
        terminate_process_group(waiter)
        raise Error
      ensure
        [ stdin, stdout_io, stderr_io ].compact.each { |io| io.close unless io.closed? }
      end

      def terminate_process_group(waiter)
        Process.kill("TERM", -waiter.pid)
        return if waiter.join(1)
        Process.kill("KILL", -waiter.pid)
        waiter.join(1)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end

      def git!(workspace, *argv)
        _stdout, stderr, status = Open3.capture3(
          { "HOME" => @environment.value.fetch("HOME") }, @git, "-C", workspace, *argv,
          unsetenv_others: true
        )
        raise Error unless status.success? && stderr.empty?
      end

      def git_output(workspace, *argv)
        stdout, stderr, status = Open3.capture3(
          { "HOME" => @environment.value.fetch("HOME") }, @git, "-C", workspace, *argv,
          unsetenv_others: true
        )
        raise Error unless status.success? && stderr.empty?
        stdout.strip
      end

      def write(path, bytes)
        File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(bytes) }
      end

      def proof_gitignore
        ".workflow-creator-gateway.sock\n.hive-proof-home/\n.hive-proof-hive-home/\nskills/\n"
      end
    end

    class ExternalActionsObserver
      def initialize(workspace:, candidate_environment:, fixture_path:, receipt_bytes:)
        @workspace, @fixture = workspace, fixture_path
        @environment = WorkflowCreator::Values.capture(candidate_environment)
        @receipt_bytes = receipt_bytes
        @git = %w[/usr/bin/git /bin/git].find { |path| File.executable?(path) }
        raise Error unless @git
      end

      def call(workspace:, candidate_environment:)
        raise Error, "workspace changed" unless workspace == @workspace
        observed = WorkflowCreator::Values.capture(candidate_environment)
        raise Error, "candidate environment changed" unless observed.canonical_bytes == @environment.canonical_bytes
        raise Error, "candidate environment has authority" if
          observed.value.any? { |key, _value| AUTHORITY.match?(key) || CREDENTIAL.match?(key) }
        raise Error, "fixture identity changed" unless observed.value.fetch("HIVE_CLAUDE_BIN") == @fixture
        receipt = File.join(workspace, ".hive-state", "workflow-creator-fixture-receipt.json")
        raise Error, "fixture receipt changed" unless File.binread(receipt) == @receipt_bytes
        raise Error, "git remote exists" unless git_output(workspace, "remote").empty?
        reject_git_authority!(git_output(workspace, "config", "--local", "--null", "--list"))
        { "status" => "observed", "actions" => [] }
      rescue StandardError => error
        raise Error, "workflow-creator external actions are unverified: #{error.class}: #{error.message}", cause: nil
      end

      private

      def reject_git_authority!(raw)
        raw.split("\0").reject(&:empty?).each do |row|
          key, value = row.split("\n", 2)
          unsafe = key.match?(/\A(?:remote\.|url\.|credential\.|include\.|http\.|gpg\.)/i)
          unsafe ||= key.match?(/\A(?:core\.hooksPath|core\.sshCommand|commit\.gpgSign|tag\.gpgSign)\z/i)
          unsafe ||= key.match?(/\Abranch\..+\.remote\z/i) && value != "."
          raise Error, "git authority exists: #{key}" if unsafe
        end
      end

      def git_output(workspace, *argv)
        stdout, _stderr, status = Open3.capture3(
          { "HOME" => @environment.value.fetch("HOME") }, @git, "-C", workspace, *argv,
          unsetenv_others: true
        )
        raise Error unless status.success?
        stdout.strip
      end
    end
  end
end
