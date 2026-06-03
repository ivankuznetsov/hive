require "json"
require "fileutils"
require "securerandom"
require "time"
require "hive/patrol/feature"
require "hive/patrol/finding"

module Hive
  module Patrol
    class StateStore
      attr_reader :project_root, :root

      def initialize(project_root)
        @project_root = File.expand_path(project_root)
        @root = File.join(@project_root, ".hive-state", "patrol")
      end

      def ensure!
        %w[features findings patches reports runs].each { |name| FileUtils.mkdir_p(File.join(root, name)) }
      end

      def write_feature(feature)
        write_json(File.join(root, "features", "#{feature.id}.json"), feature.to_h)
      end

      def write_finding(finding)
        write_json(File.join(root, "findings", "#{finding.id}.json"), finding.to_h)
      end

      def write_patch(id, data)
        write_json(File.join(root, "patches", "#{id}.json"), data)
      end

      def state
        read_json(File.join(root, "state.json"))
      end

      def update_state(data)
        write_json(File.join(root, "state.json"), state.merge(data))
      end

      def fingerprints
        read_json(File.join(root, "fingerprints.json"))
      end

      def write_fingerprints(data)
        write_json(File.join(root, "fingerprints.json"), data)
      end

      def dismissed
        read_json(File.join(root, "dismissed.json"))
      end

      def write_dismissed(data)
        write_json(File.join(root, "dismissed.json"), data)
      end

      def run_dir(prefix)
        ensure!
        path = File.join(root, "runs", "#{prefix}-#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}-#{SecureRandom.hex(4)}")
        FileUtils.mkdir_p(path)
        path
      end

      def write_run_log(id, data)
        write_json(File.join(root, "runs", "#{id}.json"), data)
      end

      def write_json(path, data)
        FileUtils.mkdir_p(File.dirname(path))
        tmp = "#{path}.tmp.#{Process.pid}.#{SecureRandom.hex(4)}"
        File.write(tmp, "#{JSON.pretty_generate(data)}\n")
        File.rename(tmp, path)
        data
      ensure
        FileUtils.rm_f(tmp) if tmp && File.exist?(tmp)
      end

      def read_json(path)
        return {} unless File.exist?(path)

        parsed = JSON.parse(File.read(path))
        parsed.is_a?(Hash) ? parsed : {}
      rescue JSON::ParserError, SystemCallError
        {}
      end
    end
  end
end
