require "digest"
require "json"
require "time"
require "hive/errors"
require "hive/config"
require "hive/markers"
require "hive/recovery"
require "hive/secret_scanner"
require "hive/task_projection/reader"
require "hive/agent_git_gate"
require "hive/worktree"
require "hive/review_pass"
require "hive/stages/review/orchestrator_owned"

module Hive
  # A task-local authorization is immutable intent; only fixed-completion
  # receipts spend it. Callers hold the task lock for every write. This reader
  # never clears a marker, schedules work, or creates a directory.
  class ReviewBudget
    DIGEST = /\A[0-9a-f]{64}\z/
    OID = /\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/
    GRANT_FILE = /\Areview-grant-([0-9a-f]{64})\.json\z/
    COMPLETION_FILE = /\Areview-completion-([0-9a-f]{64})-(\d{2,})\.json\z/
    PASS_FILE = Hive::ReviewPass::SUFFIX
    MAX_FILES = 4096
    MAX_ARTIFACT_BYTES = 1024 * 1024
    MAX_TOTAL_BYTES = 32 * 1024 * 1024
    EMPTY_CHAIN = Digest::SHA256.hexdigest("hive-review-budget-chain-v1")

    class Refused < Hive::UsageError
      attr_reader :reason, :remediation
      alias error_kind reason

      def initialize(reason, message, remediation: "Refresh operational status and inspect the named review evidence.")
        @reason = reason.to_s
        @remediation = remediation
        super(message)
      end
    end

    Snapshot = Data.define(
      :state, :reason, :remediation, :evidence_token, :evidence, :receipts,
      :completions, :granted, :spent, :remaining, :slot, :blocking_marker,
      :decision_id, :original_scope, :exhausted_pass
    ) do
      def eligible? = state == "eligible"
      def applicable? = %w[pending applied fixing verifying suspended exhausted].include?(state)
      def runnable? = %w[applied fixing verifying exhausted].include?(state)
      def [](key) = public_send(key)
    end

    def self.canonical(value)
      Hive::TaskProjection.canonical(value)
    end

    def self.digest(value)
      Digest::SHA256.hexdigest(JSON.generate(canonical(value)))
    end

    def self.normalize_decision(passes:, reason:)
      amount = if passes.is_a?(Integer)
        passes
      elsif passes.is_a?(String) && passes.match?(/\A[1-3]\z/)
        passes.to_i
      end
      unless amount && (1..3).cover?(amount)
        raise Refused.new("invalid_passes", "--passes must be an integer from 1 through 3")
      end
      unless reason.is_a?(String)
        raise Refused.new("invalid_reason", "--reason is required")
      end
      text = reason.dup.force_encoding(Encoding::UTF_8)
      unless text.valid_encoding?
        raise Refused.new("invalid_reason", "--reason must be valid UTF-8")
      end
      text = Hive::Recovery.canonical_wire_value(text.strip)
      if text.empty? || text.bytesize > 1024 || text.match?(/[\p{Cc}\p{Cf}]/)
        raise Refused.new("invalid_reason", "--reason must contain 1–1024 bytes without control characters")
      end
      if Hive::SecretScanner.match?(text, path: "review-grant-reason")
        raise Refused.new("invalid_reason", "--reason contains secret-shaped text; provide a non-sensitive explanation")
      end
      { passes: amount, reason: text }
    rescue Hive::SecretScanner::Unavailable
      raise Refused.new("secret_scan_unavailable", "reason validation is unavailable; repair the secret scanner and retry")
    end

    attr_reader :task, :project, :store

    def initialize(task:, project:, head: nil, worktree_path: nil, resume_evidence: nil, clock: -> { Time.now.utc })
      @task = task
      @project = project.to_s
      @head = head
      @worktree_path = worktree_path
      @resume_evidence = resume_evidence
      @clock = clock
      @store = Store.new(self)
    end

    def folder = File.expand_path(task.folder)
    def reviews = File.join(folder, "reviews")
    def audit_path = File.join(folder, "review-budget", "audit.jsonl")

    def present?
      store.names.any?
    end

    def observe
      evidence, records, completions = read_evidence
      original = records.first&.fetch("scope")
      if !records.empty? && (original != evidence.fetch("scope") ||
          records.first.fetch("task_generation") != evidence.fetch("task_generation"))
        return snapshot("expired", evidence, records, completions,
                        reason: "review_scope_changed", remediation: "Prior grants belong to an expired review scope; retained audit is at review-budget/audit.jsonl.")
      end
      if evidence.fetch("marker").fetch("name") == "review_complete" || !review_stage?
        return snapshot(records.empty? ? "unavailable" : "completed", evidence, records, completions,
                        reason: "review_completed", remediation: "This review has completed; prior allowance cannot attach to another review.")
      end
      unless records.empty?
        check_bound_artifacts!(records, completions, evidence)
        store.check_audit_anchor!(records, evidence.fetch("scope"))
        latest = records.last
        count = completions.count { |entry| entry.fetch("decision_id") == latest.fetch("decision_id") }
        remaining = records.sum { |entry| entry.fetch("amount") } - completions.length
        marker = evidence.fetch("marker")
        if marker == latest.fetch("evidence").fetch("marker") && count.zero?
          check_observation_binding!(latest, evidence)
          return snapshot("pending", evidence, records, completions)
        end
        if eligible_marker?(marker)
          validate_exhaustion!(evidence, records, completions)
          if remaining.zero? && evidence.fetch("pass") > completions.map { |entry| entry.fetch("pass") }.max.to_i
            return snapshot("eligible", evidence, records, completions)
          end
          return snapshot("suspended", evidence, records, completions,
                          reason: "grant_marker_changed", remediation: "The current marker differs from the granted observation; existing recovery rules must resolve it.")
        end
        if blocking_marker?(marker)
          return snapshot("suspended", evidence, records, completions,
                          reason: marker.fetch("attrs")["reason"].to_s,
                          remediation: "Use the existing recovery route for #{marker.fetch('name')}; the grant supplies budget only.")
        end
        if count.zero? && remaining.positive?
          check_observation_binding!(latest, evidence, marker: false)
        end
        state = if marker.fetch("name") == "review_working" && marker.fetch("attrs")["phase"] == "fix"
          "fixing"
        elsif remaining.zero?
          "verifying"
        else
          "applied"
        end
        return snapshot(state, evidence, records, completions)
      end
      store.check_audit_anchor!([], evidence.fetch("scope"))
      unless eligible_marker?(evidence.fetch("marker"))
        return snapshot("unavailable", evidence, [], [], reason: "not_final_fix_unverified",
                        remediation: "Only REVIEW_STALE reason=final_fix_unverified permits a fix-pass grant.")
      end
      validate_exhaustion!(evidence, [], [])
      snapshot("eligible", evidence, [], [])
    rescue Refused => error
      snapshot("refused", nil, [], [], reason: error.reason, remediation: "#{error.message}. #{error.remediation}")
    rescue SystemCallError, IOError, JSON::ParserError, ArgumentError, KeyError, TypeError => error
      snapshot("refused", nil, [], [], reason: "invalid_evidence", remediation: "Review evidence is unavailable (#{error.class}); inspect task artifacts and refresh.")
    end

    # A replay is identified by the old grant observation, before asking for a
    # still-present stale marker. It never allocates or clears anything.
    def replay(evidence_token:, passes:, reason:)
      decision = self.class.normalize_decision(passes: passes, reason: reason)
      token = valid_digest!(evidence_token, "evidence token")
      receipt = store.grants.find { |entry| entry.fetch("observation_digest") == token } || store.archived_grant(token)
      return nil unless receipt
      unless receipt.fetch("amount") == decision.fetch(:passes) && receipt.fetch("reason") == decision.fetch(:reason)
        raise Refused.new("decision_conflict", "this observation already has a different amount or reason")
      end
      receipt
    end

    def record_grant!(snapshot:, passes:, reason:, caller:, source:)
      decision = self.class.normalize_decision(passes: passes, reason: reason)
      existing = replay(evidence_token: snapshot.evidence_token, **decision)
      return existing if existing
      current = observe
      unless snapshot.eligible? && current.eligible? && current.evidence_token == snapshot.evidence_token
        raise Refused.new("stale_evidence", "review-grant evidence changed; refresh operational status")
      end
      caller = bounded_identity!(caller, "caller")
      source = bounded_identity!(source, "source")
      document = {
        "schema" => Store::GRANT_SCHEMA, "schema_version" => 1,
        "project" => project, "task" => task.slug.to_s, "task_id" => task.id.to_s,
        "task_generation" => current.evidence.fetch("task_generation"),
        "scope" => current.original_scope, "sequence" => current.receipts.length + 1,
        "observation_digest" => current.evidence_token, "evidence" => current.evidence,
        "previous_receipt_digest" => chain_digest(current.receipts, current.completions),
        "amount" => decision.fetch(:passes), "reason" => decision.fetch(:reason),
        "caller" => caller, "source" => source,
        "decision_id" => self.class.digest([ project, task.id.to_s, task.slug.to_s, current.evidence_token, decision ]),
        "recorded_at" => @clock.call.utc.iso8601(6)
      }
      receipt = store.write_grant!(document)
      reconcile_audit!(receipt)
      receipt
    end

    def reconcile_audit!(receipt)
      store.reconcile_audit!(receipt)
    end

    def record_expiry!(reason:)
      value = bounded_identity!(reason, "expiry reason")
      store.grants.map { |receipt| store.append_audit!(receipt, expiry_reason: value) }
    end

    # The coordinator uses this result under its task lock, and only clears
    # `pending`, with the complete recorded marker attrs. `applied` proves
    # the exact post-state; historical/changed never authorizes a clear.
    def application_state(receipt)
      current = observe
      return "historical" if %w[expired completed unavailable].include?(current.state)
      return "changed" if current.state == "refused" || current.original_scope != receipt.fetch("scope")
      return "historical" unless current.receipts.last&.fetch("decision_id") == receipt.fetch("decision_id")
      if current.state == "pending"
        current.evidence.fetch("marker") == receipt.fetch("evidence").fetch("marker") ? "pending" : "changed"
      elsif %w[applied fixing verifying].include?(current.state)
        "applied"
      elsif %w[eligible suspended exhausted].include?(current.state) &&
          current.completions.any? { |entry| entry.fetch("decision_id") == receipt.fetch("decision_id") }
        "historical"
      else
        "changed"
      end
    end

    def next_slot(snapshot: observe)
      return nil unless snapshot.runnable? && snapshot.remaining.positive?
      latest = snapshot.receipts.last
      return nil unless latest
      completed = snapshot.completions.count { |entry| entry.fetch("decision_id") == latest.fetch("decision_id") }
      { "decision_id" => latest.fetch("decision_id"), "slot" => completed + 1,
        "grant_sequence" => latest.fetch("sequence"), "observation_digest" => latest.fetch("observation_digest") }
    end

    # Recovery may clear a park only after the preserved work still binds the
    # original slot. This supplies evidence validation, never retry authority.
    def validate_resume!(snapshot: observe, reviewed_head: nil)
      if snapshot.state == "refused"
        raise Refused.new(snapshot.reason, snapshot.remediation)
      end
      return true unless snapshot.applicable? && snapshot.remaining.positive?

      latest = snapshot.receipts.last
      completed = snapshot.completions.select { |entry| entry.fetch("decision_id") == latest.fetch("decision_id") }
      proof = snapshot.evidence.fetch("resume_evidence")
      slot = completed.length + 1
      if proof.is_a?(Hash) && proof["grant_decision"] == latest.fetch("decision_id") &&
          proof["grant_slot"].to_s == slot.to_s && proof["pass"].to_s == snapshot.evidence.fetch("pass").to_s
        valid_oid!(proof["input_head"], "granted fix input HEAD")
        unless proof["phase"] == "fix" && proof["head"] == snapshot.evidence.fetch("head") &&
            proof["input_artifacts_digest"] == self.class.digest(snapshot.evidence.fetch("artifacts"))
          raise Refused.new("evidence_changed", "the incomplete granted fix HEAD or accepted findings changed")
        end
      elsif completed.empty?
        check_observation_binding!(latest, snapshot.evidence, marker: false)
      else
        pass = snapshot.evidence.fetch("pass")
        pending_findings = snapshot.evidence.fetch("artifacts").keys.any? do |name|
          Hive::ReviewPass.number(name) == pass && Hive::Stages::Review.reviewer_file?(name)
        end
        if pending_findings && pass > completed.last.fetch("pass") &&
            snapshot.evidence.fetch("head") != completed.last.fetch("head") &&
            snapshot.evidence.fetch("head") != reviewed_head
          raise Refused.new("evidence_changed", "the granted retry findings have no matching reviewed HEAD")
        end
      end
      true
    end

    # Failed attempts may have committed before parking. Keep the slot's
    # original input across retries so every partial commit is guardrailed.
    def fix_input_head(snapshot:)
      logical = next_slot(snapshot: snapshot)
      raise Refused.new("budget_exhausted", "no granted fix slot is available") unless logical

      proof = snapshot.evidence.fetch("resume_evidence")
      if proof.is_a?(Hash) && proof["grant_decision"] == logical.fetch("decision_id") &&
          proof["grant_slot"].to_s == logical.fetch("slot").to_s
        validate_resume!(snapshot: snapshot)
        valid_oid!(proof["input_head"], "granted fix input HEAD")
      else
        snapshot.evidence.fetch("head")
      end
    end

    # `snapshot` is captured immediately before Phase 4. The caller retains it
    # through a successful fix, including the guardrail approval route.
    def complete_fix!(snapshot:, pass:, head:)
      logical = next_slot(snapshot: snapshot)
      raise Refused.new("budget_exhausted", "no granted fix slot is available") unless logical
      evidence, receipts, completions = read_evidence
      unless review_stage? && evidence.fetch("marker").fetch("name") != "review_complete" &&
          evidence.fetch("scope") == snapshot.original_scope && evidence.fetch("task_generation") == snapshot.evidence.fetch("task_generation") &&
          receipts.map { |entry| entry.fetch("decision_id") } == snapshot.receipts.map { |entry| entry.fetch("decision_id") }
        raise Refused.new("stale_evidence", "review scope changed before granted fix completion")
      end
      existing = completions.find do |entry|
        entry.values_at("decision_id", "slot") == logical.values_at("decision_id", "slot")
      end
      if existing
        unless existing.fetch("head") == head && existing.fetch("pass") == pass
          raise Refused.new("completion_conflict", "a granted fix completion is permanently sealed")
        end
        store.append_audit!(receipts.last, completion: existing)
        return existing
      end
      unless evidence.fetch("artifacts") == snapshot.evidence.fetch("artifacts")
        raise Refused.new("stale_evidence", "accepted review artifacts changed before granted fix completion")
      end
      current = self.snapshot("applied", evidence, receipts, completions)
      unless next_slot(snapshot: current) == logical
        raise Refused.new("completion_conflict", "granted fix logical slot changed")
      end
      document = {
        "schema" => Store::COMPLETION_SCHEMA, "schema_version" => 1,
        "project" => project, "task" => task.slug.to_s, "task_id" => task.id.to_s,
        "task_generation" => snapshot.evidence.fetch("task_generation"),
        "scope" => snapshot.original_scope, "decision_id" => logical.fetch("decision_id"),
        "slot" => logical.fetch("slot"), "kind" => "fixed", "pass" => positive_integer!(pass, "pass"),
        "head" => valid_oid!(head, "completed fix HEAD"), "input_head" => fix_input_head(snapshot: snapshot),
        "input_artifacts" => snapshot.evidence.fetch("artifacts"),
        "previous_receipt_digest" => chain_digest(current.receipts, current.completions),
        "recorded_at" => @clock.call.utc.iso8601(6)
      }
      completion = store.write_completion!(document)
      store.append_audit!(receipts.last, completion: completion)
      completion
    end

    def chain_digest(grants, completions)
      chain_records(grants, completions).reduce(EMPTY_CHAIN) { |digest, entry| self.class.digest([ digest, entry ]) }
    end

    def chain_records(grants, completions)
      grants.flat_map do |grant|
        [ grant ] + completions.select { |entry| entry.fetch("decision_id") == grant.fetch("decision_id") }.sort_by { |entry| entry.fetch("slot") }
      end
    end

    def capture_custody = Custody.new(self)

    def verify_custody!(capture)
      capture.verify!
    end

    def valid_digest!(value, label)
      raise Refused.new("invalid_evidence", "#{label} must be a SHA-256 digest") unless value.is_a?(String) && DIGEST.match?(value)
      value
    end

    def valid_oid!(value, label)
      raise Refused.new("invalid_evidence", "#{label} is missing or invalid") unless value.is_a?(String) && OID.match?(value)
      value
    end

    def positive_integer!(value, label)
      raise Refused.new("invalid_evidence", "#{label} must be a positive integer") unless value.is_a?(Integer) && value.positive?
      value
    end

    def bounded_identity!(value, label)
      unless value.is_a?(String) && value.valid_encoding? && value.bytesize.between?(1, 256) && !value.match?(/[\p{Cc}\p{Cf}]/)
        raise Refused.new("invalid_evidence", "grant #{label} is invalid")
      end
      Hive::Recovery.canonical_wire_value(value)
    end

    private

    def snapshot(state, evidence, records, completions, reason: nil, remediation: nil)
      granted = records.sum { |entry| entry.fetch("amount") }
      spent = completions.length
      usable = !%w[expired completed refused unavailable].include?(state)
      remaining = usable ? granted - spent : 0
      Snapshot.new(state: state, reason: reason, remediation: remediation,
        evidence_token: state == "eligible" ? self.class.digest(evidence) : nil,
        evidence: evidence, receipts: records, completions: completions,
        granted: granted, spent: spent, remaining: remaining,
        slot: remaining.positive? ? { "decision_id" => records.last.fetch("decision_id"), "slot" => completions.count { |entry| entry.fetch("decision_id") == records.last.fetch("decision_id") } + 1 } : nil,
        blocking_marker: state == "suspended" ? evidence.fetch("marker") : nil,
        decision_id: records.last&.fetch("decision_id"),
        original_scope: records.first&.fetch("scope") || (evidence && evidence.fetch("scope")),
        exhausted_pass: evidence && evidence.fetch("pass"))
    end

    def read_evidence
      store.directory!(folder)
      marker = read_marker
      identity = { "project" => project, "task" => task.slug.to_s, "task_id" => task.id.to_s }
      if identity.values.any?(&:empty?)
        raise Refused.new("invalid_task_identity", "review grant requires a project, slug and stable task ID")
      end
      history = Hive::TaskProjection::Reader.new(task_folder: folder, task: task).read_bounded(marker: marker)
      unless history.current? && !history.journal_records.empty?
        raise Refused.new("invalid_task_history", history.diagnostics.first&.fetch("message", nil) || "task journal is unavailable")
      end
      epoch = history.projection.to_h.fetch("identity").fetch("task_generation")
      unless epoch.is_a?(Integer) && epoch >= 0
        raise Refused.new("invalid_task_history", "task input generation must be an authoritative integer")
      end
      artifacts = artifact_digests
      grants, completions = store.records
      scope = scope_evidence(history.journal_records, artifacts)
      pass = marker.attrs["pass"].to_s.match?(/\A\d+\z/) ? marker.attrs["pass"].to_i : 0
      pass = artifacts.keys.filter_map { |name| PASS_FILE.match(name)&.[](1)&.to_i }.max.to_i if pass.zero?
      worktree = worktree_evidence
      evidence = identity.merge("task_generation" => epoch, "marker" => marker_hash(marker),
        "head" => reviewed_head(worktree), "worktree" => worktree, "artifacts" => artifacts, "scope" => scope, "pass" => pass,
        "escalation_proof" => escalation_proof(artifacts, pass),
        "ownership" => history.projection.to_h.fetch("identity"),
        "resume_evidence" => resume_evidence(marker, history.journal_records),
        "receipt_chain_digest" => chain_digest(grants, completions))
      unless read_marker.raw == marker.raw && artifact_digests == artifacts && store.records == [ grants, completions ] && worktree_evidence == worktree && reviewed_head(worktree) == evidence.fetch("head")
        raise Refused.new("evidence_changed", "review evidence changed during observation; refresh operational status")
      end
      [ self.class.canonical(evidence), grants, completions ]
    end

    def read_marker
      bytes = store.read_regular(task.state_file, max_bytes: MAX_ARTIFACT_BYTES)
      Hive::Markers.current_from_content(bytes)
    end

    def artifact_digests
      return {} unless store.directory!(reviews, missing: true)
      names = Dir.children(reviews).select { |name| name.match?(PASS_FILE) }.sort
      raise Refused.new("evidence_limit", "too many current review artifacts") if names.length > MAX_FILES
      total = 0
      names.to_h do |name|
        bytes = store.read_regular(File.join(reviews, name), max_bytes: MAX_ARTIFACT_BYTES)
        total += bytes.bytesize
        raise Refused.new("evidence_limit", "current review artifacts exceed the bounded read limit") if total > MAX_TOTAL_BYTES
        [ name, Digest::SHA256.hexdigest(bytes) ]
      end
    end

    def scope_evidence(records, artifacts)
      transitions = records.select do |record|
        payload = record.fetch("payload")
        activity = payload["activity_kind"]
        target = payload["to_stage"].to_s
        from = payload["from_stage"].to_s
        (record["event_type"] == "operator_action" && (review_stage_string?(from) || review_stage_string?(target))) ||
          (%w[approval_recorded rejection_recorded decision_recorded].include?(activity) && !target.empty?) ||
          (activity == "stage_transition" && review_stage_string?(record["stage"]) && payload["transition"] == "completed")
      end
      first_pass = artifacts.keys.filter_map { |name| PASS_FILE.match(name)&.[](1)&.to_i }.min
      anchors = artifacts.select do |name, _|
        name.start_with?("fix-success-") && PASS_FILE.match(name)[1].to_i == first_pass
      end
      { "history_digest" => self.class.digest(transitions), "anchor_artifacts" => anchors,
        "first_pass" => first_pass }
    end

    def worktree_evidence
      return nil unless task.respond_to?(:project_root) && task.project_root
      pointer = Hive::Worktree.read_owned_pointer(folder, project_root: task.project_root,
        slug: task.slug, expected_root: Hive::Worktree.canonical_root(task.project_root))
      { "pointer" => self.class.canonical(pointer), "pointer_digest" => Digest::SHA256.hexdigest(store.read_regular(File.join(folder, "worktree.yml"), max_bytes: Hive::Worktree::STRICT_POINTER_MAX_BYTES)) }
    rescue Hive::WorktreeError => error
      raise Refused.new("worktree_unavailable", "review worktree ownership is unavailable: #{error.message}")
    end

    def reviewed_head(worktree)
      value = if @head.respond_to?(:call)
        @head.call
      elsif @head
        @head
      else
        path = worktree ? worktree.fetch("pointer").fetch("path") : @worktree_path || task.worktree_path
        result = Hive::AgentGitGate.read(path, :head_oid)
        raise Refused.new("worktree_unavailable", "review worktree HEAD cannot be read") unless result.success?
        result.stdout.strip
      end
      valid_oid!(value, "review worktree HEAD")
    rescue Hive::AgentGitGate::Error
      raise Refused.new("worktree_unavailable", "review worktree identity or HEAD is unavailable")
    end

    def resume_evidence(marker, records)
      supplied = @resume_evidence.respond_to?(:call) ? @resume_evidence.call : @resume_evidence
      return self.class.canonical(supplied) if supplied
      return self.class.canonical(marker.attrs) if %i[review_error review_working].include?(marker.name) && marker.attrs["phase"] == "fix" && marker.attrs["grant_decision"]
      record = records.reverse.find do |entry|
        entry["event_type"] == "activity_recorded" && entry.dig("payload", "activity_kind") == "recovery_recorded" && entry.dig("payload", "review_grant_resume").is_a?(Hash)
      end
      record && record.fetch("payload").fetch("review_grant_resume")
    end

    def review_stage? = review_stage_string?(task.stage_name.to_s)
    def review_stage_string?(value) = %w[review 6-review].include?(value) # coding-scoped: grants extend the coding review loop only.
    def marker_hash(marker) = self.class.canonical("name" => marker.name.to_s, "attrs" => marker.attrs, "raw" => marker.raw)
    def eligible_marker?(marker) = marker.fetch("name") == "review_stale" && marker.fetch("attrs")["reason"] == "final_fix_unverified"
    def blocking_marker?(marker) = !%w[none review_working].include?(marker.fetch("name"))

    def validate_exhaustion!(evidence, records, completions)
      pass = positive_integer!(evidence.fetch("pass"), "exhausted pass")
      raise Refused.new("missing_evidence", "exhausted review requires a preceding fixed HEAD receipt") if pass <= 1
      validate_admitted_exhaustion!(evidence, records, completions)
      artifacts = evidence.fetch("artifacts")
      reviewer_files = artifacts.keys.select do |name|
        PASS_FILE.match(name)[1].to_i == pass && Hive::Stages::Review.reviewer_file?(name)
      end
      raise Refused.new("missing_evidence", "missing reviewer findings for pass #{pass}") if reviewer_files.empty?
      escalation = "escalations-#{format('%02d', pass)}.md"
      raise Refused.new("missing_evidence", "missing reviews/#{escalation}") unless artifacts.key?(escalation)
      raise Refused.new("contradictory_evidence", "reviewer errors remain for pass #{pass}") if artifacts.key?("errors-#{format('%02d', pass)}.md")
      if artifacts.key?("fix-success-#{format('%02d', pass)}.md")
        raise Refused.new("contradictory_evidence", "exhausted pass already has a completion receipt")
      end
      highest = artifacts.keys.select { |name| Hive::Stages::Review.reviewer_file?(name) }.map { |name| PASS_FILE.match(name)[1].to_i }.max
      raise Refused.new("contradictory_evidence", "stale marker does not bind the latest reviewer pass") unless highest == pass
      predecessor = "fix-success-#{format('%02d', pass - 1)}.md"
      unless artifacts.key?(predecessor)
        raise Refused.new("missing_evidence", "missing reviews/#{predecessor}; current HEAD alone cannot prove the reviewed HEAD")
      end
      line = store.read_regular(File.join(reviews, predecessor), max_bytes: MAX_ARTIFACT_BYTES).lines.first.to_s
      head = line[/\bhead=([0-9a-f]{40}(?:[0-9a-f]{24})?)\b/, 1]
      kind = line[/\bkind=([a-z_]+)\b/, 1]
      unless head == evidence.fetch("head") && %w[fixed ci_repaired].include?(kind)
        raise Refused.new("head_changed", "reviews/#{predecessor} does not prove this exhausted review HEAD")
      end
      accepted = reviewer_files.sum do |name|
        store.read_regular(File.join(reviews, name), max_bytes: MAX_ARTIFACT_BYTES).lines.count do |line|
          Hive::Stages::Review.auto_fix_finding_line?(line)
        end
      end
      escalations_body = store.read_regular(File.join(reviews, escalation), max_bytes: MAX_ARTIFACT_BYTES)
      questions = escalations_body.split(/^\s*###\s+Q\d+\.\s*/).drop(1)
      if questions.empty?
        accepted += escalations_body.lines.count { |line| Hive::Stages::Review.auto_fix_finding_line?(line) }
        unanswered = escalations_body.scan(/^\s*-\s+\[\s*\]\s+/).length
      else
        answered = questions.count { |question| !question.split(/^\s*###\s+A\d+\.\s*/, 2).last.to_s.strip.empty? && question.match?(/^\s*###\s+A\d+\./) }
        accepted += answered
        unanswered = questions.length - answered
      end
      counters = evidence.fetch("marker").fetch("attrs")
      unless counters["accepted"].to_s.match?(/\A\d+\z/) && counters["escalations"].to_s.match?(/\A\d+\z/)
        raise Refused.new("missing_evidence", "final-fix marker lacks accepted/escalation counters")
      end
      if accepted != counters.fetch("accepted").to_i || unanswered != counters.fetch("escalations").to_i || (accepted.zero? && unanswered.zero?)
        raise Refused.new("contradictory_evidence", "accepted findings contradict the final-fix marker")
      end
      unless records.empty?
        if records.sum { |entry| entry.fetch("amount") } != completions.length
          raise Refused.new("budget_remaining", "the current grant is not exhausted; a new grant requires fresh final verification")
        end
      end
    end

    def validate_admitted_exhaustion!(evidence, records, completions)
      configured = task.respond_to?(:project_root) && task.project_root && Hive::Config.load(task.project_root).dig("review", "max_passes")
      ceiling = (configured || 3) + 1
      records.each do |receipt|
        ceiling = widen_ci_ceiling(ceiling, evidence.fetch("artifacts"))
        if receipt.fetch("evidence").fetch("pass") > ceiling
          raise Refused.new("contradictory_evidence", "grant observation pass has no admitted review history")
        end
        ceiling = [ ceiling, receipt.fetch("evidence").fetch("pass") + receipt.fetch("amount") ].max
        fixed = completions.select { |entry| entry.fetch("decision_id") == receipt.fetch("decision_id") }
        ceiling = [ ceiling, fixed.map { |entry| entry.fetch("pass") + 1 }.max.to_i ].max
      end
      ceiling = widen_ci_ceiling(ceiling, evidence.fetch("artifacts"))
      if evidence.fetch("pass") > ceiling
        raise Refused.new("contradictory_evidence", "exhausted review pass has no admitted fix, grant or CI-repair history")
      end
    end

    def widen_ci_ceiling(ceiling, artifacts)
      loop do
        name = "fix-success-#{format('%02d', ceiling)}.md"
        break unless artifacts.key?(name)
        line = store.read_regular(File.join(reviews, name), max_bytes: MAX_ARTIFACT_BYTES).lines.first.to_s
        break unless line.match?(/\bkind=ci_repaired\b/)
        ceiling += 1
      end
      ceiling
    end

    def check_bound_artifacts!(records, completions, evidence)
      records.each do |receipt|
        # Evidence at exhausted passes is retained: it is the accepted work
        # the operator authorized, so edits cannot silently rebind a grant.
        receipt.fetch("evidence").fetch("artifacts").each do |name, digest|
          next if name.start_with?("escalations-") && completions.any? { |entry| entry.fetch("decision_id") == receipt.fetch("decision_id") }
          next if permitted_escalation_answers?(receipt, evidence, name)
          unless evidence.fetch("artifacts")[name] == digest
            raise Refused.new("evidence_changed", "granted review artifact changed or disappeared: reviews/#{name}")
          end
        end
      end
    end

    def check_observation_binding!(receipt, evidence, marker: true)
      before = receipt.fetch("evidence")
      fields = %w[head artifacts scope task_generation worktree]
      fields << "marker" if marker
      matches = fields.all? do |key|
        before.fetch(key) == evidence.fetch(key) ||
          (key == "head" && !marker && partial_fix_head_bound?(receipt, evidence)) ||
          (key == "artifacts" && before.fetch("artifacts").keys == evidence.fetch("artifacts").keys &&
            before.fetch("artifacts").all? { |name, digest| evidence.fetch("artifacts")[name] == digest || permitted_escalation_answers?(receipt, evidence, name) })
      end
      unless matches
        raise Refused.new("evidence_changed", "preserved accepted findings or HEAD changed before the granted fix")
      end
    end

    def partial_fix_head_bound?(receipt, evidence)
      proof = evidence.fetch("resume_evidence")
      return false unless proof.is_a?(Hash)
      proof["grant_decision"] == receipt.fetch("decision_id") && proof["grant_slot"].to_s == "1" &&
        proof["input_head"] == receipt.fetch("evidence").fetch("head") && proof["head"] == evidence.fetch("head") &&
        proof["pass"].to_s == receipt.fetch("evidence").fetch("pass").to_s && proof["phase"] == "fix"
    end

    def escalation_proof(artifacts, pass)
      name = "escalations-#{format('%02d', pass)}.md"
      return nil unless artifacts.key?(name)

      bytes = store.read_regular(File.join(reviews, name), max_bytes: MAX_ARTIFACT_BYTES)
      unless Digest::SHA256.hexdigest(bytes) == artifacts.fetch(name)
        raise Refused.new("evidence_changed", "escalation evidence changed during observation")
      end
      EscalationProof.capture(name, bytes)
    end

    def permitted_escalation_answers?(receipt, evidence, name)
      original = receipt.fetch("evidence").fetch("escalation_proof")
      return false unless original && original.fetch("name") == name

      marker = evidence.fetch("marker")
      attrs = marker.fetch("attrs")
      proof = evidence.fetch("resume_evidence")
      waiting = marker.fetch("name") == "review_waiting" && attrs["pass"].to_s == receipt.fetch("evidence").fetch("pass").to_s
      fixing = proof.is_a?(Hash) && proof["phase"] == "fix" &&
        proof["grant_decision"] == receipt.fetch("decision_id") && proof["pass"].to_s == receipt.fetch("evidence").fetch("pass").to_s
      return false unless waiting || fixing

      current = escalation_proof(evidence.fetch("artifacts"), receipt.fetch("evidence").fetch("pass"))
      current && EscalationProof.fills_only?(original, current)
    end
  end
end

require "hive/review_budget/escalation_proof"
require "hive/review_budget/store"
require "hive/review_budget/custody"
