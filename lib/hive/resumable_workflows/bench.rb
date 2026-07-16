require "digest"
require "json"
require "pathname"
require "yaml"
require "hive/provider_routing/configuration"
require "hive/resumable_workflow"

module Hive
  module ResumableWorkflows
    class Bench
      TERMINAL_RUN_STATUSES = %w[generated empty_diff].freeze

      def initialize(workflow)
        @workflow = workflow
      end

      def snapshot(row:, project_root:, config:)
        campaign_path = File.join(row.folder, "campaign.yml")
        campaign = YAML.safe_load(File.read(campaign_path))
        unless campaign.is_a?(Hash)
          raise Hive::ResumableWorkflow::SnapshotError,
                "bench campaign #{campaign_path} must be a YAML mapping"
        end

        campaign_id = segment(campaign.fetch("campaign_id"), "campaign_id")
        tasks = unique_segments(campaign.fetch("tasks"), "tasks")
        candidates = unique_segments(campaign.fetch("candidates"), "candidates")
        exclusions = Array(campaign["exclusions"]).map do |entry|
          [ entry.fetch("task").to_s, entry.fetch("candidate").to_s ]
        end
        result_paths = []
        children = tasks.flat_map do |task_id|
          candidates.filter_map do |candidate_id|
            next if exclusions.include?([ task_id, candidate_id ])

            result_path = File.join(
              project_root, "runs", campaign_id, "#{candidate_id}--#{task_id}", "results.json"
            )
            result_paths << result_path
            child_from_result(
              task_id: task_id,
              candidate_id: candidate_id,
              result_path: result_path,
              project_root: project_root,
              config: config
            )
          end
        end
        fingerprint = checkpoint_fingerprint(campaign_path, result_paths)
        generation = fingerprint.delete_prefix("sha256:")[0, 15].to_i(16)
        Hive::ResumableWorkflow::Snapshot.new(
          workflow_id: "#{row.project}/bench/#{row.slug}",
          kind: "bench",
          checkpoint_generation: generation,
          checkpoint_fingerprint: fingerprint,
          children: children,
          source: campaign_path
        )
      rescue KeyError => e
        raise Hive::ResumableWorkflow::SnapshotError,
              "bench campaign #{campaign_path} is missing #{e.key.inspect}"
      rescue Psych::Exception => e
        raise Hive::ResumableWorkflow::SnapshotError,
              "bench campaign #{campaign_path} is invalid YAML: #{e.message}"
      rescue Errno::ENOENT, Errno::EACCES => e
        raise Hive::ResumableWorkflow::SnapshotError,
              "bench campaign #{campaign_path} is unavailable: #{e.message}"
      end

      def configuration_for(child:, row:, config:)
        stage_name = row.stage.to_s.sub(/\A\d+-/, "")
        stage = @workflow.stage_for_dir(row.stage) || @workflow.stage_named(stage_name)
        Hive::ProviderRouting::Configuration.from(
          cfg: config,
          stage_name: stage_name,
          routing: child.routing || stage&.routing,
          agent: stage&.agent,
          model: stage&.model,
          effort: stage&.effort,
          source: "bench recovery #{child.child_id}"
        )
      end

      def resume_command(row:, snapshot:)
        _ = snapshot
        row.suggested_command.to_s.empty? ? "hive run #{row.slug}" : row.suggested_command
      end

      private

      def child_from_result(task_id:, candidate_id:, result_path:, project_root:, config:)
        child_id = "#{candidate_id}/#{task_id}"
        artifact_ref = relative_ref(result_path, project_root)
        result = JSON.parse(File.read(result_path))
        cell = Array(result["cells"]).find do |entry|
          entry["task_id"].to_s == task_id && entry["agent_id"].to_s == candidate_id
        end
        if cell && TERMINAL_RUN_STATUSES.include?(cell["run_status"].to_s)
          return child(child_id, "complete", artifact_ref: artifact_ref)
        end

        pending = matching_entry(result["pending"], task_id, candidate_id)
        if pending
          provider = pending["failed_provider"] || pending["provider"] || infer_provider(candidate_id)
          accounts = config[Hive::ProviderRouting::PROVIDER_ACCOUNTS_KEY] ||
            Hive::ProviderRouting.default_accounts
          if provider && accounts.key?(provider)
            routing = { "pool" => [ { "provider" => provider } ] }
            return child(
              child_id,
              "provider_retryable",
              failed_provider: provider,
              artifact_ref: artifact_ref,
              routing: routing,
              reason: pending["reason"]
            )
          end

          return child(
            child_id,
            "terminal",
            artifact_ref: artifact_ref,
            reason: "pending result lacks configured provider provenance"
          )
        end

        failed = matching_entry(result["failed"], task_id, candidate_id)
        return child(child_id, "terminal", artifact_ref: artifact_ref, reason: failed["reason"]) if failed

        patch = bought_patch(result_path)
        return child(child_id, "complete", artifact_ref: relative_ref(patch, project_root)) if patch

        child(child_id, "pending", artifact_ref: artifact_ref)
      rescue Errno::ENOENT
        child(child_id, "pending")
      rescue JSON::ParserError => e
        raise Hive::ResumableWorkflow::SnapshotError,
              "bench result #{result_path} is invalid JSON: #{e.message}"
      end

      def matching_entry(entries, task_id, candidate_id)
        Array(entries).find do |entry|
          entry["task_id"].to_s == task_id && entry["agent_id"].to_s == candidate_id
        end
      end

      def child(child_id, status, failed_provider: nil, artifact_ref: nil, routing: nil, reason: nil)
        Hive::ResumableWorkflow::Child.new(
          child_id: child_id,
          status: status,
          failed_provider: failed_provider,
          artifact_ref: artifact_ref,
          routing: routing,
          reason: reason
        )
      end

      def bought_patch(result_path)
        cell_root = File.dirname(result_path)
        Dir.glob(File.join(cell_root, "*", "*", "target", "candidate.patch")).sort.first
      end

      def infer_provider(candidate_id)
        id = candidate_id.downcase
        return "grok" if id.start_with?("all-grok")
        return "pi" if id.start_with?("all-glm", "all-kimi", "glm-plan")
        return "claude" if id.start_with?("all-opus")
        return "codex" if id.start_with?("all-codex")

        nil
      end

      def relative_ref(path, project_root)
        Pathname.new(path).relative_path_from(Pathname.new(project_root)).to_s
      end

      def checkpoint_fingerprint(campaign_path, result_paths)
        digest = ::Digest::SHA256.new
        ([ campaign_path ] + result_paths.sort).each do |path|
          digest << path << "\0"
          digest << (File.file?(path) ? File.binread(path) : "missing") << "\0"
        end
        "sha256:#{digest.hexdigest}"
      end

      def unique_segments(values, label)
        unless values.is_a?(Array) && !values.empty?
          raise Hive::ResumableWorkflow::SnapshotError, "bench #{label} must be a non-empty array"
        end
        segments = values.map { |value| segment(value, label) }
        if segments.uniq.length != segments.length
          raise Hive::ResumableWorkflow::SnapshotError, "bench #{label} contains duplicates"
        end
        segments
      end

      def segment(value, label)
        text = value.to_s
        unless text.match?(/\A[a-zA-Z0-9][a-zA-Z0-9._>-]*\z/)
          raise Hive::ResumableWorkflow::SnapshotError,
                "bench #{label} contains unsafe path segment #{value.inspect}"
        end
        text
      end
    end
  end
end

Hive::ResumableWorkflows::Registry.register("bench", ->(workflow) { Hive::ResumableWorkflows::Bench.new(workflow) })
