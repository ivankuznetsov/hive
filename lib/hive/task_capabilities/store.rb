require "json"
require "hive/atomic_file"
require "hive/lock"
require "hive/task_meta"
require "hive/task_capabilities/plan"

module Hive
  module TaskCapabilities
    # Only the two fixed controller anchors establish accepted authority.
    # Directory contents, including schema-valid agent proposals, do not.
    class Store
      POINTER = "execution-plan-current.json".freeze
      CHAIN = "capability-accepted.jsonl".freeze
      DIRECTORIES = { "plan" => "execution-plans", "result" => "capability-results", "approval" => "capability-approvals" }.freeze
      class InvalidState < Hive::Error; end
      class Conflict < Hive::ConcurrentRunError; end

      def initialize(task_folder)
        @folder = File.expand_path(task_folder)
      end

      def current
        return nil unless adoption

        entries = accepted
        pointer = parse_file(File.join(@folder, POINTER))
        unless pointer.is_a?(Hash) && pointer.keys.sort == %w[digest schema_version task version] &&
            pointer["schema_version"] == 1 && pointer["task"] == identity
          raise InvalidState, "invalid execution-plan current pointer"
        end
        plan = plan_from_entries(pointer.fetch("digest"), entries)
        raise InvalidState, "execution-plan pointer version mismatch" unless pointer["version"] == plan.version
        plan
      end

      def history
        return [] unless adoption
        accepted.select { |entry| entry["kind"] == "plan" }.map { |entry| read_plan(entry.fetch("digest")) }
      end

      def read_plan(digest)
        plan_from_entries(digest, accepted)
      end

      def activate(plan, expected_version:, observation: nil, approvals: [])
        mutate(observation) do
          initial = !File.exist?(File.join(@folder, POINTER))
          current_plan = initial ? nil : current
          unless expected_version == current_plan&.version && plan.version == (current_plan&.version || 0) + 1
            raise Conflict, "execution-plan version changed; refresh before accepting"
          end
          unless adoption && plan.data.fetch("task") == identity &&
              (!initial || adoption.fetch("initial_plan_digest") == plan.digest)
            raise InvalidState, "execution-plan adoption or task identity mismatch"
          end
          approved = approvals.map do |value|
            data = Plan.redact(Hive::WorkflowPackage::CanonicalJSON.normalize(value))
            validate_blob_identity!(data)
            [ "approval", data, ::Digest::SHA256.hexdigest(canonical(data)) ]
          end
          accept!("plan", plan.data, plan.digest, before: approved)
          Hive::TaskMeta.validate_observation!(@folder, @observation)
          Hive::AtomicFile.write(File.join(@folder, POINTER), canonical(
            "schema_version" => 1, "task" => identity, "digest" => plan.digest, "version" => plan.version
          ), mode: 0o600, create: false)
          plan
        end
      end

      def accept_blob(kind, value, observation: nil)
        raise InvalidState, "unsupported accepted capability blob kind" unless %w[result approval].include?(kind)
        mutate(observation) do
          plan = current || raise(InvalidState, "capability results require an adopted execution plan")
          data = Plan.redact(Hive::WorkflowPackage::CanonicalJSON.normalize(value))
          validate_blob_identity!(data, kind == "result" ? plan.digest : nil)
          digest = ::Digest::SHA256.hexdigest(canonical(data))
          accept!(kind, data, digest)
          digest
        end
      end

      def read_blob(kind, digest)
        entries = accepted
        unless entries.any? { |entry| entry["kind"] == kind && entry["digest"] == digest }
          raise InvalidState, "unaccepted capability #{kind} reference"
        end
        load_blob(kind, digest)
      end

      private

      def canonical(value) = Hive::WorkflowPackage::CanonicalJSON.generate(value)

      def identity
        Hive::WorkflowPackage::CanonicalJSON.normalize(Hive::TaskMeta.stable_identity(metadata))
      end

      def metadata
        stat = File.lstat(@folder)
        raise InvalidState, "capability task root must be an existing regular directory" unless stat.directory? && !stat.symlink?
        read = Hive::TaskMeta.read_for_admission(@folder)
        raise InvalidState, "invalid capability adoption metadata: #{read.error}" unless read.ok?
        read.data
      rescue Errno::ENOENT, Errno::ENOTDIR => error
        raise InvalidState, "capability task root disappeared: #{error.message}"
      end

      def adoption
        value = metadata[:task_capabilities]
        if !value && [ POINTER, CHAIN ].any? { |name| File.exist?(File.join(@folder, name)) || File.symlink?(File.join(@folder, name)) }
          raise InvalidState, "capability anchors exist without adoption metadata"
        end
        value
      end

      def mutate(observation)
        Hive::TaskMeta.with_observation(@folder, observation) do |current_observation|
          Hive::TaskMeta.validate_observation!(@folder, current_observation)
          Hive::Lock.with_task_lock(@folder, create: false, observation: current_observation, operation: "task-capabilities") do
            @observation = current_observation
            yield
          ensure
            @observation = nil
          end
        end
      end

      def parse_file(path)
        stat = File.lstat(path)
        raise InvalidState, "capability state must be a regular file" unless stat.file? && !stat.symlink?
        JSON.parse(File.binread(path))
      rescue JSON::ParserError, SystemCallError => error
        raise InvalidState, "cannot read capability state: #{error.class}: #{error.message}"
      end

      def load_blob(kind, digest)
        unless DIRECTORIES.key?(kind) && Plan::DIGEST.match?(digest.to_s)
          raise InvalidState, "invalid capability blob reference"
        end
        directory = File.join(@folder, DIRECTORIES.fetch(kind))
        raise InvalidState, "capability store directory must not be a symlink" if File.symlink?(directory)
        path = File.join(directory, "#{digest}.json")
        value = parse_file(path)
        unless ::Digest::SHA256.file(path).hexdigest == digest && canonical(value) == File.binread(path)
          raise InvalidState, "capability blob digest mismatch"
        end
        value
      end

      def accepted
        return [] unless adoption
        path = File.join(@folder, CHAIN)
        stat = File.lstat(path)
        raise InvalidState, "capability acceptance chain must be a regular file" unless stat.file? && !stat.symlink?
        previous = nil
        entries = File.readlines(path).each_with_index.map do |line, index|
          entry = JSON.parse(line)
          unless entry.is_a?(Hash) && entry.keys.sort == %w[digest kind previous sequence task] &&
              entry["sequence"] == index + 1 && entry["previous"] == previous && entry["task"] == identity
            raise InvalidState, "invalid capability acceptance chain"
          end
          data = load_blob(entry["kind"], entry["digest"])
          if entry["kind"] == "plan"
            plan = Plan.new(data)
            raise InvalidState, "accepted execution plan task mismatch" unless plan.data.fetch("task") == identity
            raise InvalidState, "accepted execution plan canonical identity changed" unless plan.digest == entry["digest"]
          else
            validate_blob_identity!(data, entry["kind"] == "result" ? data["execution_plan_digest"] : nil)
          end
          previous = ::Digest::SHA256.hexdigest(line)
          entry
        end
        plan_digests = entries.select { |entry| entry["kind"] == "plan" }.map { |entry| entry["digest"] }
        unless plan_digests.include?(adoption.fetch("initial_plan_digest"))
          raise InvalidState, "initial execution plan is not accepted"
        end
        entries.select { |entry| entry["kind"] == "result" }.each do |entry|
          unless plan_digests.include?(load_blob(entry["kind"], entry["digest"])["execution_plan_digest"])
            raise InvalidState, "capability blob references an unaccepted execution plan"
          end
        end
        entries.select { |entry| entry["kind"] == "plan" }.each do |entry|
          load_blob("plan", entry["digest"]).fetch("approvals").each do |reference|
            digest = reference.is_a?(Hash) ? reference["digest"] : reference
            unless entries.any? { |accepted| accepted["kind"] == "approval" && accepted["digest"] == digest }
              raise InvalidState, "execution plan references an unaccepted approval"
            end
          end
        end
        entries
      rescue JSON::ParserError, Hive::ConfigError, SystemCallError => error
        raise InvalidState, "invalid capability acceptance chain: #{error.message}"
      end

      def plan_from_entries(digest, entries)
        unless entries.any? { |entry| entry["kind"] == "plan" && entry["digest"] == digest }
          raise InvalidState, "unaccepted execution-plan reference"
        end
        plan = Plan.new(load_blob("plan", digest))
        raise InvalidState, "execution-plan read changed its canonical identity" unless plan.digest == digest
        plan
      end

      def validate_blob_identity!(data, digest = nil)
        unless data.is_a?(Hash) && data["task"] == identity &&
            (!digest || (Plan::DIGEST.match?(digest.to_s) && data["execution_plan_digest"] == digest))
          raise InvalidState, "capability blob task or execution-plan identity mismatch"
        end
      end

      def accept!(kind, data, digest, before: [])
        chain_path = File.join(@folder, CHAIN)
        entries = File.exist?(chain_path) ? accepted : []
        additions = (before + [ [ kind, data, digest ] ]).reject do |entry_kind, _, entry_digest|
          entries.any? { |entry| entry["kind"] == entry_kind && entry["digest"] == entry_digest }
        end
        if kind == "plan"
          references = entries.select { |entry| entry["kind"] == "approval" }.map { |entry| entry["digest"] } + before.map(&:last)
          unless data.fetch("approvals").all? { |reference| references.include?(reference.is_a?(Hash) ? reference["digest"] : reference) }
            raise InvalidState, "execution plan references an unaccepted approval"
          end
        end
        lines = File.exist?(chain_path) ? File.readlines(chain_path) : []
        additions.each do |entry_kind, entry_data, entry_digest|
          directory = File.join(@folder, DIRECTORIES.fetch(entry_kind))
          raise InvalidState, "capability store directory must not be a symlink" if File.symlink?(directory)
          FileUtils.mkdir_p(directory)
          path = File.join(directory, "#{entry_digest}.json")
          if File.exist?(path) || File.symlink?(path)
            load_blob(entry_kind, entry_digest)
          else
            Hive::AtomicFile.write(path, canonical(entry_data), mode: 0o600, create: false)
          end
          lines << canonical("sequence" => lines.length + 1, "previous" => lines.last && ::Digest::SHA256.hexdigest(lines.last),
                             "kind" => entry_kind, "digest" => entry_digest, "task" => identity)
        end
        Hive::TaskMeta.validate_observation!(@folder, @observation)
        Hive::AtomicFile.write(chain_path, lines.join, mode: 0o600, create: false) unless additions.empty?
      end
    end
  end
end
