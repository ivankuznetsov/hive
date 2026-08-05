# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "securerandom"
require "tempfile"
require "time"
require_relative "result"

module HivePatrolEvidence
  # Composes exactly one reduced installed smoke and publishes its single result.
  class Runner
    class Error < StandardError
      attr_reader :reason

      def initialize(reason, message = reason)
        @reason = reason
        super(message)
      end
    end
    class AuthorityError < Error; end
    class PublicationError < Error; end
    class EvidenceError < Error; end

    MAX_STORE_RESULTS = 128
    MAX_STORE_BYTES = 64 * 1024 * 1024
    MIN_RETENTION_DAYS = 30
    SAFE_SHA = /\A[0-9a-f]{40}\z/
    SAFE_ID = /\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/
    READ_FLAGS = File::RDONLY | (File.const_defined?(:NOFOLLOW) ? File::NOFOLLOW : 0)

    class << self
      def run!(**options) = new(**options).send(:run)
      def cleanup!(evidence_root:, result_path:, now: Time.now.utc)
        allocate.send(:cleanup_result!, evidence_root:, result_path:, now:)
      end

      private :new
    end

    def initialize(repo_root:, evidence_root:, controller_sha:, candidate_sha:, authorization:,
                   invocation_id:, project_root:, observations_path:, image:,
                   candidate_factory: nil, sandbox_factory: nil, controller_factory: nil,
                   provider_probe_factory: nil, clock: -> { Time.now.utc })
      @repo_root = File.expand_path(repo_root)
      @evidence_root = File.expand_path(evidence_root)
      @controller_sha = controller_sha.to_s.downcase
      @candidate_sha = candidate_sha.to_s.downcase
      @authorization = authorization.to_s
      @invocation_id = invocation_id.to_s
      @project_root = File.expand_path(project_root)
      @observations_path = File.expand_path(observations_path)
      @image = image.to_s
      @candidate_factory = candidate_factory
      @sandbox_factory = sandbox_factory
      @controller_factory = controller_factory
      @provider_probe_factory = provider_probe_factory
      @clock = clock
    end

    private

    def cleanup_result!(evidence_root:, result_path:, now:)
      root = File.realpath(File.expand_path(evidence_root))
      root_stat = File.lstat(root)
      unless root_stat.directory? && !root_stat.symlink? && root_stat.uid == Process.uid &&
             (root_stat.mode & 0o777) == 0o700
        raise EvidenceError.new("evidence_custody", "evidence store custody failed")
      end
      path = File.expand_path(result_path)
      run_root = File.dirname(path)
      unless File.basename(path) == "result.json" && File.dirname(run_root) == root &&
             File.basename(run_root).match?(/\Au3c-[A-Za-z0-9._-]{1,123}\z/)
        raise EvidenceError.new("evidence_custody", "cleanup result is outside the evidence store")
      end
      run_stat = File.lstat(run_root)
      unless run_stat.directory? && !run_stat.symlink? && run_stat.uid == Process.uid &&
             (run_stat.mode & 0o777) == 0o700
        raise EvidenceError.new("evidence_custody", "cleanup run directory custody failed")
      end
      File.open(path, READ_FLAGS) do |file|
        file.flock(File::LOCK_EX)
        original = file.stat
        unless original.file? && original.nlink == 1 && original.uid == Process.uid &&
               (original.mode & 0o777) == 0o600 && original.size <= Result::MAX_RESULT_BYTES
          raise EvidenceError.new("evidence_custody", "cleanup result custody failed")
        end
        bytes = file.read(Result::MAX_RESULT_BYTES + 1)
        document = JSON.parse(bytes)
        unless Result.canonical(document) == bytes &&
               Result::TERMINAL_STATUSES.include?(document.fetch("status")) &&
               document.fetch("finished_at")
          raise EvidenceError.new("evidence_custody", "cleanup result is not terminal canonical evidence")
        end
        cutoff = now.utc - (MIN_RETENTION_DAYS * 86_400)
        finished_at = Time.iso8601(document.fetch("finished_at"))
        unless original.mtime.utc <= cutoff && finished_at.utc <= cutoff
          raise EvidenceError.new("evidence_custody", "cleanup result is inside its retention window")
        end
        current = File.lstat(path)
        unless %i[dev ino uid mode nlink].all? do |field|
          current.public_send(field) == original.public_send(field)
        end
          raise EvidenceError.new("evidence_custody", "cleanup result identity changed")
        end
        File.unlink(path)
        fsync_directory(run_root)
      ensure
        file.flock(File::LOCK_UN) rescue nil
      end
      unless Dir.empty?(run_root)
        raise EvidenceError.new("evidence_custody", "cleanup run directory is not empty")
      end
      current_run = File.lstat(run_root)
      unless %i[dev ino uid mode].all? do |field|
        current_run.public_send(field) == run_stat.public_send(field)
      end
        raise EvidenceError.new("evidence_custody", "cleanup run directory identity changed")
      end
      Dir.rmdir(run_root)
      fsync_directory(root)
      true
    rescue EvidenceError
      raise
    rescue JSON::ParserError, KeyError, ArgumentError, SystemCallError
      raise EvidenceError.new("evidence_custody", "explicit evidence cleanup failed"), cause: nil
    end

    def run
      verify_authority!
      started_at = timestamp
      run_id = run_id(started_at)
      authority = authority_record(run_id)
      begin
        verify_evidence_store!
      rescue EvidenceError => error
        raise unless error.reason == "evidence_store_full"

        terminal = Result.terminal(
          status: "blocked", reason: error.reason, authority:, candidate: nil,
          sandbox: nil, smoke: nil, provider: nil, process_evidence: [],
          started_at: started_at.iso8601(6), finished_at: timestamp.iso8601(6)
        )
        return {
          "status" => "blocked", "reason" => error.reason, "run_id" => run_id,
          "result_path" => nil, "result" => terminal
        }.freeze
      end
      run_root = create_run_root!(run_id)
      result_path = File.join(run_root, "result.json")
      initial = Result.not_started(authority:, started_at: started_at.iso8601(6))
      create_initial_result!(result_path, initial.canonical_bytes)

      candidate_owner = build_candidate
      candidate = candidate_owner.prepare!(run_root:)
      sandbox = build_sandbox
      sandbox_receipt = sandbox.run!(
        candidate:, project_root: @project_root, observations_path: @observations_path,
        controller_root: @repo_root, run_root:, image: @image
      )
      admitted_candidate = candidate_owner.verify!(receipt: sandbox_receipt)
      smoke = build_controller(run_root).external_smoke(
        controller_sha: @controller_sha, candidate_sha: @candidate_sha,
        candidate: admitted_candidate, sandbox_result: sandbox_receipt.fetch("payload")
      )
      reverify_control_bytes!(authority)
      provider_owner = build_provider_probe
      provider = provider_owner.call
      reverify_control_bytes!(authority)
      finished_at = timestamp
      terminal = Result.terminal(
        status: "installed_live_smoke_verified", reason: nil, authority:,
        candidate: admitted_candidate, sandbox: sandbox_receipt.fetch("sandbox"),
        smoke:, provider:, process_evidence: sandbox_receipt.fetch("process_evidence"),
        started_at: started_at.iso8601(6), finished_at: finished_at.iso8601(6)
      )
      provider_owner.validate_retained!(terminal.canonical_bytes) if
        provider_owner.respond_to?(:validate_retained!)
      replace_expected!(result_path, initial.canonical_bytes, terminal.canonical_bytes)
      {
        "status" => terminal.to_h.fetch("status"), "run_id" => run_id,
        "result_path" => result_path, "result" => terminal
      }.freeze
    rescue PublicationError
      raise
    rescue Error => error
      publish_nonpassing(
        error, result_path, initial, authority, started_at,
        candidate: admitted_candidate, sandbox_receipt:, smoke:, provider:
      )
    rescue StandardError => error
      reason = error.respond_to?(:reason) ? error.reason.to_s : "unexpected_failure"
      reason = "unexpected_failure" unless Result::REASONS.include?(reason)
      wrapped = Error.new(reason, error.class.name)
      publish_nonpassing(
        wrapped, result_path, initial, authority, started_at,
        candidate: admitted_candidate, sandbox_receipt:, smoke:, provider:
      )
    end

    def publish_nonpassing(error, result_path, initial, authority, started_at,
                           candidate: nil, sandbox_receipt: nil, smoke: nil, provider: nil)
      raise error unless result_path && initial && authority && started_at

      status = blocked_reason?(error.reason) ? "blocked" : "failed"
      reason = Result::REASONS.include?(error.reason) ? error.reason : "unexpected_failure"
      terminal = Result.terminal(
        status:, reason:, authority:, candidate:,
        sandbox: sandbox_receipt&.fetch("sandbox"), smoke:, provider:,
        process_evidence: sandbox_receipt&.fetch("process_evidence") || [],
        started_at: started_at.iso8601(6),
        finished_at: timestamp.iso8601(6)
      )
      replace_expected!(result_path, initial.canonical_bytes, terminal.canonical_bytes)
      {
        "status" => status, "reason" => reason, "run_id" => authority.fetch("run_id"),
        "result_path" => result_path, "result" => terminal
      }.freeze
    end

    def blocked_reason?(reason)
      %w[
        manual_authority_missing sandbox_unavailable installed_dependency_missing
        credential_unavailable provider_unavailable evidence_store_full
      ].include?(reason)
    end

    def verify_authority!
      unless SAFE_SHA.match?(@controller_sha) && SAFE_SHA.match?(@candidate_sha) &&
             @controller_sha != @candidate_sha
        raise AuthorityError.new("authority_binding", "controller and candidate identities are invalid")
      end
      unless SAFE_ID.match?(@invocation_id) && @authorization.bytesize.between?(1, 4096)
        raise AuthorityError.new("manual_authority_missing", "manual authorization is invalid")
      end
      repo = owned_directory!(@repo_root, "controller checkout")
      head = git(repo, "rev-parse", "HEAD").strip
      raise AuthorityError.new("authority_binding", "controller checkout is not the authorized SHA") unless
        head == @controller_sha
      status = git(repo, "status", "--porcelain", "--untracked-files=all")
      raise AuthorityError.new("controller_checkout_dirty", "controller checkout is not clean") unless status.empty?
      protected_main = protected_main_ref(repo)
      ancestry!(repo, @controller_sha, protected_main, "controller is not reachable from protected main")
      ancestry!(repo, @candidate_sha, protected_main, "candidate is not reachable from protected main")
      ancestry!(repo, @controller_sha, @candidate_sha, "candidate does not descend from the controller")
    end

    def protected_main_ref(repo)
      %w[refs/remotes/origin/main refs/heads/main].find do |ref|
        _out, _err, status = Open3.capture3("git", "-C", repo, "rev-parse", "--verify", ref)
        status.success?
      end || raise(AuthorityError.new("authority_binding", "protected main is unavailable"))
    end

    def ancestry!(repo, ancestor, descendant, message)
      _out, _err, status = Open3.capture3(
        "git", "-C", repo, "merge-base", "--is-ancestor", ancestor, descendant
      )
      raise AuthorityError.new("authority_binding", message) unless status.success?
    end

    def verify_evidence_store!
      root = owned_directory!(@evidence_root, "evidence store")
      stat = File.lstat(root)
      raise EvidenceError.new("evidence_custody", "evidence store must be mode 0700") unless
        (stat.mode & 0o777) == 0o700
      count = 0
      bytes = 0
      Dir.each_child(root) do |name|
        path = File.join(root, name)
        child = File.lstat(path)
        unless child.directory? && !child.symlink? && child.uid == Process.uid &&
               (child.mode & 0o777) == 0o700
          raise EvidenceError.new("evidence_custody", "evidence store contains an unsafe run directory")
        end
        Dir.each_child(path) do |entry|
          result = File.join(path, entry)
          result_stat = File.lstat(result)
          unless entry == "result.json" && result_stat.file? && !result_stat.symlink? &&
                 result_stat.uid == Process.uid && (result_stat.mode & 0o777) == 0o600 &&
                 result_stat.size <= Result::MAX_RESULT_BYTES
            raise EvidenceError.new("evidence_custody", "evidence store contains an unsafe result")
          end
          count += 1
          bytes += result_stat.size
          if count >= MAX_STORE_RESULTS || bytes + Result::MAX_RESULT_BYTES > MAX_STORE_BYTES
            raise EvidenceError.new("evidence_store_full", "evidence store is full")
          end
        end
      end
    rescue Errno::ENOENT, Errno::EACCES
      raise EvidenceError.new("evidence_custody", "evidence store is unavailable")
    end

    def create_run_root!(run_id)
      path = File.join(@evidence_root, run_id)
      Dir.mkdir(path, 0o700)
      stat = File.lstat(path)
      unless stat.directory? && !stat.symlink? && stat.uid == Process.uid && (stat.mode & 0o777) == 0o700
        raise EvidenceError.new("path_custody", "run directory custody failed")
      end
      path
    rescue Errno::EEXIST
      raise EvidenceError.new("path_custody", "run directory already exists")
    end

    def create_initial_result!(path, bytes)
      flags = File::WRONLY | File::CREAT | File::EXCL
      flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
      File.open(path, flags, 0o600) do |file|
        file.binmode
        file.write(bytes)
        file.flush
        file.fsync
      end
      File.chmod(0o600, path)
      fsync_directory(File.dirname(path))
    rescue SystemCallError
      raise PublicationError.new("publication_conflict", "cannot create the initial result")
    end

    def replace_expected!(path, expected, replacement)
      File.open(path, READ_FLAGS | File::RDWR) do |locked|
        locked.flock(File::LOCK_EX)
        original = locked.stat
        validate_result_identity!(path, original)
        actual = locked.read(Result::MAX_RESULT_BYTES + 1)
        raise PublicationError.new("publication_conflict", "result expected bytes changed") unless
          actual == expected

        Tempfile.create([ ".patrol-result-", ".tmp" ], File.dirname(path), mode: File::RDWR, perm: 0o600) do |staged|
          staged.binmode
          staged.write(replacement)
          staged.flush
          staged.fsync
          File.chmod(0o600, staged.path)
          validate_result_identity!(path, original)
          locked.rewind
          raise PublicationError.new("publication_conflict", "result changed while locked") unless
            locked.read(Result::MAX_RESULT_BYTES + 1) == expected
          File.rename(staged.path, path)
        end
        fsync_directory(File.dirname(path))
      ensure
        locked.flock(File::LOCK_UN) rescue nil
      end
      File.open(path, READ_FLAGS) do |published|
        stat = published.stat
        valid = stat.file? && stat.uid == Process.uid && (stat.mode & 0o777) == 0o600 &&
          published.read(Result::MAX_RESULT_BYTES + 1) == replacement
        raise PublicationError.new("publication_conflict", "published result differs") unless valid
      end
    rescue PublicationError
      raise
    rescue SystemCallError
      raise PublicationError.new("publication_conflict", "result publication failed")
    end

    def validate_result_identity!(path, expected)
      current = File.lstat(path)
      fields = %i[dev ino uid mode nlink]
      valid = current.file? && !current.symlink? && current.nlink == 1 &&
        fields.all? { |field| current.public_send(field) == expected.public_send(field) }
      raise PublicationError.new("publication_conflict", "result path identity changed") unless valid
    end

    def build_candidate
      return @candidate_factory.call(
        repo_root: @repo_root, controller_sha: @controller_sha, candidate_sha: @candidate_sha
      ) if @candidate_factory

      require_relative "candidate"
      Candidate.new(repo_root: @repo_root, controller_sha: @controller_sha, candidate_sha: @candidate_sha)
    end

    def build_sandbox
      return @sandbox_factory.call(image: @image) if @sandbox_factory

      require_relative "sandbox"
      Sandbox.new(image: @image)
    end

    def build_controller(run_root)
      return @controller_factory.call(
        repo_root: @repo_root, project_root: @project_root,
        observations_path: @observations_path, run_root:
      ) if @controller_factory

      require_relative "../../test/e2e/lib/patrol_qualification"
      Hive::E2E::PatrolQualification::Controller.new(
        repo_root: @repo_root, project_root: @project_root,
        hive_home: File.join(run_root, "controller-home"),
        observations_path: @observations_path, evidence_root: run_root
      )
    end

    def build_provider_probe
      @provider_probe ||= if @provider_probe_factory
        @provider_probe_factory.call
      else
        require_relative "provider_probe"
        ProviderProbe.new
      end
    end

    def authority_record(run_id)
      {
        "run_id" => run_id,
        "controller_sha" => @controller_sha,
        "candidate_sha" => @candidate_sha,
        "runner_sha256" => Digest::SHA256.file(__FILE__).hexdigest,
        "controller_script_sha256" => controller_script_digest,
        "authorization_sha256" => Digest::SHA256.hexdigest(@authorization),
        "invocation_id" => @invocation_id
      }
    end

    def run_id(time)
      suffix = Digest::SHA256.hexdigest(
        [ @controller_sha, @candidate_sha, @invocation_id, @authorization ].join("\0")
      )[0, 12]
      "u3c-#{time.utc.strftime('%Y%m%dT%H%M%S%6NZ')}-#{suffix}"
    end

    def reverify_control_bytes!(authority)
      valid = Digest::SHA256.file(__FILE__).hexdigest == authority.fetch("runner_sha256") &&
        controller_script_digest == authority.fetch("controller_script_sha256")
      raise AuthorityError.new("authority_binding", "controller bytes changed during the run") unless valid
    rescue SystemCallError
      raise AuthorityError.new("authority_binding", "controller bytes are unavailable")
    end

    def controller_script_digest
      path = File.join(@repo_root, "test/e2e/lib/patrol_qualification.rb")
      flags = File::RDONLY
      flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
      File.open(path, flags) do |file|
        stat = file.stat
        unless stat.file? && stat.nlink == 1 && stat.uid == Process.uid && stat.size <= 1024 * 1024
          raise AuthorityError.new("authority_binding", "controller script is unsafe")
        end
        digest = Digest::SHA256.new
        while (chunk = file.read(64 * 1024))
          digest.update(chunk)
        end
        digest.hexdigest
      end
    rescue Errno::ENOENT, Errno::ELOOP, Errno::EACCES
      raise AuthorityError.new("authority_binding", "controller script is unavailable")
    end

    def timestamp
      value = @clock.call
      raise AuthorityError.new("authority_binding", "clock is invalid") unless value.respond_to?(:utc)
      value.utc
    end

    def owned_directory!(path, label)
      stat = File.lstat(path)
      unless stat.directory? && !stat.symlink? && stat.uid == Process.uid
        raise AuthorityError.new("authority_binding", "#{label} is not an owned directory")
      end
      File.realpath(path)
    rescue Errno::ENOENT, Errno::EACCES
      raise AuthorityError.new("authority_binding", "#{label} is unavailable")
    end

    def git(repo, *arguments)
      stdout, _stderr, status = Open3.capture3("git", "-C", repo, *arguments)
      raise AuthorityError.new("authority_binding", "git authority check failed") unless status.success?
      stdout
    rescue SystemCallError
      raise AuthorityError.new("authority_binding", "git authority check is unavailable")
    end

    def fsync_directory(path)
      File.open(path, File::RDONLY) { |directory| directory.fsync }
    end
  end
end
