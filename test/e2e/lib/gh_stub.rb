require "fileutils"
require "json"

module Hive
  module E2E
    class GhStub
      class VerificationError < StandardError; end

      ROOT_NAME = "gh-stub"
      SCRIPT_NAME = "script.json"
      STATE_NAME = "state.json"
      AUDIT_NAME = "audit.jsonl"
      LOCK_NAME = ".lock"
      ALLOWED_KEYS = %w[args cwd repository response stdout stderr exit_status].freeze

      attr_reader :root

      def self.root_for(run_home)
        File.join(run_home, ROOT_NAME)
      end

      def self.validate_interactions(interactions)
        raise ArgumentError, "script_gh.interactions must be an array" unless interactions.is_a?(Array)

        interactions.map.with_index(1) do |interaction, index|
          raise ArgumentError, "gh interaction #{index} must be a map" unless interaction.is_a?(Hash)

          unknown = interaction.keys.map(&:to_s) - ALLOWED_KEYS
          raise ArgumentError, "gh interaction #{index} has unknown keys: #{unknown.join(', ')}" unless unknown.empty?

          item = interaction.transform_keys(&:to_s)
          args = item["args"]
          unless args.is_a?(Array) && args.all? { |arg| arg.is_a?(String) }
            raise ArgumentError, "gh interaction #{index}.args must be an array of strings"
          end
          if item.key?("stdout") && item.key?("response")
            raise ArgumentError, "gh interaction #{index} cannot set both stdout and response"
          end
          %w[cwd repository stdout stderr].each do |key|
            next unless item.key?(key)
            raise ArgumentError, "gh interaction #{index}.#{key} must be a string" unless item[key].is_a?(String)
          end
          if item.key?("exit_status")
            status = item["exit_status"]
            unless status.is_a?(Integer) && status.between?(0, 255)
              raise ArgumentError, "gh interaction #{index}.exit_status must be an integer from 0 to 255"
            end
          end
          item
        end
      end

      def initialize(run_home)
        @root = self.class.root_for(run_home)
      end

      def script_path
        File.join(@root, SCRIPT_NAME)
      end

      def state_path
        File.join(@root, STATE_NAME)
      end

      def audit_path
        File.join(@root, AUDIT_NAME)
      end

      def install(interactions)
        normalized = self.class.validate_interactions(interactions)
        FileUtils.mkdir_p(@root)
        with_lock do
          if path_entry?(script_path) || path_entry?(state_path)
            raise ArgumentError,
                  "a gh script is already installed; put every expected call in one ordered interaction sequence"
          end
          write_json(script_path, "schema" => "hive-e2e-gh-script", "schema_version" => 1,
                                  "interactions" => normalized)
          write_json(state_path, "next_index" => 0)
        end
        self
      end

      def audit
        with_lock { read_audit }
      end

      def verify!
        with_lock do
          rejected = read_audit.reject { |entry| entry["matched"] == true }
          unless rejected.empty?
            reasons = rejected.map { |entry| entry["reason"].to_s }.uniq.join("; ")
            raise VerificationError, "gh shim rejected #{rejected.size} invocation(s): #{reasons}"
          end
          next true unless path_entry?(script_path)

          script = read_json_file(script_path, "gh script")
          state = read_json_file(state_path, "gh state")
          expected = Array(script["interactions"]).size
          consumed = Integer(state.fetch("next_index"))
          next true if consumed == expected

          raise VerificationError, "gh script consumed #{consumed} of #{expected} interaction(s)"
        end
      rescue JSON::ParserError, KeyError, ArgumentError => e
        raise VerificationError, "gh shim evidence is invalid: #{e.message}"
      end

      private

      def with_lock
        FileUtils.mkdir_p(@root)
        File.open(File.join(@root, LOCK_NAME), File::RDWR | File::CREAT, 0o600) do |lock|
          lock.flock(File::LOCK_EX)
          yield
        ensure
          lock.flock(File::LOCK_UN)
        end
      end

      def write_json(path, value)
        tmp = "#{path}.tmp.#{Process.pid}"
        File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
          file.write(JSON.generate(value))
          file.write("\n")
        end
        File.rename(tmp, path)
      ensure
        FileUtils.rm_f(tmp) if tmp
      end

      def read_json_file(path, label)
        stat = File.lstat(path)
        raise VerificationError, "#{label} must be a regular file" unless stat.file? && !stat.symlink?

        JSON.parse(File.read(path))
      rescue Errno::ENOENT
        raise VerificationError, "#{label} is missing"
      end

      def read_audit
        return [] unless path_entry?(audit_path)

        stat = File.lstat(audit_path)
        unless stat.file? && !stat.symlink?
          raise VerificationError, "gh audit must be a regular file"
        end

        File.readlines(audit_path, chomp: true).reject(&:empty?).map { |line| JSON.parse(line) }
      end

      def path_entry?(path)
        File.exist?(path) || File.symlink?(path)
      end
    end
  end
end
