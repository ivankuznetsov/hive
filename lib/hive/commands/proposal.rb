require "digest"
require "json"
require "open3"
require "pathname"
require "tmpdir"
require "hive/git_ops"
require "hive/config"
require "hive/proposals/authority"
require "hive/proposals/producer"
require "hive/proposals/compiler"
require "hive/proposals/decision_service"
require "hive/proposals/query"
require "hive/proposals/reconciler"
require "hive/task_resolver"

module Hive
  module Commands
    class Proposal
      MAX_INPUT_BYTES = 256 * 1024
      SOURCE_COMMANDS = %w[submit evaluate].freeze
      READ_COMMANDS = %w[list show filter].freeze
      LIFECYCLE_COMMANDS = %w[decide supersede rollback].freeze
      COMMANDS = (SOURCE_COMMANDS + READ_COMMANDS + LIFECYCLE_COMMANDS + %w[refresh]).freeze

      def initialize(subcommand, target, input:, project: nil, json: false, stdout: $stdout,
                     task_resolver: nil, producer_factory: nil, reconciler: nil,
                     source_ref: nil, output_root: nil, compile_only: false, check: false,
                     refresh_runner: nil, project_root: Dir.pwd, filters: {},
                     include_drafts: false, include_quarantine: false,
                     expected_head_version: nil, expected_head_digest: nil,
                     considered_evaluation_ids: [], authority_identity: nil,
                     policy_fingerprint: nil)
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
        @project_root = File.expand_path(project_root)
        @filters = filters
        @include_drafts = include_drafts
        @include_quarantine = include_quarantine
        @expected_head_version = expected_head_version
        @expected_head_digest = expected_head_digest
        @considered_evaluation_ids = considered_evaluation_ids
        @authority_identity = authority_identity
        @policy_fingerprint = policy_fingerprint
      end

      def call
        unless COMMANDS.include?(@subcommand)
          raise Hive::Proposals::InvalidRecord, "unknown proposal command #{@subcommand.inspect}"
        end
        validate_invocation!
        return refresh if @subcommand == "refresh"
        return read_command if READ_COMMANDS.include?(@subcommand)
        return lifecycle_command if LIFECYCLE_COMMANDS.include?(@subcommand)

        task = @task_resolver.call(@target, @project)
        @reconciler.call(task)
        payload, artifact = read_artifact(task)
        producer = @producer_factory.call(task)
        result = @subcommand == "submit" ? submit(producer, payload, artifact) :
          evaluate(producer, payload, artifact)
        render(result)
        result
      rescue Hive::Error => error
        render_error(error) if @json
        raise
      end

      private

      def validate_invocation!
        if (SOURCE_COMMANDS + LIFECYCLE_COMMANDS).include?(@subcommand) && @input.to_s.empty?
          raise Hive::Proposals::InvalidRecord,
                "hive proposal #{@subcommand}: --input FILE is required"
        end
        if (LIFECYCLE_COMMANDS + %w[show]).include?(@subcommand) && @target.to_s.empty?
          raise Hive::Proposals::InvalidRecord,
                "hive proposal #{@subcommand}: TARGET is required"
        end
      end

      def render_error(error)
        schema = if %w[list filter].include?(@subcommand)
          "hive-proposal-list"
        elsif @subcommand == "show"
          "hive-proposal-show"
        else
          "hive-proposal-mutation"
        end
        @stdout.puts(JSON.generate(
          "schema" => schema, "schema_version" => 1, "ok" => false,
          "error_class" => error.class.name.split("::").last,
          "error_kind" => error_kind(error), "exit_code" => error.exit_code,
          "message" => error.message
        ))
      end

      def error_kind(error)
        case error
        when Hive::Proposals::Unauthorized then "unauthorized"
        when Hive::Proposals::StaleObservation then "stale"
        when Hive::Proposals::Conflict then "conflict"
        when Hive::Proposals::QuotaExceeded then "quota"
        when Hive::Proposals::QuarantinedSource then "quarantine"
        when Hive::Proposals::SourceUnavailable then "source_unavailable"
        when Hive::ConfigError then "config"
        else "invalid"
        end
      end

      def read_command
        project_root = read_project_root
        _ops, _store, query, _config = live_components(project_root)
        case @subcommand
        when "show"
          render_show(query.show(@target, include_diagnostics: @include_quarantine))
        when "list", "filter"
          filters = @subcommand == "list" ? {} : @filters
          render_list(
            query.list(
              filters:, include_drafts: @include_drafts,
              include_diagnostics: @include_quarantine
            ), schema: @subcommand == "list" ? "hive-proposal-list" : "hive-proposal-list"
          )
        end
      end

      def lifecycle_command
        proposal_id = Proposals.proposal_id!(@target)
        ops, store, _query, config = live_components(@project_root)
        payload, artifact = read_project_artifact(@project_root)
        service = Hive::Proposals::DecisionService.new(
          store:, authority: Hive::Proposals::Authority.new(config), git_ops: ops,
          policy: config.dig("proposals", "evidence")
        )
        common = {
          proposal_id:, expected_head: expected_head,
          authority_identity: required_option(@authority_identity, "--authority"),
          expected_policy_fingerprint: required_option(@policy_fingerprint, "--policy-fingerprint"),
          provenance: lifecycle_provenance(ops, payload, artifact),
          policy_receipt: payload.delete("policy_receipt")
        }
        result = case @subcommand
        when "decide" then decide(service, payload, common)
        when "supersede" then supersede(service, payload, common)
        when "rollback" then rollback(service, payload, common)
        end
        render_lifecycle(result)
      end

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
          result = Hive::Proposals::Compiler.compile_at_ref(
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
          result = Hive::Proposals::Compiler.compile_at_ref(
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

      def live_components(project_root)
        config = Hive::Config.load(project_root)
        ops = Hive::GitOps.new(project_root)
        unless ops.hive_state_worktree_exists?
          raise Hive::Proposals::SourceUnavailable,
                "proposal command requires an initialized hive/state worktree"
        end
        proposal_root = File.join(ops.hive_state_path, "proposals", "v1")
        Hive::Proposals::Reconciler.new(git_ops: ops).reconcile! if File.exist?(proposal_root)
        store = Hive::Proposals::Store.new(root: proposal_root)
        [ ops, store, Hive::Proposals::Query.new(store:), config ]
      end

      def read_project_root
        return File.expand_path(@target) if %w[list filter].include?(@subcommand) && @target

        @project_root
      end

      def expected_head
        version = Integer(required_option(@expected_head_version, "--expected-head-version"))
        raise Hive::Proposals::InvalidRecord, "expected head version must be non-negative" if version.negative?
        {
          "version" => version,
          "digest" => Proposals.digest!(
            required_option(@expected_head_digest, "--expected-head-digest"),
            label: "expected lifecycle head digest"
          )
        }
      rescue ArgumentError, TypeError
        raise Hive::Proposals::InvalidRecord, "expected head version must be non-negative"
      end

      def required_option(value, name)
        return value unless value.nil? || value.to_s.empty?

        raise Hive::Proposals::InvalidRecord, "proposal #{@subcommand} requires #{name}"
      end

      def decide(service, payload, common)
        data = Proposals.closed_hash!(
          payload,
          required: %w[outcome rationale_category rationale idempotency_key],
          optional: %w[links policy_receipt], label: "proposal decision artifact"
        )
        service.decide(
          **common, outcome: data.fetch("outcome"),
          considered_evaluation_ids: Array(@considered_evaluation_ids),
          rationale_category: data.fetch("rationale_category"),
          rationale: data.fetch("rationale"), links: data.fetch("links", []),
          idempotency_key: data.fetch("idempotency_key")
        )
      end

      def supersede(service, payload, common)
        data = Proposals.closed_hash!(
          payload, required: %w[successor_id idempotency_key],
          optional: %w[policy_receipt], label: "proposal supersession artifact"
        )
        service.supersede(
          **common, successor_id: data.fetch("successor_id"),
          idempotency_key: data.fetch("idempotency_key")
        )
      end

      def rollback(service, payload, common)
        data = Proposals.closed_hash!(
          payload,
          required: %w[reverted_revision reason external_revert idempotency_key],
          optional: %w[policy_receipt], label: "proposal rollback artifact"
        )
        service.rollback(
          **common, reverted_revision: data.fetch("reverted_revision"),
          reason: data.fetch("reason"), external_revert: data.fetch("external_revert"),
          idempotency_key: data.fetch("idempotency_key")
        )
      end

      def lifecycle_provenance(ops, payload, artifact)
        key = payload.fetch("idempotency_key", "proposal-lifecycle")
        {
          "task_id" => "operator", "task_generation" => 0,
          "ownership_generation" => required_option(@policy_fingerprint, "--policy-fingerprint"),
          "attempt_id" => Proposals.label!(key, label: "proposal lifecycle idempotency key"),
          "workflow_id" => "proposal-lifecycle", "stage" => "operator",
          "actor" => { "id" => "pending-authority", "kind" => "lifecycle_authority" },
          "source_commit" => ops.hive_state_head_sha,
          "artifact_reference" => artifact.fetch("reference"),
          "artifact_digest" => artifact.fetch("digest")
        }
      end

      def render_list(result, schema:)
        payload = {
          "schema" => schema, "schema_version" => 1, "ok" => true,
          "filters" => result.filters, "proposals" => result.proposals.map(&:to_h),
          "diagnostics" => result.diagnostics.map(&:to_h),
          "result_digest" => result.digest
        }
        if @json
          @stdout.puts(JSON.generate(payload))
        else
          result.proposals.each do |projection|
            @stdout.puts(
              [ projection.proposal_id, projection.status,
                projection.subject.fetch("kind"), projection.subject.fetch("reference"),
                projection.revision,
                "head=#{projection.lifecycle_head.fetch('version')}:#{projection.lifecycle_head.fetch('digest')}" ]
                .map { |value| terminal(value) }.join("\t")
            )
          end
          result.diagnostics.each do |diagnostic|
            @stdout.puts("quarantine\t#{terminal(diagnostic.code)}\t#{terminal(diagnostic.path)}")
          end
        end
        result
      end

      def render_show(result)
        payload = {
          "schema" => "hive-proposal-show", "schema_version" => 1, "ok" => true,
          "proposal" => result.to_h
        }
        if @json
          @stdout.puts(JSON.generate(payload))
        else
          @stdout.puts(JSON.pretty_generate(payload.fetch("proposal")))
        end
        result
      end

      def render_lifecycle(result)
        payload = {
          "schema" => "hive-proposal-mutation", "schema_version" => 1, "ok" => true,
          "action" => @subcommand,
          "outcome" => result.applied ? "applied" : "idempotent",
          "proposal_id" => result.projection.proposal_id,
          "event_id" => result.event.event_id,
          "status" => result.projection.status,
          "lifecycle_head" => result.projection.lifecycle_head
        }
        if @json
          @stdout.puts(JSON.generate(payload))
        else
          @stdout.puts(
            "hive: proposal #{terminal(result.projection.proposal_id)} " \
            "#{terminal(@subcommand)} #{terminal(payload.fetch('outcome'))} " \
            "status=#{terminal(result.projection.status)} event=#{terminal(result.event.event_id)}"
          )
        end
        result
      end

      def terminal(value)
        value.to_s.each_codepoint.map do |codepoint|
          if codepoint == 9
            "\\t"
          elsif codepoint == 10
            "\\n"
          elsif codepoint == 13
            "\\r"
          elsif codepoint < 32 || codepoint == 127
            format("\\u%04x", codepoint)
          else
            codepoint.chr(Encoding::UTF_8)
          end
        end.join
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
        read_project_artifact(task.project_root)
      end

      def read_project_artifact(project_root)
        path = File.expand_path(@input.to_s)
        stat = File.lstat(path)
        unless stat.file? && !stat.symlink?
          raise Hive::Proposals::InvalidRecord, "proposal input must be a regular non-symlink file"
        end
        if stat.size > MAX_INPUT_BYTES
          raise Hive::Proposals::InvalidRecord, "proposal input exceeds #{MAX_INPUT_BYTES} bytes"
        end
        project_root = File.realpath(project_root)
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
            "action" => @subcommand, "outcome" => "recorded",
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
