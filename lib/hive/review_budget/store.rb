require "hive/atomic_file"

module Hive
  class ReviewBudget
    # The only persisted authority is this write-once receipt chain. The
    # bounded audit tail detects missing/replaced current receipts and records
    # decisions across resets; it is never used to reconstruct active grants.
    class Store
      GRANT_SCHEMA = "hive-review-budget-grant".freeze
      COMPLETION_SCHEMA = "hive-review-budget-completion".freeze
      AUDIT_SCHEMA = "hive-review-budget-audit".freeze
      MAX_BYTES = 256 * 1024
      MAX_AUDIT_TAIL = 4 * 1024 * 1024
      GRANT_KEYS = %w[amount caller decision_id evidence observation_digest previous_receipt_digest project recorded_at reason schema schema_version scope sequence source task task_generation task_id].freeze
      COMPLETION_KEYS = %w[decision_id head input_artifacts input_head kind pass previous_receipt_digest project recorded_at schema schema_version scope slot task task_generation task_id].freeze
      AUDIT_KEYS = %w[amount caller decision_id event observation_digest project reason receipt_digest recorded_at schema schema_version scope source task task_generation task_id].freeze

      class StrictHash < Hash
        def []=(key, value)
          raise JSON::ParserError, "duplicate review-budget key" if key?(key)
          super
        end
      end

      def initialize(budget)
        @budget = budget
      end

      def names
        return [] unless directory!(@budget.reviews, missing: true)
        candidates = Dir.children(@budget.reviews).select do |name|
          name.start_with?("review-grant-", "review-completion-")
        end
        if candidates.any? { |name| !name.match?(GRANT_FILE) && !name.match?(COMPLETION_FILE) }
          raise Refused.new("unsafe_state", "malformed controller review-budget receipt filename")
        end
        raise Refused.new("evidence_limit", "too many current review-budget receipts") if candidates.length > MAX_FILES
        candidates.sort
      end

      def records
        documents = names.map do |name|
          document = parse(read_regular(File.join(@budget.reviews, name), max_bytes: MAX_BYTES, private: true))
          validate!(document, name)
          document
        end
        grants = documents.select { |entry| entry["schema"] == GRANT_SCHEMA }.sort_by { |entry| entry.fetch("sequence") }
        completions = documents.select { |entry| entry["schema"] == COMPLETION_SCHEMA }
        validate_chain!(grants, completions)
        [grants, completions.sort_by { |entry| [grants.index { |grant| grant.fetch("decision_id") == entry.fetch("decision_id") }, entry.fetch("slot")] }]
      end

      def grants = records.first

      def archived_grant(token)
        archive = File.join(@budget.reviews, "archive")
        return nil unless directory!(archive, missing: true)
        directories = Dir.children(archive).sort
        raise Refused.new("evidence_limit", "too many review archives for bounded decision replay") if directories.length > MAX_FILES
        matches = directories.filter_map do |name|
          directory = File.join(archive, name)
          directory!(directory)
          path = File.join(directory, "review-grant-#{token}.json")
          next unless File.exist?(path) || File.symlink?(path)
          document = parse(read_regular(path, max_bytes: MAX_BYTES, private: true))
          validate!(document, File.basename(path))
          document
        end
        if matches.length > 1 && matches.uniq.length != 1
          raise Refused.new("unsafe_state", "archived grant decision is ambiguous")
        end
        matches.first
      end

      def write_grant!(document)
        write_once!("review-grant-#{document.fetch('observation_digest')}.json", document)
      end

      def write_completion!(document)
        write_once!("review-completion-#{document.fetch('decision_id')}-#{format('%02d', document.fetch('slot'))}.json", document)
      end

      def directory!(path, missing: false, private: false)
        # Check every existing parent, rather than trusting a no-follow open
        # of the final file through a substituted parent symlink.
        components = File.expand_path(path).split(File::SEPARATOR).reject(&:empty?)
        current = File::SEPARATOR
        components.each do |component|
          current = File.join(current, component)
          stat = File.lstat(current)
          unless stat.directory? && !stat.symlink?
            raise Refused.new("unsafe_state", "review-budget parent must be a real directory: #{component}")
          end
          if current == path && private && (stat.mode & 0o077) != 0
            raise Refused.new("unsafe_state", "review-budget directory must be private")
          end
        end
        true
      rescue Errno::ENOENT
        return false if missing
        raise Refused.new("missing_evidence", "review-budget directory is missing")
      end

      def read_regular(path, max_bytes:, private: false)
        directory!(File.dirname(path))
        stat = File.lstat(path)
        raise Refused.new("unsafe_state", "review-budget evidence must be a regular file: #{File.basename(path)}") unless stat.file? && !stat.symlink?
        File.open(path, File::RDONLY | File::NOFOLLOW) do |file|
          opened = file.stat
          unless opened.file? && opened.dev == stat.dev && opened.ino == stat.ino
            raise Refused.new("unsafe_state", "review-budget evidence changed while opening")
          end
          if private && (opened.mode & 0o077) != 0
            raise Refused.new("unsafe_state", "review-budget receipt must be private")
          end
          bytes = file.read(max_bytes + 1)
          raise Refused.new("evidence_limit", "review-budget evidence exceeds its bounded read limit") if bytes.bytesize > max_bytes
          bytes
        end
      rescue Errno::ENOENT
        raise Refused.new("missing_evidence", "missing #{File.basename(path)}")
      rescue Errno::ELOOP
        raise Refused.new("unsafe_state", "review-budget symlink refused")
      end

      def append_audit!(receipt, expiry_reason: nil, completion: nil)
        # Verify the intact receipt before audit repair; audit bytes alone can
        # never recreate a deleted authorization.
        matching = grants.find { |entry| entry.fetch("decision_id") == receipt.fetch("decision_id") } || archived_grant(receipt.fetch("observation_digest"))
        raise Refused.new("unsafe_state", "grant receipt missing or replaced before audit reconciliation") unless matching == receipt
        ensure_directory!(@budget.folder)
        ensure_directory!(File.dirname(@budget.audit_path), private: true)
        entry = audit_entry(receipt)
        entry = entry.merge("event" => "expiry", "expiry_reason" => expiry_reason) if expiry_reason
        if completion
          unless records.last.include?(completion) && completion.fetch("decision_id") == receipt.fetch("decision_id")
            raise Refused.new("unsafe_state", "fixed completion missing before audit reconciliation")
          end
          entry = entry.merge("event" => "fixed", "completion_slot" => completion.fetch("slot"), "completion_digest" => ReviewBudget.digest(completion))
        end
        line = JSON.generate(ReviewBudget.canonical(entry)) << "\n"
        entries, torn, size = audit_tail
        if torn && !line.start_with?(torn)
          raise Refused.new("unsafe_state", "review-budget audit has an unrelated torn final entry")
        end
        existing = entries.find { |item| item.fetch("decision_id") == receipt.fetch("decision_id") && item.fetch("event") == entry.fetch("event") && item["completion_slot"] == entry["completion_slot"] }
        if existing && existing != entry
          raise Refused.new("decision_conflict", "review-budget audit conflicts with its immutable grant")
        end
        flags = File::WRONLY | File::CREAT | File::NOFOLLOW
        File.open(@budget.audit_path, flags, 0o600) do |file|
          unless file.stat.file? && (file.stat.mode & 0o077).zero? && file.stat.size == size
            raise Refused.new("unsafe_state", "review-budget audit identity changed")
          end
          if torn
            file.truncate(size - torn.bytesize)
            file.flush
            file.fsync
          end
          unless existing
            file.seek(0, IO::SEEK_END)
            file.write(line)
            file.flush
            file.fsync
          end
        end
        Hive::AtomicFile.fsync_directory(File.dirname(@budget.audit_path))
        entry
      end

      def reconcile_audit!(receipt)
        completed = records.last.select { |entry| entry.fetch("decision_id") == receipt.fetch("decision_id") }
        _, torn, = audit_tail
        if torn
          match = completed.find do |completion|
            entry = audit_entry(receipt).merge("event" => "fixed", "completion_slot" => completion.fetch("slot"), "completion_digest" => ReviewBudget.digest(completion))
            JSON.generate(ReviewBudget.canonical(entry)).concat("\n").start_with?(torn)
          end
          append_audit!(receipt, completion: match) if match
        end
        append_audit!(receipt)
        completed.each { |completion| append_audit!(receipt, completion: completion) }
      end

      def check_audit_anchor!(grants, scope)
        entries, torn, = audit_tail
        # Pending receipt/audit interruption is reconciled by the coordinator;
        # a torn entry is never counted as another decision.
        relevant = entries.reverse.find { |entry| entry.fetch("scope") == scope && entry.fetch("event") == "grant" }
        return unless relevant
        receipt = grants.find { |item| item.fetch("decision_id") == relevant.fetch("decision_id") }
        unless receipt && ReviewBudget.digest(receipt) == relevant.fetch("receipt_digest")
          raise Refused.new("unsafe_state", "current review-budget grant is missing or replaced; audit cannot reactivate it")
        end
        completions = records.last
        entries.select { |entry| entry.fetch("event") == "fixed" && entry.fetch("scope") == scope }.each do |entry|
          completion = completions.find { |item| item.values_at("decision_id", "slot") == entry.values_at("decision_id", "completion_slot") }
          unless completion && ReviewBudget.digest(completion) == entry.fetch("completion_digest")
            raise Refused.new("unsafe_state", "fixed completion is missing or replaced; its logical slot remains sealed")
          end
        end
        if torn
          candidates = grants.flat_map do |grant|
            [audit_entry(grant)] + completions.select { |completion| completion.fetch("decision_id") == grant.fetch("decision_id") }.map do |completion|
              audit_entry(grant).merge("event" => "fixed", "completion_slot" => completion.fetch("slot"), "completion_digest" => ReviewBudget.digest(completion))
            end
          end
          unless candidates.any? { |entry| JSON.generate(ReviewBudget.canonical(entry)).concat("\n").start_with?(torn) }
            raise Refused.new("unsafe_state", "review-budget audit has an unrelated torn final entry")
          end
        end
      end

      private

      def parse(bytes)
        JSON.parse(bytes, object_class: StrictHash, allow_duplicate_key: false)
      rescue JSON::ParserError
        raise Refused.new("unsafe_state", "review-budget receipt is malformed JSON")
      end

      def validate!(document, name)
        grant = name.match?(GRANT_FILE)
        keys = grant ? GRANT_KEYS : COMPLETION_KEYS
        schema = grant ? GRANT_SCHEMA : COMPLETION_SCHEMA
        unless document.is_a?(Hash) && document.keys.sort == keys.sort && document["schema"] == schema && document["schema_version"] == 1 &&
            document["project"] == @budget.project && document["task"] == @budget.task.slug.to_s && document["task_id"] == @budget.task.id.to_s &&
            document["task_generation"].is_a?(Integer) && document["task_generation"] >= 0
          raise Refused.new("unsafe_state", "review-budget receipt has an invalid version, key set or task identity")
        end
        @budget.valid_digest!(document.fetch("decision_id"), "decision ID")
        @budget.valid_digest!(document.fetch("previous_receipt_digest"), "preceding receipt digest")
        Time.iso8601(document.fetch("recorded_at"))
        scope = document.fetch("scope")
        unless scope.is_a?(Hash) && scope.keys.sort == %w[anchor_artifacts first_pass history_digest] && scope.fetch("first_pass").is_a?(Integer)
          raise Refused.new("unsafe_state", "review-budget original scope is invalid")
        end
        @budget.valid_digest!(scope.fetch("history_digest"), "scope history digest")
        validate_artifacts!(scope.fetch("anchor_artifacts"))
        grant ? validate_grant!(document, name) : validate_completion!(document, name)
      rescue ArgumentError, TypeError, KeyError
        raise Refused.new("unsafe_state", "review-budget receipt fields are malformed")
      end

      def validate_grant!(document, name)
        @budget.positive_integer!(document.fetch("sequence"), "grant sequence")
        unless document.fetch("amount").is_a?(Integer) && (1..3).cover?(document.fetch("amount"))
          raise Refused.new("unsafe_state", "review-budget amount is invalid")
        end
        text = document.fetch("reason")
        unless text.is_a?(String) && text.valid_encoding? && text.bytesize.between?(1, 1024) && text == text.strip && !text.match?(/[\p{Cc}\p{Cf}]/)
          raise Refused.new("unsafe_state", "review-budget reason is invalid")
        end
        %w[caller source].each { |key| @budget.bounded_identity!(document.fetch(key), key) }
        token = @budget.valid_digest!(document.fetch("observation_digest"), "grant observation")
        evidence = document.fetch("evidence")
        unless name == "review-grant-#{token}.json" && evidence.is_a?(Hash) &&
            evidence.keys.sort == %w[artifacts head marker ownership pass project receipt_chain_digest resume_evidence scope task task_generation task_id worktree] &&
            ReviewBudget.digest(evidence) == token && evidence.fetch("scope") == document.fetch("scope") &&
            evidence.fetch("task_generation") == document.fetch("task_generation") &&
            evidence.values_at("project", "task", "task_id") == document.values_at("project", "task", "task_id")
          raise Refused.new("unsafe_state", "review-budget observation binding is invalid")
        end
        validate_artifacts!(evidence.fetch("artifacts"))
        @budget.valid_oid!(evidence.fetch("head"), "reviewed HEAD")
        @budget.valid_digest!(evidence.fetch("receipt_chain_digest"), "observation receipt chain")
        @budget.positive_integer!(evidence.fetch("pass"), "exhausted pass")
        marker = evidence.fetch("marker")
        unless marker.is_a?(Hash) && marker.keys.sort == %w[attrs name raw] && marker.fetch("attrs").is_a?(Hash) &&
            marker.fetch("name") == "review_stale" && marker.fetch("attrs")["reason"] == "final_fix_unverified" &&
            Hive::Markers.current_from_content(marker.fetch("raw")).attrs == marker.fetch("attrs")
          raise Refused.new("unsafe_state", "review-budget bound marker is invalid")
        end
        expected_id = ReviewBudget.digest([document.fetch("project"), document.fetch("task_id"), document.fetch("task"), token,
          { passes: document.fetch("amount"), reason: document.fetch("reason") }])
        raise Refused.new("unsafe_state", "review-budget decision identity is invalid") unless expected_id == document.fetch("decision_id")
      end

      def validate_completion!(document, name)
        slot = @budget.positive_integer!(document.fetch("slot"), "fix slot")
        @budget.positive_integer!(document.fetch("pass"), "fix pass")
        @budget.valid_oid!(document.fetch("head"), "fixed HEAD")
        @budget.valid_oid!(document.fetch("input_head"), "fix input HEAD")
        validate_artifacts!(document.fetch("input_artifacts"))
        unless document.fetch("kind") == "fixed" && name == "review-completion-#{document.fetch('decision_id')}-#{format('%02d', slot)}.json"
          raise Refused.new("unsafe_state", "review-budget completion identity is invalid")
        end
      end

      def validate_artifacts!(artifacts)
        unless artifacts.is_a?(Hash) && artifacts.length <= MAX_FILES && artifacts.all? { |name, digest| name.is_a?(String) && !name.include?("/") && name.match?(PASS_FILE) && digest.is_a?(String) && digest.match?(DIGEST) }
          raise Refused.new("unsafe_state", "review-budget artifact digests are invalid")
        end
      end

      def validate_chain!(grants, completions)
        ids = grants.map { |entry| entry.fetch("decision_id") }
        if ids.uniq.length != ids.length || completions.any? { |entry| !ids.include?(entry.fetch("decision_id")) }
          raise Refused.new("unsafe_state", "review-budget completion has no immutable grant")
        end
        previous = EMPTY_CHAIN
        grants.each_with_index do |grant, index|
          unless grant.fetch("sequence") == index + 1 && grant.fetch("previous_receipt_digest") == previous && grant.fetch("evidence").fetch("receipt_chain_digest") == previous
            raise Refused.new("unsafe_state", "review-budget receipt chain is missing, replaced or out of order")
          end
          previous = ReviewBudget.digest([previous, grant])
          fixed = completions.select { |entry| entry.fetch("decision_id") == grant.fetch("decision_id") }.sort_by { |entry| entry.fetch("slot") }
          fixed.each_with_index do |completion, slot_index|
            unless completion.fetch("slot") == slot_index + 1 && completion.fetch("slot") <= grant.fetch("amount") &&
                completion.fetch("previous_receipt_digest") == previous && completion.fetch("scope") == grant.fetch("scope") &&
                completion.fetch("task_generation") == grant.fetch("task_generation")
              raise Refused.new("unsafe_state", "review-budget fix completion chain is invalid")
            end
            previous = ReviewBudget.digest([previous, completion])
          end
          if index < grants.length - 1 && fixed.length != grant.fetch("amount")
            raise Refused.new("unsafe_state", "a later review grant precedes exhausted fixed slots")
          end
        end
      end

      def write_once!(name, document)
        validate!(ReviewBudget.canonical(document), name)
        bytes = JSON.generate(ReviewBudget.canonical(document)) << "\n"
        raise Refused.new("evidence_limit", "review-budget receipt exceeds its byte limit") if bytes.bytesize > MAX_BYTES
        ensure_directory!(@budget.folder)
        ensure_directory!(@budget.reviews, private: true)
        path = File.join(@budget.reviews, name)
        begin
          File.open(path, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) do |file|
            file.write(bytes)
            file.flush
            file.fsync
          end
          Hive::AtomicFile.fsync_directory(@budget.reviews)
        rescue Errno::EEXIST
          unless read_regular(path, max_bytes: MAX_BYTES, private: true) == bytes
            raise Refused.new("decision_conflict", "review-budget receipt is immutable and already differs")
          end
        end
        parse(read_regular(path, max_bytes: MAX_BYTES, private: true))
      end

      def ensure_directory!(path, private: false)
        begin
          Dir.mkdir(path, private ? 0o700 : 0o755)
          Hive::AtomicFile.fsync_directory(File.dirname(path))
        rescue Errno::EEXIST
          directory!(path)
        end
        # reviews/ already exists in pre-feature tasks. Making that existing
        # controller-artifact directory private does not alter its contents.
        File.chmod(0o700, path) if private
        directory!(path, private: private)
      end

      def audit_entry(receipt)
        { "schema" => AUDIT_SCHEMA, "schema_version" => 1, "event" => "grant",
          "decision_id" => receipt.fetch("decision_id"), "observation_digest" => receipt.fetch("observation_digest"),
          "receipt_digest" => ReviewBudget.digest(receipt), "scope" => receipt.fetch("scope"),
          "project" => receipt.fetch("project"), "task" => receipt.fetch("task"), "task_id" => receipt.fetch("task_id"),
          "task_generation" => receipt.fetch("task_generation"), "amount" => receipt.fetch("amount"),
          "reason" => receipt.fetch("reason"), "caller" => receipt.fetch("caller"), "source" => receipt.fetch("source"),
          "recorded_at" => receipt.fetch("recorded_at") }
      end

      def audit_tail
        path = @budget.audit_path
        return [[], nil, 0] unless directory!(File.dirname(path), missing: true, private: true)
        stat = File.lstat(path)
        unless stat.file? && !stat.symlink? && (stat.mode & 0o077).zero?
          raise Refused.new("unsafe_state", "review-budget audit must be a private regular file")
        end
        bytes = File.open(path, File::RDONLY | File::NOFOLLOW) do |file|
          unless file.stat.ino == stat.ino && file.stat.dev == stat.dev
            raise Refused.new("unsafe_state", "review-budget audit changed while opening")
          end
          file.seek([stat.size - MAX_AUDIT_TAIL, 0].max)
          file.read(MAX_AUDIT_TAIL + 1)
        end
        bytes = bytes.split("\n", 2).last.to_s if stat.size > MAX_AUDIT_TAIL
        torn = bytes.empty? || bytes.end_with?("\n") ? nil : bytes.split("\n", -1).last
        lines = bytes.lines
        lines.pop if torn
        entries = lines.map do |line|
          value = parse(line)
          extra = case value.is_a?(Hash) && value["event"]
          when "expiry" then ["expiry_reason"]
          when "fixed" then %w[completion_digest completion_slot]
          else []
          end
          expected_keys = AUDIT_KEYS + extra
          unless value.is_a?(Hash) && value.keys.sort == expected_keys.sort && value["schema"] == AUDIT_SCHEMA && value["schema_version"] == 1 && %w[grant expiry fixed].include?(value["event"]) &&
              value["project"] == @budget.project && value["task"] == @budget.task.slug.to_s && value["task_id"] == @budget.task.id.to_s &&
              value["decision_id"].is_a?(String) && value["decision_id"].match?(DIGEST) && value["receipt_digest"].is_a?(String) && value["receipt_digest"].match?(DIGEST)
            raise Refused.new("unsafe_state", "review-budget audit entry is invalid")
          end
          value
        end
        [entries, torn, stat.size]
      rescue Errno::ENOENT
        [[], nil, 0]
      end
    end
  end
end
