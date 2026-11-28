require "digest"
require "fileutils"
require "hive/errors"
require "hive/git_ref"
require "hive/managed_git"

module Hive
  # Hardened, policy-light Git operations used after an agent has edited a
  # repository. The facade deliberately exposes a closed authority vocabulary:
  # bounded repository reads, exact detached materialization, remote
  # observation, and exact expected-state publication.
  #
  # This is application-level process hardening, not a Git or operating-system
  # sandbox. Hive remains responsible for credentials, transport policy,
  # branch naming, durable intent, PR workflow, and operator approval.
  module AgentGitGate
    OID = /\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/
    REMOTE_NAME = /\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/
    SAFE_REMOTE_SCHEMES = %w[git https ssh].freeze
    NETWORK_TIMEOUT_SEC = Hive::ManagedGit::NETWORK_TIMEOUT_SEC

    class Error < Hive::Error; end
    class InvalidRequest < Error; end
    class UnsupportedOperation < InvalidRequest; end
    class CommandFailed < Error; end
    class DeadlineExceeded < CommandFailed; end
    class RemoteConflict < Error; end
    class MaterializationFailed < Error; end
    class PublicationFailed < Error; end
    class CheckoutRefused < Error
      REASONS = %i[
        ignored_obstruction dirty_worktree branch_moved local_head_moved
        command_failed
      ].freeze

      attr_reader :reason

      def initialize(reason, message)
        raise ArgumentError, "unknown checkout refusal #{reason.inspect}" unless REASONS.include?(reason)

        @reason = reason
        super(message)
      end
    end
    # A local fast-forward precondition does not hold. `reason` is a stable
    # symbol so callers can name the exact operator action.
    class FastForwardRefused < Error
      REASONS = %i[
        branch_moved local_head_moved dirty_worktree remote_object_unavailable
        not_fast_forward
      ].freeze

      attr_reader :reason

      def initialize(reason, message)
        raise ArgumentError, "unknown fast-forward refusal #{reason.inspect}" unless REASONS.include?(reason)

        @reason = reason
        super(message)
      end
    end

    ReadResult = Data.define(
      :operation, :stdout, :stderr, :exitstatus, :overflow
    ) do
      def initialize(operation:, stdout:, stderr:, exitstatus:, overflow:)
        unless operation.is_a?(String) || operation.is_a?(Symbol)
          raise InvalidRequest, "read result operation is invalid"
        end
        unless stdout.is_a?(String) && stderr.is_a?(String)
          raise InvalidRequest, "read result output is invalid"
        end
        unless overflow == true || overflow == false
          raise InvalidRequest, "read result overflow state is invalid"
        end

        # A bounded capture kills an overflowing child, so the process may
        # die by signal and report no exit status at all. That is expected
        # exactly when overflow was proven; otherwise a missing status stays
        # invalid.
        status =
          begin
            Integer(exitstatus)
          rescue ArgumentError, TypeError
            raise InvalidRequest, "read result exit status is invalid" unless overflow == true

            0
          end
        raise InvalidRequest, "read result exit status is invalid" if status.negative?

        super(
          operation: operation.to_sym,
          stdout: stdout.dup.freeze,
          stderr: stderr.dup.freeze,
          exitstatus: status,
          overflow: overflow
        )
      end

      def success?
        exitstatus.to_i.zero? && !overflow
      end
    end

    RemoteObservation = Data.define(
      :remote_fingerprint, :branch, :ref, :oid
    ) do
      def initialize(remote_fingerprint:, branch:, ref:, oid:)
        fingerprint = remote_fingerprint.to_s.downcase
        unless fingerprint.match?(/\A[0-9a-f]{64}\z/)
          raise InvalidRequest, "remote observation fingerprint is invalid"
        end

        name = Hive::GitRef.validate_branch_name(branch)
        expected_ref = "refs/heads/#{name}"
        unless ref.to_s == expected_ref
          raise InvalidRequest, "remote observation ref does not match its branch"
        end

        normalized_oid = oid&.to_s&.downcase
        if normalized_oid && !normalized_oid.match?(OID)
          raise InvalidRequest, "remote observation OID is invalid"
        end

        super(
          remote_fingerprint: fingerprint.dup.freeze,
          branch: name.dup.freeze,
          ref: expected_ref.freeze,
          oid: normalized_oid&.dup&.freeze
        )
      rescue ArgumentError, TypeError
        raise InvalidRequest, "remote observation is invalid"
      end

      def present?
        !oid.nil?
      end
    end

    MaterializationReceipt = Data.define(
      :destination, :oid, :disposition
    ) do
      def initialize(destination:, oid:, disposition:)
        path = destination.to_s
        unless !path.empty? && !path.match?(/[\0\r\n]/) &&
               File.expand_path(path) == path
          raise InvalidRequest, "materialization receipt destination is invalid"
        end

        normalized_oid = oid.to_s.downcase
        unless normalized_oid.match?(OID)
          raise InvalidRequest, "materialization receipt OID is invalid"
        end
        unless %i[created existing].include?(disposition)
          raise InvalidRequest, "materialization receipt disposition is invalid"
        end

        super(
          destination: path.dup.freeze,
          oid: normalized_oid.dup.freeze,
          disposition: disposition
        )
      end
    end

    PublicationReceipt = Data.define(
      :remote_fingerprint, :branch, :expected_oid, :before_oid,
      :published_oid, :after_oid
    ) do
      def initialize(remote_fingerprint:, branch:, expected_oid:, before_oid:,
                     published_oid:, after_oid:)
        fingerprint = remote_fingerprint.to_s.downcase
        unless fingerprint.match?(/\A[0-9a-f]{64}\z/)
          raise InvalidRequest, "publication receipt fingerprint is invalid"
        end

        name = Hive::GitRef.validate_branch_name(branch)
        expected = normalized_optional_oid(expected_oid, "expected")
        before = normalized_optional_oid(before_oid, "before")
        published = normalized_oid(published_oid, "published")
        after = normalized_oid(after_oid, "after")
        unless expected == before
          raise InvalidRequest, "publication receipt expectation does not match before state"
        end
        unless published == after
          raise InvalidRequest, "publication receipt published state is not verified"
        end

        super(
          remote_fingerprint: fingerprint.dup.freeze,
          branch: name.dup.freeze,
          expected_oid: expected&.dup&.freeze,
          before_oid: before&.dup&.freeze,
          published_oid: published.dup.freeze,
          after_oid: after.dup.freeze
        )
      rescue ArgumentError, TypeError
        raise InvalidRequest, "publication receipt is invalid"
      end

      def success?
        after_oid == published_oid
      end

      private

      def normalized_optional_oid(value, label)
        return if value.nil?

        normalized_oid(value, label)
      end

      def normalized_oid(value, label)
        value = value.to_s.downcase
        unless value.match?(OID)
          raise InvalidRequest, "publication receipt #{label} OID is invalid"
        end

        value
      end
    end

    FastForwardReceipt = Data.define(
      :remote_fingerprint, :branch, :before_oid, :after_oid
    ) do
      def initialize(remote_fingerprint:, branch:, before_oid:, after_oid:)
        fingerprint = remote_fingerprint.to_s.downcase
        unless fingerprint.match?(/\A[0-9a-f]{64}\z/)
          raise InvalidRequest, "fast-forward receipt fingerprint is invalid"
        end

        name = Hive::GitRef.validate_branch_name(branch)
        before = before_oid.to_s.downcase
        after = after_oid.to_s.downcase
        unless before.match?(OID) && after.match?(OID) && before != after
          raise InvalidRequest, "fast-forward receipt OIDs are invalid"
        end

        super(
          remote_fingerprint: fingerprint.dup.freeze,
          branch: name.dup.freeze,
          before_oid: before.dup.freeze,
          after_oid: after.dup.freeze
        )
      rescue ArgumentError, TypeError
        raise InvalidRequest, "fast-forward receipt is invalid"
      end
    end

    PullRequestObservation = Data.define(
      :remote_fingerprint, :pr_number, :ref, :oid
    ) do
      def initialize(remote_fingerprint:, pr_number:, ref:, oid:)
        fingerprint = remote_fingerprint.to_s.downcase
        unless fingerprint.match?(/\A[0-9a-f]{64}\z/)
          raise InvalidRequest, "pull request observation fingerprint is invalid"
        end

        number = Integer(pr_number)
        raise InvalidRequest, "pull request number must be positive" unless number.positive?

        expected_ref = "refs/pull/#{number}/head"
        unless ref.to_s == expected_ref
          raise InvalidRequest, "pull request observation ref does not match its PR number"
        end

        normalized_oid = oid&.to_s&.downcase
        if normalized_oid && !normalized_oid.match?(OID)
          raise InvalidRequest, "pull request observation OID is invalid"
        end

        super(
          remote_fingerprint: fingerprint.dup.freeze,
          pr_number: number,
          ref: expected_ref.freeze,
          oid: normalized_oid&.dup&.freeze
        )
      rescue ArgumentError, TypeError
        raise InvalidRequest, "pull request observation is invalid"
      end

      def present?
        !oid.nil?
      end
    end

    QuarantineFetchReceipt = Data.define(
      :remote_fingerprint, :pr_number, :ref, :quarantine_ref, :oid
    ) do
      def initialize(remote_fingerprint:, pr_number:, ref:, quarantine_ref:, oid:)
        fingerprint = remote_fingerprint.to_s.downcase
        unless fingerprint.match?(/\A[0-9a-f]{64}\z/)
          raise InvalidRequest, "quarantine fetch receipt fingerprint is invalid"
        end

        number = Integer(pr_number)
        raise InvalidRequest, "pull request number must be positive" unless number.positive?

        expected_ref = "refs/pull/#{number}/head"
        unless ref.to_s == expected_ref
          raise InvalidRequest, "quarantine fetch receipt ref does not match its PR number"
        end

        qref = quarantine_ref.to_s
        unless qref.start_with?("refs/hive/internal-pr-checkout/")
          raise InvalidRequest, "quarantine ref is outside the internal-pr-checkout namespace"
        end

        normalized_oid = oid.to_s.downcase
        unless normalized_oid.match?(OID)
          raise InvalidRequest, "quarantine fetch receipt OID is invalid"
        end

        super(
          remote_fingerprint: fingerprint.dup.freeze,
          pr_number: number,
          ref: expected_ref.freeze,
          quarantine_ref: qref.dup.freeze,
          oid: normalized_oid.dup.freeze
        )
      rescue ArgumentError, TypeError
        raise InvalidRequest, "quarantine fetch receipt is invalid"
      end
    end

    module_function

    # Execute one closed, read-only Git operation. Callers receive process
    # status as data because ancestry checks intentionally use exit 1 for
    # "false". Unknown operations and unknown arguments fail before spawn.
    def read(repository_path, operation, max_stdout_bytes: nil, **parameters)
      args = read_arguments(operation, parameters)
      out, err, status, overflow = capture(
        repository_path, args,
        max_stdout_bytes: max_stdout_bytes
      )
      ReadResult.new(
        operation: operation.to_sym,
        stdout: immutable(out),
        stderr: immutable(err),
        exitstatus: status.exitstatus,
        overflow: overflow
      )
    rescue ArgumentError, TypeError => e
      raise InvalidRequest, e.message
    end

    # External readers such as Betterleaks inherit the same no-helper Git
    # policy as closed reads, without reaching into ManagedGit themselves.
    def read_environment
      env = { "GIT_CONFIG_GLOBAL" => File::NULL, "GIT_CONFIG_NOSYSTEM" => "1",
              "GIT_CONFIG_COUNT" => Hive::ManagedGit::CONFIG.length.to_s }
      Hive::ManagedGit::CONFIG.each_with_index do |entry, index|
        key, value = entry.split("=", 2)
        env["GIT_CONFIG_KEY_#{index}"] = key
        env["GIT_CONFIG_VALUE_#{index}"] = value
      end
      env
    end

    # The creation OID is provenance, not the current PR diff base. Prefer
    # the remote-tracking target and use a local target for offline repositories.
    def change_base(repository_path, branch:, head_oid:)
      target = read(repository_path, :branch_oid, branch: branch, remote: true)
      target = read(repository_path, :branch_oid, branch: branch) unless target.success?
      raise CommandFailed, "PR base branch is unavailable" unless target.success?

      base = read(repository_path, :merge_base, base_oid: target.stdout.strip, head_oid: head_oid)
      raise CommandFailed, "PR merge-base is unavailable" unless base.success?

      base.stdout.strip
    end

    def diff_digest(path, base_oid:, head_oid:)
      repository = repository_path(path)
      validate_repository_config!(repository)
      arguments = read_arguments(:diff, { base_oid: base_oid, head_oid: head_oid })
      digest = Digest::SHA256.new
      Hive::ManagedGit.popen3(repository, *arguments) do |input, output, error, process|
        input.close
        drain = Thread.new { IO.copy_stream(error, File::NULL) }
        while (chunk = output.read(16 * 1024))
          digest << chunk
        end
        drain.value
        raise CommandFailed, "publication diff is unavailable" unless process.value.success?
      end
      digest.hexdigest
    end

    def observe_remote_branch(repository_path:, branch:, remote: "origin",
                              allow_local_transport: false, timeout_sec: nil, deadline: nil)
      name = branch_name(branch)
      target = resolve_remote_target(
        repository_path, remote, push: false,
        allow_local_transport: allow_local_transport
      )
      observe_resolved_remote(
        repository_path, target, name,
        allow_local_transport: allow_local_transport,
        timeout_sec: effective_timeout(timeout_sec: timeout_sec, deadline: deadline)
      )
    end

    def verify_repository_config!(repository_path)
      repository = repository_path(repository_path)
      validate_repository_config!(repository)
      true
    end

    def remote_target_fingerprint(repository_path:, remote: "origin", push: false,
                                  allow_local_transport: false)
      repository = repository_path(repository_path)
      validate_repository_config!(repository)
      target = resolve_remote_target(
        repository, remote, push: push,
        allow_local_transport: allow_local_transport
      )
      immutable(remote_fingerprint(target))
    end

    def observe_pull_request_head(repository_path:, pr_number:, remote: "origin",
                                  expected_remote_fingerprint: nil,
                                  allow_local_transport: false,
                                  timeout_sec: nil, deadline: nil)
      repository = repository_path(repository_path)
      validate_repository_config!(repository)
      number = positive_pr_number(pr_number)
      target = resolve_remote_target(
        repository, remote, push: false,
        allow_local_transport: allow_local_transport
      )
      fingerprint = remote_fingerprint(target)
      if expected_remote_fingerprint &&
         fingerprint != expected_remote_fingerprint.to_s.downcase
        raise RemoteConflict, "remote target changed after observation"
      end

      observe_resolved_pull_request(
        repository, target, number, fingerprint,
        allow_local_transport: allow_local_transport,
        timeout_sec: effective_timeout(timeout_sec: timeout_sec, deadline: deadline)
      )
    end

    # Fetch one exact pull-request head commit without side effects on tags,
    # ordinary tracking refs, or FETCH_HEAD, then install the caller's
    # transaction-scoped quarantine ref strictly from absence at that exact OID.
    def fetch_pull_request_commit(repository_path:, pr_number:, expected_oid:,
                                  quarantine_ref:, remote: "origin",
                                  expected_remote_fingerprint: nil,
                                  allow_local_transport: false,
                                  timeout_sec: nil, deadline: nil)
      repository = repository_path(repository_path)
      validate_repository_config!(repository)
      number = positive_pr_number(pr_number)
      expected = exact_oid(expected_oid, label: "expected PR head OID")
      qref = validated_internal_pr_ref(quarantine_ref, label: "quarantine ref")

      if read(repository, :ref_oid, ref: qref).success?
        raise RemoteConflict, "quarantine ref already exists"
      end

      target = resolve_remote_target(
        repository, remote, push: false,
        allow_local_transport: allow_local_transport
      )
      fingerprint = remote_fingerprint(target)
      if expected_remote_fingerprint &&
         fingerprint != expected_remote_fingerprint.to_s.downcase
        raise RemoteConflict, "remote target changed after observation"
      end

      before = observe_resolved_pull_request(
        repository, target, number, fingerprint,
        allow_local_transport: allow_local_transport,
        timeout_sec: effective_timeout(timeout_sec: timeout_sec, deadline: deadline)
      )
      unless before.present? && before.oid == expected
        raise RemoteConflict, "remote pull request head changed before exact fetch"
      end

      pr_ref = "refs/pull/#{number}/head"
      _out, err, status, _overflow = capture(
        repository,
        [ "fetch", "--no-tags", "--no-write-fetch-head", target, pr_ref ],
        allow_local_transport: allow_local_transport,
        timeout_sec: effective_timeout(timeout_sec: timeout_sec, deadline: deadline)
      )
      unless status.success?
        if err.include?("managed Git command timed out")
          raise DeadlineExceeded, "pull request fetch timed out"
        end
        raise CommandFailed, "observed pull request commit could not be fetched"
      end

      after = observe_resolved_pull_request(
        repository, target, number, fingerprint,
        allow_local_transport: allow_local_transport,
        timeout_sec: effective_timeout(timeout_sec: timeout_sec, deadline: deadline)
      )
      unless after.present? && after.oid == expected
        raise RemoteConflict, "remote pull request head changed during exact fetch"
      end

      commit = read(repository, :commit_oid, oid: expected)
      unless commit.success? && commit.stdout.strip.downcase == expected
        raise RemoteConflict, "fetched pull request commit does not match expected OID"
      end

      zero = "0" * expected.length
      command!(
        repository, "update-ref", qref, expected, zero,
        error_class: RemoteConflict,
        message: "quarantine ref could not be installed from absence"
      )
      installed = read(repository, :ref_oid, ref: qref)
      unless installed.success? && installed.stdout.strip.downcase == expected
        raise RemoteConflict, "quarantine ref installation could not be verified"
      end

      QuarantineFetchReceipt.new(
        remote_fingerprint: immutable(fingerprint),
        pr_number: number,
        ref: immutable(pr_ref),
        quarantine_ref: immutable(qref),
        oid: immutable(expected)
      )
    end

    def ensure_immutable_ref(repository_path:, ref:, oid:)
      repository = repository_path(repository_path)
      validate_repository_config!(repository)
      target_ref = validated_internal_pr_ref(ref, label: "immutable archive ref")
      expected = exact_oid(oid, label: "immutable archive OID")
      commit = read(repository, :commit_oid, oid: expected)
      unless commit.success? && commit.stdout.strip.downcase == expected
        raise CommandFailed, "immutable archive commit is unavailable"
      end

      existing = read(repository, :ref_oid, ref: target_ref)
      if existing.success?
        current = existing.stdout.strip.downcase
        return :existing if current == expected

        raise RemoteConflict, "immutable archive ref already points to a different commit"
      end

      zero = "0" * expected.length
      command!(
        repository, "update-ref", target_ref, expected, zero,
        error_class: RemoteConflict,
        message: "immutable archive ref could not be installed from absence"
      )
      :created
    end

    def delete_ref_if_matches(repository_path:, ref:, expected_oid:)
      repository = repository_path(repository_path)
      validate_repository_config!(repository)
      target_ref = validated_owned_deletable_ref(ref)
      expected = exact_oid(expected_oid, label: "expected ref OID")
      existing = read(repository, :ref_oid, ref: target_ref)
      return :absent unless existing.success?

      current = existing.stdout.strip.downcase
      unless current == expected
        raise RemoteConflict, "ref no longer matches expected OID"
      end

      command!(
        repository, "update-ref", "-d", target_ref, expected,
        error_class: RemoteConflict,
        message: "ref could not be removed at expected OID"
      )
      :deleted
    end

    def update_branch_ref(repository_path:, branch:, new_oid:, expected_old_oid:)
      repository = repository_path(repository_path)
      validate_repository_config!(repository)
      name = branch_name(branch)
      target = exact_oid(new_oid, label: "new branch OID")
      expected_old = exact_oid(expected_old_oid, label: "expected old branch OID")
      commit = read(repository, :commit_oid, oid: target)
      unless commit.success? && commit.stdout.strip.downcase == target
        raise CommandFailed, "target branch commit is unavailable"
      end

      command!(
        repository, "update-ref", "refs/heads/#{name}", target, expected_old,
        error_class: RemoteConflict,
        message: "owned branch ref moved before expected-OID update"
      )
      verified = read(repository, :branch_oid, branch: name)
      unless verified.success? && verified.stdout.strip.downcase == target
        raise CommandFailed, "owned branch ref update could not be verified"
      end

      immutable(target)
    end

    def checkout_detached_preserving_ignored(repository_path:, oid:)
      repository = repository_path(repository_path)
      validate_repository_config!(repository)
      expected = exact_oid(oid, label: "checkout OID")
      commit = read(repository, :commit_oid, oid: expected)
      unless commit.success? && commit.stdout.strip.downcase == expected
        raise CheckoutRefused.new(:command_failed, "checkout target commit is unavailable")
      end

      _out, err, status, _overflow = capture(
        repository, [ "checkout", "--no-overwrite-ignore", "--detach", expected ]
      )
      unless status.success?
        if err.match?(/untracked working tree files would be overwritten|Updating the following directories would lose untracked files/i)
          raise CheckoutRefused.new(
            :ignored_obstruction,
            "checkout refused to overwrite untracked or ignored local files"
          )
        end
        if err.match?(/local changes.*would be overwritten/i)
          raise CheckoutRefused.new(
            :dirty_worktree,
            "checkout refused because local tracked changes would be overwritten"
          )
        end
        raise CheckoutRefused.new(:command_failed, "exact detached checkout failed")
      end

      head = read(repository, :head_oid)
      unless head.success? && head.stdout.strip.downcase == expected
        raise CheckoutRefused.new(:command_failed, "detached checkout HEAD could not be verified")
      end
      immutable(expected)
    end

    def attach_branch_head(repository_path:, branch:, expected_oid:)
      repository = repository_path(repository_path)
      validate_repository_config!(repository)
      name = branch_name(branch)
      expected = exact_oid(expected_oid, label: "expected branch OID")
      branch_tip = read(repository, :branch_oid, branch: name)
      unless branch_tip.success? && branch_tip.stdout.strip.downcase == expected
        raise RemoteConflict, "owned branch ref does not match expected commit before attach"
      end
      head = read(repository, :head_oid)
      unless head.success? && head.stdout.strip.downcase == expected
        raise RemoteConflict, "worktree HEAD does not match expected commit before attach"
      end

      command!(
        repository, "symbolic-ref", "HEAD", "refs/heads/#{name}",
        error_class: CommandFailed,
        message: "owned branch HEAD attach failed"
      )
      current = read(repository, :current_branch)
      final_head = read(repository, :head_oid)
      unless current.success? && current.stdout.strip == name &&
             final_head.success? && final_head.stdout.strip.downcase == expected
        raise CommandFailed, "owned branch HEAD attach could not be verified"
      end
      immutable(expected)
    end

    # Recovery-only helper called after GitTransition has proven every tracked
    # index and worktree path belongs strictly to {from_tree, to_tree} and no
    # untracked or ignored obstruction exists for `target_oid`.
    def recover_index_and_worktree(repository_path:, target_oid:)
      repository = repository_path(repository_path)
      validate_repository_config!(repository)
      expected = exact_oid(target_oid, label: "recovery target OID")
      commit = read(repository, :commit_oid, oid: expected)
      unless commit.success? && commit.stdout.strip.downcase == expected
        raise CommandFailed, "recovery target commit is unavailable"
      end

      command!(
        repository, "read-tree", "--reset", expected,
        error_class: CommandFailed,
        message: "recovery index reset failed"
      )
      command!(
        repository, "checkout-index", "--all", "--force",
        error_class: CommandFailed,
        message: "recovery working tree checkout failed"
      )
      command!(
        repository, "update-ref", "--no-deref", "HEAD", expected,
        error_class: CommandFailed,
        message: "recovery HEAD update failed"
      )
      immutable(expected)
    end

    def materialize_owned_branch(repository_path:, branch:, oid:, destination:, destination_root:)
      repository = repository_path(repository_path)
      validate_repository_config!(repository)
      name = branch_name(branch)
      expected = exact_oid(oid, label: "materialization OID")
      target = contained_destination(destination, destination_root)

      resolved = command!(
        repository, "rev-parse", "--verify", "#{expected}^{commit}",
        error_class: MaterializationFailed,
        message: "materialization object is unavailable"
      ).strip.downcase
      unless resolved == expected
        raise MaterializationFailed,
              "materialization object does not resolve to the exact requested commit"
      end

      if File.exist?(target) || File.symlink?(target) || worktree_paths(repository).include?(target)
        raise MaterializationFailed,
              "owned branch destination already exists or is registered"
      end
      if read(repository, :branch_oid, branch: name).success?
        raise MaterializationFailed, "owned branch #{name} already exists"
      end

      FileUtils.mkdir_p(File.dirname(target))
      command!(
        repository, "worktree", "add", "-b", name, target, expected,
        error_class: MaterializationFailed,
        message: "owned branch materialization failed"
      )
      current_branch = read(target, :current_branch)
      head = read(target, :head_oid)
      status = read(target, :status)
      unless current_branch.success? && current_branch.stdout.strip == name &&
             head.success? && head.stdout.strip.downcase == expected &&
             status.success? && status.stdout.empty?
        raise MaterializationFailed, "owned branch materialization could not be verified"
      end

      MaterializationReceipt.new(
        destination: immutable(target), oid: immutable(expected),
        disposition: :created
      )
    rescue SystemCallError => e
      raise MaterializationFailed, "materialization filesystem operation failed: #{e.class}"
    end

    # Materialize an already-present immutable commit into a detached worktree
    # constrained to an explicitly supplied destination root.
    def materialize(repository_path:, oid:, destination:, destination_root:)
      repository = repository_path(repository_path)
      expected = exact_oid(oid, label: "materialization OID")
      target = contained_destination(destination, destination_root)
      resolved = command!(
        repository, "rev-parse", "--verify", "#{expected}^{commit}",
        error_class: MaterializationFailed,
        message: "materialization object is unavailable"
      ).strip.downcase
      unless resolved == expected
        raise MaterializationFailed,
              "materialization object does not resolve to the exact requested commit"
      end

      paths = worktree_paths(repository)
      if File.directory?(target) && paths.include?(target)
        verify_materialization!(target, expected)
        return MaterializationReceipt.new(
          destination: immutable(target), oid: immutable(expected),
          disposition: :existing
        )
      end
      if File.exist?(target)
        raise MaterializationFailed,
              "materialization destination exists outside the repository worktree registry"
      end

      if paths.include?(target)
        command!(
          repository, "worktree", "prune", "--expire", "now",
          error_class: MaterializationFailed,
          message: "stale materialization registration could not be pruned"
        )
      end

      FileUtils.mkdir_p(File.dirname(target))
      command!(
        repository, "worktree", "add", "--detach", target, expected,
        error_class: MaterializationFailed,
        message: "exact detached materialization failed"
      )
      verify_materialization!(target, expected)
      MaterializationReceipt.new(
        destination: immutable(target), oid: immutable(expected),
        disposition: :created
      )
    rescue SystemCallError => e
      raise MaterializationFailed, "materialization filesystem operation failed: #{e.class}"
    end

    # Observe one remote ref, fetch that exact ref, reject movement, then
    # materialize the observed immutable commit. The remote target is resolved
    # again and fingerprinted so a named remote rewrite cannot redirect the
    # second half of the operation.
    def materialize_remote(repository_path:, remote:, observation:,
                           destination:, destination_root:,
                           allow_local_transport: false)
      unless observation.is_a?(RemoteObservation) && observation.present?
        raise InvalidRequest, "remote materialization requires a present RemoteObservation"
      end

      repository = repository_path(repository_path)
      target = resolve_remote_target(
        repository, remote, push: false,
        allow_local_transport: allow_local_transport
      )
      unless remote_fingerprint(target) == observation.remote_fingerprint
        raise RemoteConflict, "remote target changed after observation"
      end

      command!(
        repository, "fetch", "--no-tags", target, observation.ref,
        allow_local_transport: allow_local_transport,
        timeout_sec: NETWORK_TIMEOUT_SEC,
        error_class: MaterializationFailed,
        message: "observed remote object could not be fetched"
      )
      fetched = command!(
        repository, "rev-parse", "--verify", "FETCH_HEAD^{commit}",
        error_class: MaterializationFailed,
        message: "fetched remote object could not be resolved"
      ).strip.downcase
      unless fetched == observation.oid
        raise RemoteConflict,
              "remote branch moved after observation; exact materialization refused"
      end

      materialize(
        repository_path: repository, oid: observation.oid,
        destination: destination, destination_root: destination_root
      )
    end

    # Publish an immutable local commit only when the remote ref matches the
    # caller's exact expected OID or exact expected absence. A successful
    # process exit is not proof: the remote is observed again and the typed
    # receipt is returned only when it names the published OID.
    def publish(repository_path:, oid:, branch:, remote: "origin",
                expected_remote_oid: nil, expected_remote_absent: false,
                allow_local_transport: false)
      published = exact_oid(oid, label: "publication OID")
      name = branch_name(branch)
      expected = publication_expectation(
        expected_remote_oid, expected_remote_absent
      )
      repository = repository_path(repository_path)

      local = command!(
        repository, "rev-parse", "--verify", "#{published}^{commit}",
        error_class: PublicationFailed,
        message: "publication object is unavailable"
      ).strip.downcase
      unless local == published
        raise PublicationFailed,
              "publication object does not resolve to the exact requested commit"
      end

      target = resolve_remote_target(
        repository, remote, push: true,
        allow_local_transport: allow_local_transport
      )
      before = observe_resolved_remote(
        repository, target, name,
        allow_local_transport: allow_local_transport
      )
      expected_before = expected_remote_absent ? nil : expected
      unless before.oid == expected_before
        raise RemoteConflict,
              "remote branch changed before exact publication"
      end

      ref = "refs/heads/#{name}"
      lease = "--force-with-lease=#{ref}:#{expected_before}"
      refspec = "#{published}:#{ref}"
      _out, _err, status, _overflow = capture(
        repository, [ "push", lease, target, refspec ],
        allow_local_transport: allow_local_transport,
        timeout_sec: NETWORK_TIMEOUT_SEC
      )
      after = observe_resolved_remote(
        repository, target, name,
        allow_local_transport: allow_local_transport
      )
      unless after.oid == published
        if after.oid != before.oid
          raise RemoteConflict,
                "remote branch changed during exact publication"
        end
        message = status.success? ?
          "exact publication was not observable" :
          "exact publication failed"
        raise PublicationFailed, message
      end

      PublicationReceipt.new(
        remote_fingerprint: before.remote_fingerprint,
        branch: immutable(name),
        expected_oid: immutable_or_nil(expected_before),
        before_oid: immutable_or_nil(before.oid),
        published_oid: immutable(published),
        after_oid: immutable(after.oid)
      )
    rescue ArgumentError, TypeError => e
      raise InvalidRequest, e.message
    end

    # Compatibility composition helper for Hive callers that still select a
    # local branch above the boundary. The branch is resolved once and the
    # resulting immutable OID, not the mutable branch name, is published.
    def publish_local_branch(repository_path:, branch:, remote: "origin",
                             expected_remote_oid: nil,
                             expected_remote_absent: false, expected_local_oid: nil,
                             allow_local_transport: false)
      name = branch_name(branch)
      expected = publication_expectation(
        expected_remote_oid, expected_remote_absent
      )
      oid = command!(
        repository_path(repository_path),
        "rev-parse", "--verify", "refs/heads/#{name}^{commit}",
        error_class: PublicationFailed,
        message: "local publication branch could not be resolved"
      ).strip.downcase
      if expected_local_oid && oid != exact_oid(expected_local_oid, label: "expected local publication OID")
        raise RemoteConflict, "local branch moved before exact publication"
      end
      publish(
        repository_path: repository_path, oid: oid, branch: name,
        remote: remote, expected_remote_oid: expected,
        expected_remote_absent: expected_remote_absent,
        allow_local_transport: allow_local_transport
      )
    end

    # Fast-forward a clean, attached worktree to the exact OID of a present
    # RemoteObservation. Never resets, forces, or rebases: the branch must
    # still name `expected_oid`, the worktree must be clean, the observed
    # commit must already be present and descend strictly from it, and the
    # remote must still name the observed OID immediately before
    # `merge --ff-only`. The receipt is returned only after HEAD, branch and
    # cleanliness are verified at the new commit.
    def fast_forward(repository_path:, branch:, expected_oid:, observation:,
                     remote: "origin", allow_local_transport: false)
      repository = repository_path(repository_path)
      name = branch_name(branch)
      before = exact_oid(expected_oid, label: "expected local OID")
      unless observation.is_a?(RemoteObservation) && observation.present? &&
             observation.branch == name
        raise InvalidRequest, "fast-forward requires a present RemoteObservation of the same branch"
      end

      after = observation.oid
      assert_fast_forward_local!(repository, name, before, after)
      target = resolve_remote_target(
        repository, remote, push: false,
        allow_local_transport: allow_local_transport
      )
      unless remote_fingerprint(target) == observation.remote_fingerprint
        raise RemoteConflict, "remote target changed after observation"
      end
      current = observe_resolved_remote(
        repository, target, name,
        allow_local_transport: allow_local_transport
      )
      unless current.oid == after
        raise RemoteConflict, "remote branch moved after observation; fast-forward refused"
      end

      # `--no-overwrite-ignore`: status does not list ignored files, so a
      # locally ignored file at a path the adopted commits track must stop the
      # merge rather than be replaced.
      command!(
        repository, "merge", "--ff-only", "--no-overwrite-ignore", "--no-edit", "--no-stat", after,
        error_class: CommandFailed,
        message: "exact fast-forward failed (an ignored local file may occupy a path the adopted commits track)"
      )
      unless read(repository, :current_branch).stdout.strip == name &&
             read(repository, :head_oid).stdout.strip.downcase == after &&
             read(repository, :status).then { |status| status.success? && status.stdout.empty? }
        raise CommandFailed, "fast-forward result could not be verified"
      end

      FastForwardReceipt.new(
        remote_fingerprint: observation.remote_fingerprint, branch: name,
        before_oid: before, after_oid: after
      )
    end

    def remote_urls(repository_path:, remote: "origin", push: false)
      repository = repository_path(repository_path)
      name = remote_name(remote)
      args = [ "remote", "get-url" ]
      args << "--push" if push
      args.push("--all", name)
      result = read_result(repository, :remote_urls, args)
      unless result.success?
        raise CommandFailed, "remote URL lookup failed"
      end

      result.stdout.lines.map(&:strip).reject(&:empty?).map { |url| immutable(url) }.freeze
    end

    def remove_materialization(repository_path:, destination:, destination_root:, force: false)
      unless force == true || force == false
        raise InvalidRequest, "materialization removal force is invalid"
      end

      repository = repository_path(repository_path)
      target = contained_destination(destination, destination_root)
      registered = worktree_paths(repository)
      return :absent unless registered.include?(target) || File.exist?(target)
      unless registered.include?(target)
        raise MaterializationFailed,
              "materialization destination is not registered to this repository"
      end

      command!(
        repository, "worktree", "remove", *(force ? [ "--force" ] : []), target,
        error_class: MaterializationFailed,
        message: "materialization removal failed"
      )
      :removed
    end

    def assert_fast_forward_local!(repository, name, before, after)
      branch = read(repository, :current_branch)
      unless branch.success? && branch.stdout.strip == name
        raise FastForwardRefused.new(:branch_moved, "worktree is not attached to #{name}")
      end
      head = read(repository, :head_oid)
      unless head.success? && head.stdout.strip.downcase == before
        raise FastForwardRefused.new(:local_head_moved, "worktree HEAD no longer names the expected commit")
      end
      status = read(repository, :status)
      unless status.success? && status.stdout.empty?
        raise FastForwardRefused.new(:dirty_worktree, "worktree has staged, unstaged or untracked changes")
      end
      object = read(repository, :commit_oid, oid: after)
      unless object.success? && object.stdout.strip.downcase == after
        raise FastForwardRefused.new(:remote_object_unavailable, "observed remote commit is not present locally")
      end
      return if before != after && read(repository, :ancestor, base_oid: before, head_oid: after).success?

      raise FastForwardRefused.new(:not_fast_forward, "observed remote commit does not strictly descend from the worktree HEAD")
    end
    private_class_method :assert_fast_forward_local!

    def read_arguments(operation, parameters)
      args = case operation.to_sym
      when :current_branch
        expect_parameters!(parameters)
        [ "symbolic-ref", "--quiet", "--short", "HEAD" ]
      when :head_oid
        expect_parameters!(parameters)
        [ "rev-parse", "--verify", "HEAD^{commit}" ]
      when :git_dir
        expect_parameters!(parameters)
        [ "rev-parse", "--absolute-git-dir" ]
      when :git_common_dir
        expect_parameters!(parameters)
        [ "rev-parse", "--git-common-dir" ]
      when :head_symbolic_ref
        expect_parameters!(parameters)
        [ "symbolic-ref", "--quiet", "HEAD" ]
      when :ref_oid
        ref = validated_readable_ref(parameters.delete(:ref))
        expect_parameters!(parameters)
        [ "rev-parse", "--verify", "--quiet", "#{ref}^{commit}" ]
      when :tree_entries
        oid = exact_oid(parameters.delete(:oid), label: "tree OID")
        expect_parameters!(parameters)
        [ "ls-tree", "-r", "-z", oid ]
      when :index_entries
        expect_parameters!(parameters)
        [ "ls-files", "--stage", "-z" ]
      when :untracked_files
        expect_parameters!(parameters)
        [ "ls-files", "--others", "--exclude-standard", "-z" ]
      when :ignored_files
        expect_parameters!(parameters)
        [ "ls-files", "--others", "--ignored", "--exclude-standard", "-z" ]
      when :branch_oid
        branch = Hive::GitRef.validate_branch_name(parameters.delete(:branch))
        remote = parameters.delete(:remote) == true
        expect_parameters!(parameters)
        ref = remote ? "refs/remotes/origin/#{branch}" : "refs/heads/#{branch}"
        [ "rev-parse", "--verify", "#{ref}^{commit}" ]
      when :merge_base
        base = exact_oid(parameters.delete(:base_oid), label: "base OID")
        head = exact_oid(parameters.delete(:head_oid), label: "head OID")
        expect_parameters!(parameters)
        [ "merge-base", base, head ]
      when :commit_oid
        oid = exact_oid(parameters.delete(:oid), label: "commit OID")
        expect_parameters!(parameters)
        [ "rev-parse", "--verify", "#{oid}^{commit}" ]
      when :ancestor
        base = exact_oid(parameters.delete(:base_oid), label: "base OID")
        head = exact_oid(parameters.delete(:head_oid), label: "head OID")
        expect_parameters!(parameters)
        [ "merge-base", "--is-ancestor", base, head ]
      when :commit_count
        base = exact_oid(parameters.delete(:base_oid), label: "base OID")
        head = exact_oid(parameters.delete(:head_oid), label: "head OID")
        expect_parameters!(parameters)
        [ "rev-list", "--count", "#{base}..#{head}" ]
      when :commits
        base = exact_oid(parameters.delete(:base_oid), label: "base OID")
        head = exact_oid(parameters.delete(:head_oid), label: "head OID")
        expect_parameters!(parameters)
        [ "rev-list", "--reverse", "#{base}..#{head}" ]
      when :object_list
        base = exact_oid(parameters.delete(:base_oid), label: "base OID")
        head = exact_oid(parameters.delete(:head_oid), label: "head OID")
        expect_parameters!(parameters)
        [ "rev-list", "--objects", "--no-object-names", "#{base}..#{head}" ]
      when :status
        expect_parameters!(parameters)
        [
          "status", "--porcelain=v1", "--untracked-files=all",
          "--ignore-submodules=none", "-z"
        ]
      when :object_type
        oid = exact_oid(parameters.delete(:oid), label: "object OID")
        expect_parameters!(parameters)
        [ "cat-file", "-t", oid ]
      when :object_size
        spec = object_spec(parameters)
        expect_parameters!(parameters)
        [ "cat-file", "-s", spec ]
      when :object_content
        spec = object_spec(parameters)
        expect_parameters!(parameters)
        [ "cat-file", "-p", spec ]
      when :changed_paths
        base = exact_oid(parameters.delete(:base_oid), label: "base OID")
        head = exact_oid(parameters.delete(:head_oid), label: "head OID")
        expect_parameters!(parameters)
        [ "diff", "--name-only", "--diff-filter=ACMRT", "-z", base, head ]
      when :raw_changed_paths
        base = exact_oid(parameters.delete(:base_oid), label: "base OID")
        head = exact_oid(parameters.delete(:head_oid), label: "head OID")
        expect_parameters!(parameters)
        [
          "diff", "--raw", "--diff-filter=ACDMRTUXB", "-z",
          base, head, "--"
        ]
      when :diff
        base = exact_oid(parameters.delete(:base_oid), label: "base OID")
        head = exact_oid(parameters.delete(:head_oid), label: "head OID")
        expect_parameters!(parameters)
        [ "diff", "--binary", "--full-index", base, head ]
      when :commit_patch
        oid = exact_oid(parameters.delete(:oid), label: "commit OID")
        expect_parameters!(parameters)
        [
          "show", "--format=fuller", "--no-renames", "--binary",
          oid
        ]
      when :worktree_paths
        expect_parameters!(parameters)
        [ "worktree", "list", "--porcelain" ]
      else
        raise UnsupportedOperation, "unsupported hardened Git read: #{operation}"
      end
      args.freeze
    end
    private_class_method :read_arguments

    def object_spec(parameters)
      oid = exact_oid(parameters.delete(:oid), label: "object OID")
      path = parameters.delete(:path)
      return oid if path.nil?

      value = path.to_s
      if value.empty? || value.start_with?("/") || value.match?(/[\0\r\n]/)
        raise InvalidRequest, "Git object path is invalid"
      end
      "#{oid}:#{value}"
    end
    private_class_method :object_spec

    def expect_parameters!(parameters)
      return if parameters.empty?

      raise InvalidRequest,
            "unsupported hardened Git arguments: #{parameters.keys.map(&:to_s).sort.join(', ')}"
    end
    private_class_method :expect_parameters!

    def verify_materialization!(destination, expected)
      branch = read(destination, :current_branch)
      unless branch.exitstatus == 1 && branch.stdout.empty? ||
             branch.success? && branch.stdout.strip.empty?
        raise MaterializationFailed,
              "materialized worktree is attached to a branch"
      end
      head = read(destination, :head_oid)
      unless head.success? && head.stdout.strip.downcase == expected
        raise MaterializationFailed,
              "materialized worktree does not match the exact requested commit"
      end
      status = read(destination, :status)
      unless status.success? && status.stdout.empty?
        raise MaterializationFailed, "materialized worktree is dirty"
      end

      true
    end
    private_class_method :verify_materialization!

    def worktree_paths(repository)
      result = read(repository, :worktree_paths)
      raise MaterializationFailed, "worktree registry lookup failed" unless result.success?

      result.stdout.lines.filter_map do |line|
        next unless line.start_with?("worktree ")

        realpath_or_expand(line.delete_prefix("worktree ").strip)
      end.freeze
    end
    private_class_method :worktree_paths

    def observe_resolved_remote(repository, target, branch,
                                allow_local_transport:,
                                timeout_sec: NETWORK_TIMEOUT_SEC)
      ref = "refs/heads/#{branch}"
      out, err, status, _overflow = capture(
        repository, [ "ls-remote", "--heads", target, ref ],
        allow_local_transport: allow_local_transport,
        timeout_sec: timeout_sec
      )
      unless status.success?
        raise DeadlineExceeded, "remote branch observation timed out" if err.include?("managed Git command timed out")

        raise CommandFailed, "remote branch observation failed"
      end

      lines = out.lines.map(&:strip).reject(&:empty?)
      if lines.length > 1
        raise CommandFailed, "remote branch observation returned multiple records"
      end
      oid = nil
      if lines.one?
        value, returned_ref = lines.first.split(/\s+/, 2)
        unless returned_ref == ref && value.to_s.downcase.match?(OID)
          raise CommandFailed, "remote branch observation returned an invalid record"
        end
        oid = value.downcase
      end
      RemoteObservation.new(
        remote_fingerprint: immutable(remote_fingerprint(target)),
        branch: immutable(branch),
        ref: immutable(ref),
        oid: immutable_or_nil(oid)
      )
    end
    private_class_method :observe_resolved_remote

    def observe_resolved_pull_request(repository, target, pr_number, fingerprint,
                                      allow_local_transport:,
                                      timeout_sec: NETWORK_TIMEOUT_SEC)
      ref = "refs/pull/#{pr_number}/head"
      out, err, status, _overflow = capture(
        repository, [ "ls-remote", target, ref ],
        allow_local_transport: allow_local_transport,
        timeout_sec: timeout_sec
      )
      unless status.success?
        if err.include?("managed Git command timed out")
          raise DeadlineExceeded, "pull request observation timed out"
        end

        raise CommandFailed, "pull request head observation failed"
      end

      lines = out.lines.map(&:strip).reject(&:empty?)
      if lines.length > 1
        raise CommandFailed, "pull request head observation returned multiple records"
      end
      oid = nil
      if lines.one?
        value, returned_ref = lines.first.split(/\s+/, 2)
        unless returned_ref == ref && value.to_s.downcase.match?(OID)
          raise CommandFailed, "pull request head observation returned an invalid record"
        end
        oid = value.downcase
      end
      PullRequestObservation.new(
        remote_fingerprint: immutable(fingerprint),
        pr_number: pr_number,
        ref: immutable(ref),
        oid: immutable_or_nil(oid)
      )
    end
    private_class_method :observe_resolved_pull_request

    def effective_timeout(timeout_sec: nil, deadline: nil)
      budget = if deadline
        Float(deadline) - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      elsif !timeout_sec.nil?
        Float(timeout_sec)
      else
        NETWORK_TIMEOUT_SEC.to_f
      end
      unless budget.finite? && budget.positive?
        raise DeadlineExceeded, "network operation deadline expired"
      end

      [ budget, NETWORK_TIMEOUT_SEC.to_f ].min
    rescue ArgumentError, TypeError
      raise InvalidRequest, "network timeout is invalid"
    end
    private_class_method :effective_timeout

    def positive_pr_number(value)
      number = Integer(value)
      raise InvalidRequest, "pull request number must be positive" unless number.positive?

      number
    rescue ArgumentError, TypeError
      raise InvalidRequest, "pull request number must be positive"
    end
    private_class_method :positive_pr_number

    def validated_internal_pr_ref(value, label:)
      ref = value.to_s
      suffix = ref.delete_prefix("refs/hive/internal-pr-checkout/")
      if ref == suffix || suffix.empty?
        raise InvalidRequest, "#{label} must stay under refs/hive/internal-pr-checkout/"
      end

      Hive::GitRef.validate_branch_name(suffix)
      ref
    rescue ArgumentError
      raise InvalidRequest, "#{label} is invalid"
    end
    private_class_method :validated_internal_pr_ref

    def validated_owned_deletable_ref(value)
      ref = value.to_s
      return validated_internal_pr_ref(ref, label: "owned ref") if ref.start_with?("refs/hive/internal-pr-checkout/")
      return ref if ref.match?(/\Arefs\/heads\/hive\/review\/pr-[1-9][0-9]*\z/)

      raise InvalidRequest, "ref is outside the owned deletable namespace"
    end
    private_class_method :validated_owned_deletable_ref

    def validated_readable_ref(value)
      ref = value.to_s
      if ref.start_with?("refs/hive/internal-pr-checkout/")
        return validated_internal_pr_ref(ref, label: "ref")
      end
      if ref.start_with?("refs/heads/")
        Hive::GitRef.validate_branch_name(ref.delete_prefix("refs/heads/"))
        return ref
      end
      if ref.start_with?("refs/remotes/origin/")
        Hive::GitRef.validate_branch_name(ref.delete_prefix("refs/remotes/origin/"))
        return ref
      end
      return ref if ref.match?(/\Arefs\/pull\/[1-9][0-9]*\/head\z/)

      raise InvalidRequest, "readable ref is invalid"
    rescue ArgumentError
      raise InvalidRequest, "readable ref is invalid"
    end
    private_class_method :validated_readable_ref

    def resolve_remote_target(repository, remote, push:, allow_local_transport:)
      value = remote.to_s
      if value.match?(REMOTE_NAME)
        urls = remote_urls(repository_path: repository, remote: value, push: push)
        unless urls.one?
          raise InvalidRequest,
                "remote target must resolve to exactly one #{push ? 'push' : 'fetch'} URL"
        end
        value = urls.first
      end
      validate_transport_target(value, allow_local_transport: allow_local_transport)
    end
    private_class_method :resolve_remote_target

    def validate_transport_target(target, allow_local_transport:)
      value = target.to_s
      if value.empty? || value.start_with?("-") || value.match?(/[\0\r\n]/)
        raise InvalidRequest, "Git remote target is invalid"
      end
      if value.start_with?("ext::")
        raise InvalidRequest, "Git remote transport \"ext\" is not allowed"
      end
      if value.match?(/\A(?:[^@\/]+@)?[^:\/]+:.+\z/) &&
          !value.match?(/\A[a-z][a-z0-9+.-]*:\/\//i)
        return immutable(value)
      end
      if value.match?(/\A[a-z][a-z0-9+.-]*:\/\//i)
        scheme = value.split(":", 2).first.downcase
        unless SAFE_REMOTE_SCHEMES.include?(scheme)
          raise InvalidRequest, "Git remote transport #{scheme.inspect} is not allowed"
        end
        authority = value.split("://", 2).last.split("/", 2).first
        if authority.empty? || authority.count("@") > 1
          raise InvalidRequest, "Git remote target authority is invalid"
        end
        userinfo, host = if authority.include?("@")
          authority.split("@", 2)
        else
          [ nil, authority ]
        end
        if host.to_s.empty?
          raise InvalidRequest, "Git remote target authority is invalid"
        end
        if userinfo && (
          scheme == "https" || userinfo.match?(/:|%3a/i)
        )
          raise InvalidRequest,
                "Git remote credentials must be injected, not embedded in the target"
        end
        return immutable(value)
      end
      if allow_local_transport
        return immutable(File.expand_path(value))
      end

      raise InvalidRequest, "local Git transports are not allowed"
    end
    private_class_method :validate_transport_target

    def remote_fingerprint(target)
      Digest::SHA256.hexdigest(target)
    end
    private_class_method :remote_fingerprint

    def branch_name(value)
      Hive::GitRef.validate_branch_name(value)
    rescue ArgumentError
      raise InvalidRequest, "Git branch name is invalid"
    end
    private_class_method :branch_name

    def remote_name(value)
      name = value.to_s
      raise InvalidRequest, "Git remote name is invalid" unless name.match?(REMOTE_NAME)

      name
    end
    private_class_method :remote_name

    def exact_oid(value, label:)
      oid = value.to_s.downcase
      raise InvalidRequest, "#{label} is invalid" unless oid.match?(OID)

      oid
    end
    private_class_method :exact_oid

    def publication_expectation(expected_oid, expected_absent)
      expected = expected_oid &&
                 exact_oid(expected_oid, label: "expected remote OID")
      if expected && expected_absent
        raise InvalidRequest, "publication cannot expect both an OID and absence"
      end
      unless expected || expected_absent
        raise InvalidRequest,
              "publication requires an exact expected remote OID or absence"
      end

      expected
    end
    private_class_method :publication_expectation

    def repository_path(value)
      path = File.expand_path(value.to_s)
      raise InvalidRequest, "repository path is not a directory" unless File.directory?(path)

      path
    end
    private_class_method :repository_path

    def contained_destination(destination, root)
      declared_root = File.expand_path(root.to_s)
      target = File.expand_path(destination.to_s)
      unless File.directory?(declared_root)
        raise InvalidRequest, "materialization destination root is not a directory"
      end
      unless target.start_with?("#{declared_root}#{File::SEPARATOR}") &&
             target != declared_root
        raise InvalidRequest, "materialization destination is outside its declared root"
      end

      root_path = File.realpath(declared_root)
      ancestor = target
      ancestor = File.dirname(ancestor) until File.exist?(ancestor) ||
                                            File.symlink?(ancestor)
      ancestor_path = File.realpath(ancestor)
      unless ancestor_path == root_path ||
             ancestor_path.start_with?("#{root_path}#{File::SEPARATOR}")
        raise InvalidRequest,
              "materialization destination escapes through a symlinked ancestor"
      end
      if File.exist?(target) || File.symlink?(target)
        target_path = File.realpath(target)
        unless target_path.start_with?("#{root_path}#{File::SEPARATOR}") &&
               target_path != root_path
          raise InvalidRequest,
                "materialization destination resolves outside its declared root"
        end
      end
      target
    rescue Errno::ENOENT, Errno::ELOOP
      raise InvalidRequest, "materialization destination cannot be resolved safely"
    end
    private_class_method :contained_destination

    def realpath_or_expand(path)
      File.realpath(File.expand_path(path.to_s))
    rescue Errno::ENOENT
      File.expand_path(path.to_s)
    end
    private_class_method :realpath_or_expand

    def command!(repository, *args, allow_local_transport: false,
                 timeout_sec: nil,
                 error_class:, message:)
      out, _err, status, _overflow = capture(
        repository, args, allow_local_transport: allow_local_transport,
        timeout_sec: timeout_sec
      )
      raise error_class, message unless status.success?

      out
    end
    private_class_method :command!

    def read_result(repository, operation, args)
      out, err, status, overflow = capture(repository, args)
      ReadResult.new(
        operation: operation,
        stdout: immutable(out),
        stderr: immutable(err),
        exitstatus: status.exitstatus,
        overflow: overflow
      )
    end
    private_class_method :read_result

    def capture(repository, args, max_stdout_bytes: nil,
                allow_local_transport: false, timeout_sec: nil)
      repository = repository_path(repository)
      validate_repository_config!(repository)
      if max_stdout_bytes
        limit = Integer(max_stdout_bytes)
        raise InvalidRequest, "max_stdout_bytes must be positive" unless limit.positive?

        Hive::ManagedGit.capture3_bounded(
          repository, *args, max_stdout_bytes: limit,
          allow_local_transport: allow_local_transport
        )
      else
        out, err, status = Hive::ManagedGit.capture3(
          repository, *args,
          allow_local_transport: allow_local_transport,
          timeout_sec: timeout_sec
        )
        [ out, err, status, false ]
      end
    end
    private_class_method :capture

    def validate_repository_config!(repository)
      unsafe, _err, status = Hive::ManagedGit.executable_local_config(repository)
      unless status.success?
        raise InvalidRequest,
              "repository-local Git configuration could not be inspected safely"
      end
      return if unsafe.empty?

      raise InvalidRequest,
            "repository-local executable Git helpers are not allowed"
    end
    private_class_method :validate_repository_config!

    def immutable(value)
      value.to_s.dup.freeze
    end
    private_class_method :immutable

    def immutable_or_nil(value)
      value && immutable(value)
    end
    private_class_method :immutable_or_nil
  end
end
