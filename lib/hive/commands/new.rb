require "securerandom"
require "fileutils"
require "time"
require "erb"
require "hive/config"
require "hive/git_ops"

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

      class ProjectNotFound < Hive::Error; end
      class InvalidSlugError < Hive::Error; end
      class SlugCollisionError < Hive::Error; end

      def initialize(project_name, text, slug_override: nil, body_override: nil, attachments: [])
        @project_name = project_name
        @text = text.to_s
        @slug_override = slug_override
        @body_override = body_override
        @attachments = attachments
      end

      def call
        call!
      rescue ProjectNotFound, InvalidSlugError, SlugCollisionError => e
        warn "hive: #{e.message}"
        exit 1
      end

      def call!
        project = Hive::Config.find_project(@project_name)
        unless project
          raise ProjectNotFound,
            "project not initialized: #{@project_name} (run `hive init <path>` first)"
        end

        slug = @slug_override || derive_slug(@text)
        validate_slug!(slug)

        hive_state = project["hive_state_path"]
        task_dir = File.join(hive_state, "stages", "1-inbox", slug)
        if File.exist?(task_dir)
          raise SlugCollisionError, "slug collision at #{task_dir} (rare; retry the command)"
        end
        FileUtils.mkdir_p(task_dir)

        idea_path = File.join(task_dir, "idea.md")
        File.write(idea_path, render_idea(slug, @text, body_override: @body_override))
        copy_attachments!(task_dir)

        ops = Hive::GitOps.new(project["path"])
        ops.hive_commit(stage_name: "1-inbox", slug: slug, action: "captured")

        puts "hive: captured #{idea_path}"
        puts "next: mv #{task_dir} #{File.join(hive_state, 'stages', '2-brainstorm/')} && hive run <task>"
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
          raise InvalidSlugError,
            "invalid slug '#{slug}' (must match #{SLUG_RE.source}; rephrase the task text so its derived slug fits the pattern)"
        end
        return unless RESERVED_SLUGS.include?(slug.downcase) || slug.include?("..") || slug.include?("/") || slug.include?("@")

        raise InvalidSlugError, "reserved or unsafe slug '#{slug}'"
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

      def copy_attachments!(task_dir)
        return if @attachments.empty?

        assets_dir = File.join(task_dir, "assets")
        FileUtils.mkdir_p(assets_dir)
        @attachments.each do |src, dest_name|
          name = dest_name.to_s
          if name.empty? || name != File.basename(name)
            raise InvalidSlugError, "invalid attachment filename '#{dest_name}'"
          end

          FileUtils.cp(src, File.join(assets_dir, name))
        end
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
