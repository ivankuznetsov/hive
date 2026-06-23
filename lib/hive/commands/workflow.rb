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
      SUBCOMMANDS = %w[new].freeze

      class UsageError < Hive::Error
        attr_reader :value, :expected

        # Closed set of usage-error shapes (which structured field each carries):
        #   missing subcommand        -> expected only
        #   unknown subcommand        -> value (the rejected verb) + expected
        #   bad/missing/reserved id / -> value (the rejected/colliding token) only
        #   scaffold collision
        def initialize(message, value: nil, expected: nil)
          super(message)
          @value = value
          @expected = expected
        end

        def exit_code
          Hive::ExitCodes::USAGE
        end
      end

      def self.new!(id, project_root: Dir.pwd, json: false, stdout: $stdout)
        new("new", id, project_root: project_root, json: json, stdout: stdout).call!
      end

      def self.normalize_and_validate_id!(raw)
        id = normalize_id(raw)
        validate_id!(id)
        id
      end

      def self.scaffold_files!(id_raw, project_root:)
        id = normalize_and_validate_id!(id_raw)
        paths = scaffold_paths(id, project_root: project_root)
        refuse_overwrite!(paths)
        begin
          write_scaffold!(id, paths)
          validate_descriptor!(paths.fetch(:descriptor))
          Hive::Workflows::Project.reset!
        rescue StandardError
          rollback_scaffold(paths)
          raise
        end
        { id: id, paths: paths }
      end

      # Shared scaffold-commit contract: hive init --new-workflow (fresh and
      # existing) and `hive workflow new` all commit a scaffolded descriptor
      # (plus, for init, the config.yml rebind) under the same
      # "workflows/<slug> created" message. Callers own the commit lock and the
      # pathspec relative-path mapping; this centralizes the stage/action
      # contract so the magic strings live in one place.
      def self.commit_workflow_scaffold(ops, slug:, pathspecs:)
        ops.hive_commit(stage_name: "workflows", slug: slug, action: "created", pathspecs: pathspecs)
      end

      # Filesystem-only rollback: unwinds the working-tree files write_scaffold!
      # created, NOT any git side-effects of a partially-run commit. hive_commit
      # stages by explicit pathspec, so a same-command retry re-stages exactly
      # these paths and refuse_overwrite! re-checks them — removing the files is
      # all a retry needs.
      #
      # NOTE: the shared-worktree callers commit into the long-lived
      # `.hive-state` worktree, where a failed commit ALSO leaves these pathspecs
      # STAGED. `hive init --new-workflow` on an existing project resets the index
      # for them (Init#reset_hive_state_index); `hive workflow new`'s own
      # commit_scaffold! (below) shares the SAME pre-existing exposure but
      # currently relies on this filesystem-only rollback alone — out of scope to
      # fix here, but `workflow new` is NOT index-safe just because init now is.
      # Either way this method intentionally leaves git untouched.
      # remove_scaffold_path tolerates
      # an already-absent target (like rm_f/rm_rf's force) and continues to the
      # next path on a fault, but CAPTURES the errno so warn_failed_scaffold_cleanup
      # can tell the operator WHY a leftover survived rather than emitting a bare
      # path list — a leftover would otherwise resurface as a confusing
      # refuse_overwrite! "already exists" on the next attempt.
      def self.rollback_scaffold(paths)
        reasons = {}
        remove_scaffold_path(paths.fetch(:descriptor), reasons)
        remove_scaffold_path(paths.fetch(:instruction_dir), reasons)
        warn_failed_scaffold_cleanup(paths, reasons)
      end

      # Remove one scaffold path, recording the underlying errno when a genuine
      # permission/busy fault keeps it on disk. The existence guard makes an
      # already-absent target a no-op (matching rm_f/rm_rf's force: true) without
      # swallowing the real fault the way the force variants do.
      def self.remove_scaffold_path(path, reasons)
        return unless File.exist?(path) || File.symlink?(path)

        FileUtils.remove_entry(path)
      rescue SystemCallError => e
        reasons[path] = e
      end
      private_class_method :remove_scaffold_path

      def self.normalize_id(value)
        id = value.to_s.strip
        return id unless id.empty?

        raise UsageError.new("missing workflow id", value: value)
      end
      private_class_method :normalize_id

      def self.validate_id!(id)
        unless WORKFLOW_ID_RE.match?(id)
          raise UsageError.new("invalid workflow id #{id.inspect} (must match #{WORKFLOW_ID_RE.source})", value: id)
        end
        return unless Hive::Workflows::Registry::WORKFLOWS.key?(id.to_sym)

        raise UsageError.new("workflow id #{id.inspect} is reserved by a built-in workflow", value: id)
      end
      private_class_method :validate_id!

      def self.scaffold_paths(id, project_root:)
        workflows_dir = workflow_dir(project_root)
        {
          descriptor: File.join(workflows_dir, "#{id}.yml"),
          instruction_dir: File.join(workflows_dir, id),
          instruction: File.join(workflows_dir, id, "work.md")
        }
      end
      private_class_method :scaffold_paths

      # Single source of "<hive_state_path>/workflows" — the scaffolder needs the
      # raw config error to surface (no fallback), which Loader.workflow_dir
      # provides; Project#workflow_dir_for is the fallback-wrapping variant.
      def self.workflow_dir(project_root)
        Hive::Workflows::Loader.workflow_dir(project_root)
      end
      private_class_method :workflow_dir

      def self.refuse_overwrite!(paths)
        collisions = [ paths.fetch(:descriptor), paths.fetch(:instruction_dir), paths.fetch(:instruction) ].select do |path|
          File.exist?(path)
        end
        return if collisions.empty?

        raise UsageError.new("workflow scaffold already exists at #{collisions.join(', ')}", value: collisions.first)
      end
      private_class_method :refuse_overwrite!

      def self.write_scaffold!(id, paths)
        FileUtils.mkdir_p(paths.fetch(:instruction_dir))
        File.write(paths.fetch(:descriptor), render_descriptor(id))
        File.write(paths.fetch(:instruction), File.read(File.join(TEMPLATE_ROOT, "work.md")))
      end
      private_class_method :write_scaffold!

      def self.render_descriptor(id)
        template = File.read(File.join(TEMPLATE_ROOT, "descriptor.yml.erb"))
        ERB.new(template, trim_mode: "-").result_with_hash(id: id)
      end
      private_class_method :render_descriptor

      def self.validate_descriptor!(path)
        Hive::Workflows::DescriptorParser.parse_file(path)
      end
      private_class_method :validate_descriptor!

      # Localizes the signal when a permission/busy failure leaves the scaffold
      # on disk, where it would otherwise resurface as a confusing
      # refuse_overwrite! "already exists" on the next attempt. `reasons` carries
      # the errno remove_scaffold_path captured per leftover so the operator
      # learns WHY cleanup failed (e.g. EACCES on a read-only parent) instead of
      # a bare path list.
      def self.warn_failed_scaffold_cleanup(paths, reasons = {})
        leftovers = [ paths.fetch(:descriptor), paths.fetch(:instruction_dir) ].select { |path| File.exist?(path) }
        return if leftovers.empty?

        described = leftovers.map do |path|
          reason = reasons[path]
          reason ? "#{path} (#{reason.class}: #{reason.message})" : path
        end
        warn "hive workflow: scaffold cleanup could not remove #{described.join(', ')}; " \
             "remove them manually before retrying --new-workflow"
      rescue Errno::EPIPE
        nil
      end
      private_class_method :warn_failed_scaffold_cleanup

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
        expected_list = SUBCOMMANDS.join(", ")
        if @subcommand.nil?
          raise UsageError.new(
            "missing SUBCOMMAND (expected: #{expected_list})",
            expected: SUBCOMMANDS
          )
        end

        unless @subcommand == "new"
          raise UsageError.new(
            "unknown workflow subcommand #{@subcommand.inspect} (expected: #{expected_list})",
            value: @subcommand,
            expected: SUBCOMMANDS
          )
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

      def commit_scaffold!(id, paths)
        ops = Hive::GitOps.new(@project_root)
        Hive::Lock.with_commit_lock(hive_state_path) do
          self.class.commit_workflow_scaffold(ops, slug: id, pathspecs: [
            relative_to_workflows_root(paths.fetch(:descriptor)),
            relative_to_workflows_root(paths.fetch(:instruction_dir))
          ])
        end
      end

      def relative_to_workflows_root(path)
        Pathname.new(path).relative_path_from(Pathname.new(hive_state_path)).to_s
      end

      def hive_state_path
        @hive_state_path ||= File.expand_path(Hive::Config.load(@project_root).fetch("hive_state_path"), @project_root)
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

      # Surface command-specific UsageError details through structured extras so
      # agents do not need to regex `message`. Passed through the local seam to
      # avoid changing the gem-wide ErrorEnvelope.build.
      def error_extras(error)
        extras = {}
        extras["value"] = error.value if error.respond_to?(:value) && !error.value.nil?
        extras["expected"] = error.expected if error.respond_to?(:expected) && !error.expected.nil?

        extras
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
