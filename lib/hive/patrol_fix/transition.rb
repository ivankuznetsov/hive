require "digest"
require "json"
require "time"
require "fileutils"
require "hive/git_ops"
require "hive/managed_directory"
require "hive/patrol_fix/receipt_store"
require "hive/patrol_fix/task_manifest"
require "hive/patrol_fix/worktree_receipt"

module Hive
  module PatrolFix
    # Replays the controller mutations that follow an immutable semantic
    # decision. Callers execute it under StageTransition's stable slug lock;
    # its intent lives under that same non-moving directory.
    class Transition
      SCHEMA = "hive-patrol-fix-route-intent".freeze
      SCHEMA_VERSION = 1
      INTENT_FILENAME = "route-intent.json".freeze
      MAX_INTENT_BYTES = 32 * 1024
      ROUTES = %w[rework publication_rework].freeze
      class InvalidTransition < Hive::Error; end

      def initialize(task, worktree_root: nil, commit: nil, clock: -> { Time.now.utc })
        @task = task
        @worktree_root = worktree_root
        @clock = clock
        @commit = commit || lambda do |stage_name:, slug:, action:, pathspecs:|
          Hive::GitOps.new(@task.project_root).hive_commit(
            stage_name: stage_name, slug: slug, action: action, pathspecs: pathspecs
          )
        end
        @directory = Hive::ManagedDirectory.new(
          root: File.join(task.hive_state_path, "patrol-fix", "transitions", task.slug),
          anchor: task.hive_state_path, label: "Patrol-fix route transition"
        )
      end

      def apply_review!(decision)
        return { task_folder: current_task_folder } unless decision.dig("payload", "route") == "rework"

        validate_decision!(decision, route: "rework")
        intent = begin_intent(
          action_id: decision.fetch("receipt_id"), route: "rework",
          stage: "review", destination: stage_dir("fix"), operator: "controller:review",
          carried_receipts: []
        )
        apply_intent(intent)
      end

      def apply_publication_block!(receipt)
        validate_publication_block!(receipt)
        target = receipt.dig("payload", "rework_stage")
        destination = { "inbox" => stage_dir("inbox"), "fix" => stage_dir("fix"),
                        "review" => stage_dir("review") }
                      .fetch(target)
        carried = if target == "review"
          [ receipt.dig("payload", "fix_receipt_id"),
            receipt.dig("payload", "validation_receipt_id") ]
        else
          []
        end
        intent = begin_intent(
          action_id: receipt.fetch("receipt_id"), route: "publication_rework",
          stage: "publish", destination: destination,
          operator: "operator:publication_policy", carried_receipts: carried
        )
        apply_intent(intent)
      end

      def reconcile!
        intent = read_intent
        return unless intent
        if intent.fetch("status") == "completed"
          folder = current_task_folder
          commit_intent!(intent)
          return { task_folder: folder, generation: intent.fetch("to_generation") }
        end

        apply_intent(intent)
      end

      private

      def begin_intent(action_id:, route:, stage:, destination:, operator:, carried_receipts:)
        current = read_intent
        if current && current.fetch("status") == "pending"
          unless current.fetch("action_id") == action_id && current.fetch("route") == route
            raise InvalidTransition, "another Patrol-fix route mutation is pending"
          end
          return current
        end
        folder = current_task_folder
        manifest = TaskManifest.new(task_folder: folder).read
        next_generation = manifest.dig("task", "generation") + 1
        next_digest = Digest::SHA256.hexdigest(PatrolFix.canonical_json(
          "kind" => "patrol-fix-generation-transition", "route" => route,
          "action_id" => action_id, "prior_digest" => manifest.dig("evidence_revision", "digest"),
          "generation" => next_generation
        ))
        intent = {
          "schema" => SCHEMA, "schema_version" => SCHEMA_VERSION,
          "status" => "pending", "task" => @task.slug, "action_id" => action_id,
          "route" => route, "stage" => stage, "from" => "#{@task.stage_index}-#{@task.stage_name}",
          "to" => destination, "from_generation" => next_generation - 1,
          "to_generation" => next_generation,
          "from_digest" => manifest.dig("evidence_revision", "digest"),
          "to_digest" => next_digest, "operator" => operator.to_s,
          "carried_receipts" => carried_receipts,
          "recorded_at" => @clock.call.utc.iso8601
        }
        write_intent(intent)
        intent
      end

      def apply_intent(intent)
        folder = current_task_folder
        manifest_store = TaskManifest.new(task_folder: folder)
        manifest = PatrolFix.deep_copy(manifest_store.read)
        current_generation = manifest.dig("task", "generation")
        if current_generation == intent.fetch("from_generation")
          unless manifest.dig("evidence_revision", "digest") == intent.fetch("from_digest")
            raise InvalidTransition, "route transition evidence changed before generation advance"
          end
          manifest.fetch("task")["generation"] = intent.fetch("to_generation")
          manifest.fetch("evidence_revision").merge!(
            "generation" => intent.fetch("to_generation"),
            "digest" => intent.fetch("to_digest")
          )
          manifest_store.write!(manifest)
        elsif current_generation != intent.fetch("to_generation") ||
              manifest.dig("evidence_revision", "digest") != intent.fetch("to_digest")
          raise InvalidTransition, "route transition generation is no longer recoverable"
        end

        rotate_worktree!(folder, intent)
        append_generation_receipt!(folder, intent)
        folder = move_if_needed!(folder, intent)
        write_intent(intent.merge("status" => "completed"))
        commit_intent!(intent)
        { task_folder: folder, generation: intent.fetch("to_generation") }
      rescue Hive::ManagedDirectory::UnsafeError, TaskManifest::InvalidManifest,
             ReceiptStore::InvalidReceipt, WorktreeReceipt::InvalidWorktree => e
        raise InvalidTransition, e.message
      end

      def commit_intent!(intent)
        @commit.call(
          stage_name: intent.fetch("to"), slug: @task.slug,
          action: intent.fetch("route") == "rework" ?
            "review rework" : "publication policy rework",
          pathspecs: [
            File.join("stages", intent.fetch("from"), @task.slug),
            File.join("stages", intent.fetch("to"), @task.slug),
            File.join("patrol-fix", "transitions", @task.slug, INTENT_FILENAME)
          ].uniq
        )
      end

      def rotate_worktree!(folder, intent)
        path = File.join(folder, WorktreeReceipt::FILENAME)
        return unless File.exist?(path) || File.symlink?(path)

        custody = WorktreeReceipt.new(
          task_folder: folder, project_root: @task.project_root, slug: @task.slug,
          worktree_root: @worktree_root
        )
        owner = custody.read
        return if owner.fetch("generation") == intent.fetch("to_generation") &&
          owner.fetch("evidence_digest") == intent.fetch("to_digest")
        unless owner.fetch("generation") == intent.fetch("from_generation") &&
               owner.fetch("evidence_digest") == intent.fetch("from_digest")
          raise InvalidTransition, "worktree custody cannot be rotated from this generation"
        end
        custody.rotate!(
          generation: intent.fetch("to_generation"),
          evidence_digest: intent.fetch("to_digest")
        )
      end

      def append_generation_receipt!(folder, intent)
        manifest = TaskManifest.new(task_folder: folder).read
        payload = {
          "outcome_receipt_id" => intent.fetch("action_id"),
          "operator" => intent.fetch("operator"),
          "carried_receipts" => intent.fetch("carried_receipts")
        }
        receipt_id = "reopen-#{Digest::SHA256.hexdigest(PatrolFix.canonical_json(
          "task" => manifest.fetch("task"), "stage" => intent.fetch("stage"),
          "payload" => payload
        ))[0, 24]}"
        ReceiptStore.new(task_folder: folder).append!(
          "schema" => ReceiptStore::SCHEMA, "schema_version" => ReceiptStore::SCHEMA_VERSION,
          "receipt_id" => receipt_id, "kind" => "reopen", "stage" => intent.fetch("stage"),
          "task" => manifest.fetch("task"),
          "evidence_revision" => manifest.fetch("evidence_revision"),
          "recorded_at" => intent.fetch("recorded_at"), "payload" => payload
        )
      end

      def move_if_needed!(folder, intent)
        destination = File.join(@task.hive_state_path, "stages", intent.fetch("to"), @task.slug)
        return folder if folder == destination
        unless File.basename(File.dirname(folder)) == intent.fetch("from")
          raise InvalidTransition, "route transition task is outside its source stage"
        end
        FileUtils.mkdir_p(File.dirname(destination))
        raise InvalidTransition, "route transition destination already exists" if File.exist?(destination)
        File.rename(folder, destination)
        Hive::AtomicFile.fsync_directory(File.dirname(folder))
        Hive::AtomicFile.fsync_directory(File.dirname(destination))
        destination
      rescue SystemCallError, IOError => e
        raise InvalidTransition, "route transition move failed: #{e.message}"
      end

      def validate_decision!(decision, route:)
        unless decision.is_a?(Hash) && decision["kind"] == "decision" &&
               decision["stage"] == "review" && decision.dig("payload", "route") == route
          raise InvalidTransition, "review transition requires the exact semantic decision receipt"
        end
        manifest = TaskManifest.new(task_folder: current_task_folder).read
        unless decision.fetch("task") == manifest.fetch("task") &&
               decision.fetch("evidence_revision") == manifest.fetch("evidence_revision")
          raise InvalidTransition, "review transition decision is stale"
        end
      end

      def validate_publication_block!(receipt)
        folder = current_task_folder
        manifest = TaskManifest.new(task_folder: folder).read
        rows = ReceiptStore.new(task_folder: folder).read_all
        stored = rows.find do |row|
          row["receipt_id"] == receipt["receipt_id"]
        end if receipt.is_a?(Hash)
        unless stored == receipt && receipt["kind"] == "publication_block" &&
               receipt["stage"] == "publish" &&
               receipt.fetch("task") == manifest.fetch("task") &&
               receipt.fetch("evidence_revision") == manifest.fetch("evidence_revision")
          raise InvalidTransition, "publication rework requires the exact current block receipt"
        end
        payload = receipt.fetch("payload")
        review = rows.find { |row| row["receipt_id"] == payload["review_receipt_id"] }
        fix = rows.find { |row| row["receipt_id"] == payload["fix_receipt_id"] }
        validation = rows.find do |row|
          row["receipt_id"] == payload["validation_receipt_id"]
        end
        common_identity = [ receipt.fetch("task"), receipt.fetch("evidence_revision") ]
        unless review&.values_at("task", "evidence_revision") == common_identity &&
               fix&.values_at("task", "evidence_revision") == common_identity &&
               validation&.values_at("task", "evidence_revision") == common_identity &&
               review.values_at("kind", "stage") == %w[decision review] &&
               review.dig("payload", "route") == "publish" &&
               fix.values_at("kind", "stage") == %w[fix fix] &&
               validation.values_at("kind", "stage") == %w[validation validate] &&
               review.dig("payload", "fix_receipt_id") == fix["receipt_id"] &&
               review.dig("payload", "validation_receipt_id") == validation["receipt_id"] &&
               [ review.dig("payload", "head_revision"),
                 fix.dig("payload", "head_revision"),
                 validation.dig("payload", "worktree_head") ].all? do |head|
                 head == payload["head_revision"]
               end &&
               [ review.dig("payload", "diff_digest"),
                 fix.dig("payload", "diff_digest") ].all? do |digest|
                 digest == payload["diff_digest"]
               end
          raise InvalidTransition, "publication block no longer binds its exact evidence chain"
        end
      rescue KeyError
        raise InvalidTransition, "publication rework requires the exact current block receipt"
      end

      def current_task_folder
        matches = @task.workflow.stage_dirs.filter_map do |stage|
          folder = File.join(@task.hive_state_path, "stages", stage, @task.slug)
          folder if File.directory?(folder)
        end
        raise InvalidTransition, "Patrol-fix task location is ambiguous or missing" unless matches.length == 1
        matches.first
      end

      def read_intent
        bytes = @directory.read(INTENT_FILENAME, max_bytes: MAX_INTENT_BYTES, missing: true)
        return unless bytes
        validate_intent(JSON.parse(bytes))
      rescue JSON::ParserError => e
        raise InvalidTransition, "route transition intent is malformed: #{e.message}"
      rescue Hive::ManagedDirectory::UnsafeError => e
        raise InvalidTransition, "route transition store is unsafe: #{e.message}"
      end

      def write_intent(intent)
        validate_intent(intent)
        @directory.atomic_write(
          INTENT_FILENAME, PatrolFix.canonical_json(intent), mode: 0o600,
          max_existing_bytes: MAX_INTENT_BYTES
        )
      rescue Hive::ManagedDirectory::UnsafeError => e
        raise InvalidTransition, "route transition store is unsafe: #{e.message}"
      end

      def validate_intent(intent)
        fields = %w[schema schema_version status task action_id route stage from to from_generation to_generation from_digest to_digest operator carried_receipts recorded_at]
        unless intent.is_a?(Hash) && intent.keys.sort == fields.sort &&
               intent["schema"] == SCHEMA && intent["schema_version"] == SCHEMA_VERSION &&
               %w[pending completed].include?(intent["status"]) && intent["task"] == @task.slug &&
               ROUTES.include?(intent["route"]) && %w[inbox review publish].include?(intent["stage"]) &&
               @task.workflow.stage_dirs.include?(intent["from"]) &&
               @task.workflow.stage_dirs.include?(intent["to"]) &&
               intent["from_generation"].is_a?(Integer) &&
               intent["to_generation"] == intent["from_generation"] + 1 &&
               intent["from_digest"].to_s.match?(/\A[0-9a-f]{64}\z/) &&
               intent["to_digest"].to_s.match?(/\A[0-9a-f]{64}\z/) &&
               intent["action_id"].is_a?(String) && !intent["action_id"].empty? &&
               intent["operator"].is_a?(String) && !intent["operator"].empty? &&
               intent["carried_receipts"].is_a?(Array) && intent["carried_receipts"].length <= 2
          raise InvalidTransition, "route transition intent is invalid"
        end
        validate_route_shape!(intent)
        Time.iso8601(intent.fetch("recorded_at"))
        intent
      rescue ArgumentError, KeyError
        raise InvalidTransition, "route transition intent timestamp is invalid"
      end


      def validate_route_shape!(intent)
        valid = if intent["route"] == "rework"
          intent["stage"] == "review" && intent["from"] == stage_dir("review") &&
            intent["to"] == stage_dir("fix") && intent["operator"] == "controller:review" &&
            intent["carried_receipts"].empty?
        else
          destinations = {
            stage_dir("inbox") => 0,
            stage_dir("fix") => 0,
            stage_dir("review") => 2
          }
          intent["stage"] == "publish" && intent["from"] == stage_dir("publish") &&
            intent["operator"] == "operator:publication_policy" &&
            destinations[intent["to"]] == intent["carried_receipts"].length &&
            intent["carried_receipts"].all? do |receipt_id|
              receipt_id.is_a?(String) && !receipt_id.empty? && receipt_id.bytesize <= 128
            end
        end
        raise InvalidTransition, "route transition intent has an invalid semantic shape" unless valid
      end

      def stage_dir(name)
        @task.workflow.stage_named(name)&.dir or
          raise InvalidTransition, "Patrol-fix workflow is missing stage #{name.inspect}"
      end
    end
  end
end
