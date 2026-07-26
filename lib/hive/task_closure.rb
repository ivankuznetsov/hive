require "digest"
require "json"
require "openssl"
require "time"
require "uri"
require "hive/atomic_file"
require "hive/attempts/store"
require "hive/config"
require "hive/gh"
require "hive/git_ops"
require "hive/lock"
require "hive/markers"
require "hive/paths"
require "hive/task_projection/store"
require "hive/task_resolver"
require "hive/task_closure_contract"
require "hive/workflow_package/canonical_json"
require "hive/worktree"

module Hive
  # Evidence-bound operator closure for work delivered outside a task's
  # ordinary PR path. closure.json is deliberately separate from the
  # attempt-bound journal: a remote merge can prove delivery, but it cannot
  # retroactively prove that a local attempt succeeded.
  class TaskClosure
    SCHEMA = "hive-task-closure".freeze
    SCHEMA_VERSION = Hive::Schemas::SCHEMA_VERSIONS.fetch(SCHEMA)
    INPUT_SCHEMA = "hive-task-closure-input".freeze
    INPUT_SCHEMA_VERSION = Hive::Schemas::SCHEMA_VERSIONS.fetch(INPUT_SCHEMA)
    RECEIPT_BASENAME = "closure.json".freeze
    # Reuse the existing task-lock temporary namespace so both freshly
    # initialized and older hive/state worktrees already ignore this private
    # sidecar during StageAction's slug-scoped git add.
    LOCK_BASENAME = ".lock.tmp.closure".freeze
    QUARANTINE_DIR = "closure-quarantine".freeze
    REASONS = Hive::TaskClosureContract::REASONS
    AUTHORITIES = %w[remote_merge operator_attestation].freeze
    CHANNELS = %w[cli web bot].freeze
    RECEIPT_CHANNELS = (CHANNELS + %w[daemon]).freeze
    MAX_EVIDENCE = 16
    MAX_REFERENCE_BYTES = 512
    MAX_ATTESTATION_BYTES = 2 * 1024
    MAX_QUARANTINE_REASON_BYTES = 240
    RECEIPT_KEYS = %w[
      schema schema_version status reason authority task observation
      task_repository evidence evidence_digest successor attestation
      preview_digest confirmed_by confirmed_at receipt_digest
    ].freeze
    EVIDENCE_KEYS = %w[
      kind host repository number oid head_oid url state merged_at
      same_repository reachable_from_default
    ].freeze
    FULL_OID_RE = /\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/i
    SUCCESSOR_RE = /\A([^:\s]+):([a-z][a-z0-9-]{1,63})\z/

    class Error < Hive::Error; end
    class InvalidInput < Error; end
    class VerificationFailed < Error; end
    class StalePreview < Error; end
    class Unauthorized < Error; end
    class InvalidReceipt < Error; end

    Preview = Data.define(
      :input, :task, :task_repository, :evidence, :successor, :authority,
      :evidence_digest, :preview_digest, :errors, :blockers
    ) do
      def valid?
        errors.empty? && blockers.empty?
      end

      def to_h
        {
          "schema" => Hive::TaskClosure::INPUT_SCHEMA,
          "schema_version" => Hive::TaskClosure::INPUT_SCHEMA_VERSION,
          "ok" => valid?,
          "input" => input,
          "task" => task,
          "task_repository" => task_repository,
          "evidence" => evidence,
          "successor" => successor,
          "authority" => authority,
          "evidence_digest" => evidence_digest,
          "preview_digest" => preview_digest,
          "errors" => errors,
          "blockers" => blockers
        }
      end
    end

    ReadResult = Data.define(:status, :receipt, :error, :quarantine_path) do
      def valid? = status == "valid"
      def absent? = status == "absent"

      def to_h
        {
          "status" => status,
          "receipt" => receipt,
          "error" => error,
          "quarantine_path" => quarantine_path
        }
      end
    end

    class << self
      def preview(task:, project:, input:, gh: Hive::Gh, now: Time.now.utc)
        new(gh: gh, now: now).preview(task: task, project: project, input: input)
      end

      def confirm!(task:, project:, input:, preview_digest:, operator:, channel:,
                   authorized:, gh: Hive::Gh, now: Time.now.utc)
        new(gh: gh, now: now).confirm!(
          task: task, project: project, input: input,
          preview_digest: preview_digest, operator: operator, channel: channel,
          authorized: authorized
        )
      end

      # Internal daemon authority for the one closure Hive can decide without
      # an operator: the task-bound PR is immutably merged into the same
      # registered repository. Cross-repository or semantic supersession still
      # requires the explicit preview/confirm flow above.
      def reconcile_remote_merge!(task:, project:, pr_url:, expected_head:,
                                  expected_merge_oid:, gh: Hive::Gh,
                                  now: Time.now.utc)
        new(gh: gh, now: now).reconcile_remote_merge!(
          task: task, project: project, pr_url: pr_url,
          expected_head: expected_head,
          expected_merge_oid: expected_merge_oid
        )
      end

      def read(task, project: nil, quarantine: true)
        new.read(task, project: project, quarantine: quarantine)
      end

      def projection(task, project: nil)
        service = new
        result = service.read(task, project: project)
        return nil if result.absent?
        return result.receipt if result.valid?

        {
          "status" => "invalid",
          "reason" => result.error.to_s[0, MAX_QUARANTINE_REASON_BYTES],
          "quarantine_path" => result.quarantine_path
        }
      end

      def valid_for_transition?(task, receipt_digest:, project: nil)
        !transition_evidence(
          task, receipt_digest: receipt_digest, project: project
        ).nil?
      end

      def transition_evidence(task, receipt_digest:, project: nil)
        result = read(task, project: project)
        return nil unless result.valid?
        return nil unless secure_compare(
          result.receipt.fetch("receipt_digest"), receipt_digest.to_s
        )

        validate_active_cas!(task, result.receipt) unless terminal_task?(task)
        {
          "type" => "task_closure",
          "receipt_digest" => result.receipt.fetch("receipt_digest"),
          "evidence_digest" => result.receipt.fetch("evidence_digest"),
          "reason" => result.receipt.fetch("reason"),
          "authority" => result.receipt.fetch("authority")
        }
      rescue Hive::Error, SystemCallError, IOError
        nil
      end

      def terminal_task?(task)
        "#{task.stage_index}-#{task.stage_name}" ==
          task.workflow.stages.max_by(&:index).dir
      end

      def canonical_json(value)
        Hive::WorkflowPackage::CanonicalJSON.generate(value)
      end

      def digest(value)
        ::Digest::SHA256.hexdigest(canonical_json(value))
      end

      def secure_compare(left, right)
        left = left.to_s
        right = right.to_s
        return false unless left.bytesize == right.bytesize

        OpenSSL.fixed_length_secure_compare(left, right)
      end

      def marker_generation(marker)
        digest(
          "name" => marker.name.to_s,
          "attrs" => marker.attrs.to_h.transform_keys(&:to_s).sort.to_h
        )
      end

      def task_generation(task, marker: Hive::Markers.current(task.state_file))
        markerless = if File.file?(task.state_file)
          Hive::Markers.without_markers(File.binread(task.state_file))
        else
          ""
        end
        meta = File.file?(task.meta_yml_path) ? File.binread(task.meta_yml_path) : ""
        pr_path = File.join(task.folder, "pr.md")
        pr_identity = File.file?(pr_path) ? File.binread(pr_path) : ""
        projection = Hive::TaskProjection::Store.new(task_folder: task.folder).read(
          marker: marker
        )
        digest(
          "slug" => task.slug,
          "id" => task.id&.to_s,
          "workflow" => task.workflow.id.to_s,
          "state_without_markers_sha256" => ::Digest::SHA256.hexdigest(markerless),
          "meta_sha256" => ::Digest::SHA256.hexdigest(meta),
          "pr_identity_sha256" => ::Digest::SHA256.hexdigest(pr_identity),
          "condition_task_generation" => projection["identity"]["task_generation"],
          "commit_generation" => projection["identity"]["commit_generation"]
        )
      end

      def validate_active_cas!(task, receipt)
        observation = receipt.fetch("observation")
        current_stage = "#{task.stage_index}-#{task.stage_name}"
        marker = Hive::Markers.current(task.state_file)
        unless observation.fetch("stage") == current_stage &&
               observation.fetch("task_generation") == task_generation(task, marker: marker) &&
               observation.fetch("marker_generation") == marker_generation(marker)
          raise InvalidReceipt, "closure receipt no longer matches the active task generation"
        end
        true
      end
    end

    def initialize(gh: Hive::Gh, now: Time.now.utc, attempt_store: nil)
      @gh = gh
      @now = now.utc
      @attempt_store = attempt_store || default_attempt_store
    end

    def preview(task:, project:, input:)
      errors = []
      blockers = []
      normalized_input = normalize_input(input, errors)
      task_repository = resolve_task_repository(task, project, errors)
      successor = resolve_successor(normalized_input, task, errors)
      evidence = verify_evidence(normalized_input, task_repository, errors)
      authority = closure_authority(normalized_input, task_repository, evidence, errors)
      delivered_heads = evidence.filter_map do |item|
        item["head_oid"] if item["kind"] == "pull_request" &&
                            item["same_repository"] == true
      end
      blockers.concat(
        task_blockers(task, project, delivered_heads: delivered_heads)
      )

      task_observation = observation(task, project)
      evidence_digest = self.class.digest(evidence)
      preview_identity = {
        "input" => normalized_input,
        "task" => task_observation,
        "task_repository" => task_repository,
        "evidence" => evidence,
        "successor" => successor,
        "authority" => authority,
        "evidence_digest" => evidence_digest
      }
      preview_digest = self.class.digest(preview_identity)
      Preview.new(
        input: normalized_input,
        task: task_observation,
        task_repository: task_repository,
        evidence: evidence,
        successor: successor,
        authority: authority,
        evidence_digest: evidence_digest,
        preview_digest: preview_digest,
        errors: errors.freeze,
        blockers: blockers.freeze
      )
    rescue InvalidInput, Hive::ConfigError, Hive::GhError => e
      errors ||= []
      errors << field_error("input", "invalid", e.message)
      fallback_preview(task, project, input, errors, blockers || [])
    end

    def confirm!(task:, project:, input:, preview_digest:, operator:, channel:, authorized:)
      authorize!(operator: operator, channel: channel, authorized: authorized)
      submitted_digest = preview_digest.to_s
      unless submitted_digest.match?(/\A[0-9a-f]{64}\z/)
        raise StalePreview, "confirmation requires the exact preview digest"
      end

      with_closure_lock(task) do
        locked_task = resolve_current_task(task, project)
        existing = read(locked_task, project: project)
        if existing.valid?
          return resume_existing!(
            task: locked_task, project: project, input: input,
            preview_digest: submitted_digest, receipt: existing.receipt
          )
        end
        if !existing.absent?
          raise InvalidReceipt,
                "invalid closure receipt was quarantined; inspect " \
                "#{existing.quarantine_path || 'the closure quarantine'}"
        end

        current = preview(task: locked_task, project: project, input: input)
        validate_preview!(current)
        unless self.class.secure_compare(current.preview_digest, submitted_digest)
          raise StalePreview,
                "task, ownership, worktree, or remote evidence changed after preview"
        end

        receipt = build_receipt(current, operator: operator, channel: channel)
        persist_receipt!(locked_task, receipt)
        transition!(locked_task, project, receipt)
        archived = resolve_current_task(locked_task, project)
        result = read(archived, project: project)
        raise InvalidReceipt, "closure receipt did not survive archival" unless result.valid?

        result.receipt
      end
    end

    def reconcile_remote_merge!(task:, project:, pr_url:, expected_head:,
                                expected_merge_oid:)
      input = {
        "reason" => "already_delivered",
        "evidence" => [ pr_url.to_s ],
        "successor" => nil,
        "attestation" => nil
      }
      with_closure_lock(task) do
        locked_task = resolve_current_task(task, project)
        existing = read(locked_task, project: project)
        if existing.valid?
          receipt = existing.receipt
          unless receipt.fetch("authority") == "remote_merge" &&
                 receipt.dig("confirmed_by", "channel") == "daemon"
            raise InvalidReceipt,
                  "an operator closure receipt already owns this task"
          end
          validate_expected_remote_merge!(
            receipt.fetch("evidence"),
            expected_head: expected_head,
            expected_merge_oid: expected_merge_oid
          )
          return resume_existing!(
            task: locked_task,
            project: project,
            input: input,
            preview_digest: receipt.fetch("preview_digest"),
            receipt: receipt
          )
        end
        unless existing.absent?
          raise InvalidReceipt,
                "invalid closure receipt was quarantined; inspect " \
                "#{existing.quarantine_path || 'the closure quarantine'}"
        end

        current = preview(task: locked_task, project: project, input: input)
        validate_preview!(current)
        unless current.authority == "remote_merge" &&
               current.evidence.all? { |item| item["same_repository"] == true }
          raise VerificationFailed,
                "automatic reconciliation accepts only same-repository remote merge evidence"
        end
        validate_expected_remote_merge!(
          current.evidence,
          expected_head: expected_head,
          expected_merge_oid: expected_merge_oid
        )

        receipt = build_receipt(
          current, operator: "hive-daemon", channel: "daemon"
        )
        persist_receipt!(locked_task, receipt)
        transition!(locked_task, project, receipt)
        archived = resolve_current_task(locked_task, project)
        result = read(archived, project: project)
        raise InvalidReceipt, "closure receipt did not survive archival" unless result.valid?

        result.receipt
      end
    end

    def read(task, project: nil, quarantine: true)
      path = File.join(task.folder, RECEIPT_BASENAME)
      unless File.file?(path)
        quarantined = latest_quarantine(task)
        return quarantined if quarantined

        return ReadResult.new(
          status: "absent", receipt: nil, error: nil, quarantine_path: nil
        )
      end

      bytes = File.binread(path)
      receipt = JSON.parse(bytes)
      validate_receipt!(receipt, task: task, project: project)
      ReadResult.new(status: "valid", receipt: receipt, error: nil, quarantine_path: nil)
    rescue JSON::ParserError, InvalidReceipt, KeyError, TypeError, ArgumentError => e
      quarantine_path = quarantine ? quarantine!(task, bytes || safe_read(path), e.message) : nil
      ReadResult.new(
        status: "invalid", receipt: nil,
        error: e.message.to_s[0, MAX_QUARANTINE_REASON_BYTES],
        quarantine_path: quarantine_path
      )
    rescue SystemCallError, IOError => e
      ReadResult.new(
        status: "invalid", receipt: nil,
        error: "#{e.class}: #{e.message}".to_s[0, MAX_QUARANTINE_REASON_BYTES],
        quarantine_path: nil
      )
    end

    private

    def normalize_input(input, errors)
      value = input.respond_to?(:to_h) ? input.to_h : {}
      value = value.transform_keys(&:to_s)
      reason = valid_utf8_string(value["reason"], field: "reason", errors: errors)
      errors << field_error("reason", "unsupported", "must be already_delivered or superseded") unless
        REASONS.include?(reason)

      references = value["evidence"] || value["evidence_refs"] || []
      references = [ references ] unless references.is_a?(Array)
      if references.size > MAX_EVIDENCE
        errors << field_error("evidence", "too_many", "at most #{MAX_EVIDENCE} evidence items are allowed")
      end
      references = references.first(MAX_EVIDENCE).each_with_index.filter_map do |reference, index|
        text = valid_utf8_string(reference, field: "evidence[#{index}]", errors: errors)
        next if text.empty?
        if text.bytesize > MAX_REFERENCE_BYTES
          errors << field_error(
            "evidence[#{index}]", "too_large",
            "evidence references are capped at #{MAX_REFERENCE_BYTES} bytes"
          )
          next
        end
        text
      end

      attestation = valid_utf8_string(value["attestation"], field: "attestation", errors: errors)
      if attestation.bytesize > MAX_ATTESTATION_BYTES
        errors << field_error(
          "attestation", "too_large",
          "operator attestation is capped at #{MAX_ATTESTATION_BYTES} bytes"
        )
        attestation = ""
      end
      successor = valid_utf8_string(value["successor"], field: "successor", errors: errors)

      if reason == "superseded"
        errors << field_error("successor", "required", "superseded closure requires one registered successor") if
          successor.empty?
        errors << field_error("attestation", "required", "superseded closure requires an operator statement") if
          attestation.empty?
      end
      if reason == "already_delivered" && (!successor.empty? || !attestation.empty?)
        errors << field_error(
          "reason", "incompatible_fields",
          "successor and attestation are only accepted for superseded closure"
        )
      end
      errors << field_error("evidence", "required", "at least one immutable delivery item is required") if
        references.empty?

      {
        "reason" => reason,
        "evidence" => references,
        "successor" => successor.empty? ? nil : successor,
        "attestation" => attestation.empty? ? nil : attestation
      }
    end

    def valid_utf8_string(value, field:, errors:)
      string = value.nil? ? "" : value.to_s
      unless string.encoding == Encoding::UTF_8 ? string.valid_encoding? : string.dup.force_encoding(Encoding::UTF_8).valid_encoding?
        errors << field_error(field, "invalid_utf8", "#{field} must be valid UTF-8")
        return ""
      end
      string = string.encode(Encoding::UTF_8)
      if string.include?("\0")
        errors << field_error(field, "invalid_character", "#{field} contains a NUL byte")
        return ""
      end
      string.strip
    rescue EncodingError
      errors << field_error(field, "invalid_utf8", "#{field} must be valid UTF-8")
      ""
    end

    def resolve_task_repository(task, project, errors)
      registration = registered_project(project)
      unless same_path?(registration.fetch("path"), task.project_root)
        errors << field_error("task", "registration_mismatch", "task is outside the registered project checkout")
        return nil
      end

      config = Hive::Config.load(task.project_root)
      live = @gh.repository_identity(task.project_root, cfg: config)
      host = live.fetch("host").downcase
      repository = live.fetch("repository").downcase
      @gh.ensure_authenticated!(config, host: host)
      stored = registration["repository_identity"].to_s.downcase
      expected = "#{host}/#{repository}"
      if stored.empty? || stored.start_with?("local:") || stored != expected
        errors << field_error(
          "task_repository", "identity_mismatch",
          "registered repository identity must exactly match the live GitHub origin"
        )
      end
      # Closure evidence is remote delivery truth. A local/project-configured
      # branch can be stale or intentionally point at a release branch, so it
      # must not define what "reachable from the default branch" means.
      default_branch = @gh.closure_default_branch(
        host: host, repository: repository, cfg: config
      )
      {
        "host" => host,
        "repository" => repository,
        "identity" => expected,
        "default_branch" => default_branch
      }
    rescue Hive::Error, KeyError, SystemCallError, IOError => e
      errors << field_error("task_repository", "unresolved", e.message)
      nil
    end

    def resolve_successor(input, task, errors)
      reference = input["successor"].to_s
      return nil if reference.empty?

      match = SUCCESSOR_RE.match(reference)
      unless match
        errors << field_error("successor", "invalid", "successor must be exact project:slug")
        return nil
      end
      project_name = match[1]
      slug = match[2]
      registered_project(project_name)
      successor = Hive::TaskResolver.new(slug, project_filter: project_name).resolve
      if same_path?(successor.folder, task.folder)
        errors << field_error("successor", "self_reference", "a task cannot supersede itself")
        return nil
      end
      {
        "project" => project_name,
        "slug" => successor.slug,
        "id" => successor.id,
        "stage" => "#{successor.stage_index}-#{successor.stage_name}"
      }
    rescue Hive::Error => e
      errors << field_error("successor", "unregistered", e.message)
      nil
    end

    def verify_evidence(input, task_repository, errors)
      return [] unless task_repository

      default_branches = {}
      normalized = input.fetch("evidence").each_with_index.filter_map do |reference, index|
        identity = parse_evidence_reference(reference, task_repository, index, errors)
        next unless identity

        begin
          default_branch = evidence_default_branch(
            identity, task_repository, default_branches
          )
          facts = if identity.fetch("kind") == "pull_request"
            verify_pull_request(
              identity, task_repository, default_branch: default_branch
            )
          else
            verify_commit(
              identity, task_repository, default_branch: default_branch
            )
          end
          facts
        rescue Hive::Error, KeyError, JSON::ParserError, TypeError => e
          errors << field_error("evidence[#{index}]", "verification_failed", e.message)
          nil
        end
      end
      normalized.sort_by do |item|
        [ item.fetch("host"), item.fetch("repository"), item.fetch("kind"),
          item["number"].to_i, item.fetch("oid") ]
      end
    end

    def parse_evidence_reference(reference, task_repository, index, errors)
      if reference.match?(FULL_OID_RE)
        oid = reference.downcase
        return {
          "kind" => "commit",
          "host" => task_repository.fetch("host"),
          "repository" => task_repository.fetch("repository"),
          "oid" => oid,
          "url" => canonical_commit_url(
            task_repository.fetch("host"), task_repository.fetch("repository"), oid
          )
        }
      end

      if (identity = reference.match(
        /\A([A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+)#([1-9][0-9]*)\z/
      ))
        return pull_request_identity(
          task_repository.fetch("host"), identity[1], identity[2].to_i
        )
      end

      if (pull_request = Hive::Gh.parse_pull_request_url(reference))
        unless pull_request.fetch("host") == task_repository.fetch("host")
          raise InvalidInput,
                "evidence host #{pull_request.fetch('host').inspect} is not the task repository host"
        end
        return pull_request_identity(
          pull_request.fetch("host"),
          pull_request.fetch("repository"),
          pull_request.fetch("number")
        )
      end

      uri = URI.parse(reference)
      unless uri.scheme == "https" && uri.host && uri.userinfo.nil? &&
             uri.query.nil? && uri.fragment.nil? && uri.port == 443
        raise InvalidInput, "evidence URL must be credential-free HTTPS with no query or fragment"
      end
      host = uri.host.downcase
      unless host == task_repository.fetch("host")
        raise InvalidInput, "evidence host #{host.inspect} is not the task repository host"
      end
      if (match = uri.path.match(
        %r{\A/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/commit/([0-9a-fA-F]{40}(?:[0-9a-fA-F]{24})?)\z}
      ))
        repository = "#{match[1]}/#{match[2]}"
        oid = match[3].downcase
        return {
          "kind" => "commit",
          "host" => host,
          "repository" => validated_repository(repository),
          "oid" => oid,
          "url" => canonical_commit_url(host, repository, oid)
        }
      end

      raise InvalidInput, "evidence URL must identify one GitHub pull request or full commit OID"
    rescue URI::InvalidURIError, InvalidInput, Hive::GhError => e
      errors << field_error("evidence[#{index}]", "invalid_reference", e.message)
      nil
    end

    def pull_request_identity(host, repository, number)
      repository = validated_repository(repository)
      {
        "kind" => "pull_request",
        "host" => host.downcase,
        "repository" => repository.downcase,
        "number" => number,
        "url" => "https://#{host.downcase}/#{repository.downcase}/pull/#{number}"
      }
    end

    def evidence_default_branch(identity, task_repository, cache)
      key = [ identity.fetch("host"), identity.fetch("repository") ]
      cache[key] ||= if identity.fetch("repository") == task_repository.fetch("repository") &&
                        identity.fetch("host") == task_repository.fetch("host")
        task_repository.fetch("default_branch")
      else
        @gh.closure_default_branch(
          host: identity.fetch("host"), repository: identity.fetch("repository"), cfg: nil
        )
      end
    end

    def verify_pull_request(identity, task_repository, default_branch:)
      facts = @gh.closure_pr_facts(
        host: identity.fetch("host"),
        repository: identity.fetch("repository"),
        number: identity.fetch("number"),
        default_branch: default_branch,
        cfg: nil
      )
      state = facts.fetch("state").to_s.upcase
      raise VerificationFailed, "pull request is #{state.empty? ? 'missing' : state}, not MERGED" unless state == "MERGED"

      merge_oid = facts.fetch("merge_oid").to_s.downcase
      raise VerificationFailed, "merged pull request has no full immutable merge OID" unless
        merge_oid.match?(FULL_OID_RE)
      head_oid = facts.fetch("head_oid").to_s.downcase
      raise VerificationFailed, "merged pull request has no full immutable head OID" unless
        head_oid.match?(FULL_OID_RE)
      observed_repository = facts.fetch("repository").to_s.downcase
      unless observed_repository == identity.fetch("repository").downcase
        raise VerificationFailed, "pull request repository identity changed during verification"
      end
      same_repository = observed_repository == task_repository.fetch("repository") &&
                        identity.fetch("host") == task_repository.fetch("host")
      {
        "kind" => "pull_request",
        "host" => identity.fetch("host"),
        "repository" => observed_repository,
        "number" => identity.fetch("number"),
        "oid" => merge_oid,
        "head_oid" => head_oid,
        "url" => identity.fetch("url"),
        "state" => "MERGED",
        "merged_at" => facts.fetch("merged_at"),
        "same_repository" => same_repository,
        "reachable_from_default" => facts.fetch("reachable_from_default") == true
      }.tap do |item|
        raise VerificationFailed, "merged pull request is not reachable from its default branch" unless
          item.fetch("reachable_from_default")
      end
    end

    def verify_commit(identity, task_repository, default_branch:)
      facts = @gh.closure_commit_facts(
        host: identity.fetch("host"),
        repository: identity.fetch("repository"),
        oid: identity.fetch("oid"),
        default_branch: default_branch,
        cfg: nil
      )
      oid = facts.fetch("oid").to_s.downcase
      unless oid == identity.fetch("oid") && oid.match?(FULL_OID_RE)
        raise VerificationFailed, "commit lookup did not return the requested immutable OID"
      end
      raise VerificationFailed, "commit is not reachable from the repository default branch" unless
        facts.fetch("reachable_from_default") == true

      same_repository = identity.fetch("repository") == task_repository.fetch("repository") &&
                        identity.fetch("host") == task_repository.fetch("host")
      {
        "kind" => "commit",
        "host" => identity.fetch("host"),
        "repository" => identity.fetch("repository"),
        "number" => nil,
        "oid" => oid,
        "head_oid" => nil,
        "url" => identity.fetch("url"),
        "state" => "REACHABLE",
        "merged_at" => nil,
        "same_repository" => same_repository,
        "reachable_from_default" => true
      }
    end

    def closure_authority(input, task_repository, evidence, errors)
      return nil unless task_repository
      if evidence.empty?
        errors << field_error("evidence", "unverified", "at least one verified immutable delivery item is required")
        return nil
      end

      cross_repository = evidence.any? { |item| item["same_repository"] != true }
      if input.fetch("reason") == "already_delivered" && cross_repository
        errors << field_error(
          "evidence", "cross_repository",
          "already_delivered accepts only evidence from the task repository"
        )
        return nil
      end
      if cross_repository && input["attestation"].to_s.empty?
        errors << field_error(
          "attestation", "required",
          "cross-repository evidence requires explicit operator attestation"
        )
        return nil
      end
      cross_repository || input.fetch("reason") == "superseded" ?
        "operator_attestation" : "remote_merge"
    end

    def task_blockers(task, project, ignore_task_lock: false, delivered_heads: [])
      blockers = []
      if !ignore_task_lock && live_task_lock?(task)
        blockers << blocker("live_attempt", "a live task owner must finish before closure")
      end
      active_attempts(task, project).each do |attempt|
        blockers << blocker(
          "live_attempt",
          "durable attempt #{attempt.attempt_id} is #{attempt.state}"
        )
      end
      blockers.concat(worktree_blockers(task, delivered_heads: delivered_heads))
      blockers.uniq
    rescue Hive::Error, SystemCallError, IOError => e
      [ blocker("ownership_unverifiable", e.message) ]
    end

    def live_task_lock?(task)
      return false unless File.file?(task.lock_file)

      holder = Hive::Lock.read_task_lock(task.lock_file)
      return true unless holder.is_a?(Hash) && holder["pid"].is_a?(Integer)

      Process.kill(0, holder.fetch("pid"))
      recorded = holder["process_start_time"]
      live = Hive::Lock.process_start_time(holder.fetch("pid"))
      recorded.nil? || live.nil? || recorded == live
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end

    def active_attempts(task, project)
      scan = @attempt_store.scan
      unless scan.invalid_records.empty?
        raise VerificationFailed, "durable attempt store contains unreadable records"
      end
      scan.records.select do |attempt|
        attempt.live? &&
          attempt["project"].to_s == project.to_s &&
          attempt["task_slug"].to_s == task.slug.to_s
      end
    end

    def worktree_blockers(task, delivered_heads: [])
      pointer_path = File.join(task.folder, "worktree.yml")
      return [] unless File.file?(pointer_path)

      pointer = Hive::Worktree.read_owned_pointer(
        task.folder,
        project_root: task.project_root,
        slug: task.slug,
        expected_root: Hive::Worktree.canonical_root(task.project_root)
      )
      path = pointer.fetch("path")
      return [ blocker("worktree_missing", "owned worktree is missing") ] unless File.directory?(path)

      status = local_git(path, "status", "--porcelain=v1", "--untracked-files=all")
      return [ blocker("unique_worktree_changes", "owned worktree has uncommitted changes") ] unless status.empty?

      head = local_git(path, "rev-parse", "HEAD").strip.downcase
      verified_heads = Array(delivered_heads).map { |oid| oid.to_s.downcase }
      return [] if head.match?(FULL_OID_RE) && verified_heads.include?(head)

      config = Hive::Config.load(task.project_root)
      branch = config["default_branch"].to_s.strip
      branch = Hive::GitOps.new(task.project_root).default_branch.to_s if branch.empty?
      baseline = [ "origin/#{branch}", branch ].find do |ref|
        _out, _err, result = local_git_capture(
          path, "rev-parse", "--verify", "#{ref}^{commit}"
        )
        result.success?
      end
      return [ blocker("worktree_unverifiable", "default branch ref is unavailable") ] unless baseline

      # Prefer the remote default branch when available. A local default
      # branch may itself contain unpushed commits and must not waive unique
      # work merely because the task worktree happens to include them.
      unique = Integer(
        local_git(path, "rev-list", "--count", "#{baseline}..HEAD"),
        exception: false
      ).to_i.positive?
      unique ? [ blocker("unique_worktree_changes", "owned worktree has unique commits") ] : []
    rescue Hive::Error, KeyError, SystemCallError, IOError => e
      [ blocker("worktree_unverifiable", e.message) ]
    end

    def local_git(path, *args)
      out, err, status = local_git_capture(path, *args)
      raise Hive::GitError, "git #{args.first} failed: #{err.to_s.strip}" unless status.success?

      out.to_s
    end

    def local_git_capture(path, *args)
      Hive::Gh.capture3(
        "git", "-C", path, *args,
        timeout_sec: 10, max_stdout_bytes: 64 * 1024
      )
    end

    def observation(task, project)
      marker = Hive::Markers.current(task.state_file)
      {
        "project" => project.to_s,
        "slug" => task.slug,
        "id" => task.id,
        "workflow" => task.workflow.id.to_s,
        "folder" => task.folder,
        "stage" => "#{task.stage_index}-#{task.stage_name}",
        "marker" => marker.name.to_s,
        "task_generation" => self.class.task_generation(task, marker: marker),
        "marker_generation" => self.class.marker_generation(marker)
      }
    end

    def authorize!(operator:, channel:, authorized:)
      raise Unauthorized, "closure confirmation requires an authorized operator" unless authorized == true
      raise Unauthorized, "closure confirmation channel is not allowlisted" unless CHANNELS.include?(channel.to_s)
      raise Unauthorized, "closure confirmation requires an operator identity" if operator.to_s.strip.empty?
    end

    def validate_preview!(preview)
      return if preview.valid?

      details = (preview.errors + preview.blockers).map { |entry| entry.fetch("message") }.join("; ")
      raise VerificationFailed, details
    end

    def build_receipt(preview, operator:, channel:)
      body = {
        "schema" => SCHEMA,
        "schema_version" => SCHEMA_VERSION,
        "status" => "confirmed",
        "reason" => preview.input.fetch("reason"),
        "authority" => preview.authority,
        "task" => preview.task.slice("project", "slug", "id", "workflow"),
        "observation" => preview.task.slice(
          "stage", "marker", "task_generation", "marker_generation"
        ),
        "task_repository" => preview.task_repository,
        "evidence" => preview.evidence,
        "evidence_digest" => preview.evidence_digest,
        "successor" => preview.successor,
        "attestation" => preview.input["attestation"],
        "preview_digest" => preview.preview_digest,
        "confirmed_by" => { "operator" => operator.to_s, "channel" => channel.to_s },
        "confirmed_at" => @now.iso8601(6)
      }
      body.merge("receipt_digest" => self.class.digest(body))
    end

    def persist_receipt!(task, receipt)
      path = File.join(task.folder, RECEIPT_BASENAME)
      if File.file?(path)
        current = JSON.parse(File.binread(path))
        validate_receipt!(current, task: task, project: receipt.dig("task", "project"))
        return current if current.fetch("receipt_digest") == receipt.fetch("receipt_digest")

        raise InvalidReceipt, "a different closure receipt already exists for this task"
      end
      Hive::AtomicFile.write(path, "#{self.class.canonical_json(receipt)}\n", mode: 0o600)
      File.chmod(0o600, path)
      Hive::AtomicFile.fsync_directory(task.folder)
      receipt
    end

    def validate_receipt!(receipt, task:, project:)
      raise InvalidReceipt, "closure receipt must be an object" unless receipt.is_a?(Hash)
      unless receipt.keys.sort == RECEIPT_KEYS.sort
        raise InvalidReceipt, "closure receipt fields do not match the v1 contract"
      end
      raise InvalidReceipt, "unsupported closure receipt schema" unless
        receipt["schema"] == SCHEMA && receipt["schema_version"] == SCHEMA_VERSION
      raise InvalidReceipt, "closure receipt status is not confirmed" unless receipt["status"] == "confirmed"
      raise InvalidReceipt, "closure receipt reason is unsupported" unless REASONS.include?(receipt["reason"])
      raise InvalidReceipt, "closure receipt authority is unsupported" unless AUTHORITIES.include?(receipt["authority"])
      expected_digest = receipt["receipt_digest"].to_s
      unsigned = receipt.reject { |key, _| key == "receipt_digest" }
      unless expected_digest.match?(/\A[0-9a-f]{64}\z/) &&
             self.class.secure_compare(expected_digest, self.class.digest(unsigned))
        raise InvalidReceipt, "closure receipt digest does not match its canonical contents"
      end
      identity = receipt.fetch("task")
      unless identity.is_a?(Hash) &&
             identity.keys.sort == %w[id project slug workflow] &&
             identity.fetch("project").is_a?(String) &&
             identity.fetch("slug").is_a?(String) &&
             identity.fetch("workflow").is_a?(String) &&
             (identity["id"].nil? || identity["id"].is_a?(Integer))
        raise InvalidReceipt, "closure receipt task identity is malformed"
      end
      expected_project = project || identity.fetch("project")
      unless identity.fetch("project").to_s == expected_project.to_s &&
             identity.fetch("slug").to_s == task.slug.to_s &&
             identity["id"].to_s == task.id.to_s &&
             identity.fetch("workflow").to_s == task.workflow.id.to_s
        raise InvalidReceipt, "closure receipt task identity does not match this task"
      end
      observation = receipt.fetch("observation")
      unless observation.is_a?(Hash) &&
             observation.keys.sort == %w[marker marker_generation stage task_generation] &&
             observation.fetch("stage").to_s.match?(/\A[0-9]+-[a-z0-9][a-z0-9-]*\z/) &&
             !observation.fetch("marker").to_s.empty? &&
             observation.fetch("task_generation").to_s.match?(/\A[0-9a-f]{64}\z/) &&
             observation.fetch("marker_generation").to_s.match?(/\A[0-9a-f]{64}\z/)
        raise InvalidReceipt, "closure receipt observation is malformed"
      end
      repository = validate_receipt_repository!(receipt.fetch("task_repository"))
      validate_receipt_registration!(
        repository, task: task, project: expected_project
      )
      evidence = receipt.fetch("evidence")
      raise InvalidReceipt, "closure receipt has invalid evidence" unless
        evidence.is_a?(Array) && evidence.length.between?(1, MAX_EVIDENCE)
      evidence.each { |item| validate_receipt_evidence!(item, repository) }
      unless self.class.secure_compare(
        receipt.fetch("evidence_digest"), self.class.digest(evidence)
      )
        raise InvalidReceipt, "closure evidence digest does not match"
      end
      validate_receipt_semantics!(receipt)
      self.class.validate_active_cas!(task, receipt) unless self.class.terminal_task?(task)
      receipt
    end

    def validate_receipt_repository!(repository)
      unless repository.is_a?(Hash) &&
             repository.keys.sort == %w[default_branch host identity repository]
        raise InvalidReceipt, "closure task repository is malformed"
      end
      host = Hive::Gh::RepositoryIdentity.validated_github_host(
        repository.fetch("host")
      ).downcase
      slug = validated_repository(repository.fetch("repository")).downcase
      identity = repository.fetch("identity").to_s.downcase
      branch = repository.fetch("default_branch").to_s
      unless identity == "#{host}/#{slug}" &&
             !branch.empty? && !branch.match?(/[\0\r\n\s]/)
        raise InvalidReceipt, "closure task repository identity is malformed"
      end
      { "host" => host, "repository" => slug }
    rescue Hive::GhError, InvalidInput, KeyError, TypeError
      raise InvalidReceipt, "closure task repository identity is malformed"
    end

    def validate_receipt_registration!(repository, task:, project:)
      registration = registered_project(project)
      expected_identity = "#{repository.fetch('host')}/#{repository.fetch('repository')}"
      unless same_path?(registration.fetch("path"), task.project_root) &&
             registration.fetch("repository_identity", "").to_s.downcase == expected_identity
        raise InvalidReceipt, "closure task repository no longer matches its registered identity"
      end
      true
    rescue Hive::ConfigError, KeyError, TypeError
      raise InvalidReceipt, "closure task repository registration is unavailable"
    end

    def validate_receipt_evidence!(item, task_repository)
      unless item.is_a?(Hash) && item.keys.sort == EVIDENCE_KEYS.sort
        raise InvalidReceipt, "closure evidence item is malformed"
      end
      kind = item.fetch("kind").to_s
      host = Hive::Gh::RepositoryIdentity.validated_github_host(
        item.fetch("host")
      ).downcase
      repository = validated_repository(item.fetch("repository")).downcase
      oid = item.fetch("oid").to_s.downcase
      unless host == task_repository.fetch("host") &&
             oid.match?(FULL_OID_RE) &&
             item.fetch("reachable_from_default") == true &&
             [ true, false ].include?(item.fetch("same_repository"))
        raise InvalidReceipt, "closure evidence item is not immutable and reachable"
      end
      same_repository = repository == task_repository.fetch("repository")
      unless item.fetch("same_repository") == same_repository
        raise InvalidReceipt, "closure evidence repository relationship is inconsistent"
      end

      expected_url = if kind == "pull_request"
        number = item.fetch("number")
        unless number.is_a?(Integer) && number.positive? &&
               item.fetch("state") == "MERGED" &&
               item.fetch("head_oid").to_s.match?(FULL_OID_RE) &&
               !item.fetch("merged_at").to_s.empty?
          raise InvalidReceipt, "closure pull request evidence is malformed"
        end
        Time.iso8601(item.fetch("merged_at").to_s)
        "https://#{host}/#{repository}/pull/#{number}"
      elsif kind == "commit"
        unless item["number"].nil? && item.fetch("state") == "REACHABLE" &&
               item["merged_at"].nil? && item["head_oid"].nil?
          raise InvalidReceipt, "closure commit evidence is malformed"
        end
        canonical_commit_url(host, repository, oid)
      else
        raise InvalidReceipt, "closure evidence kind is unsupported"
      end
      unless item.fetch("url") == expected_url
        raise InvalidReceipt, "closure evidence URL is not canonical"
      end
    rescue Hive::GhError, InvalidInput, KeyError, TypeError, ArgumentError
      raise InvalidReceipt, "closure evidence item is malformed"
    end

    def validate_receipt_semantics!(receipt)
      preview_digest = receipt.fetch("preview_digest").to_s
      raise InvalidReceipt, "closure preview digest is malformed" unless
        preview_digest.match?(/\A[0-9a-f]{64}\z/)

      confirmation = receipt.fetch("confirmed_by")
      unless confirmation.is_a?(Hash) &&
             confirmation.keys.sort == %w[channel operator] &&
             RECEIPT_CHANNELS.include?(confirmation.fetch("channel").to_s) &&
             !confirmation.fetch("operator").to_s.strip.empty?
        raise InvalidReceipt, "closure confirmation identity is malformed"
      end
      Time.iso8601(receipt.fetch("confirmed_at").to_s)

      reason = receipt.fetch("reason")
      authority = receipt.fetch("authority")
      successor = receipt["successor"]
      attestation = receipt["attestation"]
      if reason == "already_delivered"
        unless authority == "remote_merge" && successor.nil? && attestation.nil? &&
               receipt.fetch("evidence").all? { |item| item["same_repository"] == true }
          raise InvalidReceipt, "already-delivered closure semantics are inconsistent"
        end
        return true
      end

      unless authority == "operator_attestation" &&
             successor.is_a?(Hash) &&
             successor.keys.sort == %w[id project slug stage] &&
             !successor.fetch("project").to_s.empty? &&
             successor.fetch("slug").to_s.match?(/\A[a-z][a-z0-9-]{1,63}\z/) &&
             successor.fetch("stage").to_s.match?(/\A[0-9]+-[a-z0-9][a-z0-9-]*\z/) &&
             (successor["id"].nil? || successor["id"].is_a?(Integer)) &&
             attestation.is_a?(String) && attestation.valid_encoding? &&
             !attestation.strip.empty? && attestation.bytesize <= MAX_ATTESTATION_BYTES
        raise InvalidReceipt, "superseded closure semantics are inconsistent"
      end
      true
    rescue ArgumentError, KeyError, TypeError
      raise InvalidReceipt, "closure confirmation metadata is malformed"
    end

    def resume_existing!(task:, project:, input:, preview_digest:, receipt:)
      unless self.class.secure_compare(receipt.fetch("preview_digest"), preview_digest)
        raise StalePreview, "existing closure receipt belongs to a different preview"
      end
      normalized_errors = []
      normalized = normalize_input(input, normalized_errors)
      raise InvalidInput, normalized_errors.map { |entry| entry["message"] }.join("; ") unless normalized_errors.empty?
      unless normalized.fetch("reason") == receipt.fetch("reason") &&
             normalized["successor"].to_s == successor_reference(receipt["successor"]) &&
             normalized["attestation"].to_s == receipt["attestation"].to_s
        raise StalePreview, "existing closure receipt belongs to different closure input"
      end
      requested = normalized.fetch("evidence")
      recorded = receipt.fetch("evidence").map { |item| item.fetch("url") }.sort
      unless requested.map { |reference| canonical_reference(reference, receipt.fetch("task_repository")) }.sort ==
             recorded
        raise StalePreview, "existing closure receipt belongs to different evidence"
      end

      refreshed_errors = []
      refreshed = verify_evidence(normalized, receipt.fetch("task_repository"), refreshed_errors)
      raise VerificationFailed, refreshed_errors.map { |entry| entry["message"] }.join("; ") unless refreshed_errors.empty?
      unless self.class.secure_compare(receipt.fetch("evidence_digest"), self.class.digest(refreshed))
        raise StalePreview, "remote evidence changed after the closure receipt was written"
      end

      unless self.class.terminal_task?(task)
        self.class.validate_active_cas!(task, receipt)
        delivered_heads = receipt.fetch("evidence").filter_map do |item|
          item["head_oid"] if item["kind"] == "pull_request" &&
                              item["same_repository"] == true
        end
        blockers = task_blockers(
          task, project, delivered_heads: delivered_heads
        )
        raise VerificationFailed, blockers.map { |entry| entry["message"] }.join("; ") unless blockers.empty?
      end
      transition!(task, project, receipt)
      archived = resolve_current_task(task, project)
      result = read(archived, project: project)
      raise InvalidReceipt, "closure receipt did not survive archival" unless result.valid?

      result.receipt
    end

    def validate_expected_remote_merge!(evidence, expected_head:, expected_merge_oid:)
      head = expected_head.to_s.downcase
      merge_oid = expected_merge_oid.to_s.downcase
      unless head.match?(FULL_OID_RE) && merge_oid.match?(FULL_OID_RE)
        raise VerificationFailed,
              "automatic reconciliation requires full expected head and merge OIDs"
      end
      item = Array(evidence).find { |entry| entry["kind"] == "pull_request" }
      unless item &&
             self.class.secure_compare(item.fetch("head_oid").to_s, head) &&
             self.class.secure_compare(item.fetch("oid").to_s, merge_oid)
        raise StalePreview,
              "pull request head or merge OID changed before automatic closure"
      end
      true
    end

    def transition!(task, project, receipt)
      require "hive/commands/stage_action"
      Hive::Commands::StageAction.archive_with_closure(
        task,
        project: project,
        receipt_digest: receipt.fetch("receipt_digest"),
        observation_guard: lambda do |locked_task|
          validate_final_transition!(locked_task, project, receipt)
        end
      )
    end

    def validate_final_transition!(task, project, receipt)
      self.class.validate_active_cas!(task, receipt)

      repository_errors = []
      live_repository = resolve_task_repository(task, project, repository_errors)
      unless repository_errors.empty? &&
             live_repository == receipt.fetch("task_repository")
        detail = repository_errors.map { |entry| entry.fetch("message") }.join("; ")
        raise StalePreview,
              detail.empty? ? "task repository identity changed before archive" : detail
      end

      normalized = {
        "reason" => receipt.fetch("reason"),
        "evidence" => receipt.fetch("evidence").map { |item| item.fetch("url") },
        "successor" => successor_reference(receipt["successor"]),
        "attestation" => receipt["attestation"]
      }
      evidence_errors = []
      refreshed = verify_evidence(normalized, live_repository, evidence_errors)
      unless evidence_errors.empty? &&
             self.class.secure_compare(
               receipt.fetch("evidence_digest"), self.class.digest(refreshed)
             )
        detail = evidence_errors.map { |entry| entry.fetch("message") }.join("; ")
        raise StalePreview,
              detail.empty? ? "remote evidence changed before archive" : detail
      end

      validate_daemon_pr_binding!(task, receipt) if
        receipt.dig("confirmed_by", "channel") == "daemon"
      delivered_heads = refreshed.filter_map do |item|
        item["head_oid"] if item["kind"] == "pull_request" &&
                            item["same_repository"] == true
      end
      blockers = task_blockers(
        task, project,
        ignore_task_lock: true,
        delivered_heads: delivered_heads
      )
      unless blockers.empty?
        raise VerificationFailed,
              blockers.map { |entry| entry.fetch("message") }.join("; ")
      end
      true
    end

    def validate_daemon_pr_binding!(task, receipt)
      frontmatter = Hive::Gh.pr_frontmatter(File.join(task.folder, "pr.md"))
      current = Hive::Gh.parse_pull_request_url(frontmatter["pr_url"])
      evidence = receipt.fetch("evidence").find do |item|
        item["kind"] == "pull_request"
      end
      head = %w[head_oid head_sha headRefOid].filter_map do |field|
        value = frontmatter[field].to_s.downcase
        value if value.match?(FULL_OID_RE)
      end.first
      unless current && evidence &&
             current.fetch("url") == evidence.fetch("url") &&
             current.fetch("number") == evidence.fetch("number") &&
             head == evidence.fetch("head_oid")
        raise StalePreview,
              "task pull request binding changed before automatic archive"
      end
      true
    end

    def with_closure_lock(task)
      path = File.join(task.folder, LOCK_BASENAME)
      File.open(path, File::RDWR | File::CREAT, 0o600) do |lock|
        lock.chmod(0o600)
        lock.flock(File::LOCK_EX)
        yield
      ensure
        lock&.flock(File::LOCK_UN)
      end
    rescue SystemCallError, IOError => e
      raise Error, "closure lock is unavailable: #{e.message}"
    end

    def resolve_current_task(task, project)
      Hive::TaskResolver.new(task.slug, project_filter: project).resolve
    end

    def quarantine!(task, bytes, reason)
      return nil if bytes.nil?

      root = quarantine_root(task)
      FileUtils.mkdir_p(root, mode: 0o700)
      File.chmod(0o700, File.join(Hive::Paths.state_home, QUARANTINE_DIR))
      File.chmod(0o700, File.dirname(root))
      File.chmod(0o700, root)
      token = "#{@now.strftime('%Y%m%dT%H%M%S%6NZ')}-#{::Digest::SHA256.hexdigest(bytes)[0, 16]}"
      path = File.join(root, "#{token}.json")
      Hive::AtomicFile.write(path, bytes, mode: 0o600)
      Hive::AtomicFile.write(
        "#{path}.reason.json",
        "#{JSON.generate('reason' => reason.to_s[0, MAX_QUARANTINE_REASON_BYTES], 'quarantined_at' => @now.iso8601(6))}\n",
        mode: 0o600
      )
      receipt_path = File.join(task.folder, RECEIPT_BASENAME)
      File.unlink(receipt_path) if File.file?(receipt_path)
      Hive::AtomicFile.fsync_directory(task.folder)
      path
    rescue SystemCallError, IOError
      nil
    end

    def latest_quarantine(task)
      root = quarantine_root(task)
      path = Dir[File.join(root, "*.json")]
             .reject { |candidate| candidate.end_with?(".reason.json") }
             .max_by { |candidate| File.basename(candidate) }
      return nil unless path

      metadata = JSON.parse(File.read("#{path}.reason.json", 4 * 1024))
      ReadResult.new(
        status: "invalid",
        receipt: nil,
        error: metadata.fetch("reason").to_s[0, MAX_QUARANTINE_REASON_BYTES],
        quarantine_path: path
      )
    rescue JSON::ParserError, KeyError, SystemCallError, IOError
      nil
    end

    def quarantine_root(task)
      project_key = "#{File.basename(task.project_root)}-" \
                    "#{::Digest::SHA256.hexdigest(task.project_root)[0, 12]}"
      File.join(Hive::Paths.state_home, QUARANTINE_DIR, project_key, task.slug)
    end

    def fallback_preview(task, project, input, errors, blockers)
      normalized = {
        "reason" => input.respond_to?(:[]) ? input[:reason] || input["reason"] : nil,
        "evidence" => [],
        "successor" => nil,
        "attestation" => nil
      }
      task_observation = observation(task, project)
      Preview.new(
        input: normalized, task: task_observation, task_repository: nil,
        evidence: [], successor: nil, authority: nil,
        evidence_digest: self.class.digest([]),
        preview_digest: self.class.digest(
          "input" => normalized, "task" => task_observation, "invalid" => true
        ),
        errors: errors.freeze, blockers: blockers.freeze
      )
    end

    def canonical_reference(reference, task_repository)
      errors = []
      parse_evidence_reference(reference, task_repository, 0, errors)&.fetch("url") ||
        reference
    end

    def successor_reference(successor)
      return "" unless successor.is_a?(Hash)

      "#{successor.fetch('project')}:#{successor.fetch('slug')}"
    end

    def registered_project(name)
      Hive::Config.find_project(name.to_s) ||
        raise(Hive::ConfigError, "unknown registered project #{name.inspect}")
    end

    def validated_repository(repository)
      raw = repository.to_s
      value = Hive::Gh::RepositoryIdentity.validated_repository_slug(raw)
      raise InvalidInput, "repository identity must be owner/name" unless value == raw

      value
    rescue Hive::GhError
      raise InvalidInput, "repository identity must be owner/name"
    end

    def canonical_commit_url(host, repository, oid)
      "https://#{host.downcase}/#{validated_repository(repository).downcase}/commit/#{oid.downcase}"
    end

    def same_path?(left, right)
      File.realpath(left) == File.realpath(right)
    rescue SystemCallError
      File.expand_path(left) == File.expand_path(right)
    end

    def safe_read(path)
      File.binread(path)
    rescue SystemCallError, IOError
      nil
    end

    def field_error(field, code, message)
      { "field" => field, "code" => code, "message" => message.to_s[0, 500] }
    end

    def blocker(code, message)
      { "code" => code, "message" => message.to_s[0, 500], "owner" => "operator" }
    end

    def default_attempt_store
      root = ENV["HIVE_ATTEMPT_STORE_ROOT"].to_s
      Hive::Attempts::Store.new(
        root: root.empty? ? Hive::Paths.attempts_root : root,
        create_directories: false
      )
    end
  end
end
