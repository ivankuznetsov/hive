require "base64"
require "json"
require "open3"
require "shellwords"
require "time"
require "hive/secret_patterns"

module Hive
  # Durable, lossless marker evidence. Projection is local: it never consults
  # GitHub or scans Git history. Tokens belong to the current action producer.
  module ReviewPublicationRecovery
    VERSION = "1".freeze
    FIELDS = %w[worktree branch pr_url pr_number pr_state is_draft local_head remote_head
                publication verification unpushed_shas candidate_shas classification failure_reason
                push_command verification_recipe observed_at ready_command origin_reason reviewer_files unavailable_fields local_ci hosted_ci local_ci_head hosted_ci_head recovery_reason].freeze
    OID = /\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/
    MAX_BYTES = 48 * 1024
    module_function

    def encode(evidence)
      unavailable = []
      result = evidence.each_with_object({ "rp_version" => VERSION }) do |(key, value), attrs|
        next unless FIELDS.include?(key.to_s)
        json = JSON.generate(value)
        if json.bytesize > MAX_BYTES
          unavailable << key.to_s
          json = "null"
        end
        attrs["rp_#{key}"] = Base64.urlsafe_encode64(json, padding: false)
      end
      unless unavailable.empty?
        result["rp_unavailable_fields"] = Base64.urlsafe_encode64(JSON.generate(unavailable), padding: false)
      end
      result
    end

    def decode(attrs)
      return nil unless attrs["rp_version"]
      return { "publication" => "unknown", "failure_reason" => "unsupported_evidence_version" } unless attrs["rp_version"] == VERSION

      FIELDS.each_with_object({}) do |key, out|
        encoded = attrs["rp_#{key}"]
        next unless encoded
        raise ArgumentError if encoded.bytesize > MAX_BYTES * 2
        value = JSON.parse(Base64.urlsafe_decode64(encoded))
        valid = case key
        when "unpushed_shas", "candidate_shas"
          value.nil? || (value.is_a?(Array) && value.size <= 256 && value.all? { |oid| oid.is_a?(String) && oid.match?(OID) })
        when "unavailable_fields"
          value.is_a?(Array) && value.size <= FIELDS.size && value.all? { |v| FIELDS.include?(v) }
        when "reviewer_files"
          value.is_a?(Array) && value.size <= 100 && value.all? { |v| v.is_a?(String) && v.match?(%r{\Areviews/[^/\x00-\x1f]+\.md\z}) }
        when "is_draft" then value.nil? || value == true || value == false
        when "pr_number" then value.nil? || (value.is_a?(Integer) && value.positive?)
        when "publication" then %w[unpublished published unknown not_applicable].include?(value)
        when "verification" then %w[pending failed verified].include?(value)
        else value.nil? || value.is_a?(String)
        end
        raise ArgumentError unless valid
        out[key] = value
      end
    rescue ArgumentError, JSON::ParserError
      { "publication" => "unknown", "failure_reason" => "invalid_publication_evidence" }
    end

    # Explicit PR reference, never origin/default..HEAD. Delivery ancestry is
    # separate from publication and is supplied by the closure caller.
    def classify(worktree:, reference_oid:, delivered_heads: [], head: "HEAD")
      local = git(worktree, "rev-parse", "--verify", "#{head}^{commit}")&.strip
      reference = reference_oid.to_s.downcase
      candidates = local&.match?(OID) ? [ local ] : []
      unknown = { "classification" => "unknown", "unpushed_shas" => nil,
                  "candidate_shas" => candidates, "failure_reason" => "pr_reference_unavailable" }
      return unknown unless reference.match?(OID) && local&.match?(OID)
      resolved = git(worktree, "rev-parse", "--verify", "#{reference}^{commit}")&.strip
      return unknown unless resolved == reference

      commits = git(worktree, "rev-list", "--max-count=257", "--reverse", "#{reference}..#{local}")
      return unknown unless commits
      shas = commits.lines.map(&:strip)
      return unknown.merge("failure_reason" => "commit_evidence_exceeds_bound") if shas.size > 256
      ancestor = git(worktree, "merge-base", "--is-ancestor", reference, local)
      delivered = Array(delivered_heads).any? do |oid|
        oid.to_s.match?(OID) && git(worktree, "merge-base", "--is-ancestor", local, oid)
      end
      { "classification" => local == reference ? "equal" : ancestor ? "ahead" : "divergent",
        "unpushed_shas" => shas, "candidate_shas" => [], "failure_reason" => nil,
        "head_delivered" => !!delivered }
    end

    def git(path, *args)
      out, _err, status = Open3.capture3("git", "-C", path, *args)
      out if status.success?
    rescue SystemCallError, IOError
      nil
    end

    def retry_recipe(target:, worktree:)
      # Refresh, select exactly one canonical retry, then exec without shell
      # interpolation. The executor rejects any change since this snapshot.
      program = <<~'RUBY'.strip
        d=JSON.parse(STDIN.read); abort "status unavailable" unless d["ok"]==true
        rows=Array(d["tasks"]).select{|r| r.dig("identity","project").to_s+":"+r.dig("identity","slug").to_s==ARGV.fetch(0)}
        abort "task missing or ambiguous" unless rows.one?
        a=rows.first["action"]
        abort "workflow.retry is ineligible; use explicit operator recovery" unless a && a["action_id"]=="workflow.retry" && a["target"]==ARGV[0] && a["observation_token"].to_s.match?(/\A[0-9a-f]{64}\z/)
        exec("hive","act","workflow.retry",ARGV[0],"--observation",a.fetch("observation_token"),"--json")
      RUBY
      "cd #{Shellwords.escape(worktree)} && hive status --operational --json | ruby -rjson -e #{Shellwords.escape(program)} -- #{Shellwords.escape(target)}"
    end

    def lines(evidence)
      return [] unless evidence
      labels = { "publication" => "Publication", "verification" => "Verification", "local_ci" => "Local CI", "hosted_ci" => "Hosted CI", "local_ci_head" => "Last local CI head", "hosted_ci_head" => "Last hosted CI head", "unavailable_fields" => "Fields unavailable (bounded or redacted evidence)", "local_head" => "Local head",
        "remote_head" => "Observed PR head", "observed_at" => "Observed at", "worktree" => "Worktree", "branch" => "Branch",
        "failure_reason" => "Failure", "unpushed_shas" => "Commits absent from PR", "candidate_shas" => "Local candidates",
        "remediation" => "Remediation", "push_command" => "Push", "retry_command" => "Current retry",
        "verification_recipe" => "Refresh and retry (refuses ineligible actions)", "recovery_guidance" => "Recovery", "recovery_reason" => "Recovery command unavailable",
        "readiness_guidance" => "Draft readiness prerequisites", "ready_command" => "Conditional manual ready" }
      labels.filter_map do |key, label|
        value = evidence[key]
        next if value.nil? || value == "" || value == []
        "#{label}: #{value.is_a?(Array) ? value.join(', ') : value}"
      end
    end

    def project(attrs, action: nil, marker: nil)
      evidence = decode(attrs)
      if !evidence && marker.to_s.match?(/\Areview_(?:complete|error|stale|ci_stale|waiting)\z/)
        evidence = { "publication" => "unknown", "verification" => "pending", "failure_reason" => "legacy_publication_evidence_unavailable" }
      end
      return nil unless evidence
      result = evidence.dup
      result.keys.each do |key|
        value = result[key]
        if value.is_a?(String)
          redacted = Hive::SecretPatterns.redact(value).gsub(/[\x00-\x08\x0b-\x1f\x7f]/, "")
          if key.end_with?("command", "recipe") && (value.bytesize > MAX_BYTES || redacted != value)
            result[key] = nil
            result["unavailable_fields"] = (Array(result["unavailable_fields"]) + [ key ]).uniq
          else
            result[key] = redacted
          end
        end
      end
      result["retry_command"] = if action && action["action_id"] == "workflow.retry"
        Shellwords.join([ "hive", "act", "workflow.retry", action.fetch("target"),
                          "--observation", action.fetch("observation_token"), "--json" ])
      end
      if attrs["reason"] == "final_fix_unverified" || evidence["origin_reason"] == "final_fix_unverified"
        suffix = format("%02d", attrs["pass"].to_i)
        result["remediation"] = "Resolve escalations=#{attrs['escalations'].to_i} and accepted=#{attrs['accepted'].to_i} findings in #{Array(evidence["reviewer_files"]).empty? ? "reviews/*-#{suffix}.md (reviewer file list unavailable)" : evidence["reviewer_files"].join(", ")}. Commit fixes locally before explicit operator/coordinator verification retry. Editing review checkboxes does not apply fixes. Raising review.max_passes explicitly authorizes a changed repair budget."
      else
        result["remediation"] = case evidence["publication"]
        when "published"
          evidence["verification"] == "verified" ?
            "Exact published head verified. Continue through the normal workflow to finalize." :
            "Published head retained. Resolve the reported review, CI or infrastructure failure before retrying exact-head verification."
        when "unpublished"
          "Local commits are retained. Resolve the publication failure, verify repository identity, then publish and retry verification."
        when "not_applicable"
          "Publication is not applicable to this review."
        else
          "Publication is unknown. Inspect the PR branch and reconcile divergence or identity failures before another push."
        end
      end
      result["recovery_guidance"] = result["retry_command"] ? "Use the current observation-bound workflow.retry action." :
        "Routine retry is ineligible. After remediation, select this task in hive tui and press r to submit an explicit review retry through the existing recovery coordinator."
      if evidence["verification"] == "verified"
        %w[push_command verification_recipe retry_command recovery_guidance].each { |key| result.delete(key) }
      end
      unless evidence["is_draft"] == true && evidence["pr_state"] == "OPEN"
        result.delete("ready_command")
        result.delete("readiness_guidance")
      end
      if evidence["is_draft"] == true && evidence["pr_state"] == "OPEN"
        result["readiness_guidance"] = "Use normal finalize by default: it owns scan-before-ready and pr_observed. Manual ready requires confirmed publication, successful exact-head verification, and a successful current secret scan. Manual ready bypasses Hive's scan_pr_for_secrets (including hit blocking and body scrubbing) and the finalize pr_observed activity record."
      end
      result
    end
  end
end
