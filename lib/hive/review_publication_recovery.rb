require "base64"
require "json"
require "open3"
require "shellwords"
require "time"

module Hive
  # Durable, lossless marker evidence. Projection is local: it never consults
  # GitHub or scans Git history. Tokens belong to the current action producer.
  module ReviewPublicationRecovery
    VERSION = "1".freeze
    FIELDS = %w[worktree branch pr_url pr_number pr_state is_draft local_head remote_head
                publication verification unpushed_shas candidate_shas classification failure_reason
                push_command verification_recipe observed_at ready_command origin_reason].freeze
    OID = /\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/
    MAX_BYTES = 48 * 1024
    module_function

    def encode(evidence)
      evidence.each_with_object({ "rp_version" => VERSION }) do |(key, value), attrs|
        next unless FIELDS.include?(key.to_s)
        json = JSON.generate(value)
        raise ArgumentError, "review publication field exceeds bound: #{key}" if json.bytesize > MAX_BYTES
        attrs["rp_#{key}"] = Base64.urlsafe_encode64(json, padding: false)
      end
    end

    def decode(attrs)
      return nil unless attrs["rp_version"]
      return { "publication" => "unknown", "failure_reason" => "unsupported_evidence_version" } unless attrs["rp_version"] == VERSION

      FIELDS.each_with_object({}) do |key, out|
        encoded = attrs["rp_#{key}"]
        next unless encoded
        raise ArgumentError if encoded.bytesize > MAX_BYTES * 2
        out[key] = JSON.parse(Base64.urlsafe_decode64(encoded))
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

      commits = git(worktree, "rev-list", "--reverse", "#{reference}..#{local}")
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

    def project(attrs, action: nil)
      evidence = decode(attrs)
      return nil unless evidence
      result = evidence.dup
      result["retry_command"] = if action && action["action_id"] == "workflow.retry"
        Shellwords.join([ "hive", "act", "workflow.retry", action.fetch("target"),
                          "--observation", action.fetch("observation_token"), "--json" ])
      end
      if attrs["reason"] == "final_fix_unverified"
        suffix = format("%02d", attrs["pass"].to_i)
        result["remediation"] = "Resolve escalations=#{attrs['escalations'].to_i} and accepted=#{attrs['accepted'].to_i} findings in reviews/*-#{suffix}.md. Commit fixes locally before explicit operator/coordinator verification retry. Editing review checkboxes does not apply fixes. Raising review.max_passes explicitly authorizes a changed repair budget."
      else
        result["remediation"] = "Retain local commits. Reconcile divergence or identity failures before publication; then refresh the canonical recovery action."
      end
      result["recovery_guidance"] = result["retry_command"] ? "Use the current observation-bound workflow.retry action." :
        "Routine retry is ineligible. Use the existing explicit operator/coordinator recovery path after remediation."
      if evidence["is_draft"] == true && evidence["pr_state"] == "OPEN"
        result["readiness_guidance"] = "Use normal finalize by default: it owns scan-before-ready and pr_observed. Manual ready requires confirmed publication, successful exact-head verification, and a successful current secret scan. Manual ready bypasses Hive's scan_pr_for_secrets (including hit blocking and body scrubbing) and the finalize pr_observed activity record."
      end
      result
    end
  end
end
