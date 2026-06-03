require "securerandom"
require "fileutils"
require "time"
require "erb"
require "hive/config"
require "hive/git_ops"
require "hive/paths"
require "hive/task_counter"
require "hive/task_meta"
require "hive/tui/text"

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
      class SlugCollisionError < TypedValueError; end
      # Raised when an attachment's filename fails the basename/empty guard
      # in `copy_attachments!`. Distinct from `InvalidSlugError` so TUI
      # callers can distinguish "rephrase the title" feedback from
      # "attachment routing bug" feedback in their rescue lists.
      class InvalidAttachmentError < TypedValueError; end

      def initialize(project_name, text, slug_override: nil, body_override: nil, attachments: [])
        @project_name = project_name
        @text = text.to_s
        @slug_override = slug_override
        @body_override = body_override
        @attachments = attachments
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
      rescue ProjectNotFound, InvalidSlugError, InvalidAttachmentError,
             SlugCollisionError, SystemCallError, IOError => e
        warn "hive: #{e.message}"
        exit 1
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

        hive_state = project["hive_state_path"]
        task_dir = File.join(hive_state, "stages", "1-inbox", slug)
        if File.exist?(task_dir)
          raise SlugCollisionError.new(
            "slug collision at #{task_dir} (rare; retry the command)",
            value: slug
          )
        end
        FileUtils.mkdir_p(task_dir)

        idea_path = File.join(task_dir, "idea.md")
        id = nil
        begin
          File.write(idea_path, render_idea(slug, @text, body_override: @body_override))
          copy_attachments!(task_dir)
          id = allocate_task_id
          Hive::TaskMeta.write(task_dir, id: id, slug: slug, display_name: nil)
        rescue StandardError
          # An idea.md or attachment write failure leaves an orphan
          # uncommitted task on disk that the snapshot would surface as
          # a broken `1-inbox/` entry. Roll the directory back so the
          # capture is atomic — either the task is committed or it
          # never existed.
          FileUtils.rm_rf(task_dir)
          raise
        end

        ops = Hive::GitOps.new(project["path"])
        ops.hive_commit(stage_name: "1-inbox", slug: slug, action: "captured")
        spawn_name_generator(task_dir)

        puts "hive: captured #{idea_path}"
        target_hint = id ? id.to_s : "<task>"
        puts "next: mv #{task_dir} #{File.join(hive_state, 'stages', '2-brainstorm/')} && hive run #{target_hint}"
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
          "hive", "generate-name", task_dir,
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
