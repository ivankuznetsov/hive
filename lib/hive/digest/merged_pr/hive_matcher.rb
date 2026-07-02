require "logger"
require "hive/config"

module Hive
  module Digest
    module MergedPr
      class HiveMatcher
        STAGES_DIR = "stages".freeze

        def initialize(registry: -> { Hive::Config.registered_projects }, logger: Logger.new($stderr))
          @registry = registry
          @logger = logger
        end

        def match(head_ref)
          slug = slug_from_branch(head_ref)
          return nil if slug.nil? || slug.empty?

          @registry.call.each do |entry|
            match = find_slug(entry.fetch("hive_state_path"), slug)
            return match if match
          rescue StandardError => e
            @logger&.warn("merged-pr digest: Hive match skipped for #{slug}: #{e.message}")
          end
          nil
        rescue StandardError => e
          @logger&.warn("merged-pr digest: Hive match failed for #{head_ref}: #{e.message}")
          nil
        end

        private

        def slug_from_branch(head_ref)
          text = head_ref.to_s
          text.start_with?("hive/") ? text.split("/", 2).last : nil
        end

        def find_slug(hive_state_path, slug)
          # A real Hive slug is a single path segment; reject anything with a
          # separator or a `.`/`..` component so a crafted branch like
          # `hive/..` (which would collapse to the stages dir on join) or
          # `hive/foo/bar` cannot escape the per-stage lookup below.
          return nil if slug.include?("/") || slug.include?(File::SEPARATOR)
          return nil if slug == "." || slug == ".."

          stages_root = File.join(hive_state_path, STAGES_DIR)
          return nil unless File.directory?(stages_root)

          # Enumerate real stage dirs and test a literal join per stage rather
          # than globbing the untrusted slug into Dir[...]: a crafted branch
          # like `hive/*` would otherwise match `stages/*/<glob>` and fabricate
          # a bogus Hive-task annotation.
          stage = Dir.children(stages_root).find do |st|
            File.directory?(File.join(stages_root, st, slug))
          end
          stage && { slug: slug, stage: stage }
        end
      end
    end
  end
end
