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
          stages_root = File.join(hive_state_path, STAGES_DIR)
          Dir[File.join(stages_root, "*", slug)].find { |path| File.directory?(path) }&.then do |path|
            { slug: slug, stage: File.basename(File.dirname(path)) }
          end
        end
      end
    end
  end
end
