require "erb"
require "fileutils"
require "json"
require "pathname"
require "shellwords"
require "hive"
require "hive/config"
require "hive/git_ops"
require "hive/lock"
require "hive/workflows/descriptor_parser"
require "hive/workflows/loader"
require "hive/workflows/project"
require "hive/workflows/registry"

module Hive
  module Commands
    class Workflow
      TEMPLATE_ROOT = File.expand_path("../../../templates/workflows/blank", __dir__)
      WORKFLOW_ID_RE = Hive::Workflows::DescriptorParser::SAFE_SLUG
      SCHEMA = "hive-workflow-new".freeze

      class UsageError < Hive::Error
        attr_reader :value

        def initialize(message, value: nil)
          super(message)
          @value = value
        end

        def exit_code
          Hive::ExitCodes::USAGE
        end
      end

      def self.new!(id, project_root: Dir.pwd, json: false, stdout: $stdout)
        new("new", id, project_root: project_root, json: json, stdout: stdout).call!
      end

      def self.normalize_and_validate_id!(raw)
        command = new("new", raw)
        id = command.send(:normalize_id, raw)
        command.send(:validate_id!, id)
        id
      end

      def self.scaffold_files!(id_raw, project_root:)
        command = new("new", id_raw, project_root: project_root)
        id = command.send(:normalize_id, id_raw)
        command.send(:validate_id!, id)
        paths = command.send(:scaffold_paths, id)
        command.send(:refuse_overwrite!, paths)
        begin
          command.send(:write_scaffold!, id, paths)
          command.send(:validate_descriptor!, paths.fetch(:descriptor))
          Hive::Workflows::Project.reset!
        rescue StandardError
          command.send(:rollback_scaffold, paths)
          raise
        end
        { id: id, paths: paths }
      end

      def self.rollback_scaffold(paths)
        new("new").send(:rollback_scaffold, paths)
      end

      def initialize(subcommand, id = nil, project_root: Dir.pwd, json: false, stdout: $stdout)
        @subcommand = subcommand
        @id = id
        @project_root = File.expand_path(project_root)
        @json = json
        @stdout = stdout
      end

      def call
        call!
      rescue UsageError, Hive::ConfigError, Hive::GitError, Hive::ConcurrentRunError,
             SystemCallError, IOError => e
        # ConcurrentRunError (commit-lock contention, TEMPFAIL/75) is now caught
        # too: previously it escaped to bin/hive as plain stderr, hiding the
        # retryable-vs-terminal distinction from --json agent callers.
        # SystemCallError/IOError are caught for the same reason: a disk-write
        # fault from write_scaffold!'s mkdir_p/File.write would otherwise escape
        # past `call` to bin/hive (which only handles Errno::EPIPE/Thor::Error/
        # Hive::Error), yielding a raw backtrace instead of the schema'd --json
        # envelope. error_kind_for's else→ERROR arm classifies them.
        if @json
          @stdout.puts JSON.generate(error_payload(e))
        else
          warn "hive workflow: #{e.message}"
        end
        # SystemCallError/IOError carry no #exit_code; map them to GENERIC the
        # same way ErrorEnvelope.build does for the --json exit_code field.
        exit(e.respond_to?(:exit_code) ? e.exit_code : Hive::ExitCodes::GENERIC)
      end

      def call!
        unless @subcommand == "new"
          raise UsageError.new("unknown workflow subcommand #{@subcommand.inspect} (expected: new)", value: @subcommand)
        end

        scaffold = self.class.scaffold_files!(@id, project_root: @project_root)
        id = scaffold.fetch(:id)
        paths = scaffold.fetch(:paths)
        begin
          # commit_scaffold! is INSIDE the rollback protection: a commit failure
          # (GitError / ConcurrentRunError) would otherwise leave orphan
          # descriptor + instruction files on disk that make the next retry fail
          # in refuse_overwrite!, turning a retryable command into a stuck one.
          commit_scaffold!(id, paths)
        rescue StandardError
          self.class.rollback_scaffold(paths)
          raise
        end

        payload = success_payload(id, paths)
        if @json
          @stdout.puts JSON.generate(payload)
        else
          @stdout.puts "hive: created workflow #{id} at #{paths.fetch(:descriptor)}"
          @stdout.puts "next: #{payload.fetch("next")}"
        end
        payload
      end

      private

      def normalize_id(value)
        id = value.to_s.strip
        return id unless id.empty?

        raise UsageError.new("missing workflow id", value: value)
      end

      def validate_id!(id)
        unless WORKFLOW_ID_RE.match?(id)
          raise UsageError.new("invalid workflow id #{id.inspect} (must match #{WORKFLOW_ID_RE.source})", value: id)
        end
        return unless Hive::Workflows::Registry::WORKFLOWS.key?(id.to_sym)

        raise UsageError.new("workflow id #{id.inspect} is reserved by a built-in workflow", value: id)
      end

      def scaffold_paths(id)
        workflows_dir = workflow_dir
        {
          workflows_dir: workflows_dir,
          descriptor: File.join(workflows_dir, "#{id}.yml"),
          instruction_dir: File.join(workflows_dir, id),
          instruction: File.join(workflows_dir, id, "work.md")
        }
      end

      def workflow_dir
        # Single source of "<hive_state_path>/workflows" — the scaffolder needs
        # the raw config error to surface (no fallback), which Loader.workflow_dir
        # provides; Project#workflow_dir_for is the fallback-wrapping variant.
        Hive::Workflows::Loader.workflow_dir(@project_root)
      end

      def refuse_overwrite!(paths)
        collisions = [ paths.fetch(:descriptor), paths.fetch(:instruction_dir), paths.fetch(:instruction) ].select do |path|
          File.exist?(path)
        end
        return if collisions.empty?

        raise UsageError.new("workflow scaffold already exists at #{collisions.join(', ')}", value: collisions.first)
      end

      def write_scaffold!(id, paths)
        FileUtils.mkdir_p(paths.fetch(:instruction_dir))
        File.write(paths.fetch(:descriptor), render_descriptor(id))
        File.write(paths.fetch(:instruction), File.read(File.join(TEMPLATE_ROOT, "work.md")))
      end

      def render_descriptor(id)
        template = File.read(File.join(TEMPLATE_ROOT, "descriptor.yml.erb"))
        ERB.new(template, trim_mode: "-").result_with_hash(id: id)
      end

      def validate_descriptor!(path)
        Hive::Workflows::DescriptorParser.parse_file(path)
      end

      def commit_scaffold!(id, paths)
        ops = Hive::GitOps.new(@project_root)
        Hive::Lock.with_commit_lock(hive_state_path) do
          ops.hive_commit(
            stage_name: "workflows",
            slug: id,
            action: "created",
            pathspecs: [
              relative_to_workflows_root(paths.fetch(:descriptor)),
              relative_to_workflows_root(paths.fetch(:instruction_dir))
            ]
          )
        end
      end

      def relative_to_workflows_root(path)
        Pathname.new(path).relative_path_from(Pathname.new(hive_state_path)).to_s
      end

      def hive_state_path
        @hive_state_path ||= File.expand_path(Hive::Config.load(@project_root).fetch("hive_state_path"), @project_root)
      end

      # Filesystem-only rollback: it unwinds the working-tree files write_scaffold!
      # created, NOT any git side-effects of a partially-run commit_scaffold!.
      # That is sufficient because hive_commit stages by explicit pathspec (so a
      # later retry re-stages exactly these paths) and the retry's
      # refuse_overwrite! re-checks the same paths — removing them here is all a
      # retry needs to succeed. rm_f/rm_rf swallow their own errors; a failure to
      # clean up at worst trips refuse_overwrite! on the next attempt with a clear
      # "already exists" message.
      def rollback_scaffold(paths)
        FileUtils.rm_f(paths.fetch(:descriptor))
        FileUtils.rm_rf(paths.fetch(:instruction_dir))
      end

      def success_payload(id, paths)
        {
          "schema" => SCHEMA,
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch(SCHEMA),
          "ok" => true,
          "id" => id,
          "descriptor_path" => paths.fetch(:descriptor),
          "instruction_path" => paths.fetch(:instruction),
          "next" => "hive new #{Shellwords.escape(File.basename(@project_root))} --workflow #{id} \"<your idea>\""
        }
      end

      # Route through the gem-wide ErrorEnvelope so the payload carries the same
      # schema / schema_version / error_kind keys as every other hive-* command
      # (agents branch on those uniformly).
      def error_payload(error)
        Hive::Schemas::ErrorEnvelope.build(
          schema: SCHEMA,
          error: error,
          error_kind: error_kind_for(error),
          extras: error_extras(error)
        )
      end

      # Surface the rejected/colliding id (UsageError#value) into the --json
      # payload so an agent recovers the bad id from a structured field instead
      # of regexing `message`. Passed via the local `extras` seam to avoid
      # changing the gem-wide ErrorEnvelope.build; non-UsageError producers
      # (ConfigError/GitError/…) carry no `value` and add no key.
      def error_extras(error)
        return {} unless error.respond_to?(:value) && !error.value.nil?

        { "value" => error.value }
      end

      def error_kind_for(error)
        kinds = Hive::Schemas::WorkflowNewErrorKind
        case error
        when UsageError                then kinds::USAGE
        when Hive::ConcurrentRunError  then kinds::CONCURRENT_RUN
        when Hive::GitError            then kinds::GIT
        when Hive::ConfigError         then kinds::CONFIG
        else                                kinds::ERROR
        end
      end
    end
  end
end
