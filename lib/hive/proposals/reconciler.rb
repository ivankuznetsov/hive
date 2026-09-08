require "fileutils"
require "hive/git_ops"
require "hive/lock"
require "hive/proposals/ingestor"
require "hive/secret_patterns"

module Hive
  module Proposals
    ReconciliationResult = Data.define(:processed, :consumed, :quarantined, :pending, :cleaned)

    class Reconciler
      PERMANENT_ERRORS = [
        InvalidRecord, InvalidEvent, Conflict, InconsistentHistory,
        QuarantinedSource, Unauthorized
      ].freeze

      def initialize(git_ops:, source_store: nil, store: nil, ingestor: nil, max_batch: 64)
        @git_ops = git_ops
        root = File.join(git_ops.hive_state_path, "proposals", "v1")
        @source_store = source_store || SourceEventStore.new(root: root)
        @store = store || Store.new(root: root)
        @ingestor = ingestor || Ingestor.new(
          source_store: @source_store, store: @store, git_ops: @git_ops
        )
        @max_batch = Integer(max_batch)
        raise ArgumentError, "proposal reconciliation batch must be positive" unless @max_batch.positive?
      end

      def reconcile!
        processed = consumed = quarantined = cleaned = 0
        Hive::Lock.with_commit_lock(@git_ops.hive_state_path) do
          cleaned = clean_uncommitted_state!
        end
        pending = @source_store.pending_ids.first(@max_batch)
        pending.each do |source_event_id|
          processed += 1
          begin
            source_commit = committed_source_commit!(source_event_id)
            @ingestor.ingest!(source_event_id, source_commit:)
            consumed += 1
          rescue *PERMANENT_ERRORS => error
            quarantine_source!(source_event_id, error)
            quarantined += 1
          rescue SourceUnavailable, QuotaExceeded
            next
          end
        end
        ReconciliationResult.new(
          processed:, consumed:, quarantined:,
          pending: @source_store.pending_ids.length, cleaned:
        )
      end

      private

      def committed_source_commit!(source_event_id)
        path = "proposals/v1/inbox/#{source_event_id}.json"
        commit = @git_ops.hive_state_commit_for_path(path)
        raise SourceUnavailable, "committed proposal source receipt is missing" unless commit
        bytes = @git_ops.read_hive_state_blob_at(
          @git_ops.hive_state_head_sha, path,
          max_bytes: SourceEventStore::MAX_FILE_BYTES + 1
        )
        raise SourceUnavailable, "committed proposal source receipt is missing" unless bytes
        commit
      end

      def quarantine_source!(source_event_id, error)
        Hive::Lock.with_commit_lock(@git_ops.hive_state_path) do
          snapshot = Ingestor::PathSnapshot.capture(
            @source_store.paths_for_terminal(source_event_id, state: "quarantine")
          )
          index_snapshot = Proposals::GitIndexSnapshot.capture(@git_ops)
          begin
            @source_store.quarantine!(
              source_event_id, code: quarantine_code(error),
              reason: "committed proposal source failed permanent validation"
            )
            paths = @source_store.paths_for_terminal(source_event_id, state: "quarantine")
                         .map do |path|
                           Proposals.hive_state_relative_path(
                             @git_ops, path, label: "proposal reconciliation path"
                           )
                         end
            @git_ops.hive_commit(
              stage_name: "proposal-reconcile", slug: source_event_id,
              action: "quarantined proposal source", pathspecs: paths
            )
          rescue StandardError => failure
            snapshot.restore!
            index_snapshot.restore! rescue nil
            raise failure
          end
        end
      end

      def quarantine_code(error)
        error.class.name.split("::").last
             .gsub(/([a-z\d])([A-Z])/, '\\1_\\2').downcase[0, 128]
      end

      def clean_uncommitted_state!
        output = @git_ops.run_git!(
          "-C", @git_ops.hive_state_path, "status", "--porcelain=v1", "-z",
          "--untracked-files=all", "--", "proposals/v1"
        )
        entries = output.split("\0").reject(&:empty?)
        cleaned = 0
        entries.each do |entry|
          status = entry[0, 2]
          path = entry[3..]
          next unless safe_proposal_path?(path)

          if status == "??"
            remove_untracked!(path)
          else
            @git_ops.run_git!(
              "-C", @git_ops.hive_state_path, "restore", "--source=HEAD",
              "--staged", "--worktree", "--", path
            )
          end
          cleaned += 1
        end
        cleaned
      end

      def remove_untracked!(relative)
        path = File.join(@git_ops.hive_state_path, relative)
        stat = File.lstat(path)
        if stat.directory? && !stat.symlink?
          FileUtils.rm_rf(path)
        else
          File.unlink(path)
        end
      rescue Errno::ENOENT
        nil
      end

      def safe_proposal_path?(path)
        path.is_a?(String) && path.start_with?("proposals/v1/") &&
          !path.split("/").include?("..")
      end
    end
  end
end
