require "json"
require "fileutils"
require "hive/atomic_file"
require "hive/workflow_package/canonical_json"

module Hive
  module WorkflowPackage
    class TransactionJournal
      attr_reader :path

      def initialize(workflows_dir)
        @path = File.join(workflows_dir, ".transaction.json")
      end

      def write(data)
        Hive::AtomicFile.write(path, CanonicalJSON.generate(data), mode: 0o600)
      end

      def read
        JSON.parse(File.read(path))
      rescue Errno::ENOENT
        nil
      rescue JSON::ParserError
        raise Hive::ConfigError, "managed workflow transaction journal is malformed"
      end

      def clear
        FileUtils.rm_f(path)
      end
    end
  end
end
