require "securerandom"
require "fileutils"
require "time"
require "erb"
require "digest"
require "json"
require "tmpdir"
require "hive/config"
require "hive/git_ops"
require "hive/lock"
require "hive/paths"
require "hive/task_counter"
require "hive/task_meta"
require "hive/task"
require "hive/task_action"
require "hive/markers"
require "hive/workflows"
require "hive/workflow_selection"
require "hive/workflow_package/managed_store"
require "hive/workflow_package/mutation_lock"
require "hive/tui/text"
require "hive/dependencies"
require "hive/worktree"

module Hive
  module Commands
    class New
      include Hive::Schemas::EnvelopeEmitter

      SCHEMA = "hive-new".freeze
      RESERVED_SLUGS = %w[
        head fetch_head orig_head merge_head
        master main origin hive hive-state hive_state state
      ].freeze
      SLUG_RE = /\A[a-z][a-z0-9-]{0,62}[a-z0-9]\z/
      # Leave room in the slug budget for the appended `-YYMMDD-XXXX` suffix
      # (12 chars) under the 64-char SLUG_RE max.
      DERIVED_PREFIX_MAX = 51

      # Typed errors carry the offending value via `attr_reader :value`
      # so TUI / agent callers can render a structured diagnosis
      # instead of regex-parsing `message`. Mirrors the
      # `ComposerStaging::WriteError#cause_class` pattern.
      class TypedValueError < Hive::Error
        attr_reader :value

        def initialize(message, value: nil)
          super(message)
          @value = value
        end
      end

      class ProjectNotFound < TypedValueError; end
      class InvalidSlugError < TypedValueError; end
      class InvalidDependencyError < TypedValueError; end
      class InvalidBaseError < TypedValueError
        def exit_code = Hive::ExitCodes::USAGE
      end
      class InvalidDraftPrCombination < TypedValueError
        def exit_code = Hive::ExitCodes::USAGE
      end
      class SlugCollisionError < TypedValueError; end
      # Raised when an attachment's filename fails the basename/empty guard
      # in `copy_attachments!`. Distinct from `InvalidSlugError` so TUI
      # callers can distinguish "rephrase the title" feedback from
      # "attachment routing bug" feedback in their rescue lists.
      class InvalidAttachmentError < TypedValueError; end
      # Raised when a project's configured default_workflow is not a registered
      # workflow (a hand-edit, or a workflow removed after the project was set
      # up). Distinct from the user-supplied `--workflow` UnknownWorkflow so the
      # message can name config.yml and the `call` rescue can report it cleanly
      # instead of letting a bare UnknownWorkflow block ALL task creation.
      class UnregisteredProjectWorkflow < TypedValueError; end
      # Raised when the project config.yml exists but is unreadable/unparseable
      # (corrupt YAML, a non-hash document, an I/O fault). Unlike the read-only
      # status/daemon surfaces, which degrade a bad config to a coding fallback,
      # `hive new` is a mutation: creating a task under a silently-assumed
      # default could be wrong, so it fails loudly with a typed error naming
      # config.yml (mirroring UnregisteredProjectWorkflow) instead of crashing
      # with a raw Psych backtrace that escapes call's rescue list.
      class ProjectConfigUnreadable < TypedValueError; end
      class IdempotencyConflict < TypedValueError
        def exit_code = Hive::ExitCodes::USAGE
      end
      PreparedAttachment = Data.define(:snapshot_path, :destination, :name, :sha256)

      def initialize(project_name, text, slug_override: nil, body_override: nil, attachments: [], base: nil,
                     depends_on: nil, workflow: nil, idempotency_key: nil, json: false)
        @project_name = project_name
        @text = text.to_s
        @slug_override = slug_override
        @body_override = body_override
        @attachments = attachments
        @base = base
        @depends_on = depends_on
        @workflow_name = workflow
        @idempotency_key_raw = idempotency_key
        # Machine-readable creation was added for idempotent automation.
        # Preserve the legacy plain-text contract for a bare `hive new --json`
        # whose caller did not opt into that side-effect boundary.
        @json = json && !idempotency_key.nil?
      end

      class << self
        attr_writer :name_generator_spawn

        def name_generator_spawn
          @name_generator_spawn ||= ->(*argv, **opts) { Process.spawn(*argv, **opts) }
        end

        def name_generator_spawn_configured?
          !@name_generator_spawn.nil?
        end
      end

      # CLI entry point. Naming is inverted from Ruby convention here:
      # `call` is the user-facing variant that prints to stderr and
      # `exit 1`s on known failures, while `call!` is the pure raising
      # variant intended for in-process callers (the TUI's rich-submit
      # path). Don't "fix" this swap — TUI callers depend on `call!`
      # raising so they can rescue typed errors without losing the alt
      # screen.
      def call
        call_with_envelope { call! }
      rescue Hive::Error, SystemCallError, IOError => e
        warn "hive: #{e.message}" unless @json
        # Honor each typed error's contract exit code (e.g. UnknownWorkflow →
        # USAGE 64 so an agent can tell "typo'd --workflow, fix the flag" from a
        # transient GENERIC failure); fall back to 1 for the untyped
        # SystemCallError/IOError arms.
        exit(e.respond_to?(:exit_code) ? e.exit_code : 1)
      end

      def envelope_schema = SCHEMA

      def envelope_error_kind(error)
        case error
        when IdempotencyConflict, InvalidBaseError, InvalidDraftPrCombination,
             Hive::Workflows::UnknownWorkflow then "usage"
        when Hive::ConfigError, ProjectConfigUnreadable, UnregisteredProjectWorkflow then "config"
        when Hive::ConcurrentRunError then "concurrent_run"
        when Hive::InternalError then "internal"
        else "error"
        end
      end

      def envelope_extras_for(error)
        extras = {}
        extras["value"] = error.value if error.respond_to?(:value) && !error.value.nil?
        extras["idempotency_key"] = @idempotency_key if @idempotency_key
        extras
      end

      def envelope_serialization_failure_policy = :raise

      def call!
        project = Hive::Config.find_project(@project_name)
        unless project
          raise ProjectNotFound.new(
            "project not initialized: #{@project_name} (run `hive init <path>` first)",
            value: @project_name
          )
        end

        @idempotency_key = validate_idempotency_key!
        prepare_idempotent_attachments! if @idempotency_key
        depends_on = normalize_optional(@depends_on)
        depends_on = validate_dependency!(depends_on) if depends_on
        workflow_info = resolve_workflow(project)
        workflow = workflow_info.fetch(:descriptor)
        draft_pr = workflow.draft_pr_handoff?
        if depends_on && draft_pr
          raise InvalidDraftPrCombination.new(
            "workflow #{workflow.id} uses draft-PR handoff and does not support --depends-on stacking",
            value: depends_on
          )
        end
        if normalize_optional(@base) && !draft_pr
          raise InvalidDraftPrCombination.new(
            "--base is only valid for a workflow with draft-PR handoff",
            value: @base
          )
        end
        base_branch = effective_base_branch(project, workflow)
        entry_stage = workflow.stages.first
        hive_state = project["hive_state_path"]
        fingerprint = input_fingerprint(
          workflow_info, depends_on: depends_on, base_branch: base_branch
        ) if @idempotency_key
        slug = @slug_override || derive_slug(@text)
        validate_slug!(slug)
        task_dir = File.join(hive_state, "stages", entry_stage.dir, slug)
        ops = Hive::GitOps.new(project["path"])

        if @idempotency_key
          result = with_stable_workflow_selection(workflow_info, hive_state) do |stable_selection|
            Hive::Lock.with_commit_lock(hive_state) do
              validate_stable_authored_workflow!(workflow_info, hive_state)
              existing = find_idempotent_task!(hive_state, @idempotency_key, fingerprint)
              validate_stable_authored_workflow!(workflow_info, hive_state)
              next { folder: existing.fetch(:folder), created: false } if existing

              create_task_candidate!(
                task_dir, slug: slug, entry_stage: entry_stage, workflow: workflow,
                depends_on: depends_on, base_branch: base_branch,
                workflow_info: workflow_info, hive_state: hive_state,
                idempotency_key: @idempotency_key, input_fingerprint: fingerprint,
                stable_selection: stable_selection
              )
              begin
                ops.hive_commit(stage_name: entry_stage.dir, slug: slug, action: "captured")
              rescue StandardError, Interrupt
                cleanup_failed_task_commit!(ops, hive_state, task_dir)
                raise
              end
              { folder: task_dir, created: true }
            end
          end
          unless result.fetch(:created)
            return emit_task_result(result.fetch(:folder), workflow, created: false)
          end

          spawn_name_generator(task_dir)
          return emit_task_result(task_dir, workflow, created: true)
        end

        create_task_candidate!(
          task_dir, slug: slug, entry_stage: entry_stage, workflow: workflow,
          depends_on: depends_on, base_branch: base_branch,
          workflow_info: workflow_info, hive_state: hive_state,
          idempotency_key: nil, input_fingerprint: nil
        )
        Hive::Lock.with_commit_lock(hive_state) do
          begin
            ops.hive_commit(stage_name: entry_stage.dir, slug: slug, action: "captured")
          rescue StandardError, Interrupt
            cleanup_failed_task_commit!(ops, hive_state, task_dir)
            raise
          end
        end
        spawn_name_generator(task_dir)
        emit_task_result(task_dir, workflow, created: true)
      ensure
        cleanup_prepared_attachments!
      end

      def create_task_candidate!(task_dir, slug:, entry_stage:, workflow:, depends_on:, base_branch:,
                                 workflow_info:, hive_state:, idempotency_key:, input_fingerprint:,
                                 stable_selection: :unlocked)
        created = false
        FileUtils.mkdir_p(File.dirname(task_dir))
        Dir.mkdir(task_dir)
        created = true
        idea_path = File.join(task_dir, entry_stage.state_file)
        File.write(
          idea_path,
          render_initial_state(slug, @text, body_override: @body_override, workflow: workflow)
        )
        if entry_stage.kind == :human
          Hive::Markers.set(idea_path, :waiting, "decision_id" => SecureRandom.hex(8))
        end
        copy_attachments!(task_dir)
        validate_stable_authored_workflow!(workflow_info, hive_state)
        id = Hive::TaskCounter.next_or_nil
        write_task_meta(
          task_dir, id: id, slug: slug, depends_on: depends_on,
          base_branch: base_branch, workflow: workflow,
          workflow_info: workflow_info, hive_state: hive_state,
          idempotency_key: idempotency_key, input_fingerprint: input_fingerprint,
          stable_selection: stable_selection
        )
      rescue Errno::EEXIST
        if created
          FileUtils.rm_rf(task_dir)
          raise
        end

        raise SlugCollisionError.new(
          "slug collision at #{task_dir} (rare; retry the command)",
          value: slug
        )
      rescue StandardError, Interrupt
        # Once this invocation owns the directory, any idea, attachment, or
        # metadata failure must remove its uncommitted candidate. An EEXIST
        # contender never owns the directory and therefore never removes it.
        FileUtils.rm_rf(task_dir) if created
        raise
      end

      def validate_idempotency_key!
        return nil if @idempotency_key_raw.nil?

        key = @idempotency_key_raw.to_s.strip
        unless !key.empty? && key.valid_encoding? && key.bytesize <= 512
          raise IdempotencyConflict.new(
            "idempotency key must be non-empty UTF-8 text no longer than 512 bytes",
            value: @idempotency_key_raw.to_s
          )
        end
        key
      end

      def input_fingerprint(workflow_info, depends_on:, base_branch:)
        managed = workflow_info.fetch(:managed)
        attachments = @prepared_attachments.map do |attachment|
          {
            "destination" => attachment.destination,
            "sha256" => attachment.sha256
          }
        end
        input = {
          "text" => @text,
          "body" => @body_override,
          "attachments" => attachments,
          "depends_on" => depends_on,
          "base_branch" => base_branch,
          "workflow" => workflow_info.fetch(:descriptor).id.to_s,
          "workflow_commit" => managed&.fetch("source_commit"),
          "workflow_configuration_digest" => managed&.fetch("configuration_digest"),
          "workflow_content_digest" => workflow_info[:authored_digest]
        }
        ::Digest::SHA256.hexdigest(JSON.generate(input))
      end

      def find_idempotent_task!(hive_state, key, fingerprint)
        matches = Dir.glob(File.join(hive_state, "stages", "*", "*", Hive::TaskMeta::FILENAME)).filter_map do |path|
          folder = File.dirname(path)
          read = Hive::TaskMeta.read_for_admission(folder)
          unless read.status == :ok
            raise IdempotencyConflict.new(
              "cannot prove idempotency while task metadata is unreadable at #{path}: " \
              "#{read.error || read.status}",
              value: key
            )
          end
          meta = read.data
          { folder: folder, meta: meta } if meta[:idempotency_key] == key
        end
        return nil if matches.empty?
        if matches.length > 1
          raise IdempotencyConflict.new(
            "idempotency key #{key.inspect} is already attached to multiple tasks; repair metadata before retrying",
            value: key
          )
        end

        match = matches.first
        return match if match.dig(:meta, :input_fingerprint) == fingerprint

        raise IdempotencyConflict.new(
          "idempotency key #{key.inspect} was already used for different input or workflow",
          value: key
        )
      end

      def emit_task_result(task_folder, workflow, created:)
        task = Hive::Task.new(task_folder)
        action = Hive::TaskAction.for(task, Hive::Markers.current(task.state_file))
        payload = {
          "schema" => SCHEMA,
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch(SCHEMA),
          "ok" => true,
          "created" => created,
          "slug" => task.slug,
          "workflow" => workflow.id.to_s,
          "current_stage" => "#{task.stage_index}-#{task.stage_name}",
          "task_folder" => task.folder,
          "next_action" => {
            "kind" => action.key,
            "command" => action.command,
            "outcomes" => action.allowed_outcomes
          }
        }
        if @json
          puts JSON.generate(payload)
        elsif created
          puts "hive: captured #{task.state_file}"
          target_hint = task.id ? task.id.to_s : task.slug
          next_stage = workflow.next_stage_after(task.stage_name)
          if next_stage
            destination = File.join(task.hive_state_path, "stages", "#{next_stage.dir}/")
            puts "next: mv #{task.folder} #{destination} && hive run #{target_hint}"
          else
            puts "next: hive run #{target_hint}"
          end
        else
          puts "hive: idempotent task already exists at #{task.folder}"
          puts "next: #{action.command}" if action.command
        end
        payload
      end

      def resolve_workflow(project)
        override = normalize_optional(@workflow_name)
        # With an explicit --workflow the project default is irrelevant (an
        # override always pins), so don't read config.yml at all — an
        # unreadable/corrupt config must not block a fully-specified `hive new`.
        if override
          descriptor = Hive::WorkflowSelection.fetch!(override, project_root: project.fetch("path"))
          return workflow_resolution(descriptor, project, pin: true)
        end

        cfg_default = project_default_workflow(project.fetch("path"))
        workflow_resolution(
          fetch_project_default_workflow!(cfg_default, project),
          project,
          pin: !Hive::Workflows.coding_id?(cfg_default)
        )
      end

      def workflow_resolution(descriptor, project, pin:)
        store = Hive::WorkflowPackage::ManagedStore.new(project.fetch("hive_state_path"))
        cfg = {}
        managed = store.selected(descriptor.id.to_s) { cfg = managed_project_config(project) }
        {
          descriptor: descriptor, pin: pin,
          managed: managed, managed_cfg: cfg,
          authored_digest: authored_workflow_digest(project.fetch("hive_state_path"), descriptor)
        }
      end

      def write_task_meta(task_dir, id:, slug:, depends_on:, base_branch:, workflow:, workflow_info:, hive_state:,
                          idempotency_key: nil, input_fingerprint: nil, stable_selection: :unlocked)
        managed = workflow_info.fetch(:managed)
        managed_cfg = workflow_info.fetch(:managed_cfg, {})
        store = Hive::WorkflowPackage::ManagedStore.new(hive_state)
        writer = lambda do |current|
          validate_stable_selection!(managed, current)
          Hive::TaskMeta.write(
            task_dir, id: id, slug: slug, display_name: nil, depends_on: depends_on,
            base_branch: base_branch,
            workflow: workflow_info.fetch(:pin) ? workflow.id.to_s : nil,
            workflow_commit: managed&.fetch("source_commit"),
            workflow_manifest_digest: managed&.fetch("manifest_digest"),
            workflow_configuration_digest: managed&.fetch("configuration_digest"),
            idempotency_key: idempotency_key,
            input_fingerprint: input_fingerprint
          )
        end
        return writer.call(stable_selection) unless stable_selection == :unlocked

        store.with_stable_selection(workflow.id.to_s, cfg: managed_cfg, &writer)
      end

      def with_stable_workflow_selection(workflow_info, hive_state)
        workflow = workflow_info.fetch(:descriptor)
        store = Hive::WorkflowPackage::ManagedStore.new(hive_state)
        store.with_stable_selection(
          workflow.id.to_s, cfg: workflow_info.fetch(:managed_cfg, {})
        ) do |current|
          validate_stable_selection!(workflow_info.fetch(:managed), current)
          yield current
        end
      end

      def validate_stable_selection!(managed, current)
        return unless managed
        return if current && current.fetch("source_commit") == managed.fetch("source_commit") &&
          current.fetch("manifest_digest") == managed.fetch("manifest_digest") &&
          current.fetch("configuration_digest") == managed.fetch("configuration_digest")

        raise Hive::ConcurrentRunError.new("managed workflow selection changed while creating the task")
      end

      def validate_stable_authored_workflow!(workflow_info, hive_state)
        expected = workflow_info[:authored_digest]
        return unless expected

        actual = authored_workflow_digest(hive_state, workflow_info.fetch(:descriptor))
        return if actual == expected

        raise Hive::ConcurrentRunError,
              "owner-authored workflow changed while creating the task; retry against the current descriptor"
      end

      def authored_workflow_digest(hive_state, descriptor)
        workflows = File.join(hive_state, "workflows")
        descriptor_path = File.join(workflows, "#{descriptor.id}.yml")
        return nil unless File.file?(descriptor_path)

        instruction_root = File.join(workflows, descriptor.id.to_s)
        paths = [ descriptor_path ]
        if File.directory?(instruction_root)
          paths.concat(
            Dir.glob(File.join(instruction_root, "**", "*"), File::FNM_DOTMATCH)
               .select { |path| File.file?(path) }
          )
        end
        entries = paths.sort.map do |path|
          [ path.delete_prefix("#{workflows}/"), ::Digest::SHA256.file(path).hexdigest ]
        end
        ::Digest::SHA256.hexdigest(JSON.generate(entries))
      end

      def cleanup_failed_task_commit!(ops, hive_state, task_dir)
        FileUtils.rm_rf(task_dir)
        relative = task_dir.delete_prefix("#{File.expand_path(hive_state)}/")
        ops.run_git!("-C", hive_state, "reset", "-q", "HEAD", "--", relative)
      end

      def managed_project_config(project)
        Hive::Config.load(project.fetch("path"))
      rescue Hive::UnsupportedProjectConfigError
        raise
      rescue Psych::Exception, Hive::ConfigError, SystemCallError, IOError => e
        cfg_path = File.join(project.fetch("hive_state_path").to_s, "config.yml")
        raise ProjectConfigUnreadable.new(
          "could not read #{cfg_path} (#{e.class}: #{e.message}); fix the file before creating a managed-workflow task",
          value: cfg_path
        )
      end

      # A typo'd or later-removed PROJECT default_workflow would otherwise raise
      # a bare UnknownWorkflow that names no file and was absent from #call's
      # rescue list — blocking ALL task creation for the project with an opaque
      # error. Re-raise a typed error naming config.yml, mirroring
      # Task#warn_if_unregistered_project_default. The user-supplied `--workflow`
      # path keeps WorkflowSelection.fetch!'s own valid-names message.
      def fetch_project_default_workflow!(cfg_default, project)
        Hive::WorkflowSelection.fetch!(cfg_default, project_root: project.fetch("path"))
      rescue Hive::Workflows::UnknownWorkflow
        cfg_path = File.join(project["hive_state_path"].to_s, "config.yml")
        raise UnregisteredProjectWorkflow.new(
          "project default_workflow #{cfg_default.inspect} in #{cfg_path} is not a registered " \
          "workflow (valid: #{Hive::WorkflowSelection.valid_names(project_root: project.fetch('path')).join(', ')}); " \
          "fix config.yml or pass --workflow",
          value: cfg_default
        )
      end

      def project_default_workflow(project_root)
        configured = Hive::Config.load(project_root)["default_workflow"].to_s.strip
        configured.empty? ? Hive::Config::DEFAULTS["default_workflow"] : configured
      rescue Hive::UnsupportedProjectConfigError
        raise
      rescue Psych::Exception, Hive::ConfigError, SystemCallError, IOError => e
        # A corrupt/unparseable config.yml raises Psych::SyntaxError (or
        # ConfigError for a non-hash document) out of Config.load — neither a
        # Hive::Error nor caught by call's rescue list, so it would escape as a
        # raw backtrace (exit 1). Re-raise as a typed error naming config.yml so
        # the failure is clean and actionable.
        cfg_path = File.join(File.expand_path(project_root), ".hive-state", "config.yml")
        raise ProjectConfigUnreadable.new(
          "could not read #{cfg_path} (#{e.class}: #{e.message}); fix the file or pass --workflow",
          value: cfg_path
        )
      end

      def normalize_optional(value)
        string = value.to_s.strip
        string.empty? ? nil : string
      end

      def effective_base_branch(project, workflow)
        return nil unless workflow.draft_pr_handoff?

        explicit = normalize_optional(@base)
        return validate_base!(explicit) if explicit

        cfg = Hive::Config.load(project.fetch("path"))
        detected = cfg["default_branch"].to_s.strip
        detected = Hive::GitOps.new(project.fetch("path")).default_branch if detected.empty?
        validate_base!(detected)
      rescue Psych::Exception, Hive::ConfigError, SystemCallError, IOError => e
        cfg_path = File.join(project.fetch("hive_state_path").to_s, "config.yml")
        raise ProjectConfigUnreadable.new(
          "could not resolve draft-PR base from #{cfg_path} (#{e.class}: #{e.message})",
          value: cfg_path
        )
      end

      def validate_base!(value)
        Hive::Worktree.validate_branch_name!(value)
      rescue Hive::WorktreeError
        raise InvalidBaseError.new(
          "invalid base branch #{value.inspect}; pass a branch name such as main or release/next",
          value: value
        )
      end

      def derive_slug(text)
        normalized = text.unicode_normalize(:nfd)
                         .gsub(/[^\x00-\x7F]/, "")
                         .downcase
                         .gsub(/[^a-z0-9]+/, " ")
                         .strip
        words = normalized.split(/\s+/).first(5).reject(&:empty?)
        prefix = words.empty? ? "task" : words.join("-")
        prefix = prefix.gsub(/^-+|-+$/, "")
        # Cap prefix length so the composed slug always fits SLUG_RE (≤64 chars).
        prefix = prefix[0, DERIVED_PREFIX_MAX].sub(/-+\z/, "")
        date = Time.now.strftime("%y%m%d")
        suffix = SecureRandom.hex(2)
        candidate = "#{prefix}-#{date}-#{suffix}"
        candidate = candidate.delete_prefix("-")
        candidate = "task-#{date}-#{suffix}" unless candidate.match?(/\A[a-z]/)
        candidate
      end

      def validate_slug!(slug)
        unless slug.is_a?(String) && SLUG_RE.match?(slug)
          raise InvalidSlugError.new(
            "invalid slug '#{slug}' (must match #{SLUG_RE.source}; rephrase the task text so its derived slug fits the pattern)",
            value: slug
          )
        end
        return unless RESERVED_SLUGS.include?(slug.downcase) || slug.include?("..") || slug.include?("/") || slug.include?("@")

        raise InvalidSlugError.new("reserved or unsafe slug '#{slug}'", value: slug)
      end

      def validate_dependency!(value)
        Hive::Dependencies.parse_reference(value).to_s
      rescue Hive::Dependencies::InvalidReference

        # Describe the accepted shape in plain English for humans and
        # agents; the raw offending value stays in the structured `value:`
        # field for machine consumers (the regex source is an
        # implementation detail, not an operator-facing format).
        raise InvalidDependencyError.new(
          "invalid dependency '#{value}' — expected one prerequisite task id, " \
          "slug, or explicit project:slug reference",
          value: value
        )
      end

      def render_idea(slug, text, body_override: nil)
        template = File.read(File.expand_path("../../../templates/idea.md.erb", __dir__))
        bindings = IdeaBinding.new(
          slug: slug,
          original_text: text,
          body_override: body_override,
          created_at: Time.now.utc.iso8601
        )
        ERB.new(template, trim_mode: "-").result(bindings.binding_for_erb)
      end

      def render_initial_state(slug, text, body_override:, workflow:)
        content = render_idea(slug, text, body_override: body_override)
        return content if Hive::Workflows.coding_id?(workflow.id)

        replacement = workflow.stages.first&.kind == :inert ? "\n<!-- COMPLETE -->\n" : "\n"
        content.sub(/\n?<!-- WAITING -->\n?\z/, replacement)
      end

      # Copy each `[src, dest_name]` tuple into `<task_dir>/assets/`.
      # Contract:
      #   - `src` must be an absolute filesystem path to a readable file.
      #   - `dest_name` must be a single path segment (basename only) —
      #     no directory separators, no `..`, no empty string. The guard
      #     defends against TUI callers that synthesize `dest_name` from
      #     attachment metadata; an invalid value raises
      #     `InvalidAttachmentError` so the caller's rescue list can
      #     distinguish it from real slug-derivation failures.
      # Returns nil. Raises `InvalidAttachmentError` on filename guard
      # failure or `SystemCallError`/`IOError` on copy failure. Callers
      # that need atomicity should wrap this in their own rollback (see
      # `call!`).
      def copy_attachments!(task_dir)
        return if @attachments.empty?

        assets_dir = File.join(task_dir, "assets")
        FileUtils.mkdir_p(assets_dir)
        if @prepared_attachments
          @prepared_attachments.each do |attachment|
            destination = File.join(assets_dir, attachment.name)
            FileUtils.cp(attachment.snapshot_path, destination)
            next if ::Digest::SHA256.file(destination).hexdigest == attachment.sha256

            raise InvalidAttachmentError.new(
              "attachment snapshot changed while creating the task",
              value: attachment.destination
            )
          end
        else
          @attachments.each do |src, dest_name|
            name = attachment_name!(dest_name)
            # `attachments:` is a programmatic contract used by the TUI and
            # tests; callers may pass any absolute source path they captured.
            # Keep the destination guard strict, but let FileUtils surface
            # source readability/existence failures directly.
            src_path = File.expand_path(src.to_s)
            FileUtils.cp(src_path, File.join(assets_dir, name))
          end
        end
      end

      def prepare_idempotent_attachments!
        if @attachments.empty?
          @prepared_attachments = []
          return
        end

        @attachment_snapshot_dir = Dir.mktmpdir("hive-new-attachments")
        @prepared_attachments = @attachments.each_with_index.map do |(source, destination), index|
          name = attachment_name!(destination)
          snapshot_path = File.join(@attachment_snapshot_dir, index.to_s)
          FileUtils.cp(File.expand_path(source.to_s), snapshot_path)
          PreparedAttachment.new(
            snapshot_path: snapshot_path,
            destination: destination.to_s,
            name: name,
            sha256: ::Digest::SHA256.file(snapshot_path).hexdigest
          )
        end
      end

      def cleanup_prepared_attachments!
        return unless @attachment_snapshot_dir

        FileUtils.remove_entry_secure(@attachment_snapshot_dir)
      rescue Errno::ENOENT
        nil
      ensure
        @attachment_snapshot_dir = nil
        @prepared_attachments = nil
      end

      def attachment_name!(destination)
        name = Hive::Tui::Text.sanitize(destination.to_s)
        # `name != File.basename(name)` rejects directory separators and the
        # like, but `File.basename(".") == "."` and `File.basename("..") ==
        # ".."` — both would otherwise slip through and overwrite or escape
        # `assets/`.
        if name.empty? || name == "." || name == ".." || name != File.basename(name)
          raise InvalidAttachmentError.new("invalid attachment filename '#{name}'", value: name)
        end

        name
      end

      def spawn_name_generator(task_dir)
        return nil if defined?(Minitest) && !self.class.name_generator_spawn_configured?

        FileUtils.mkdir_p(File.join(Hive::Paths.state_home, "logs"))
        log_path = File.join(Hive::Paths.state_home, "logs", "display-name.log")
        pid = self.class.name_generator_spawn.call(
          ENV.fetch("HIVE_BIN", "hive"), "generate-name", task_dir,
          pgroup: true,
          out: [ log_path, "a" ],
          err: [ log_path, "a" ]
        )
        Thread.new do
          Thread.current.report_on_exception = false
          Process.wait(pid)
        rescue Errno::ECHILD, Errno::ESRCH
          nil
        end
        pid
      rescue StandardError
        nil
      end

      class IdeaBinding
        def initialize(slug:, original_text:, body_override:, created_at:)
          @slug = slug
          @original_text = original_text
          @body_override = body_override
          @created_at = created_at
        end

        attr_reader :slug, :original_text, :body_override, :created_at

        def binding_for_erb
          binding
        end
      end
    end
  end
end
