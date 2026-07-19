require "securerandom"
require "fileutils"
require "time"
require "erb"
require "hive/config"
require "hive/git_ops"
require "hive/lock"
require "hive/paths"
require "hive/task_counter"
require "hive/task_meta"
require "hive/workflows"
require "hive/workflow_selection"
require "hive/workflow_package/managed_store"
require "hive/workflow_package/mutation_lock"
require "hive/tui/text"
require "hive/dependencies"

module Hive
  module Commands
    class New
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

      def initialize(project_name, text, slug_override: nil, body_override: nil, attachments: [], depends_on: nil,
                     workflow: nil)
        @project_name = project_name
        @text = text.to_s
        @slug_override = slug_override
        @body_override = body_override
        @attachments = attachments
        @depends_on = depends_on
        @workflow_name = workflow
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
        call!
      rescue ProjectNotFound, InvalidSlugError, InvalidDependencyError, InvalidAttachmentError,
             SlugCollisionError, UnregisteredProjectWorkflow, ProjectConfigUnreadable,
             Hive::Workflows::UnknownWorkflow,
             SystemCallError, IOError => e
        warn "hive: #{e.message}"
        # Honor each typed error's contract exit code (e.g. UnknownWorkflow →
        # USAGE 64 so an agent can tell "typo'd --workflow, fix the flag" from a
        # transient GENERIC failure); fall back to 1 for the untyped
        # SystemCallError/IOError arms.
        exit(e.respond_to?(:exit_code) ? e.exit_code : 1)
      end

      def call!
        project = Hive::Config.find_project(@project_name)
        unless project
          raise ProjectNotFound.new(
            "project not initialized: #{@project_name} (run `hive init <path>` first)",
            value: @project_name
          )
        end

        slug = @slug_override || derive_slug(@text)
        validate_slug!(slug)
        depends_on = normalize_dependency(@depends_on)
        depends_on = validate_dependency!(depends_on) if depends_on
        workflow_info = resolve_workflow(project)
        workflow = workflow_info.fetch(:descriptor)
        entry_stage = workflow.stages.first

        hive_state = project["hive_state_path"]
        task_dir = File.join(hive_state, "stages", entry_stage.dir, slug)
        if File.exist?(task_dir)
          raise SlugCollisionError.new(
            "slug collision at #{task_dir} (rare; retry the command)",
            value: slug
          )
        end
        FileUtils.mkdir_p(task_dir)

        idea_path = File.join(task_dir, entry_stage.state_file)
        id = nil
        begin
          File.write(idea_path, render_initial_state(slug, @text, body_override: @body_override, workflow: workflow))
          copy_attachments!(task_dir)
          id = allocate_task_id
          write_task_meta(task_dir, id: id, slug: slug, depends_on: depends_on,
                          workflow: workflow, workflow_info: workflow_info, hive_state: hive_state)
        rescue StandardError
          # An idea.md or attachment write failure leaves an orphan
          # uncommitted task on disk that the snapshot would surface as a
          # broken entry under the workflow's entry stage dir (`entry_stage.dir`
          # — `1-inbox` for coding, but different for other workflows). Roll the
          # directory back so the capture is atomic — either the task is
          # committed or it never existed.
          FileUtils.rm_rf(task_dir)
          raise
        end

        ops = Hive::GitOps.new(project["path"])
        Hive::Lock.with_commit_lock(hive_state) do
          ops.hive_commit(stage_name: entry_stage.dir, slug: slug, action: "captured")
        end
        spawn_name_generator(task_dir)

        puts "hive: captured #{idea_path}"
        target_hint = id ? id.to_s : slug
        next_stage = workflow.next_stage_after(entry_stage.name)
        if next_stage
          puts "next: mv #{task_dir} #{File.join(hive_state, 'stages', "#{next_stage.dir}/")} && hive run #{target_hint}"
        else
          puts "next: hive run #{target_hint}"
        end
      end

      def resolve_workflow(project)
        override = normalize_workflow(@workflow_name)
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
        managed = store.selected(descriptor.id.to_s)
        cfg = managed ? managed_project_config(project) : {}
        {
          descriptor: descriptor, pin: pin,
          managed: managed && store.selected(descriptor.id.to_s, cfg: cfg), managed_cfg: cfg
        }
      end

      def write_task_meta(task_dir, id:, slug:, depends_on:, workflow:, workflow_info:, hive_state:)
        managed = workflow_info.fetch(:managed)
        managed_cfg = workflow_info.fetch(:managed_cfg, {})
        store = Hive::WorkflowPackage::ManagedStore.new(hive_state)
        store.with_stable_selection(workflow.id.to_s, cfg: managed_cfg) do |current|
          if managed
            unless current && current.fetch("source_commit") == managed.fetch("source_commit") &&
                   current.fetch("manifest_digest") == managed.fetch("manifest_digest") &&
                   current.fetch("configuration_digest") == managed.fetch("configuration_digest")
              raise Hive::ConcurrentRunError.new("managed workflow selection changed while creating the task")
            end
          end
          Hive::TaskMeta.write(
            task_dir, id: id, slug: slug, display_name: nil, depends_on: depends_on,
            workflow: workflow_info.fetch(:pin) ? workflow.id.to_s : nil,
            workflow_commit: managed&.fetch("source_commit"),
            workflow_manifest_digest: managed&.fetch("manifest_digest"),
            workflow_configuration_digest: managed&.fetch("configuration_digest")
          )
        end
      end

      def managed_project_config(project)
        Hive::Config.load(project.fetch("path"))
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

      def normalize_workflow(value)
        string = value.to_s.strip
        string.empty? ? nil : string
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

      def normalize_dependency(value)
        string = value.to_s.strip
        string.empty? ? nil : string
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
        @attachments.each do |src, dest_name|
          name = Hive::Tui::Text.sanitize(dest_name.to_s)
          # `name != File.basename(name)` rejects directory separators
          # and the like, but `File.basename(".") == "."` and
          # `File.basename("..") == ".."` — both would otherwise slip
          # through and either overwrite `assets/` itself or escape it
          # via FileUtils.cp's path-join. Reject them explicitly.
          if name.empty? || name == "." || name == ".." || name != File.basename(name)
            raise InvalidAttachmentError.new("invalid attachment filename '#{name}'", value: name)
          end

          # `attachments:` is a programmatic contract used by the TUI and
          # tests; callers may pass any absolute source path they captured.
          # Keep the destination guard strict, but let FileUtils surface
          # source readability/existence failures directly.
          src_path = File.expand_path(src.to_s)

          FileUtils.cp(src_path, File.join(assets_dir, name))
        end
      end

      def allocate_task_id
        Hive::TaskCounter.next!
      rescue Hive::ConcurrentRunError
        nil
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
