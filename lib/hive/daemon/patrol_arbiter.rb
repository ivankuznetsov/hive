require "json"
require "time"
require "hive/atomic_file"
require "hive/paths"

module Hive
  module Daemon
    # The single owner of the per-project patrol-scan budget. Both patrol
    # schedulers expose candidates here; the cursor advances only after the
    # dispatcher has spawned and recorded the selected child.
    class PatrolArbiter
      SCHEMA = "hive-patrol-arbiter".freeze
      SCHEMA_VERSION = 1
      KINDS = %i[ordinary architecture].freeze
      STATE_KEYS = %w[schema schema_version projects].freeze
      PROJECT_KEYS = %w[last_selected updated_at].freeze

      class StateError < StandardError; end

      def initialize(ordinary_scheduler:, architecture_scheduler:,
                     state_path: File.join(Hive::Paths.state_home, "patrol_arbiter.json"),
                     dry_run: false)
        @ordinary_scheduler = ordinary_scheduler
        @architecture_scheduler = architecture_scheduler
        @state_path = state_path
        @dry_run = dry_run
      end

      def candidates(now: Time.now)
        state = load_state
        all = Array(@ordinary_scheduler&.candidates(now: now)) +
              Array(@architecture_scheduler&.candidates(now: now))
        all.group_by { |candidate| candidate.fetch(:project) }
           .sort_by(&:first)
           .filter_map do |project, project_candidates|
          select_for(project_candidates, last_selected: state.dig("projects", project, "last_selected"))
        end
      end

      def commit(candidate, now: Time.now)
        return candidate if @dry_run

        kind = candidate.fetch(:patrol_kind).to_sym
        raise ArgumentError, "unknown patrol kind #{kind.inspect}" unless KINDS.include?(kind)

        state = load_state
        state.fetch("projects")[candidate.fetch(:project).to_s] = {
          "last_selected" => kind.to_s,
          "updated_at" => now.utc.iso8601
        }
        persist(state)
        candidate
      end

      private

      def select_for(candidates, last_selected:)
        ordinary = candidates.find { |candidate| candidate[:patrol_kind].to_sym == :ordinary }
        architecture = candidates.select { |candidate| candidate[:patrol_kind].to_sym == :architecture }
                                 .min_by do |candidate|
          [ parse_time(candidate[:merged_at]), candidate[:job_id].to_s ]
        end
        return architecture || ordinary unless ordinary && architecture

        last_selected == "architecture" ? ordinary : architecture
      end

      def parse_time(value)
        value ? Time.iso8601(value.to_s).utc : Time.at(0).utc
      rescue ArgumentError
        Time.at(0).utc
      end

      def load_state
        return empty_state unless File.file?(@state_path)

        data = JSON.parse(File.binread(@state_path))
        unless data.is_a?(Hash) && data.keys.sort == STATE_KEYS.sort &&
               data["schema"] == SCHEMA && data["schema_version"] == SCHEMA_VERSION &&
               data["projects"].is_a?(Hash)
          raise StateError, "patrol arbiter state has an unsupported or invalid schema"
        end
        data.fetch("projects").each do |project, entry|
          unless !project.empty? && entry.is_a?(Hash) && entry.keys.sort == PROJECT_KEYS.sort &&
                 KINDS.map(&:to_s).include?(entry["last_selected"])
            raise StateError, "patrol arbiter project cursor is invalid"
          end
          Time.iso8601(entry.fetch("updated_at"))
        end
        data
      rescue JSON::ParserError, SystemCallError, IOError, ArgumentError, KeyError => e
        raise StateError, "cannot read patrol arbiter state (#{e.class}: #{e.message})"
      end

      def empty_state
        { "schema" => SCHEMA, "schema_version" => SCHEMA_VERSION, "projects" => {} }
      end

      def persist(state)
        Hive::AtomicFile.write(@state_path, "#{JSON.pretty_generate(state)}\n", mode: 0o600)
        File.open(File.dirname(@state_path), File::RDONLY) { |directory| directory.fsync }
      rescue Errno::EINVAL, Errno::ENOTSUP, Errno::EBADF
        nil
      end
    end
  end
end
