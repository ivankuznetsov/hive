require "hive/wiki_log"

module Hive
  module Commands
    class Wiki
      VALID_SUBCOMMANDS = %w[compile-log].freeze

      def initialize(subcommand, project_path, check: false)
        @subcommand = subcommand.to_s
        @project_path = File.expand_path(project_path || Dir.pwd)
        @check = check
      end

      def call
        case @subcommand
        when "compile-log"
          compile_log
        else
          raise Hive::InvalidTaskPath,
                "hive wiki: unknown subcommand #{@subcommand.inspect}; expected #{VALID_SUBCOMMANDS.join(', ')}"
        end
      end

      private

      def compile_log
        ensure_wiki_dir!
        if @check
          if Hive::WikiLog.stale?(@project_path)
            raise Hive::InvalidTaskPath, "hive wiki compile-log: wiki/log.md is stale; run `hive wiki compile-log`"
          end
          puts "hive wiki: wiki/log.md is up to date"
          return
        end

        Hive::WikiLog.compile!(@project_path)
        count = Hive::WikiLog.fragment_paths(@project_path).size
        puts "hive wiki: compiled wiki/log.md from #{count} fragment#{count == 1 ? '' : 's'}"
      end

      def ensure_wiki_dir!
        wiki_dir = File.join(@project_path, "wiki")
        return if Dir.exist?(wiki_dir)

        raise Hive::InvalidTaskPath, "hive wiki: not a wiki project: #{wiki_dir}"
      end
    end
  end
end
