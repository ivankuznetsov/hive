require "fileutils"
require "hive/atomic_file"
require "hive/lock"
require "hive/proposals/source_event_store"
require "hive/proposals/store"

module Hive
  module Proposals
    IngestionResult = Data.define(:kind, :proposal_id, :event_id, :source_event_id) do
      def to_h
        {
          "kind" => kind, "proposal_id" => proposal_id,
          "event_id" => event_id, "source_event_id" => source_event_id
        }
      end

      def self.from_h(value)
        new(
          kind: value.fetch("kind"), proposal_id: value.fetch("proposal_id"),
          event_id: value["event_id"], source_event_id: value.fetch("source_event_id")
        )
      end
    end

    class Ingestor
      def initialize(source_store:, store:, git_ops: nil)
        @source_store = source_store
        @store = store
        @git_ops = git_ops
      end

      def ingest!(source_event_id, source_commit:)
        id = Proposals.source_event_id!(source_event_id)
        terminal = @source_store.status(id)
        if terminal && terminal["state"] == "consumed"
          return IngestionResult.from_h(terminal.fetch("result"))
        end
        if terminal && terminal["state"] == "quarantine"
          raise QuarantinedSource, "proposal source receipt is terminally quarantined"
        end

        source = @source_store.fetch(id)
        raise SourceUnavailable, "proposal source receipt is unavailable" unless source

        if @git_ops
          ingest_committed!(source, source_commit:)
        else
          mutate!(source, source_commit:).first
        end
      end

      private

      def ingest_committed!(source, source_commit:)
        result = nil
        staged_paths = []
        snapshot = nil
        Hive::Lock.with_commit_lock(@git_ops.hive_state_path) do
          snapshot = PathSnapshot.capture(snapshot_roots(source))
          begin
            result, paths = mutate!(source, source_commit:)
            staged_paths = paths.map { |path| relative_state_path(path) }
            @git_ops.hive_commit(
              stage_name: source.to_h.dig("binding", "stage"),
              slug: source.to_h.dig("binding", "task_slug"),
              action: "ingested proposal source #{source.source_event_id}",
              pathspecs: staged_paths
            )
          rescue StandardError
            snapshot.restore!
            unstage!(staged_paths)
            raise
          end
        end
        result
      end

      def mutate!(source, source_commit:)
        mutation = case source.kind
        when "candidate_submitted" then ingest_submission!(source, source_commit:)
        when "evaluation_recorded" then ingest_evaluation!(source, source_commit:)
        else raise InvalidRecord, "unsupported proposal source event kind"
        end
        status = @source_store.mark_consumed!(source.source_event_id, result: mutation.first.to_h)
        [ mutation.first, (mutation.last + @source_store.paths_for_terminal(
          source.source_event_id, state: status.fetch("state")
        )).uniq ]
      end

      def ingest_submission!(source, source_commit:)
        subject = source.to_h.fetch("subject")
        payload = source.to_h.fetch("payload")
        record = @store.create_record!(
          proposal_id: source.proposal_id,
          subject_kind: subject.fetch("kind"), subject_ref: subject.fetch("reference"),
          revision: subject.fetch("revision"),
          proposed_change: payload.fetch("proposed_change"),
          motivation: payload.fetch("motivation"), evidence: payload.fetch("evidence"),
          author: source.to_h.fetch("actor"), lineage: payload.fetch("lineage"),
          provenance: source.provenance(source_commit:),
          source_event_id: source.source_event_id, created_at: source.to_h.fetch("created_at"),
          policy: source.to_h.fetch("policy")
        )
        result = IngestionResult.new(
          kind: "record", proposal_id: record.proposal_id,
          event_id: nil, source_event_id: source.source_event_id
        )
        [ result, @store.paths_for_record(record.proposal_id) ]
      end

      def ingest_evaluation!(source, source_commit:)
        record = @store.fetch_record(source.proposal_id)
        raise InvalidEvent, "proposal evaluation target does not exist" unless record
        ensure_subject_matches!(record, source)
        payload = source.to_h.fetch("payload")
        admitted = source.to_h.fetch("evaluator")
        event = @store.append_event!(
          proposal_id: source.proposal_id, type: "evaluation",
          data: {
            "evaluator" => {
              "id" => admitted.fetch("id"),
              "binding_fingerprint" => admitted.fetch("fingerprint"),
              "configuration_fingerprint" => admitted.fetch("configuration_fingerprint")
            },
            "method" => payload.fetch("method"), "result" => payload.fetch("result"),
            "rationale" => payload.fetch("rationale"), "evidence" => payload.fetch("evidence"),
            "links" => payload.fetch("links")
          },
          source_event_id: source.source_event_id,
          provenance: source.provenance(source_commit:),
          occurred_at: source.to_h.fetch("created_at"), policy: source.to_h.fetch("policy")
        )
        result = IngestionResult.new(
          kind: "event", proposal_id: event.proposal_id,
          event_id: event.event_id, source_event_id: source.source_event_id
        )
        [ result, [ @store.path_for_event(event) ] ]
      end

      def ensure_subject_matches!(record, source)
        subject = source.to_h.fetch("subject")
        return if record.subject == subject.slice("kind", "reference") &&
                  record.revision == subject.fetch("revision")

        raise Conflict, "proposal evaluation subject does not match its immutable candidate"
      end

      def snapshot_roots(source)
        [
          *@store.paths_for_record(source.proposal_id),
          File.join(@store.events_root, source.proposal_id),
          *@source_store.paths_for_terminal(source.source_event_id, state: "consumed")
        ].uniq
      end

      def relative_state_path(path)
        prefix = "#{File.expand_path(@git_ops.hive_state_path)}/"
        absolute = File.expand_path(path)
        raise Error, "proposal transaction path is outside hive state" unless absolute.start_with?(prefix)
        absolute.delete_prefix(prefix)
      end

      def unstage!(paths)
        return if paths.empty?
        @git_ops.run_git!("-C", @git_ops.hive_state_path, "reset", "-q", "HEAD", "--", *paths)
      rescue Hive::GitError
        nil
      end

      class PathSnapshot
        def self.capture(roots)
          new(roots).tap(&:capture!)
        end

        def initialize(roots)
          @roots = roots.map { |path| File.expand_path(path) }.uniq
          @entries = {}
        end

        def capture!
          @roots.each { |root| capture_path(root) }
          self
        end

        def restore!
          @roots.each { |root| remove_current(root) }
          @entries.sort.each do |path, entry|
            case entry.fetch("kind")
            when "directory" then FileUtils.mkdir_p(path, mode: entry.fetch("mode"))
            when "file"
              FileUtils.mkdir_p(File.dirname(path))
              Hive::AtomicFile.write(path, entry.fetch("bytes"), mode: entry.fetch("mode"))
            when "symlink"
              FileUtils.mkdir_p(File.dirname(path))
              File.symlink(entry.fetch("target"), path)
            end
          end
        end

        private

        def capture_path(path)
          stat = File.lstat(path)
          if stat.symlink?
            @entries[path] = { "kind" => "symlink", "target" => File.readlink(path) }
          elsif stat.directory?
            @entries[path] = { "kind" => "directory", "mode" => stat.mode & 0o777 }
            Dir.children(path).sort.each { |child| capture_path(File.join(path, child)) }
          elsif stat.file?
            @entries[path] = {
              "kind" => "file", "mode" => stat.mode & 0o777, "bytes" => File.binread(path)
            }
          end
        rescue Errno::ENOENT
          nil
        end

        def remove_current(path)
          stat = File.lstat(path)
          if stat.directory? && !stat.symlink?
            FileUtils.rm_rf(path)
          else
            File.unlink(path)
          end
        rescue Errno::ENOENT
          nil
        end
      end
    end
  end
end
