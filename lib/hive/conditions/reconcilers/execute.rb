require "digest"
require "hive/conditions/generation_tracker"
require "hive/git_ops"
require "hive/task_journal"
require "hive/task_projection/store"

module Hive
  module Conditions
    module Reconcilers
      ExecuteResult = Data.define(:append_result, :projection, :observations)

      class Execute
        TRANSITION = "execute_to_open_pr".freeze

        def initialize(task:, attempt:, attempt_store:, writer: nil, projection_store: nil,
                       git_ops: nil, generation_tracker: GenerationTracker.new,
                       workflow_policy: {}, operator_decisions: [])
          @task = task
          @attempt = attempt
          @attempt_store = attempt_store
          @writer = writer || Hive::TaskJournal::Writer.new(
            task_folder: task.folder, attempt_store: attempt_store
          )
          @projection_store = projection_store || Hive::TaskProjection::Store.new(
            task_folder: task.folder, attempt_store: attempt_store
          )
          @git_ops = git_ops || Hive::GitOps.new(task.worktree_path)
          @generation_tracker = generation_tracker
          @workflow_policy = workflow_policy
          @operator_decisions = operator_decisions
        end

        def reconcile(baseline_head: nil, waiting_reason: nil, research: false,
                      research_evidence: false, generation_reason: "accepted_input_changed",
                      invalidation_token: nil)
          records = Hive::TaskProjection.read_journal(
            @writer.path, attempt_store: @writer.attempt_store
          )
          generation = @generation_tracker.resolve(
            task: @task, records: records, workflow_policy: @workflow_policy,
            operator_decisions: @operator_decisions, reason: generation_reason,
            invalidation_token: invalidation_token
          )
          unless generation.task_generation == @attempt.task_input_epoch
            raise GenerationMismatch,
                  "attempt #{@attempt.attempt_id} owns task generation #{@attempt.task_input_epoch}, " \
                  "but current inputs require #{generation.task_generation}"
          end

          worktree = observe_worktree
          commit = @generation_tracker.commit(
            records: records, task_generation: generation.task_generation,
            head_sha: worktree.fetch(:head), branch: worktree.fetch(:branch)
          )
          observations = build_observations(
            records: records, generation: generation, commit: commit, worktree: worktree,
            baseline_head: baseline_head || @attempt["starting_revision"], waiting_reason: waiting_reason,
            research: research, research_evidence: research_evidence
          )
          fresh = observations.reject { |observation| already_recorded?(records, observation) }
          append_result = fresh.empty? ? nil : @writer.append_batch(fresh)
          projection = @projection_store.rebuild!
          ExecuteResult.new(
            append_result: append_result, projection: projection,
            observations: fresh.freeze
          )
        end

        private

        def observe_worktree
          {
            head: @git_ops.head_sha,
            branch: @git_ops.current_branch,
            dirty: !@git_ops.status_short.strip.empty?,
            error: nil
          }
        rescue Hive::GitError, SystemCallError => e
          { head: nil, branch: nil, dirty: nil, error: "#{e.class}: #{e.message}" }
        end

        def build_observations(records:, generation:, commit:, worktree:, baseline_head:,
                               waiting_reason:, research:, research_evidence:)
          observations = []
          observations << generation_event(generation) if generation.advanced
          observations << commit_event(generation, commit) if commit.advanced
          observations << agent_health_event(generation, commit)

          changes_state, changes_reason = changes_outcome(
            worktree: worktree, baseline_head: baseline_head, research: research
          )
          output_evidence = research && research_evidence ? research_output_evidence : nil
          observations << condition_event(
            "ChangesPresent", state: changes_state, reason: changes_reason,
            generation: generation, commit: commit,
            evidence: changes_evidence(worktree, commit, changes_reason, output_evidence: output_evidence),
            payload: { "research_output_evidence" => !output_evidence.nil? }
          )

          wait_reason = waiting_reason || derived_wait_reason(
            worktree: worktree, changes_state: changes_state, changes_reason: changes_reason,
            research: research
          )
          observations << condition_event(
            "AwaitingHuman", state: wait_reason ? "satisfied" : "unsatisfied",
            reason: wait_reason || "not_waiting", generation: generation, commit: commit,
            evidence: [ attempt_evidence ],
            payload: { "blocked_transition" => TRANSITION, "wait_reason" => wait_reason }
          )
          observations
        end

        def generation_event(generation)
          base_event(
            event_type: "generation_advanced", generation: generation,
            commit_generation: 0, reason: generation.reason,
            payload: {
              "input_fingerprint" => generation.input_fingerprint,
              "invalidation_token" => generation.invalidation_token
            }
          )
        end

        def commit_event(generation, commit)
          base_event(
            event_type: "commit_generation_advanced", generation: generation,
            commit_generation: commit.commit_generation, reason: "head_changed",
            evidence: [ commit_evidence(commit.head_sha, commit.branch) ],
            payload: { "head_sha" => commit.head_sha, "branch" => commit.branch }
          )
        end

        def agent_health_event(generation, commit)
          state, reason = if @attempt.state == "lost"
            [ "unsatisfied", "attempt_lost" ]
          elsif @attempt.state == "terminal" && @attempt.outcome != "succeeded"
            [ "unsatisfied", "attempt_terminal_#{@attempt.outcome}" ]
          elsif @attempt.state == "terminal"
            [ "satisfied", "attempt_terminal_succeeded" ]
          elsif @attempt.live?
            [ "satisfied", "attempt_live" ]
          else
            [ "unverifiable", "attempt_state_unverifiable" ]
          end
          condition_event(
            "AgentHealthy", state: state, reason: reason, generation: generation, commit: commit,
            evidence: [ attempt_evidence ],
            payload: {
              "informational_after_terminal" =>
                @attempt.state == "terminal" && @attempt.outcome == "succeeded"
            }
          )
        end

        def changes_outcome(worktree:, baseline_head:, research:)
          return [ "unverifiable", "worktree_evidence_unverifiable" ] if worktree[:error] || worktree[:head].nil?
          return [ "satisfied", "dirty_worktree" ] if worktree[:dirty]
          return [ "satisfied", "commit_present" ] if baseline_head && worktree[:head] != baseline_head
          return [ "unsatisfied", "research_no_commit" ] if research

          [ "unsatisfied", "no_worktree_changes" ]
        end

        def changes_evidence(worktree, commit, reason, output_evidence: nil)
          evidence = if worktree[:head]
            [ commit_evidence(worktree[:head], worktree[:branch]).merge(
              "dirty" => worktree[:dirty], "observation" => reason
            ) ]
          else
            [
              {
                "type" => "journal_event",
                "event_id" => "worktree-unverifiable:#{@attempt.attempt_id}:#{@attempt.lease_version}",
                "error" => worktree[:error],
                "commit_generation" => commit.commit_generation
              }
            ]
          end
          evidence << output_evidence if output_evidence
          evidence
        end

        def research_output_evidence
          path = @task.state_file
          return nil unless File.file?(path)

          {
            "type" => "file",
            "path" => File.basename(path),
            "digest" => ::Digest::SHA256.file(path).hexdigest,
            "purpose" => "research_output"
          }
        rescue SystemCallError, IOError
          nil
        end

        def derived_wait_reason(worktree:, changes_state:, changes_reason:, research:)
          return "dirty_worktree" if worktree[:dirty]
          return nil if research
          return "evidence_unverifiable" if changes_state == "unverifiable"
          return "no_worktree_changes" if changes_reason == "no_worktree_changes"

          nil
        end

        def condition_event(name, state:, reason:, generation:, commit:, evidence:, payload: {})
          base_event(
            event_type: "condition_observed", generation: generation,
            commit_generation: commit.commit_generation, reason: reason, evidence: evidence,
            payload: payload.merge("condition" => name, "state" => state)
          )
        end

        def base_event(event_type:, generation:, commit_generation:, reason:, evidence: [], payload: {})
          {
            event_type: event_type,
            task: { "id" => task_id, "slug" => @task.slug.to_s },
            workflow: task_workflow,
            stage: "4-execute", # coding-scoped: this reconciler observes the coding execute stage
            attempt_id: @attempt.attempt_id,
            task_generation: generation.task_generation,
            ownership_generation: @attempt.ownership_generation,
            commit_generation: commit_generation,
            reason: reason,
            evidence: evidence,
            provenance: {
              "source" => "execute_reconciler",
              "attempt_id" => @attempt.attempt_id,
              "lease_version" => @attempt.lease_version,
              "attempt_accepted_at" => @attempt["accepted_at"],
              "predecessor_attempt_id" => @attempt["predecessor_attempt_id"]
            },
            payload: payload
          }
        end

        def attempt_evidence
          {
            "type" => "attempt_lease",
            "attempt_id" => @attempt.attempt_id,
            "lease_version" => @attempt.lease_version,
            "state" => @attempt.state,
            "outcome" => @attempt.outcome
          }
        end

        def commit_evidence(sha, branch)
          { "type" => "commit", "sha" => sha, "branch" => branch || "(detached)" }
        end

        def already_recorded?(records, observation)
          normalized = stringify(observation)
          records.any? do |record|
            record["event_type"] == normalized["event_type"] &&
              record["attempt_id"] == normalized["attempt_id"] &&
              record["task_generation"] == normalized["task_generation"] &&
              record["commit_generation"] == normalized["commit_generation"] &&
              record["reason"] == normalized["reason"] &&
              record["evidence"] == normalized["evidence"] &&
              record["payload"] == normalized["payload"]
          end
        end

        def stringify(value)
          case value
          when Hash then value.to_h { |key, child| [ key.to_s, stringify(child) ] }
          when Array then value.map { |child| stringify(child) }
          else value
          end
        end

        def task_id
          @task.respond_to?(:id) ? @task.id&.to_s : nil
        end

        def task_workflow
          workflow = @task.respond_to?(:workflow) ? @task.workflow : nil
          workflow.respond_to?(:id) ? workflow.id.to_s : "coding"
        end
      end
    end
  end
end
