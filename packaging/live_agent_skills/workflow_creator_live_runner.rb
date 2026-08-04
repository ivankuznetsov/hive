# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "uri"
require "yaml"
require_relative "workflow_creator_execution"

module HiveLiveAgentProof
  class WorkflowCreatorLiveRunner
    class Error < StandardError; end
    class Failure < Error
      attr_reader :phase, :reason, :status

      def initialize(phase, reason, status: "failed")
        @phase, @reason, @status = phase, reason, status
        super(reason)
      end
    end
    private_constant :Failure

    Result = Data.define(:status, :provider, :receipt)
    CONFIGURATION_SCHEMA = "hive-live-openclaw-creator-configuration/v1"
    NPM_REGISTRY = "https://registry.npmjs.org"
    PROVIDERS = {
      "openai" => {
        "credential" => "OPENAI_API_KEY", "endpoint_env" => "OPENAI_BASE_URL",
        "endpoint" => "https://api.openai.com/v1"
      },
      "openrouter" => {
        "credential" => "OPENROUTER_API_KEY", "endpoint_env" => "OPENROUTER_BASE_URL",
        "endpoint" => "https://openrouter.ai/api/v1"
      }
    }.freeze
    CHILD_ENV = %w[PATH LANG LC_ALL TERM TMPDIR].freeze
    ENDPOINT_ENV = PROVIDERS.values.map { |row| row.fetch("endpoint_env") }.freeze
    PROXY_ENV = %w[HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy].freeze
    CA_ENV = %w[SSL_CERT_FILE SSL_CERT_DIR NODE_EXTRA_CA_CERTS].freeze
    AUTHORITY_ENV = /\A(?:GH_|GITHUB_|GIT_|SSH_|CI_JOB_TOKEN\z|CI_DEPLOY_PASSWORD\z)/i
    CREDENTIAL_ENV = /(?:TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL|API_?KEY|PRIVATE_?KEY|AUTHORIZATION|COOKIE|SESSION)/i
    SHA = /\A[0-9a-f]{40}\z/
    SHELL_SANITIZER = <<~'SH'.freeze
      #!/bin/bash
      set -f
      mapfile -t hive_environment_names < <(compgen -e)
      for hive_environment_name in "${hive_environment_names[@]}"; do
        hive_environment_key=${hive_environment_name^^}
        case "$hive_environment_key" in
          *TOKEN*|*SECRET*|*PASSWORD*|*PASSWD*|*CREDENTIAL*|*API_KEY*|*APIKEY*|*PRIVATE_KEY*|*PRIVATEKEY*|*AUTHORIZATION*|*COOKIE*|*SESSION*|GH_*|GITHUB_*|GIT_*|SSH_*|BASH_ENV|ENV|RUBYOPT|RUBYLIB|NODE_OPTIONS|PYTHONPATH|PERL5OPT|CDPATH|GLOBIGNORE|PROMPT_COMMAND)
            unset "$hive_environment_name"
            ;;
        esac
      done
      unset -v hive_environment_names hive_environment_name hive_environment_key
      exec /bin/bash --noprofile --norc "$@"
    SH
    private_constant :SHELL_SANITIZER

    CONFIGURATION_KEYS = %w[schema schema_version candidate_sha provider model transport dependency
                            tool_environment runtime_install skill].freeze
    TRANSPORT_KEYS = %w[endpoint proxy ca redirects].freeze
    DEPENDENCY_KEYS = %w[package version registry integrity lock_sha256 package_count node_engine node_version
                         lifecycle_scripts].freeze
    TOOL_ENVIRONMENT_KEYS = %w[authority pass_env shell].freeze
    SHELL_KEYS = %w[path sha256 size].freeze
    RUNTIME_INSTALL_KEYS = %w[schema schema_version root tree_sha256 file_count directory_count total_size
                              launcher_sha256].freeze
    SKILL_KEYS = %w[path projection_manifest_sha256].freeze
    WORKSPACE_PREPARATION_KEYS = %w[schema schema_version status skill_manifest_sha256 init_stdout_sha256
                                    git_head openclaw_config_validation_sha256
                                    openclaw_effective_policy_sha256].freeze
    CREATOR_ARGV = [ "agent", "--local", "--agent", "main", "--message",
                     WorkflowCreator::Vocabulary.fetch("prompt"), "--timeout", "180", "--json" ].freeze
    AUTHORIZED_ARGV = [ "agent", "--local", "--agent", "main", "--message",
                        WorkflowCreator::Vocabulary.fetch("task_prompt"), "--timeout", "180", "--json" ].freeze

    def self.run!(**options) = new(**options).send(:run)
    def self.shell_sanitizer_bytes = SHELL_SANITIZER

    def self.initialize_evidence!(bundle_directory:, candidate_sha:)
      WorkflowCreatorEvidence.initialize!(bundle_directory:, candidate_sha:)
    end

    def self.fail!(bundle_directory:, candidate_sha:, phase:, reason:, detail: nil, exact_secrets: [])
      path = File.join(bundle_directory, WorkflowCreator::Vocabulary.fetch("bundle_files").first)
      expected = JSON.parse(File.binread(path))
      receipt = WorkflowCreator.failure(candidate_sha:, phase:, reason:, detail:, exact_secrets:)
      admitted = WorkflowCreatorEvidence.replace_nonpassing!(
        bundle_directory:, expected:, receipt: receipt.value, exact_secrets:
      )
      Result.new(status: "failed", provider: nil, receipt: admitted)
    rescue JSON::ParserError, SystemCallError
      raise Error, "workflow-creator live failure evidence is unavailable", cause: nil
    end

    private_class_method :new

    def initialize(candidate_sha:, model:, host_environment:, configuration_record:, execution_options:,
                   external_actions_observer:, workspace_preparer:, runtime_install_verifier: nil,
                   execution_factory: WorkflowCreatorExecution.method(:start!))
      @candidate_sha = candidate_sha.to_s.downcase
      @model = model.to_s
      @host_environment = stringify(host_environment)
      @configuration_record_path = configuration_record.to_s
      @execution_options = execution_options.transform_keys(&:to_sym)
      @external_actions_observer = external_actions_observer
      @workspace_preparer = workspace_preparer
      @runtime_install_verifier = runtime_install_verifier
      @execution_factory = execution_factory
      @bundle_directory = @execution_options.fetch(:bundle_directory)
      @provider = @credential = @session = nil
      @model_loop_started = false
    rescue KeyError, NoMethodError, TypeError
      raise Error, "workflow-creator live inputs are invalid", cause: nil
    end

    def run
      @current = WorkflowCreatorEvidence.initialize!(
        bundle_directory: @bundle_directory, candidate_sha: @candidate_sha
      )
      admit_preflight!
      options = @execution_options.merge(exact_secrets: [ @credential ])
      @session = @execution_factory.call(**options)
      environment, gateway_link = configure_openclaw
      prepare_workspace!(environment, gateway_link)
      @model_loop_started = true
      @session.run_outer_workflow_creator(
        argv: CREATOR_ARGV, environment:, stdin_data: WorkflowCreator::Vocabulary.fetch("prompt")
      )
      observe_creation_only!
      @session.run_outer_authorized_work(
        argv: AUTHORIZED_ARGV, environment:, stdin_data: WorkflowCreator::Vocabulary.fetch("task_prompt")
      )
      observe_external_actions!
      observe_task!
      verify_runtime_install!
      files = created_files
      draft = @session.draft!(executed_instruction: files.fetch(2))
      primary = primary_row(draft, files)
      publish_primary(primary)
      result = @session.finish!(primary_row: primary.value)
      raise Failure.new("finalization", "execution_finalization_failed") unless result.status == "passed"

      Result.new(status: "passed", provider: @provider, receipt: primary)
    rescue Failure => failure
      finalize_failure(failure)
    rescue WorkflowCreatorExecution::Unavailable => error
      finalize_failure(Failure.new("execution", "execution_unavailable", status: "blocked"), error.message)
    rescue WorkflowCreatorExecution::Error, WorkflowCreator::Error, SystemCallError, JSON::ParserError => error
      finalize_failure(Failure.new("execution", "execution_failed"), error.message)
    rescue StandardError => error
      finalize_failure(Failure.new("execution", "execution_failed"), error.message)
    ensure
      @session&.close
    end

    def admit_preflight!
      raise Failure.new("preflight", "invalid_candidate_sha") unless SHA.match?(@candidate_sha)
      @provider = provider_for(@model)
      provider = PROVIDERS.fetch(@provider)
      @credential = @host_environment.fetch(provider.fetch("credential"), "")
      raise Failure.new("preflight", "missing_provider_credential", status: "blocked") if @credential.empty?

      openclaw = @execution_options.fetch(:openclaw)
      candidate = @execution_options.fetch(:candidate)
      validate_downstream_environment!(candidate.fetch("environment"))
      @configuration = admit_configuration!(openclaw)
      admit_skill!(@configuration.fetch("skill"), candidate)
      admit_tool_environment!(@configuration.fetch("tool_environment"), openclaw)
      admit_transport!(@configuration.fetch("transport"), openclaw)
      admit_dependency!(@configuration.fetch("dependency"), openclaw)
      admit_node!(openclaw.fetch("interpreter_or_launcher"), @configuration.dig("dependency", "node_version"))
      launcher_sha256 = admit_binary!(openclaw.fetch("executable"))
      admit_runtime_install!(@configuration.fetch("runtime_install"), launcher_sha256)
    rescue KeyError, TypeError
      raise Failure.new("preflight", "invalid_openclaw_closure")
    end

    def provider_for(model)
      parts = model.split("/")
      raise Failure.new("preflight", "missing_model") if model.empty?
      provider = parts.first
      valid = (provider == "openai" && parts.length >= 2) || (provider == "openrouter" && parts.length >= 3)
      raise Failure.new("preflight", "unsupported_provider") unless valid && parts.none?(&:empty?)
      provider
    end

    def admit_configuration!(openclaw)
      root = File.realpath(openclaw.fetch("root"))
      path = File.expand_path(@configuration_record_path)
      prefix = "#{root}/"
      raise Failure.new("preflight", "invalid_openclaw_closure") unless path.start_with?(prefix)
      relative = path.delete_prefix(prefix)
      raise Failure.new("preflight", "invalid_openclaw_closure") unless openclaw.fetch("inventory").include?(relative)
      raw = safe_file(path)
      snapshot = WorkflowCreator::Values.capture(JSON.parse(raw))
      raise Failure.new("preflight", "invalid_openclaw_closure") unless raw == snapshot.canonical_bytes
      row = snapshot.value
      exact!(row, CONFIGURATION_KEYS, "invalid_openclaw_closure")
      identity = [ CONFIGURATION_SCHEMA, 1, @candidate_sha, @provider, @model ]
      actual = row.values_at("schema", "schema_version", "candidate_sha", "provider", "model")
      raise Failure.new("preflight", "invalid_openclaw_closure") unless actual == identity
      row
    rescue WorkflowCreator::Values::Error, JSON::ParserError, SystemCallError
      raise Failure.new("preflight", "invalid_openclaw_closure")
    end

    def admit_tool_environment!(tool_environment, openclaw)
      exact!(tool_environment, TOOL_ENVIRONMENT_KEYS, "invalid_tool_environment")
      shell = tool_environment.fetch("shell")
      exact!(shell, SHELL_KEYS, "invalid_tool_environment")
      root = File.realpath(openclaw.fetch("root"))
      relative = shell.fetch("path")
      path = File.expand_path(relative, root)
      prefix = "#{root}/"
      valid = tool_environment.values_at("authority", "pass_env") == [ "shell_sanitized", [] ]
      valid &&= path.start_with?(prefix) && openclaw.fetch("inventory").include?(relative)
      bytes = safe_file(path)
      stat = File.lstat(path)
      valid &&= File.executable?(path) && (stat.mode & 0o022).zero?
      valid &&= bytes == SHELL_SANITIZER
      valid &&= shell.values_at("sha256", "size") == [ Digest::SHA256.hexdigest(bytes), bytes.bytesize ]
      raise Failure.new("preflight", "invalid_tool_environment") unless valid

      @shell_path = path
    rescue KeyError, SystemCallError, TypeError
      raise Failure.new("preflight", "invalid_tool_environment")
    end

    def admit_skill!(skill, candidate)
      exact!(skill, SKILL_KEYS, "invalid_skill_projection")
      root = File.realpath(candidate.fetch("root"))
      relative = skill.fetch("path")
      path = File.expand_path(relative, root)
      prefix = "#{root}/"
      valid = relative.instance_of?(String) && path.start_with?(prefix)
      valid &&= path.delete_prefix(prefix) == relative
      valid &&= File.realpath(path) == path && File.directory?(path) && !File.symlink?(path)
      manifest = File.join(path, "projection-manifest.json")
      manifest_relative = manifest.delete_prefix(prefix)
      valid &&= candidate.fetch("inventory").include?(manifest_relative)
      valid &&= /\A[0-9a-f]{64}\z/.match?(skill.fetch("projection_manifest_sha256"))
      valid &&= Digest::SHA256.hexdigest(safe_file(manifest)) == skill.fetch("projection_manifest_sha256")
      raise Failure.new("preflight", "invalid_skill_projection") unless valid
    rescue KeyError, SystemCallError, TypeError
      raise Failure.new("preflight", "invalid_skill_projection")
    end

    def admit_transport!(transport, openclaw)
      exact!(transport, TRANSPORT_KEYS, "invalid_transport_identity")
      expected = PROVIDERS.fetch(@provider).fetch("endpoint")
      valid = transport.values_at("endpoint", "redirects") == [ expected, "deny" ]
      valid &&= transport.fetch("proxy").nil? || safe_https?(transport.fetch("proxy"))
      valid &&= admit_ca(transport.fetch("ca"), openclaw)
      raise Failure.new("preflight", "invalid_transport_identity") unless valid
      validate_transport_overrides!(transport)
    end

    def validate_transport_overrides!(transport)
      selected_endpoint = PROVIDERS.fetch(@provider).fetch("endpoint_env")
      ENDPOINT_ENV.each do |name|
        next if @host_environment.fetch(name, "").empty?
        expected = name == selected_endpoint ? transport.fetch("endpoint") : nil
        raise Failure.new("preflight", "transport_override") unless @host_environment[name] == expected
      end
      PROXY_ENV.each do |name|
        next if @host_environment.fetch(name, "").empty?
        raise Failure.new("preflight", "transport_override") unless @host_environment[name] == transport.fetch("proxy")
      end
      expected_ca = transport.fetch("ca")&.fetch("path")
      CA_ENV.each do |name|
        next if @host_environment.fetch(name, "").empty?
        raise Failure.new("preflight", "transport_override") unless name != "SSL_CERT_DIR" &&
          @host_environment[name] == expected_ca
      end
    end

    def admit_ca(ca, openclaw)
      return true if ca.nil?
      exact!(ca, %w[path sha256 size], "invalid_transport_identity")
      root = File.realpath(openclaw.fetch("root"))
      path = File.expand_path(ca.fetch("path"), root)
      prefix = "#{root}/"
      return false unless path.start_with?(prefix) && openclaw.fetch("inventory").include?(path.delete_prefix(prefix))
      bytes = safe_file(path)
      ca.values_at("path", "sha256", "size") ==
        [ path, Digest::SHA256.hexdigest(bytes), bytes.bytesize ]
    rescue KeyError, SystemCallError
      false
    end

    def admit_dependency!(dependency, openclaw)
      exact!(dependency, DEPENDENCY_KEYS, "invalid_openclaw_closure")
      lock_path = File.expand_path(openclaw.fetch("lock"))
      lock_bytes = safe_file(lock_path)
      version, integrity, node_engine, node_version =
        dependency.values_at("version", "integrity", "node_engine", "node_version")
      valid = dependency.values_at("package", "registry", "lock_sha256") ==
        [ "openclaw", NPM_REGISTRY, Digest::SHA256.hexdigest(lock_bytes) ]
      valid &&= openclaw.fetch("version") == version
      valid &&= version.instance_of?(String) && !version.empty?
      valid &&= /\Asha512-[A-Za-z0-9+\/]+={0,2}\z/.match?(integrity)
      valid &&= node_engine.instance_of?(String) && !node_engine.empty?
      valid &&= /\A\d+\.\d+\.\d+\z/.match?(node_version)
      lock = JSON.parse(lock_bytes)
      packages = lock.fetch("packages")
      valid &&= lock.fetch("lockfileVersion") == 3 && packages.instance_of?(Hash)
      valid &&= packages.length == dependency.fetch("package_count")
      valid &&= packages.dig("", "dependencies") == { "openclaw" => version }
      valid &&= packages.dig("", "engines", "node") == node_version
      valid &&= packages.all? { |path, row| path.empty? || admitted_package?(row) }
      openclaw_row = packages.fetch("node_modules/openclaw")
      valid &&= openclaw_row.values_at("version", "integrity") == [ version, integrity ]
      valid &&= openclaw_row.dig("engines", "node") == node_engine
      lifecycle = packages.filter_map { |path, row| path unless path.empty? || row["hasInstallScript"] != true }.sort
      valid &&= lifecycle == dependency.fetch("lifecycle_scripts")
      raise Failure.new("preflight", "invalid_openclaw_closure") unless valid
    rescue JSON::ParserError, KeyError, SystemCallError, TypeError
      raise Failure.new("preflight", "invalid_openclaw_closure")
    end

    def admit_node!(path, expected_version)
      stat = File.lstat(path)
      valid = stat.file? && !stat.symlink? && stat.uid == Process.uid && stat.nlink == 1
      valid &&= (stat.mode & 0o022).zero? && File.executable?(path)
      stdout, stderr, status = Open3.capture3({}, path, "--version", unsetenv_others: true)
      valid &&= status.success? && stderr.empty? && stdout.strip == "v#{expected_version}"
      raise Failure.new("preflight", "invalid_openclaw_node") unless valid
    rescue SystemCallError
      raise Failure.new("preflight", "invalid_openclaw_node")
    end

    def admitted_package?(row)
      row.instance_of?(Hash) && row["link"] != true && row["version"].instance_of?(String) &&
        row["resolved"].to_s.start_with?("#{NPM_REGISTRY}/") &&
        /\Asha512-[A-Za-z0-9+\/]+={0,2}\z/.match?(row["integrity"])
    end

    def admit_binary!(path)
      bytes = safe_file(path)
      stat = File.lstat(path)
      valid = File.executable?(path) && (stat.mode & 0o022).zero?
      raise Failure.new("preflight", "invalid_openclaw_binary") unless valid
      Digest::SHA256.hexdigest(bytes)
    rescue SystemCallError
      raise Failure.new("preflight", "invalid_openclaw_binary")
    end

    def admit_runtime_install!(runtime_install, launcher_sha256)
      exact!(runtime_install, RUNTIME_INSTALL_KEYS, "runtime_install_unverified")
      valid = runtime_install.values_at("schema", "schema_version", "launcher_sha256") ==
        [ "hive-openclaw-runtime-install/v1", 1, launcher_sha256 ]
      valid &&= /\A[0-9a-f]{64}\z/.match?(runtime_install.fetch("tree_sha256"))
      valid &&= %w[file_count directory_count total_size].all? do |key|
        runtime_install.fetch(key).instance_of?(Integer) && runtime_install.fetch(key).positive?
      end
      root = File.expand_path(runtime_install.fetch("root"))
      valid &&= root == runtime_install.fetch("root") && File.realpath(root) == root
      @runtime_install = WorkflowCreator::Values.capture(runtime_install)
      @launcher_sha256 = launcher_sha256
      observed = verify_runtime_install!
      valid &&= observed
      raise Failure.new("preflight", "runtime_install_unverified", status: "blocked") unless valid
    rescue KeyError, SystemCallError, TypeError, WorkflowCreator::Values::Error
      raise Failure.new("preflight", "runtime_install_unverified", status: "blocked")
    end

    def verify_runtime_install!
      return false unless @runtime_install_verifier && @runtime_install

      observed = @runtime_install_verifier.call(
        runtime_install: @runtime_install.value, launcher_sha256: @launcher_sha256
      )
      valid = WorkflowCreator::Values.capture(observed).canonical_bytes == @runtime_install.canonical_bytes
      raise Failure.new("execution", "runtime_install_changed") if @model_loop_started && !valid
      valid
    rescue StandardError
      raise Failure.new("execution", "runtime_install_changed") if @model_loop_started
      false
    end

    def validate_downstream_environment!(environment)
      values = stringify(environment)
      unsafe = values.any? { |key, value| authority?(key) || [ @credential ].include?(value) }
      raise Failure.new("preflight", "unsafe_downstream_environment") if unsafe
    end

    def configure_openclaw
      workspace = @session.workspace_path
      state = File.join(workspace, ".hive-openclaw")
      bin = File.join(state, "bin")
      home = File.join(state, "home")
      FileUtils.mkdir_p([ bin, home ], mode: 0o700)
      link = File.join(bin, "hive")
      File.symlink(@session.gateway_path, link)
      raise Failure.new("configuration", "invalid_gateway_path") unless File.realpath(link) == File.realpath(@session.gateway_path)
      config_path = File.join(state, "openclaw.json")
      write_private(config_path, openclaw_configuration(workspace, bin))
      [ openclaw_environment(home:, state:, config_path:), link ]
    rescue SystemCallError
      raise Failure.new("configuration", "openclaw_configuration_failed")
    end

    def openclaw_configuration(workspace, bin)
      {
        "agents" => { "defaults" => { "workspace" => workspace, "model" => { "primary" => @model } } },
        "tools" => {
          "allow" => %w[read write edit apply_patch exec], "fs" => { "workspaceOnly" => true },
          "elevated" => { "enabled" => false },
          "exec" => { "mode" => "allowlist", "host" => "gateway", "strictInlineEval" => true,
                      "pathPrepend" => [ bin ] }
        }
      }
    end

    def openclaw_environment(home:, state:, config_path:)
      environment = CHILD_ENV.to_h { |name| [ name, @host_environment[name] ] }.compact
      provider = PROVIDERS.fetch(@provider)
      transport = @configuration.fetch("transport")
      environment[provider.fetch("credential")] = @credential
      environment[provider.fetch("endpoint_env")] = transport.fetch("endpoint")
      PROXY_ENV.each { |name| environment[name] = transport.fetch("proxy") if transport.fetch("proxy") }
      ca = transport.fetch("ca")
      environment["SSL_CERT_FILE"] = ca.fetch("path") if ca
      environment.merge!("HOME" => home, "OPENCLAW_STATE_DIR" => state,
                         "OPENCLAW_CONFIG_PATH" => config_path, "HIVE_LIVE_PROOF" => "1",
                         "SHELL" => @shell_path)
    end

    def prepare_workspace!(openclaw_environment, gateway_path)
      raise Failure.new("configuration", "workspace_preparation_failed") unless
        @workspace_preparer.respond_to?(:call)
      observation = @workspace_preparer.call(
        workspace: @session.workspace_path,
        candidate_environment: @execution_options.fetch(:candidate).fetch("environment"),
        openclaw_environment:, gateway_path:
      )
      row = WorkflowCreator::Values.capture(observation).value
      exact!(row, WORKSPACE_PREPARATION_KEYS, "workspace_preparation_failed")
      valid = row.values_at("schema", "schema_version", "status", "skill_manifest_sha256") == [
        "hive-workflow-creator-workspace-preparation", 1, "prepared",
        @configuration.dig("skill", "projection_manifest_sha256")
      ]
      valid &&= /\A[0-9a-f]{40}\z/.match?(row.fetch("git_head"))
      valid &&= %w[init_stdout_sha256 openclaw_config_validation_sha256
                    openclaw_effective_policy_sha256].all? do |key|
        /\A[0-9a-f]{64}\z/.match?(row.fetch(key))
      end
      raise Failure.new("configuration", "workspace_preparation_failed") unless valid
    rescue Failure
      raise
    rescue StandardError
      raise Failure.new("configuration", "workspace_preparation_failed")
    end

    def created_files
      validate_authored_graph!
      WorkflowCreator::Vocabulary.fetch("files").map do |relative|
        path = File.join(@session.workspace_path, relative)
        bytes = safe_file(path)
        { "path" => relative, "sha256" => Digest::SHA256.hexdigest(bytes), "size" => bytes.bytesize }
      end
    rescue SystemCallError
      raise Failure.new("evidence", "authored_files_missing")
    end

    def validate_authored_graph!
      descriptor = File.join(@session.workspace_path, WorkflowCreator::Vocabulary.fetch("files").first)
      actual = YAML.safe_load(safe_file(descriptor), permitted_classes: [], aliases: false)
      expected = {
        "id" => "editorial",
        "stages" => [
          { "name" => "research", "kind" => "agent", "state_file" => "research.md",
            "instruction" => "editorial/research.md", "permissions" => "yolo" },
          { "name" => "draft", "kind" => "agent", "state_file" => "draft.md",
            "instruction" => "editorial/draft.md", "permissions" => "yolo" },
          { "name" => "approval", "kind" => "human", "state_file" => "approval.md",
            "input" => "draft.md", "outcomes" => {
              "approve" => { "complete" => true, "artifact" => "draft.md" },
              "reject" => { "to" => "draft" }
            } }
        ]
      }
      raise Failure.new("evidence", "authored_graph_invalid") unless actual == expected
      WorkflowCreator::Vocabulary.fetch("files").drop(1).each do |relative|
        raise Failure.new("evidence", "authored_graph_invalid") if
          safe_file(File.join(@session.workspace_path, relative)).strip.empty?
      end
    rescue Psych::Exception, SystemCallError
      raise Failure.new("evidence", "authored_graph_invalid")
    end

    def observe_creation_only!
      @creation_only_task_count = task_directories.length
      raise Failure.new("evidence", "creation_only_task_created") unless @creation_only_task_count.zero?
    end

    def observe_task!
      tasks = task_directories
      raise Failure.new("evidence", "task_observation_invalid") unless tasks.length == 1
      path = tasks.fetch(0)
      relative = path.delete_prefix("#{@session.workspace_path}/")
      stage, slug = relative.split(File::SEPARATOR).last(2)
      meta = YAML.safe_load(safe_file(File.join(path, "meta.yml")), permitted_classes: [], aliases: false)
      valid = meta.instance_of?(Hash) && meta.values_at("workflow", "idempotency_key") ==
        [ "editorial", WorkflowCreator::Vocabulary.fetch("task_key") ]
      valid &&= meta.fetch("slug", slug) == slug && stage == "1-research"
      raise Failure.new("evidence", "task_observation_invalid") unless valid
      @task_observation = { "slug" => slug, "workflow" => "editorial", "current_stage" => stage }
    rescue KeyError, Psych::Exception, SystemCallError, TypeError
      raise Failure.new("evidence", "task_observation_invalid")
    end

    def task_directories
      pattern = File.join(@session.workspace_path, ".hive-state", "stages", "*", "*")
      Dir.glob(pattern).select { |path| File.directory?(path) && !File.symlink?(path) }.sort
    end

    def primary_row(draft, files)
      receipt = JSON.parse(draft.receipt_bytes)
      installed = receipt.fetch("installed_manifests")
      slug = receipt.dig("task_slug_binding", "value")
      raise Failure.new("evidence", "task_observation_invalid") unless
        @task_observation && @task_observation.fetch("slug") == slug
      receipt_record = { "kind" => "execution_receipt", "path" => "execution-receipt.json",
                         "sha256" => draft.receipt_sha256, "size" => draft.receipt_size }
      summary = { "status" => "passed", "receipt_sha256" => draft.receipt_sha256 }
      manifest = @execution_options.fetch(:manifest)
      row = {
        "schema" => WorkflowCreator::Vocabulary.fetch("evidence_schema"), "schema_version" => 1,
        "platform" => "openclaw", "candidate_sha" => @candidate_sha, "result" => "passed",
        "prompt_sha256" => Digest::SHA256.hexdigest(WorkflowCreator::Vocabulary.fetch("prompt")),
        "task_prompt_sha256" => Digest::SHA256.hexdigest(WorkflowCreator::Vocabulary.fetch("task_prompt")),
        "skill" => manifest.slice("skill_version", "canonical_digest"),
        "native_activation" => WorkflowCreator::Vocabulary.fetch("native_activation"),
        "hive_commands" => WorkflowCreator.commands_for(task_slug: slug).value,
        "created_files" => files, "validation" => WorkflowCreator::Vocabulary.fetch("graph"),
        "creation_only_task_count" => @creation_only_task_count, "task_count" => 1,
        "task" => WorkflowCreator::Vocabulary.fetch("task").merge(@task_observation),
        "external_actions" => @external_actions.fetch("actions"),
        "secret_scan" => { "status" => "passed", "scanner" => WorkflowCreator::Vocabulary.fetch("scanner") },
        "execution_kind" => "authenticated_openclaw", "model_loop" => "executed",
        "executed_instruction" => files.fetch(2), "evidence_bundle" => installed + [ receipt_record ],
        "containment" => summary, "teardown" => summary, "cleanup" => summary
      }
      bundle = WorkflowCreator::Values.capture(installed + [ receipt_record ])
      WorkflowCreator.validate_primary!(row:, manifest:, candidate_sha: @candidate_sha, bundle_records: bundle.value)
    rescue KeyError, JSON::ParserError, WorkflowCreator::Error
      raise Failure.new("evidence", "primary_evidence_invalid")
    end

    def observe_external_actions!
      raise Failure.new("evidence", "external_actions_unverified") unless
        @external_actions_observer.respond_to?(:call)

      observation = @external_actions_observer.call(
        workspace: @session.workspace_path,
        candidate_environment: @execution_options.fetch(:candidate).fetch("environment")
      )
      @external_actions = WorkflowCreator::Values.capture(observation).value
      valid = @external_actions.instance_of?(Hash) && @external_actions.keys.sort == %w[actions status]
      valid &&= @external_actions.values_at("status", "actions") == [ "observed", [] ]
      raise Failure.new("evidence", "external_actions_unverified") unless valid
    rescue Failure
      raise
    rescue StandardError
      raise Failure.new("evidence", "external_actions_unverified")
    end

    def publish_primary(primary)
      @current = WorkflowCreatorEvidence.replace_primary!(
        bundle_directory: @bundle_directory, expected: @current.value, receipt: primary.value,
        manifest: @execution_options.fetch(:manifest), candidate_sha: @candidate_sha,
        bundle_records: primary.value.fetch("evidence_bundle")
      )
    rescue StandardError
      raise Failure.new("publication", "primary_publication_failed")
    end

    def finalize_failure(failure, detail = nil)
      receipt = WorkflowCreator.failure(
        candidate_sha: @candidate_sha, phase: failure.phase, reason: failure.reason, detail:,
        execution_kind: @model_loop_started ? "authenticated_openclaw" : "unavailable",
        model_loop: @model_loop_started ? "executed" : "not_started", exact_secrets: exact_secrets
      )
      if @current
        if @current.value.fetch("result") == "failed"
          @current = WorkflowCreatorEvidence.replace_nonpassing!(
            bundle_directory: @bundle_directory, expected: @current.value,
            receipt: receipt.value, exact_secrets: exact_secrets
          )
        else
          @current = WorkflowCreatorEvidence.replace_primary_with_failure!(
            bundle_directory: @bundle_directory, expected: @current.value, receipt: receipt.value,
            manifest: @execution_options.fetch(:manifest), candidate_sha: @candidate_sha,
            bundle_records: @current.value.fetch("evidence_bundle"), exact_secrets: exact_secrets
          )
        end
      end
      Result.new(status: failure.status, provider: @provider, receipt: @current || receipt)
    rescue StandardError
      raise Error, "workflow-creator live failure evidence is unavailable", cause: nil
    end

    def safe_file(path)
      stat = File.lstat(path)
      valid = stat.file? && !stat.symlink? && stat.uid == Process.uid && stat.nlink == 1
      valid &&= (stat.mode & 0o022).zero? && stat.size.between?(1, 1_048_576)
      raise Errno::EACCES unless valid
      bytes = File.binread(path)
      raise Errno::EACCES unless File.lstat(path).ino == stat.ino
      bytes
    end

    def write_private(path, value)
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(JSON.pretty_generate(value))
        file.write("\n")
      end
    end

    def exact!(value, keys, reason)
      raise Failure.new("preflight", reason) unless value.instance_of?(Hash) && value.keys.sort == keys.sort
    end

    def safe_https?(value)
      uri = URI.parse(value)
      uri.scheme == "https" && uri.host && !uri.host.empty? && uri.userinfo.nil? && uri.fragment.nil?
    rescue URI::InvalidURIError
      false
    end

    def authority?(key) = AUTHORITY_ENV.match?(key) || CREDENTIAL_ENV.match?(key)
    def exact_secrets = PROVIDERS.values.filter_map { |row| @host_environment[row.fetch("credential")] }.reject(&:empty?)
    def stringify(value) = value.to_h.to_h { |key, item| [ key.to_s, item.to_s ] }

    class Command
      def self.call(argv, environment: ENV)
        command, *arguments = argv
        bundle, candidate = inputs(environment)
        case command
        when "initialize"
          WorkflowCreatorLiveRunner.initialize_evidence!(bundle_directory: bundle, candidate_sha: candidate)
        when "fail"
          raise Error unless arguments.length == 2
          WorkflowCreatorLiveRunner.fail!(
            bundle_directory: bundle, candidate_sha: candidate, phase: arguments.fetch(0),
            reason: arguments.fetch(1), exact_secrets: provider_secrets(environment)
          )
        else
          raise Error
        end
        0
      rescue Error, KeyError, JSON::ParserError, SystemCallError
        1
      end

      def self.inputs(environment)
        path = environment.fetch("HIVE_CREATOR_EVIDENCE_PATH")
        expected = WorkflowCreator::Vocabulary.fetch("bundle_files").first
        raise Error unless File.basename(path) == expected
        [ File.dirname(path), environment.fetch("HIVE_CANDIDATE_SHA") ]
      end
      private_class_method :inputs

      def self.provider_secrets(environment)
        PROVIDERS.values.filter_map { |row| environment[row.fetch("credential")] }.reject(&:empty?)
      end
      private_class_method :provider_secrets
    end
  end
end

exit HiveLiveAgentProof::WorkflowCreatorLiveRunner::Command.call(ARGV) if $PROGRAM_NAME == __FILE__
