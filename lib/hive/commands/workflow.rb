require "erb"
require "fileutils"
require "json"
require "pathname"
require "shellwords"
require "stringio"
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
      TEMPLATES_DIR = File.expand_path("../../../templates/workflows", __dir__)
      DEFAULT_TEMPLATE = "blank".freeze
      HONEYCOMB_TEMPLATES = %w[architecture writing].freeze
      WORKFLOW_ID_RE = Hive::Workflows::DescriptorParser::SAFE_SLUG
      SCHEMA = "hive-workflow-new".freeze
      SUBCOMMANDS = %w[new validate commit install list update remove publish].freeze

      class UsageError < Hive::Error
        attr_reader :value, :expected, :suggested_id

        # Closed set of usage-error shapes (which structured field each carries):
        #   missing subcommand        -> expected only
        #   unknown subcommand        -> value (the rejected verb) + expected
        #   bad/missing/reserved id / -> value (the rejected/colliding token) only
        #   scaffold collision
        def initialize(message, value: nil, expected: nil, suggested_id: nil)
          super(message)
          @value = value
          @expected = expected
          @suggested_id = suggested_id
        end

        def exit_code
          Hive::ExitCodes::USAGE
        end
      end

      def self.new!(id, project_root: Dir.pwd, json: false, stdout: $stdout, template: DEFAULT_TEMPLATE)
        new("new", id, project_root: project_root, json: json, stdout: stdout, template: template).call!
      end

      def self.normalize_and_validate_id!(raw, project_root: nil)
        id = normalize_id(raw)
        validate_id!(id, project_root: project_root)
        id
      end

      def self.scaffold_files!(id_raw, project_root:, template: DEFAULT_TEMPLATE)
        id = normalize_and_validate_id!(id_raw, project_root: project_root)
        template_dir = template_dir!(template)
        paths = scaffold_paths(id, project_root: project_root, template_dir: template_dir)
        refuse_overwrite!(paths, id: id, project_root: project_root)
        begin
          write_scaffold!(id, paths, template_dir)
          validate_descriptor!(paths.fetch(:descriptor))
          Hive::Workflows::Project.reset!
        rescue StandardError
          rollback_scaffold(paths)
          raise
        end
        { id: id, paths: paths }
      end

      # Inline-author pre-check for `hive init`: does scaffolding `id` clash with
      # files already on disk? A pure predicate — pass an id that
      # normalize_and_validate_id! has ALREADY accepted (the inline author
      # normalizes in prompt_new_workflow_id before calling this), so on a
      # pre-validated id it never raises and the `?` name holds. (It can still
      # raise on a corrupt project config — workflow_dir → Config.load →
      # ConfigError — but that is a real fault, not an id-shape rejection.) The
      # inline author always scaffolds from
      # the default (`blank`) template, so the pre-check resolves paths against
      # `blank` too. That is not truly template-independent — scaffold_collisions
      # also walks the template-dependent per-stage instruction files — but those
      # instructions all live under the `<id>/` dir this already checks, so the
      # descriptor + dir collision set a different template would produce is the
      # same.
      def self.scaffold_collision?(id, project_root:)
        paths = scaffold_paths(id, project_root: project_root, template_dir: template_dir!(DEFAULT_TEMPLATE))
        scaffold_collisions(paths).any?
      end

      # Return the first create-safe id in a deterministic numeric sequence.
      # This is intentionally read-only and shared by the CLI and canonical
      # skill so collision recovery never depends on an agent guessing a name.
      def self.available_id(raw, project_root:)
        base = raw.to_s.strip
        base = "workflow" unless WORKFLOW_ID_RE.match?(base)
        suffix = 1
        loop do
          candidate = suffix == 1 ? base : "#{base}-#{suffix}"
          return candidate unless unavailable_id?(candidate, project_root: project_root)

          suffix += 1
        end
      end

      # Sample templates ship as directories under `templates/workflows/` (the
      # bare `blank` stub plus richer multi-stage samples). A template dir holds
      # `descriptor.yml.erb` (rendered with the new id) and one `.md` instruction
      # per agent stage. Only dirs carrying a `descriptor.yml.erb` count, so a
      # stray file under the templates root is never offered as a template.
      def self.available_templates
        Dir.children(TEMPLATES_DIR).select do |name|
          File.file?(File.join(TEMPLATES_DIR, name, "descriptor.yml.erb"))
        end.sort
      end

      def self.template_dir!(template)
        name = template.to_s.strip
        name = DEFAULT_TEMPLATE if name.empty?
        dir = File.join(TEMPLATES_DIR, name)
        return dir if File.file?(File.join(dir, "descriptor.yml.erb"))

        if HONEYCOMB_TEMPLATES.include?(name)
          raise UsageError.new(
            "workflow template #{name.inspect} moved to Honeycomb; " \
            "install it with `hive workflow install honeycomb/#{name}`",
            value: name,
            expected: available_templates
          )
        end

        raise UsageError.new(
          "unknown workflow template #{name.inspect} (available: #{available_templates.join(', ')})",
          value: name,
          expected: available_templates
        )
      end
      private_class_method :template_dir!

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
      # created. Callers that attempted a commit own exact-path index rollback
      # while still holding the commit lock; this helper intentionally leaves
      # git untouched.
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

      def self.validate_id!(id, project_root: nil)
        unless WORKFLOW_ID_RE.match?(id)
          raise UsageError.new("invalid workflow id #{id.inspect} (must match #{WORKFLOW_ID_RE.source})", value: id)
        end
        return unless Hive::Workflows::Registry::WORKFLOWS.key?(id.to_sym)

        suggested = available_id(id, project_root: project_root) if project_root
        suffix = suggested ? "; try #{suggested.inspect}" : ""
        raise UsageError.new(
          "workflow id #{id.inspect} is reserved by a built-in workflow#{suffix}",
          value: id, suggested_id: suggested
        )
      end
      private_class_method :validate_id!

      def self.unavailable_id?(id, project_root:)
        return true if Hive::Workflows::Registry::WORKFLOWS.key?(id.to_sym)

        dir = workflow_dir(project_root)
        path_present?(File.join(dir, "#{id}.yml")) || path_present?(File.join(dir, id))
      end
      private_class_method :unavailable_id?

      def self.path_present?(path)
        File.exist?(path) || File.symlink?(path)
      end
      private_class_method :path_present?

      def self.scaffold_paths(id, project_root:, template_dir:)
        workflows_dir = workflow_dir(project_root)
        instruction_dir = File.join(workflows_dir, id)
        instructions = template_instruction_files(template_dir).map { |file| File.join(instruction_dir, file) }
        {
          descriptor: File.join(workflows_dir, "#{id}.yml"),
          instruction_dir: instruction_dir,
          instructions: instructions,
          # The primary instruction (first stage's). Keeps the `instruction_path`
          # JSON field single-valued for the strict hive-workflow-new schema; the
          # human output points at the dir when a template has several.
          instruction: instructions.first
        }
      end
      private_class_method :scaffold_paths

      # Sorted so the copy order — and the `instruction_path`/`next` the payload
      # reports — are deterministic across runs (golden-output tests).
      def self.template_instruction_files(template_dir)
        Dir.children(template_dir).select { |file| file.end_with?(".md") }.sort
      end
      private_class_method :template_instruction_files

      # Single source of "<hive_state_path>/workflows" — the scaffolder needs the
      # raw config error to surface (no fallback), which Loader.workflow_dir
      # provides; Project#workflow_dir_for is the fallback-wrapping variant.
      def self.workflow_dir(project_root)
        Hive::Workflows::Loader.workflow_dir(project_root)
      end
      private_class_method :workflow_dir

      def self.refuse_overwrite!(paths, id:, project_root:)
        collisions = scaffold_collisions(paths)
        return if collisions.empty?

        suggested = available_id(id, project_root: project_root)
        raise UsageError.new(
          "workflow scaffold already exists at #{collisions.join(', ')}; try #{suggested.inspect}",
          value: collisions.first, suggested_id: suggested
        )
      end
      private_class_method :refuse_overwrite!

      # One source of truth for "what would this scaffold overwrite?" — shared by
      # refuse_overwrite! (the scaffold_files! guard) and scaffold_collision?
      # (init's inline-author pre-check). Checks the descriptor, the instruction
      # dir, and every per-stage instruction file the template would write.
      def self.scaffold_collisions(paths)
        ([ paths.fetch(:descriptor), paths.fetch(:instruction_dir) ] + paths.fetch(:instructions)).select do |path|
          path_present?(path)
        end
      end
      private_class_method :scaffold_collisions

      def self.write_scaffold!(id, paths, template_dir)
        FileUtils.mkdir_p(paths.fetch(:instruction_dir))
        File.write(paths.fetch(:descriptor), render_descriptor(id, template_dir))
        template_instruction_files(template_dir).each do |file|
          File.write(File.join(paths.fetch(:instruction_dir), file), File.read(File.join(template_dir, file)))
        end
        write_optional_template_asset(id, template_dir, "README.md.erb", File.join(paths.fetch(:instruction_dir), "README.md"))
        write_optional_template_asset(id, template_dir, "honeycomb.yml.erb", File.join(paths.fetch(:instruction_dir), "honeycomb.yml"))
      end
      private_class_method :write_scaffold!

      def self.write_optional_template_asset(id, template_dir, template_name, destination)
        source = File.join(template_dir, template_name)
        return unless File.file?(source)

        rendered = ERB.new(File.read(source), trim_mode: "-").result_with_hash(id: id)
        File.write(destination, rendered)
      end
      private_class_method :write_optional_template_asset

      def self.render_descriptor(id, template_dir)
        template = File.read(File.join(template_dir, "descriptor.yml.erb"))
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
        leftovers = [ paths.fetch(:descriptor), paths.fetch(:instruction_dir) ].select { |path| path_present?(path) }
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

      def initialize(subcommand, id = nil, project_root: Dir.pwd, json: false, stdout: $stdout, template: DEFAULT_TEMPLATE,
                     yes: false, dry_run: false, allow_escalation: false, version: nil,
                     mapping_overrides: [], input_bindings: [])
        @subcommand = subcommand
        @id = id
        @project_root = File.expand_path(project_root)
        @json = json
        @stdout = stdout
        @template = template
        @yes = yes
        @dry_run = dry_run
        @allow_escalation = allow_escalation
        @version = version
        @mapping_overrides = mapping_overrides
        @input_bindings = input_bindings
      end

      def call
        call!
      rescue Hive::Error, SystemCallError, IOError => e
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

        unless SUBCOMMANDS.include?(@subcommand)
          raise UsageError.new(
            "unknown workflow subcommand #{@subcommand.inspect} (expected: #{expected_list})",
            value: @subcommand,
            expected: SUBCOMMANDS
          )
        end

        return commit_authored_workflow! if @subcommand == "commit"
        return lifecycle_command.call unless @subcommand == "new"

        scaffold = self.class.scaffold_files!(@id, project_root: @project_root, template: @template)
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
          if paths.fetch(:instructions).size > 1
            @stdout.puts "edit: #{paths.fetch(:instruction_dir)}/ (#{paths.fetch(:instructions).size} stage instructions to fill in)"
          else
            @stdout.puts "edit: #{paths.fetch(:instruction)} (the `work` stage instruction — a placeholder until you define it)"
          end
          @stdout.puts "next: #{payload.fetch("next")}"
        end
        payload
      end

      private

      def commit_authored_workflow!
        raise UsageError.new("workflow commit does not support --json", value: @id) if @json

        id = self.class.normalize_and_validate_id!(@id, project_root: @project_root)
        require "hive/commands/workflow/validate"
        validation = Hive::Commands::Workflow::Validate.new(
          id, project_root: @project_root, stdout: StringIO.new
        ).call!
        unless validation.fetch("origin") == "authored"
          raise UsageError.new(
            "workflow commit requires an owner-authored workflow, got #{validation.fetch('origin')}",
            value: id
          )
        end

        descriptor = validation.fetch("descriptor_path")
        instruction_dir = File.join(File.dirname(descriptor), id)
        pathspecs = [ relative_to_workflows_root(descriptor) ]
        pathspecs << relative_to_workflows_root(instruction_dir) if File.directory?(instruction_dir)
        ops = Hive::GitOps.new(@project_root)
        result = Hive::Lock.with_commit_lock(hive_state_path) do
          begin
            ops.hive_commit(
              stage_name: "workflows", slug: id, action: "defined",
              pathspecs: pathspecs
            )
          rescue StandardError
            ops.run_git!("-C", hive_state_path, "reset", "-q", "HEAD", "--", *pathspecs)
            raise
          end
        end
        @stdout.puts(
          result == :committed ?
            "hive: committed populated workflow #{id}" :
            "hive: populated workflow #{id} is already committed"
        )
        {
          "ok" => true, "id" => id, "committed" => result == :committed,
          "descriptor_path" => descriptor
        }
      end

      def lifecycle_command
        case @subcommand
        when "validate"
          require "hive/commands/workflow/validate"
          Hive::Commands::Workflow::Validate.new(
            @id, project_root: @project_root, json: @json, stdout: @stdout
          )
        when "install"
          require "hive/commands/workflow/install"
          Hive::Commands::Workflow::Install.new(
            @id, project_root: @project_root, json: @json, yes: @yes,
            dry_run: @dry_run, stdout: @stdout, allow_escalation: @allow_escalation,
            mapping_overrides: @mapping_overrides, input_bindings: @input_bindings
          )
        when "list"
          raise UsageError.new("workflow list does not accept an id", value: @id) if @id

          require "hive/commands/workflow/list"
          Hive::Commands::Workflow::List.new(project_root: @project_root, json: @json, stdout: @stdout)
        when "remove"
          require "hive/commands/workflow/remove"
          Hive::Commands::Workflow::Remove.new(
            @id, project_root: @project_root, json: @json, yes: @yes,
            dry_run: @dry_run, stdout: @stdout
          )
        when "update"
          require "hive/commands/workflow/update"
          Hive::Commands::Workflow::Update.new(
            @id, project_root: @project_root, json: @json, yes: @yes,
            allow_escalation: @allow_escalation, dry_run: @dry_run, stdout: @stdout,
            mapping_overrides: @mapping_overrides, input_bindings: @input_bindings
          )
        when "publish"
          require "hive/commands/workflow/publish"
          Hive::Commands::Workflow::Publish.new(
            @id, project_root: @project_root, json: @json, version: @version, stdout: @stdout
          )
        end
      end

      def commit_scaffold!(id, paths)
        ops = Hive::GitOps.new(@project_root)
        pathspecs = [
          relative_to_workflows_root(paths.fetch(:descriptor)),
          relative_to_workflows_root(paths.fetch(:instruction_dir))
        ]
        Hive::Lock.with_commit_lock(hive_state_path) do
          begin
            self.class.commit_workflow_scaffold(
              ops, slug: id, pathspecs: pathspecs
            )
          rescue StandardError
            ops.run_git!("-C", hive_state_path, "reset", "-q", "HEAD", "--", *pathspecs)
            raise
          end
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
          schema: response_schema,
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
        if error.respond_to?(:suggested_id) && !error.suggested_id.nil?
          extras["suggested_id"] = error.suggested_id
        end
        if @subcommand == "validate"
          extras["valid"] = false
          extras["id"] = @id.to_s
          extras["diagnostics"] = [ { "message" => error.message } ]
        end

        extras
      end

      def response_schema
        @subcommand == "validate" ? "hive-workflow-validate" : SCHEMA
      end

      def error_kind_for(error)
        kinds = Hive::Schemas::WorkflowNewErrorKind
        case error
        when UsageError                then kinds::USAGE
        when Hive::Workflows::UnknownWorkflow then kinds::USAGE
        when Hive::ConcurrentRunError  then kinds::CONCURRENT_RUN
        when Hive::GitError            then kinds::GIT
        when Hive::ConfigError         then kinds::CONFIG
        else                                kinds::ERROR
        end
      end
    end
  end
end
