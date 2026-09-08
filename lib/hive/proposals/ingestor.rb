require "fileutils"
require "json"
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
        return ingest_committed!(id, source_commit:) if @git_ops

        terminal = @source_store.status(id)
        if terminal && terminal["state"] == "consumed"
          return IngestionResult.from_h(terminal.fetch("result"))
        end
        if terminal && terminal["state"] == "quarantine"
          raise QuarantinedSource, "proposal source receipt is terminally quarantined"
        end

        source = @source_store.fetch(id)
        raise SourceUnavailable, "proposal source receipt is unavailable" unless source

        mutate!(source, source_commit:).first
      end

      private

      def ingest_committed!(source_event_id, source_commit:)
        result = nil
        staged_paths = []
        snapshot = nil
        event_snapshot = nil
        Hive::Lock.with_commit_lock(@git_ops.hive_state_path) do
          source = committed_source!(source_event_id, source_commit)
          restore_committed_target!(source)
          terminal = @source_store.status(source_event_id)
          if terminal && terminal["state"] == "consumed"
            result = IngestionResult.from_h(terminal.fetch("result"))
            verify_committed_terminal!(terminal, result)
            next
          end
          if terminal && terminal["state"] == "quarantine"
            raise QuarantinedSource, "proposal source receipt is terminally quarantined"
          end

          snapshot = PathSnapshot.capture(snapshot_roots(source))
          event_snapshot = ImmutableAppendSnapshot.capture(
            File.join(@store.events_root, source.proposal_id)
          )
          index_snapshot = Proposals::GitIndexSnapshot.capture(@git_ops)
          committed = false
          begin
            result, paths = mutate!(source, source_commit:)
            staged_paths = paths.map do |path|
              Proposals.hive_state_relative_path(
                @git_ops, path, label: "proposal transaction path"
              )
            end
            commit_result = @git_ops.hive_commit(
              stage_name: source.to_h.dig("binding", "stage"),
              slug: source.to_h.dig("binding", "task_slug"),
              action: "ingested proposal source #{source.source_event_id}",
              pathspecs: staged_paths
            )
            committed = commit_result == :committed
            verify_committed_terminal!(@source_store.status(source_event_id), result)
          rescue StandardError => error
            if committed
              restore_committed_target!(source) rescue nil
            else
              snapshot.restore!
              event_snapshot.restore!
              index_snapshot.restore! rescue nil
            end
            raise error
          end
        end
        result
      end

      def committed_source!(source_event_id, source_commit)
        relative = "proposals/v1/inbox/#{source_event_id}.json"
        bytes = @git_ops.read_hive_state_blob_at(
          source_commit, relative, max_bytes: SourceEventStore::MAX_FILE_BYTES + 1
        )
        raise SourceUnavailable, "committed proposal source receipt is missing" unless bytes

        SourceEvent.new(JSON.parse(bytes))
      rescue JSON::ParserError, InvalidRecord
        raise QuarantinedSource, "committed proposal source receipt is malformed"
      end

      def verify_committed_terminal!(terminal, result)
        unless terminal.is_a?(Hash) && terminal["state"] == "consumed" &&
               terminal["result"] == result.to_h
          raise SourceUnavailable, "proposal consumed status is unavailable or inconsistent"
        end
        state = terminal.fetch("state")
        status_path = Proposals.hive_state_relative_path(
          @git_ops, @source_store.paths_for_terminal(result.source_event_id, state:).first,
          label: "proposal terminal path"
        )
        status_bytes = @git_ops.read_hive_state_blob_at(
          @git_ops.hive_state_head_sha, status_path,
          max_bytes: SourceEventStore::MAX_FILE_BYTES + 1
        )
        unless status_bytes == Proposals.canonical(terminal)
          raise SourceUnavailable, "proposal consumed status is not durably committed"
        end

        canonical = if result.kind == "record"
          @store.fetch_record(result.proposal_id)
        else
          @store.fetch_event(result.event_id)
        end
        unless canonical && canonical.source_event_id == result.source_event_id
          raise QuarantinedSource, "proposal consumed status has no matching canonical mutation"
        end
        canonical_path = canonical.is_a?(Record) ? @store.paths_for_record(canonical.proposal_id).first :
          @store.path_for_event(canonical)
        relative = Proposals.hive_state_relative_path(
          @git_ops, canonical_path, label: "proposal canonical path"
        )
        committed = @git_ops.read_hive_state_blob_at(
          @git_ops.hive_state_head_sha, relative, max_bytes: Store::MAX_FILE_BYTES + 1
        )
        unless committed == Proposals.canonical(canonical.to_h)
          raise SourceUnavailable, "proposal canonical mutation is not durably committed"
        end
      end

      def restore_committed_target!(source)
        cleanup_paths = snapshot_roots(source) + [ File.join(@store.events_root, source.proposal_id) ]
        roots = cleanup_paths.map do |path|
          Proposals.hive_state_relative_path(
            @git_ops, path, label: "proposal cleanup path"
          )
        end
        output = @git_ops.run_git!(
          "-C", @git_ops.hive_state_path, "status", "--porcelain=v1", "-z",
          "--untracked-files=all", "--", *roots
        )
        output.split("\0").reject(&:empty?).each do |entry|
          relative = entry[3..]
          next unless roots.any? { |root| relative == root || relative.start_with?("#{root}/") }

          if entry[0, 2] == "??"
            remove_path(File.join(@git_ops.hive_state_path, relative))
          else
            @git_ops.run_git!(
              "-C", @git_ops.hive_state_path, "restore", "--source=HEAD",
              "--staged", "--worktree", "--", relative
            )
          end
        end
      end

      def remove_path(path)
        stat = File.lstat(path)
        if stat.directory? && !stat.symlink?
          FileUtils.rm_rf(path)
        else
          File.unlink(path)
        end
      rescue Errno::ENOENT
        nil
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
          *@source_store.paths_for_terminal(source.source_event_id, state: "consumed"),
          *@source_store.paths_for_terminal(source.source_event_id, state: "quarantine")
        ].uniq
      end

      # Proposal event directories are append-only. Rollback therefore needs
      # only the original directory membership, not copies of every retained
      # event byte. Existing entries are never rewritten or removed here.
      class ImmutableAppendSnapshot
        def self.capture(path)
          new(path).tap(&:capture!)
        end

        def initialize(path)
          @path = File.expand_path(path)
          @existed = false
          @children = []
        end

        def capture!
          stat = File.lstat(@path)
          raise Error, "proposal append path is not a directory" unless stat.directory? && !stat.symlink?

          @existed = true
          @children = Dir.children(@path).sort
          self
        rescue Errno::ENOENT
          self
        end

        def restore!
          unless @existed
            remove(@path)
            return
          end

          Dir.children(@path).each do |child|
            remove(File.join(@path, child)) unless @children.include?(child)
          end
        rescue Errno::ENOENT
          nil
        end

        private

        def remove(path)
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
