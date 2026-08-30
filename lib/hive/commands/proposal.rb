require "digest"
require "json"
require "open3"
require "pathname"
require "tmpdir"
require "hive/git_ops"
require "hive/proposals/producer"
require "hive/proposals/compiler"
require "hive/proposals/reconciler"
require "hive/task_resolver"

module Hive
  module Commands
    class Proposal
      MAX_INPUT_BYTES = 256 * 1024
      SOURCE_COMMANDS = %w[submit evaluate].freeze
      COMMANDS = (SOURCE_COMMANDS + %w[refresh]).freeze

      def initialize(subcommand, target, input:, project: nil, json: false, stdout: $stdout,
                     task_resolver: nil, producer_factory: nil, reconciler: nil,
                     source_ref: nil, output_root: nil, compile_only: false, check: false,
                     refresh_runner: nil)
        @subcommand = subcommand.to_s
        @target = target
        @input = input
        @project = project
        @json = json
        @stdout = stdout
        @task_resolver = task_resolver || method(:resolve_task)
        @producer_factory = producer_factory || method(:build_producer)
        @reconciler = reconciler || method(:reconcile_task)
        @source_ref = source_ref
        @output_root = output_root
        @compile_only = compile_only
        @check = check
        @refresh_runner = refresh_runner || method(:run_managed_refresh)
      end

      def call
        unless COMMANDS.include?(@subcommand)
          raise Hive::Proposals::InvalidRecord, "unknown proposal command #{@subcommand.inspect}"
        end
        return refresh if @subcommand == "refresh"

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

      def refresh
        project_root = File.expand_path(@target || Dir.pwd)
        ops = Hive::GitOps.new(project_root)
        unless ops.hive_state_worktree_exists?
          raise Hive::Proposals::SourceUnavailable, "proposal refresh requires an initialized hive/state worktree"
        end
        source_ref = @source_ref || ops.hive_state_head_sha
        if @compile_only
          if @check || @output_root.to_s.empty?
            raise Hive::Proposals::InvalidRecord,
                  "proposal refresh --compile-only requires --output-root and cannot use --check"
          end
          result = Hive::Proposals::Compiler.compile_pinned(
            git_ops: ops, source_ref:, output_root: @output_root
          )
          return render_refresh("compiled", result)
        end
        return check_refresh(ops, source_ref) if @check
        if @output_root
          raise Hive::Proposals::InvalidRecord,
                "proposal refresh --output-root is internal to --compile-only"
        end

        @refresh_runner.call(project_root, ops)
        render_refresh("queued", nil)
      end

      def check_refresh(ops, source_ref)
        result = nil
        matches = nil
        Dir.mktmpdir("hive-proposal-refresh-check-", Dir.tmpdir) do |scratch|
          result = Hive::Proposals::Compiler.compile_pinned(
            git_ops: ops, source_ref:, output_root: scratch
          )
          matches = result.paths.all? do |generated|
            live = File.join(ops.project_root, Pathname.new(generated).relative_path_from(Pathname.new(scratch)))
            File.file?(live) && File.binread(live) == File.binread(generated)
          end
        end
        unless matches
          raise Hive::Proposals::StaleObservation,
                "compiled proposal wiki views are stale for #{result.source_commit}"
        end
        render_refresh("current", result)
      end

      def run_managed_refresh(project_root, ops)
        script = File.join(project_root, ".llm-wiki", "post-commit-refresh.sh")
        unless File.file?(script) && !File.symlink?(script)
          raise Hive::Proposals::SourceUnavailable, "managed llm-wiki refresh runner is unavailable"
        end
        stdout, stderr, status = Open3.capture3(
          { "HIVE_SKIP_LLM_WIKI_POST_COMMIT" => "" },
          "bash", script, "--project", ops.hive_state_path
        )
        return if status.success?

        detail = Hive::SecretPatterns.redact("#{stdout}\n#{stderr}").strip.byteslice(0, 1_024)
        raise Hive::Proposals::SourceUnavailable,
              "managed proposal refresh failed#{detail.empty? ? '' : ": #{detail}"}"
      end

      def render_refresh(outcome, result)
        payload = {
          "schema" => "hive-proposal-mutation", "schema_version" => 1,
          "ok" => true, "action" => "refresh", "outcome" => outcome,
          "source_commit" => result&.source_commit,
          "projection_count" => result&.projection_count,
          "diagnostic_count" => result&.diagnostic_count
        }
        if @json
          @stdout.puts(JSON.generate(payload))
        else
          suffix = result ? " source=#{result.source_commit} proposals=#{result.projection_count}" : ""
          @stdout.puts("hive: proposal refresh #{outcome}#{suffix}")
        end
        result || payload
      end

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
