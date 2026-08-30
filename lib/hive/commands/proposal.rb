require "digest"
require "json"
require "pathname"
require "hive/git_ops"
require "hive/proposals/producer"
require "hive/proposals/reconciler"
require "hive/task_resolver"

module Hive
  module Commands
    class Proposal
      MAX_INPUT_BYTES = 256 * 1024
      SOURCE_COMMANDS = %w[submit evaluate].freeze

      def initialize(subcommand, target, input:, project: nil, json: false, stdout: $stdout,
                     task_resolver: nil, producer_factory: nil, reconciler: nil)
        @subcommand = subcommand.to_s
        @target = target
        @input = input
        @project = project
        @json = json
        @stdout = stdout
        @task_resolver = task_resolver || method(:resolve_task)
        @producer_factory = producer_factory || method(:build_producer)
        @reconciler = reconciler || method(:reconcile_task)
      end

      def call
        unless SOURCE_COMMANDS.include?(@subcommand)
          raise Hive::Proposals::InvalidRecord, "unknown proposal source command #{@subcommand.inspect}"
        end
        task = @task_resolver.call(@target, @project)
        @reconciler.call(task)
        payload, artifact = read_artifact(task)
        producer = @producer_factory.call(task)
        result = @subcommand == "submit" ? submit(producer, payload, artifact) :
          evaluate(producer, payload, artifact)
        render(result)
        result
      end

      private

      def submit(producer, payload, artifact)
        data = Proposals.closed_hash!(
          payload, required: %w[proposed_change motivation evidence],
          optional: %w[lineage source_event_id idempotency_key],
          label: "proposal submission artifact"
        )
        producer.submit(
          proposed_change: data.fetch("proposed_change"), motivation: data.fetch("motivation"),
          evidence: data.fetch("evidence"), lineage: data.fetch("lineage", {}), artifact:,
          source_event_id: data["source_event_id"], idempotency_key: data["idempotency_key"]
        )
      end

      def evaluate(producer, payload, artifact)
        data = Proposals.closed_hash!(
          payload, required: %w[method result rationale evidence],
          optional: %w[links source_event_id idempotency_key],
          label: "proposal evaluation artifact"
        )
        producer.evaluate(
          method: data.fetch("method"), result: data.fetch("result"),
          rationale: data.fetch("rationale"), evidence: data.fetch("evidence"),
          links: data.fetch("links", []), artifact:,
          source_event_id: data["source_event_id"], idempotency_key: data["idempotency_key"]
        )
      end

      def read_artifact(task)
        path = File.expand_path(@input.to_s)
        stat = File.lstat(path)
        unless stat.file? && !stat.symlink?
          raise Hive::Proposals::InvalidRecord, "proposal input must be a regular non-symlink file"
        end
        if stat.size > MAX_INPUT_BYTES
          raise Hive::Proposals::InvalidRecord, "proposal input exceeds #{MAX_INPUT_BYTES} bytes"
        end
        project_root = File.realpath(task.project_root)
        real_path = File.realpath(path)
        relative = Pathname.new(real_path).relative_path_from(Pathname.new(project_root)).to_s
        if relative.start_with?("../") || relative == ".."
          raise Hive::Proposals::InvalidRecord, "proposal input must be project-relative"
        end
        flags = File::RDONLY
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        bytes = File.open(path, flags) { |file| file.read(MAX_INPUT_BYTES + 1) }
        if bytes.bytesize > MAX_INPUT_BYTES
          raise Hive::Proposals::InvalidRecord, "proposal input exceeds #{MAX_INPUT_BYTES} bytes"
        end
        payload = JSON.parse(bytes)
        unless payload.is_a?(Hash)
          raise Hive::Proposals::InvalidRecord, "proposal input must contain one JSON object"
        end
        [
          payload,
          {
            "reference" => relative, "digest" => Digest::SHA256.hexdigest(bytes),
            "bytes" => bytes.bytesize, "media_type" => "application/json"
          }
        ]
      rescue Errno::ENOENT, Errno::ELOOP
        raise Hive::Proposals::InvalidRecord, "proposal input must be a regular non-symlink file"
      rescue JSON::ParserError
        raise Hive::Proposals::InvalidRecord, "proposal input must contain valid JSON"
      end

      def resolve_task(target, project)
        Hive::TaskResolver.new(target, project_filter: project).resolve
      end

      def build_producer(task)
        Hive::Proposals::Producer.for_task(project_root: task.project_root, task: task)
      end

      def reconcile_task(task)
        ops = Hive::GitOps.new(task.project_root)
        return unless ops.hive_state_worktree_exists?
        Hive::Proposals::Reconciler.new(git_ops: ops).reconcile!
      end

      def render(result)
        if @json
          @stdout.puts(JSON.generate(
            "schema" => "hive-proposal-mutation", "schema_version" => 1, "ok" => true,
            "proposal_id" => result.proposal_id, "source_event_id" => result.source_event_id,
            "source_commit" => result.source_commit,
            "mutation" => {
              "kind" => result.ingestion.kind, "event_id" => result.ingestion.event_id
            }
          ))
        else
          suffix = result.ingestion.event_id ? " event=#{result.ingestion.event_id}" : ""
          @stdout.puts(
            "hive: proposal #{result.proposal_id} source=#{result.source_event_id}#{suffix}"
          )
        end
      end
    end
  end
end
