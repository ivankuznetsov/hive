require "digest"
require "json"
require "tempfile"
require "time"
require "uri"
require "hive"
require "hive/agent_git_gate"
require "hive/gh"
require "hive/git_ref"
require "hive/managed_directory"
require "hive/secret_patterns"

module Hive
  # Lower-level, deterministic branch and pull-request publication. Product
  # workflows decide whether a patch may publish; this component owns only
  # exact Git/GitHub identity, intent durability, and replay reconciliation.
  module GithubPublication
    SCHEMA = "hive-github-publication".freeze
    SCHEMA_VERSION = 1
    MAX_STATE_BYTES = 64 * 1024
    MAX_PAGES = 100
    MAX_RECORDS = 5_000
    MAX_TITLE_BYTES = 512
    MAX_BODY_BYTES = 32 * 1024
    MAX_DIFF_BYTES = 4 * 1024 * 1024
    MAX_INVENTORY_BYTES = 16 * 1024 * 1024
    OID = /\A[0-9a-f]{40}\z/
    DIGEST = /\A[0-9a-f]{64}\z/
    PUBLICATION_ID = /\Apub-[0-9a-f]{32}\z/
    PHASES = %w[prepared push_intent branch_observed pr_create_intent pr_observed].freeze

    class Blocked < Hive::Error
      attr_reader :code

      def initialize(code, message)
        @code = code.to_s.freeze
        super(message.to_s)
      end
    end

    Request = Data.define(
      :task, :generation, :evidence_digest, :review_receipt_id,
      :worktree_path, :host, :repository, :base_branch,
      :creation_base_oid, :branch, :head_oid, :diff_digest,
      :title, :body, :diff, :draft
    ) do
      def initialize(task:, generation:, evidence_digest:, review_receipt_id:,
                     worktree_path:, host:, repository:, base_branch:,
                     creation_base_oid:, branch:, head_oid:, diff_digest:,
                     title:, body:, diff: "", draft: true)
        normalized_task = bounded_string(task, "task", 128)
        normalized_generation = Integer(generation)
        raise ArgumentError, "generation must be positive" unless normalized_generation.positive?
        evidence = digest(evidence_digest, "evidence digest")
        review = bounded_string(review_receipt_id, "review receipt", 128)
        worktree = File.expand_path(bounded_string(worktree_path, "worktree path", 4_096))
        normalized_host = Hive::Gh::RepositoryIdentity.validated_github_host(host)
        normalized_repository = Hive::Gh::RepositoryIdentity.validated_repository_slug(repository)
        raise ArgumentError, "GitHub host is too long" if normalized_host.bytesize > 253
        raise ArgumentError, "repository is too long" if normalized_repository.bytesize > 255
        normalized_base = Hive::GitRef.validate_branch_name(base_branch)
        base_oid = oid(creation_base_oid, "creation base OID")
        normalized_branch = Hive::GitRef.validate_branch_name(branch)
        normalized_head = oid(head_oid, "head OID")
        normalized_diff_digest = digest(diff_digest, "diff digest")
        normalized_title = bounded_utf8(title, "title", MAX_TITLE_BYTES, control_free: true)
        normalized_body = bounded_utf8(body, "body", MAX_BODY_BYTES)
        normalized_diff = bounded_utf8(diff, "diff", MAX_DIFF_BYTES, allow_empty: true)
        unless Digest::SHA256.hexdigest(normalized_diff) == normalized_diff_digest
          raise ArgumentError, "diff digest does not match publication bytes"
        end
        unless draft == true || draft == false
          raise ArgumentError, "draft must be boolean"
        end
        super(
          task: normalized_task.freeze, generation: normalized_generation,
          evidence_digest: evidence.freeze, review_receipt_id: review.freeze,
          worktree_path: worktree.freeze, host: normalized_host.freeze,
          repository: normalized_repository.freeze, base_branch: normalized_base.freeze,
          creation_base_oid: base_oid.freeze, branch: normalized_branch.freeze,
          head_oid: normalized_head.freeze, diff_digest: normalized_diff_digest.freeze,
          title: normalized_title.freeze, body: normalized_body.freeze,
          diff: normalized_diff.freeze, draft: draft
        )
      end

      def publication_id
        "pub-#{Digest::SHA256.hexdigest(JSON.generate(
          {
            "task" => task, "generation" => generation,
            "evidence_digest" => evidence_digest,
            "review_receipt_id" => review_receipt_id,
            "host" => host, "repository" => repository,
            "base_branch" => base_branch,
            "creation_base_oid" => creation_base_oid,
            "branch" => branch, "head_oid" => head_oid,
            "diff_digest" => diff_digest, "draft" => draft
          }.sort.to_h
        ))[0, 32]}"
      end

      def marker
        "<!-- hive-publication:v1 id=#{publication_id} base=#{creation_base_oid} -->"
      end

      def published_body
        "#{body.rstrip}\n\n#{marker}\n"
      end

      def title_digest = Digest::SHA256.hexdigest(title)
      def body_digest = Digest::SHA256.hexdigest(published_body)
      def marker_digest = Digest::SHA256.hexdigest(marker)

      private

      def bounded_string(value, label, max)
        text = value.to_s
        if text.empty? || text.bytesize > max || text.match?(/[\u0000-\u001f\u007f]/)
          raise ArgumentError, "#{label} is invalid"
        end
        text
      end

      def bounded_utf8(value, label, max, allow_empty: false, control_free: false)
        text = value.to_s.dup.force_encoding(Encoding::UTF_8)
        unless text.valid_encoding? && text.bytesize <= max &&
               (allow_empty || !text.empty?) && !text.include?("\0") &&
               (!control_free || !text.match?(/[\u0000-\u001f\u007f]/))
          raise ArgumentError, "#{label} is invalid"
        end
        text
      end

      def oid(value, label)
        normalized = value.to_s.downcase
        raise ArgumentError, "#{label} is invalid" unless normalized.match?(OID)
        normalized
      end

      def digest(value, label)
        normalized = value.to_s.downcase
        raise ArgumentError, "#{label} is invalid" unless normalized.match?(DIGEST)
        normalized
      end
    end

    # Hardened Git adapter. The returned values contain only OIDs and the
    # non-secret transport fingerprint from AgentGitGate.
    class GitGateway
      def initialize(remote: "origin", allow_local_transport: false, cfg: nil)
        @remote = remote
        @allow_local_transport = allow_local_transport
        @cfg = cfg
      end

      def repository_identity(worktree_path:)
        Hive::Gh.repository_identity(worktree_path, cfg: @cfg, managed: true)
      end

      def observe(worktree_path:, branch:)
        observation = Hive::AgentGitGate.observe_remote_branch(
          repository_path: worktree_path, branch: branch, remote: @remote,
          allow_local_transport: @allow_local_transport
        )
        {
          "oid" => observation.oid,
          "remote_fingerprint" => observation.remote_fingerprint
        }.freeze
      end

      def push_exact(worktree_path:, branch:, head_oid:, expected_remote_oid:)
        receipt = Hive::AgentGitGate.publish(
          repository_path: worktree_path, oid: head_oid, branch: branch,
          remote: @remote, expected_remote_oid: expected_remote_oid,
          expected_remote_absent: expected_remote_oid.nil?,
          allow_local_transport: @allow_local_transport
        )
        {
          "expected_oid" => receipt.expected_oid,
          "before_oid" => receipt.before_oid,
          "after_oid" => receipt.after_oid,
          "remote_fingerprint" => receipt.remote_fingerprint
        }.freeze
      end
    end

    # Complete all-state GitHub inventory and one explicit create operation.
    # `--paginate --slurp` is load-bearing: errors or malformed page arrays
    # raise instead of being mistaken for an empty inventory.
    class GithubGateway
      def initialize(transport: Hive::Gh, cfg: nil)
        @transport = transport
        @cfg = cfg
      end

      def authenticate!(host:, **)
        @transport.ensure_authenticated!(@cfg, host: host)
      end

      def list_pull_requests(repository:, host:, cursor:, **)
        raise Hive::GhError, "GitHub pagination cursor is not supported by the complete adapter" if cursor

        repo = Hive::Gh::RepositoryIdentity.validated_repository_slug(repository)
        github_host = Hive::Gh::RepositoryIdentity.validated_github_host(host)
        endpoint = "repos/#{repo}/pulls?state=all&per_page=100"
        out, err, status = @transport.capture3(
          "gh", "api", "--hostname", github_host, endpoint,
          "--paginate", "--slurp", cfg: @cfg,
          max_stdout_bytes: MAX_INVENTORY_BYTES
        )
        unless status.success?
          raise Hive::GhError,
                "GitHub pull-request inventory failed: #{err.to_s.empty? ? out : err}"
        end
        pages = JSON.parse(out)
        unless pages.is_a?(Array) && pages.length.between?(1, MAX_PAGES) &&
               pages.all? { |page| page.is_a?(Array) }
          raise Hive::GhError, "GitHub pull-request inventory was incomplete"
        end
        items = pages.flatten.map { |record| normalize_record(record, repo, github_host) }
        if items.length > MAX_RECORDS
          raise Hive::GhError, "GitHub pull-request inventory exceeded its safe record cap"
        end
        {
          "items" => items, "next_cursor" => nil,
          "has_next_page" => false, "complete" => true, "truncated" => false
        }
      rescue JSON::ParserError => e
        raise Hive::GhError, "GitHub pull-request inventory was unparseable: #{e.message}"
      end

      def create_pull_request(request:, **)
        Tempfile.create([ "hive-publication-", ".md" ], mode: File::RDWR, perm: 0o600) do |file|
          file.binmode
          file.write(request.published_body)
          file.flush
          args = [
            "gh", "pr", "create", "--repo", "#{request.host}/#{request.repository}",
            "--head", request.branch, "--base", request.base_branch,
            "--title", request.title, "--body-file", file.path
          ]
          args << "--draft" if request.draft
          out, err, status = @transport.capture3(
            *args, chdir: request.worktree_path, cfg: @cfg
          )
          unless status.success?
            raise Hive::GhError,
                  "GitHub pull-request create failed: #{err.to_s.empty? ? out : err}"
          end
          true
        end
      end

      private

      def normalize_record(record, repository, host)
        unless record.is_a?(Hash)
          raise Hive::GhError, "GitHub pull-request inventory contained a non-object"
        end
        head = record["head"]
        base = record["base"]
        unless head.is_a?(Hash) && base.is_a?(Hash)
          raise Hive::GhError, "GitHub pull-request inventory omitted ref identity"
        end
        number = record["number"]
        url = record["html_url"]
        validate_url!(url, repository, host, number)
        state = record["merged_at"] ? "MERGED" : record["state"].to_s.upcase
        unless number.is_a?(Integer) && number.positive? && %w[OPEN CLOSED MERGED].include?(state) &&
               [ true, false ].include?(record["draft"])
          raise Hive::GhError, "GitHub pull-request inventory contained invalid state"
        end
        {
          "number" => number, "url" => url, "state" => state,
          "draft" => record.fetch("draft"), "head_branch" => head["ref"],
          "head_oid" => head["sha"], "head_repository" => head.dig("repo", "full_name"),
          "base_branch" => base["ref"], "base_repository" => base.dig("repo", "full_name"),
          "title" => record["title"], "body" => record["body"].to_s
        }
      end

      def validate_url!(url, repository, host, number)
        uri = URI.parse(url.to_s)
        expected = "/#{repository}/pull/#{number}"
        unless uri.scheme == "https" && uri.host&.casecmp?(host) && uri.path.casecmp?(expected) &&
               uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil?
          raise Hive::GhError, "GitHub pull-request inventory URL identity is invalid"
        end
      rescue URI::InvalidURIError
        raise Hive::GhError, "GitHub pull-request inventory URL identity is invalid"
      end
    end

    class Controller
      STATE_FIELDS = %w[
        schema schema_version phase publication_id task generation evidence_digest
        review_receipt_id host repository base_branch creation_base_oid branch head_oid
        diff_digest title_digest body_digest marker_digest draft expected_remote_oid
        push_attempted_at push_observation create_attempts create_attempted_at
        pr updated_at
      ].freeze

      def initialize(state_path:, git_gateway:, github_gateway:, clock: -> { Time.now.utc })
        @state_path = File.expand_path(state_path)
        @directory = Hive::ManagedDirectory.new(
          root: File.dirname(@state_path), label: "GitHub publication state"
        )
        @state_name = File.basename(@state_path)
        @git = git_gateway
        @github = github_gateway
        @clock = clock
      end

      def publish!(request, revalidate:)
        unless request.is_a?(Request) && revalidate.respond_to?(:call)
          raise ArgumentError, "publication requires a strict request and revalidator"
        end
        @directory.with_lock(".#{@state_name}.lock") do
          ensure_secret_free!(request)
          authenticate(request)
          state = read_state || initialize_state(request, revalidate)
          validate_request!(state, request)
          reconcile(request, state, revalidate)
        end
      rescue Hive::ManagedDirectory::UnsafeError
        raise Blocked.new("unsafe_state", "publication state is unavailable or unsafe")
      end

      private

      def authenticate(request)
        @github.authenticate!(host: request.host, repository: request.repository)
      rescue StandardError
        blocked!("authentication_unavailable", "GitHub authentication is unavailable")
      end

      def initialize_state(request, revalidate)
        revalidate!(revalidate, :prepare)
        observe(request)
        state = identity(request).merge(
          "schema" => SCHEMA, "schema_version" => SCHEMA_VERSION,
          # V1 never replaces a pre-existing branch. The deterministic branch
          # is controller-owned only after our absence-leased attempt, or when
          # a complete inventory proves an exact controller-owned PR.
          "phase" => "prepared", "expected_remote_oid" => nil,
          "push_attempted_at" => nil, "push_observation" => nil,
          "create_attempts" => 0, "create_attempted_at" => nil,
          "pr" => nil, "updated_at" => timestamp
        )
        write_state(state)
      end

      def reconcile(request, state, revalidate)
        loop do
          validate_request!(state, request)
          owned = reconcile_pull_requests(request)
          if owned
            state = observe_pr(state, request, owned)
            revalidate!(revalidate, :final)
            return state.fetch("pr")
          end
          if state.fetch("phase") == "pr_observed"
            blocked!("pr_observation_missing", "the observed pull request is absent from the complete inventory")
          end

          case state.fetch("phase")
          when "prepared", "push_intent"
            state = reconcile_push(request, state, revalidate)
          when "branch_observed", "pr_create_intent"
            state = reconcile_create(request, state, revalidate)
          else
            blocked!("invalid_phase", "publication state phase is invalid")
          end
        end
      end

      def reconcile_push(request, state, revalidate)
        current = observe(request)
        if current.fetch("oid") == request.head_oid
          unless state.fetch("push_attempted_at") || state.fetch("push_observation")
            blocked!("remote_branch_unowned", "remote branch exists without controller publication proof")
          end
          observation = {
            "expected_oid" => state.fetch("expected_remote_oid"),
            "before_oid" => state.fetch("expected_remote_oid"),
            "after_oid" => request.head_oid,
            "remote_fingerprint" => current.fetch("remote_fingerprint")
          }
          return write_state(state.merge(
            "phase" => "branch_observed", "push_observation" => observation,
            "updated_at" => timestamp
          ))
        end
        unless current.fetch("oid") == state.fetch("expected_remote_oid")
          blocked!("remote_branch_conflict", "remote branch lease no longer matches publication intent")
        end
        unless state.fetch("phase") == "push_intent"
          state = write_state(state.merge("phase" => "push_intent", "updated_at" => timestamp))
        end
        revalidate!(revalidate, :before_push)
        if state.fetch("push_attempted_at")
          blocked!("push_outcome_unknown", "remote push outcome requires reconciliation")
        end
        state = write_state(state.merge(
          "push_attempted_at" => timestamp, "updated_at" => timestamp
        ))
        begin
          receipt = @git.push_exact(
            worktree_path: request.worktree_path, branch: request.branch,
            head_oid: request.head_oid,
            expected_remote_oid: state.fetch("expected_remote_oid")
          )
          validate_push_receipt!(receipt, state, request)
        rescue Blocked
          raise
        rescue StandardError
          blocked!("push_outcome_unknown", "remote push outcome requires reconciliation")
        end
        after = observe(request)
        unless after.fetch("oid") == request.head_oid
          blocked!("push_not_observed", "remote push was not observed at the reviewed head")
        end
        observation = {
          "expected_oid" => state.fetch("expected_remote_oid"),
          "before_oid" => receipt.fetch("before_oid"),
          "after_oid" => after.fetch("oid"),
          "remote_fingerprint" => after.fetch("remote_fingerprint")
        }
        write_state(state.merge(
          "phase" => "branch_observed", "push_observation" => observation,
          "updated_at" => timestamp
        ))
      end

      def reconcile_create(request, state, revalidate)
        remote = observe(request)
        unless remote.fetch("oid") == request.head_oid
          blocked!("remote_branch_conflict", "remote branch changed before pull-request creation")
        end
        attempts = state.fetch("create_attempts") + 1
        unless state.fetch("phase") == "pr_create_intent"
          state = write_state(state.merge(
            "phase" => "pr_create_intent", "updated_at" => timestamp
          ))
        end
        if state.fetch("create_attempted_at")
          blocked!("create_outcome_unknown", "pull-request create outcome requires reconciliation")
        end
        revalidate!(revalidate, :before_create)
        state = write_state(state.merge(
          "create_attempts" => attempts, "create_attempted_at" => timestamp,
          "updated_at" => timestamp
        ))
        begin
          @github.create_pull_request(
            request: request, publication_id: request.publication_id
          )
        rescue StandardError
          blocked!("create_outcome_unknown", "pull-request create outcome requires reconciliation")
        end
        owned = reconcile_pull_requests(request)
        return observe_pr(state, request, owned) if owned

        blocked!("create_not_observed", "pull-request creation was not present in the complete inventory")
      end

      def reconcile_pull_requests(request)
        records = complete_inventory(request)
        candidates = records.select do |record|
          record.fetch("head_branch") == request.branch ||
            record.fetch("body").lines.any? { |line| line.strip == request.marker }
        end
        return nil if candidates.empty?
        exact = candidates.select { |record| exact_owned?(record, request) }
        return exact.first if candidates.one? && exact.one?

        blocked!("pr_identity_conflict", "pull-request identity conflict requires operator reconciliation")
      end

      def complete_inventory(request)
        cursor = nil
        seen = {}
        records = []
        MAX_PAGES.times do
          page = @github.list_pull_requests(
            repository: request.repository, host: request.host,
            branch: request.branch, state: "all", cursor: cursor
          )
          validate_page!(page)
          blocked!("inventory_incomplete", "pull-request inventory is incomplete") if
            page.fetch("truncated") || !page.fetch("complete")
          records.concat(page.fetch("items").map { |record| validate_record!(record, request) })
          blocked!("inventory_capped", "pull-request inventory exceeds its safe traversal bound") if
            records.length > MAX_RECORDS
          unless records.map { |record| record.fetch("number") }.uniq.length == records.length
            blocked!("inventory_incomplete", "pull-request inventory contains duplicate records")
          end
          return records.freeze unless page.fetch("has_next_page")

          next_cursor = page.fetch("next_cursor")
          unless next_cursor.is_a?(String) && !next_cursor.empty? && !seen[next_cursor]
            blocked!("inventory_incomplete", "pull-request inventory pagination is incomplete")
          end
          seen[next_cursor] = true
          cursor = next_cursor
        end
        blocked!("inventory_capped", "pull-request inventory exceeds its safe traversal bound")
      rescue Blocked
        raise
      rescue StandardError
        blocked!("inventory_unavailable", "pull-request inventory is unavailable")
      end

      def validate_page!(page)
        fields = %w[items next_cursor has_next_page complete truncated]
        unless page.is_a?(Hash) && page.keys.sort == fields.sort &&
               page["items"].is_a?(Array) &&
               [ true, false ].include?(page["has_next_page"]) &&
               [ true, false ].include?(page["complete"]) &&
               [ true, false ].include?(page["truncated"])
          blocked!("inventory_incomplete", "pull-request inventory page is incomplete")
        end
        cursor = page.fetch("next_cursor")
        valid_cursor = page.fetch("has_next_page") ?
          cursor.is_a?(String) && !cursor.empty? : cursor.nil?
        blocked!("inventory_incomplete", "pull-request inventory cursor is incomplete") unless valid_cursor
      end

      def validate_record!(record, request)
        fields = %w[
          number url state draft head_branch head_oid head_repository
          base_branch base_repository title body
        ]
        unless record.is_a?(Hash) && record.keys.sort == fields.sort &&
               record["number"].is_a?(Integer) && record["number"].positive? &&
               %w[OPEN CLOSED MERGED].include?(record["state"]) &&
               [ true, false ].include?(record["draft"]) &&
               bounded_inventory_text?(record["title"], 1_024) &&
               bounded_inventory_text?(record["body"], 128 * 1_024)
          blocked!("inventory_invalid", "pull-request inventory record is invalid")
        end
        %w[head_branch head_oid base_branch base_repository].each do |key|
          unless record[key].is_a?(String) && !record[key].empty?
            blocked!("inventory_invalid", "pull-request inventory record is invalid")
          end
        end
        unless record["head_repository"].nil? ||
               (record["head_repository"].is_a?(String) && !record["head_repository"].empty?)
          blocked!("inventory_invalid", "pull-request inventory record is invalid")
        end
        unless record.fetch("head_oid").match?(OID)
          blocked!("inventory_invalid", "pull-request inventory record is invalid")
        end
        uri = URI.parse(record.fetch("url"))
        expected_path = "/#{request.repository}/pull/#{record.fetch('number')}"
        unless uri.scheme == "https" && uri.host&.casecmp?(request.host) &&
               uri.path.casecmp?(expected_path) && uri.userinfo.nil? &&
               uri.query.nil? && uri.fragment.nil?
          blocked!("inventory_invalid", "pull-request inventory record URL is invalid")
        end
        record
      rescue URI::InvalidURIError
        blocked!("inventory_invalid", "pull-request inventory record URL is invalid")
      end

      def bounded_inventory_text?(value, limit)
        value.is_a?(String) && value.valid_encoding? && !value.include?("\0") &&
          value.bytesize <= limit
      end

      def exact_owned?(record, request)
        record.fetch("body").lines.any? { |line| line.strip == request.marker } &&
          Digest::SHA256.hexdigest(record.fetch("title")) == request.title_digest &&
          Digest::SHA256.hexdigest(record.fetch("body")) == request.body_digest &&
          record.fetch("head_branch") == request.branch &&
          record.fetch("head_oid") == request.head_oid &&
          record.fetch("head_repository")&.casecmp?(request.repository) &&
          record.fetch("base_branch") == request.base_branch &&
          record.fetch("base_repository").casecmp?(request.repository)
      end

      def observe_pr(state, request, record)
        hosted = if record.fetch("state") == "OPEN"
          record.fetch("draft") ? "draft" : "open"
        else
          record.fetch("state").downcase
        end
        pr = identity(request).slice(
          "publication_id", "host", "repository", "base_branch",
          "creation_base_oid", "branch", "head_oid", "diff_digest",
          "title_digest", "body_digest", "marker_digest"
        ).merge(
          "number" => record.fetch("number"), "url" => record.fetch("url"),
          "hosted_state" => hosted, "observed_at" => timestamp
        )
        write_state(state.merge(
          "phase" => "pr_observed", "pr" => pr, "updated_at" => timestamp
        ))
      end

      def observe(request)
        value = @git.observe(
          worktree_path: request.worktree_path, branch: request.branch
        )
        unless value.is_a?(Hash) && value.keys.sort == %w[oid remote_fingerprint] &&
               (value["oid"].nil? || value["oid"].to_s.match?(OID)) &&
               value["remote_fingerprint"].to_s.match?(DIGEST)
          blocked!("remote_observation_invalid", "remote branch observation is invalid")
        end
        value
      rescue Blocked
        raise
      rescue StandardError
        blocked!("remote_observation_unavailable", "remote branch observation is unavailable")
      end

      def ensure_secret_free!(request)
        fields = { "title" => request.title, "body" => request.published_body, "diff" => request.diff }
        detected = fields.keys.select { |key| Hive::SecretPatterns.match?(fields.fetch(key)) }
        return if detected.empty?

        blocked!("secret_detected", "publication secret policy blocked #{detected.join(', ')} bytes")
      end

      def revalidate!(callable, phase)
        return if callable.call(phase).equal?(true)
        blocked!("stale_authority", "publication authority changed before #{phase}")
      rescue Blocked
        raise
      rescue StandardError
        blocked!("stale_authority", "publication authority could not be revalidated before #{phase}")
      end

      def identity(request)
        {
          "publication_id" => request.publication_id,
          "task" => request.task, "generation" => request.generation,
          "evidence_digest" => request.evidence_digest,
          "review_receipt_id" => request.review_receipt_id,
          "host" => request.host, "repository" => request.repository,
          "base_branch" => request.base_branch,
          "creation_base_oid" => request.creation_base_oid,
          "branch" => request.branch, "head_oid" => request.head_oid,
          "diff_digest" => request.diff_digest,
          "title_digest" => request.title_digest,
          "body_digest" => request.body_digest,
          "marker_digest" => request.marker_digest,
          "draft" => request.draft
        }
      end

      def validate_request!(state, request)
        expected = identity(request)
        mismatches = expected.keys.reject { |key| state[key] == expected[key] }
        blocked!("identity_drift", "publication identity changed: #{mismatches.join(', ')}") unless mismatches.empty?
      end

      def read_state
        bytes = @directory.read(@state_name, max_bytes: MAX_STATE_BYTES, missing: true)
        return unless bytes
        validate_state(JSON.parse(bytes))
      rescue JSON::ParserError
        blocked!("state_corrupt", "publication state is malformed")
      end

      def write_state(state)
        document = validate_state(state)
        @directory.atomic_write(
          @state_name, JSON.generate(document.sort.to_h) + "\n",
          mode: 0o600, max_existing_bytes: MAX_STATE_BYTES
        )
        document.freeze
      end

      def validate_state(state)
        unless state.is_a?(Hash) && state.keys.sort == STATE_FIELDS.sort &&
               state["schema"] == SCHEMA && state["schema_version"] == SCHEMA_VERSION &&
               PHASES.include?(state["phase"]) && state["publication_id"].to_s.match?(PUBLICATION_ID) &&
               state["generation"].is_a?(Integer) && state["generation"].positive? &&
               state["evidence_digest"].to_s.match?(DIGEST) &&
               state["creation_base_oid"].to_s.match?(OID) &&
               state["head_oid"].to_s.match?(OID) &&
               state["diff_digest"].to_s.match?(DIGEST) &&
               state["title_digest"].to_s.match?(DIGEST) &&
               state["body_digest"].to_s.match?(DIGEST) &&
               state["marker_digest"].to_s.match?(DIGEST) &&
               [ true, false ].include?(state["draft"]) &&
               state["expected_remote_oid"].nil? &&
               state["create_attempts"].is_a?(Integer) && state["create_attempts"] >= 0
          blocked!("state_corrupt", "publication state contract is invalid")
        end
        %w[task review_receipt_id host repository base_branch branch].each do |key|
          blocked!("state_corrupt", "publication state contract is invalid") unless
            state[key].is_a?(String) && !state[key].empty?
        end
        %w[push_attempted_at create_attempted_at].each do |key|
          Time.iso8601(state[key]) if state[key]
        end
        Time.iso8601(state.fetch("updated_at"))
        validate_state_relations!(state)
        state
      rescue ArgumentError, KeyError, TypeError
        blocked!("state_corrupt", "publication state contract is invalid")
      end

      def validate_state_relations!(state)
        phase = state.fetch("phase")
        push = state.fetch("push_observation")
        pr = state.fetch("pr")
        push_required = %w[branch_observed pr_create_intent].include?(phase)
        unless (!push_required && push.nil?) || (push_required && valid_push_observation?(push, state)) ||
               (phase == "pr_observed" && (push.nil? || valid_push_observation?(push, state)))
          blocked!("state_corrupt", "publication state phase evidence is invalid")
        end
        if %w[prepared push_intent branch_observed].include?(phase)
          unless state.fetch("create_attempts").zero? && state.fetch("create_attempted_at").nil? && pr.nil?
            blocked!("state_corrupt", "publication state create evidence is invalid")
          end
        elsif phase == "pr_create_intent"
          unless pr.nil? && [ 0, 1 ].include?(state.fetch("create_attempts")) &&
                 (state.fetch("create_attempts") == 1) == !state.fetch("create_attempted_at").nil?
            blocked!("state_corrupt", "publication state create evidence is invalid")
          end
        elsif phase == "pr_observed"
          unless valid_pr_observation?(pr, state) && [ 0, 1 ].include?(state.fetch("create_attempts")) &&
                 (state.fetch("create_attempts") == 1) == !state.fetch("create_attempted_at").nil?
            blocked!("state_corrupt", "publication state pull-request evidence is invalid")
          end
        end
        if phase == "prepared" && state.fetch("push_attempted_at")
          blocked!("state_corrupt", "publication state push evidence is invalid")
        end
        if push && state.fetch("push_attempted_at").nil?
          blocked!("state_corrupt", "publication state push evidence is invalid")
        end
        if phase == "pr_observed"
          imported = push.nil? && state.fetch("push_attempted_at").nil? &&
            state.fetch("create_attempts").zero?
          created = !push.nil? && !state.fetch("push_attempted_at").nil? &&
            state.fetch("create_attempts") == 1
          unless imported || created
            blocked!("state_corrupt", "publication state provenance is invalid")
          end
        end
      end

      def valid_push_observation?(value, state)
        return false unless value.is_a?(Hash) && value.keys.sort ==
          %w[after_oid before_oid expected_oid remote_fingerprint]
        value["expected_oid"] == state["expected_remote_oid"] &&
          value["before_oid"] == state["expected_remote_oid"] &&
          value["after_oid"] == state["head_oid"] &&
          value["remote_fingerprint"].to_s.match?(DIGEST)
      end

      def validate_push_receipt!(value, state, request)
        fields = %w[expected_oid before_oid after_oid remote_fingerprint]
        unless value.is_a?(Hash) && value.keys.sort == fields.sort &&
               value["expected_oid"] == state.fetch("expected_remote_oid") &&
               value["before_oid"] == state.fetch("expected_remote_oid") &&
               value["after_oid"] == request.head_oid &&
               value["remote_fingerprint"].to_s.match?(DIGEST)
          blocked!("push_outcome_unknown", "remote push outcome requires reconciliation")
        end
      end

      def valid_pr_observation?(value, state)
        fields = %w[
          publication_id host repository base_branch creation_base_oid branch
          head_oid diff_digest title_digest body_digest marker_digest number url
          hosted_state observed_at
        ]
        return false unless value.is_a?(Hash) && value.keys.sort == fields.sort
        identity_fields = fields - %w[number url hosted_state observed_at]
        return false unless identity_fields.all? { |key| value[key] == state[key] }
        return false unless value["number"].is_a?(Integer) && value["number"].positive?
        return false unless %w[open draft closed merged].include?(value["hosted_state"])
        Time.iso8601(value.fetch("observed_at"))
        uri = URI.parse(value.fetch("url").to_s)
        uri.scheme == "https" && uri.host&.casecmp?(state.fetch("host")) &&
          uri.path.casecmp?("/#{state.fetch('repository')}/pull/#{value.fetch('number')}") &&
          uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil?
      rescue ArgumentError, KeyError, URI::InvalidURIError
        false
      end

      def timestamp = @clock.call.utc.iso8601(6)
      def blocked!(code, message) = raise(Blocked.new(code, message))
    end
  end
end
