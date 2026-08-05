# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "securerandom"
require "tempfile"
require "time"
require "timeout"
require "tmpdir"
require "yaml"
require_relative "../../lib/hive/repository_identity"
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
    class CancellationError < Error; end

    MAX_STORE_RESULTS = 128
    MAX_STORE_BYTES = 64 * 1024 * 1024
    MIN_RETENTION_DAYS = 30
    SAFE_SHA = /\A[0-9a-f]{40}\z/
    SAFE_DIGEST = /\A[0-9a-f]{64}\z/
    SAFE_ID = /\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/
    READ_FLAGS = File::RDONLY | (File.const_defined?(:NOFOLLOW) ? File::NOFOLLOW : 0)
    AUTHORIZATION_SCHEMA = "hive-patrol-installed-live-smoke-authorization"
    AUTHORIZATION_KEYS = %w[
      candidate_sha controller_sha expires_at image invocation_id issued_at model nonce
      observations_sha256 project_binding_sha256 provider schema schema_version
    ].freeze
    CONTROL_PATHS = %w[
      packaging/patrol_evidence/runner.rb
      packaging/patrol_evidence/result.rb
      packaging/patrol_evidence/candidate.rb
      packaging/patrol_evidence/sandbox.rb
      packaging/patrol_evidence/provider_probe.rb
      test/e2e/lib/patrol_qualification.rb
      test/e2e/fixtures/patrol_qualification/catalog.json
      lib/hive/secret_patterns.rb
    ].freeze
    PROJECT_TREE_MAX_FILES = 4_096
    PROJECT_TREE_MAX_BYTES = 64 * 1024 * 1024
    INPUT_FILE_MAX_BYTES = 8 * 1024 * 1024
    AUTHORIZATION_MAX_AGE = 3600
    GIT_ENV = {
      "HOME" => "/nonexistent", "PATH" => "/usr/bin:/bin",
      "GIT_ATTR_NOSYSTEM" => "1", "GIT_CONFIG_GLOBAL" => "/dev/null",
      "GIT_CONFIG_NOSYSTEM" => "1", "GIT_CONFIG_SYSTEM" => "/dev/null",
      "GIT_NO_REPLACE_OBJECTS" => "1", "GIT_TERMINAL_PROMPT" => "0"
    }.freeze

    class << self
      def run!(repo_root:, evidence_root:, hive_home:, controller_sha:, candidate_sha:,
               authorization:, invocation_id:, project_root:, observations_path:, image:)
        new(
          repo_root:, evidence_root:, hive_home:, controller_sha:, candidate_sha:,
          authorization:, invocation_id:, project_root:, observations_path:, image:
        ).send(:run)
      end

      def cleanup!(evidence_root:, result_path:, now: Time.now.utc)
        allocate.send(:cleanup_result!, evidence_root:, result_path:, now:)
      end

      def authorization_template!(repo_root:, evidence_root:, hive_home:, controller_sha:, candidate_sha:,
                                  invocation_id:, project_root:, observations_path:, image:,
                                  now: Time.now.utc, nonce: SecureRandom.hex(16))
        runner = new(
          repo_root:, evidence_root:, hive_home:, controller_sha:, candidate_sha:,
          authorization: "", invocation_id:, project_root:, observations_path:, image:
        )
        runner.send(:verify_static_authority!)
        runner.send(:authorization_template, now.utc, nonce)
      end

      private :new
    end

    def initialize(repo_root:, evidence_root:, hive_home:, controller_sha:, candidate_sha:, authorization:,
                   invocation_id:, project_root:, observations_path:, image:,
                   candidate_factory: nil, sandbox_factory: nil, controller_factory: nil,
                   provider_probe_factory: nil, clock: -> { Time.now.utc })
      @repo_root = File.expand_path(repo_root)
      @evidence_root = File.expand_path(evidence_root)
      @hive_home = File.expand_path(hive_home)
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
        unless Dir.children(run_root) == [ "result.json" ]
          raise EvidenceError.new("evidence_custody", "cleanup result is not the sole run artifact")
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
      result_path = initial = transient_root = candidate_custody = admitted_candidate = nil
      sandbox_receipt = smoke = provider = nil
      started_at = timestamp
      verify_authority!(started_at)
      run_id = run_id(started_at)
      authority = authority_record(run_id)
      begin
        with_store_lock do
          verify_evidence_store!
          reject_authorization_replay!(authority.fetch("authorization_sha256"))
          run_root = create_run_root!(run_id)
          result_path = File.join(run_root, "result.json")
          initial = Result.not_started(authority:, started_at: started_at.iso8601(6))
          create_initial_result!(result_path, initial.canonical_bytes)
        end
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

      transient_root = create_transient_root!
      candidate_owner = build_candidate
      candidate = candidate_owner.prepare!(run_root: transient_root)
      candidate_custody = prepared_candidate_record(candidate)
      reverify_phase_bindings!(authority)
      sandbox = build_sandbox
      sandbox_receipt = sandbox.run!(
        candidate:, project_root: @project_root, observations_path: @observations_path,
        controller_root: @repo_root, run_root: transient_root, image: @image
      )
      admitted_candidate = candidate_owner.verify!(receipt: sandbox_receipt).merge("status" => "verified").freeze
      smoke = build_controller(transient_root).external_smoke(
        controller_sha: @controller_sha, candidate_sha: @candidate_sha,
        candidate: admitted_candidate, sandbox_result: sandbox_receipt.fetch("payload")
      )
      reverify_phase_bindings!(authority)
      remove_transient_root!(transient_root)
      transient_root = nil
      provider_owner = build_provider_probe
      provider = provider_owner.call
      reverify_phase_bindings!(authority)
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
      process_evidence = error.respond_to?(:process_evidence) ? error.process_evidence : nil
      error, transient_root = cleanup_after_error(error, transient_root)
      publish_nonpassing(
        error, result_path, initial, authority, started_at,
        candidate: admitted_candidate || candidate_custody, sandbox_receipt:, smoke:, provider:,
        process_evidence:
      )
    rescue StandardError => error
      process_evidence = error.respond_to?(:process_evidence) ? error.process_evidence : nil
      reason = error.respond_to?(:reason) ? error.reason.to_s : "unexpected_failure"
      reason = "unexpected_failure" unless Result::REASONS.include?(reason)
      wrapped = Error.new(reason, error.class.name)
      wrapped, transient_root = cleanup_after_error(wrapped, transient_root)
      publish_nonpassing(
        wrapped, result_path, initial, authority, started_at,
        candidate: admitted_candidate || candidate_custody, sandbox_receipt:, smoke:, provider:,
        process_evidence:
      )
    ensure
      remove_transient_root!(transient_root) if transient_root
    end

    def cleanup_after_error(error, transient_root)
      return [ error, nil ] unless transient_root

      remove_transient_root!(transient_root)
      [ error, nil ]
    rescue Error => cleanup_error
      [ cleanup_error, nil ]
    end

    def publish_nonpassing(error, result_path, initial, authority, started_at,
                           candidate: nil, sandbox_receipt: nil, smoke: nil, provider: nil,
                           process_evidence: nil)
      raise error unless result_path && initial && authority && started_at

      status = blocked_reason?(error.reason) ? "blocked" : "failed"
      reason = Result::REASONS.include?(error.reason) ? error.reason : "unexpected_failure"
      terminal = Result.terminal(
        status:, reason:, authority:, candidate:,
        sandbox: sandbox_receipt&.fetch("sandbox"), smoke:, provider:,
        process_evidence: process_evidence || sandbox_receipt&.fetch("process_evidence") || [],
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

    def verify_authority!(now)
      verify_static_authority!
      @authorization_record = admit_authorization(now)
    end

    def verify_static_authority!
      unless SAFE_SHA.match?(@controller_sha) && SAFE_SHA.match?(@candidate_sha) &&
             @controller_sha != @candidate_sha
        raise AuthorityError.new("authority_binding", "controller and candidate identities are invalid")
      end
      raise AuthorityError.new("manual_authority_missing", "manual invocation identity is invalid") unless
        SAFE_ID.match?(@invocation_id)
      repo = owned_directory!(@repo_root, "controller checkout")
      head = git(repo, "rev-parse", "HEAD").strip
      raise AuthorityError.new("authority_binding", "controller checkout is not the authorized SHA") unless
        head == @controller_sha
      status = git(repo, "status", "--porcelain", "--untracked-files=all")
      raise AuthorityError.new("controller_checkout_dirty", "controller checkout is not clean") unless status.empty?
      remote_identity = Hive::RepositoryIdentity.normalize(git(repo, "remote", "get-url", "origin"), base_path: repo)
      unless remote_identity == "github.com/ivankuznetsov/hive"
        raise AuthorityError.new("authority_binding", "controller repository identity differs")
      end
      protected_main = protected_main_ref(repo)
      ancestry!(repo, @controller_sha, protected_main, "controller is not reachable from protected main")
      ancestry!(repo, @candidate_sha, protected_main, "candidate is not reachable from protected main")
      ancestry!(repo, @controller_sha, @candidate_sha, "candidate does not descend from the controller")
      verify_control_tree!(repo)
      @project_binding = build_project_binding
    end

    def protected_main_ref(repo)
      ref = "refs/remotes/origin/main"
      resolved = git(repo, "rev-parse", "--verify", "#{ref}^{commit}").strip
      raise AuthorityError.new("authority_binding", "protected main is unavailable") unless SAFE_SHA.match?(resolved)

      resolved
    end

    def ancestry!(repo, ancestor, descendant, message)
      _out, _err, status = capture_git(repo, "merge-base", "--is-ancestor", ancestor, descendant)
      raise AuthorityError.new("authority_binding", message) unless status.success?
    end

    def verify_control_tree!(repo)
      rows = CONTROL_PATHS.map do |relative|
        path = File.join(repo, relative)
        bytes = read_regular_file!(path, "controller file", 2 * 1024 * 1024)
        committed = git(repo, "show", "#{@controller_sha}:#{relative}")
        unless Digest::SHA256.digest(bytes) == Digest::SHA256.digest(committed)
          raise AuthorityError.new("authority_binding", "controller file differs from its authorized commit")
        end
        [ relative, Digest::SHA256.hexdigest(bytes) ]
      end
      @control_tree_sha256 = digest_json(rows.to_h)
    end

    def admit_authorization(now)
      unless @authorization.bytesize.between?(1, 8192)
        raise AuthorityError.new("manual_authority_missing", "manual authorization is invalid")
      end
      document = JSON.parse(@authorization)
      unless document.is_a?(Hash) && document.keys.sort == AUTHORIZATION_KEYS &&
             Result.canonical(document) == @authorization &&
             document.values_at("schema", "schema_version") == [ AUTHORIZATION_SCHEMA, 1 ]
        raise AuthorityError.new("manual_authority_missing", "manual authorization is not canonical")
      end
      issued_at = Time.iso8601(document.fetch("issued_at"))
      expires_at = Time.iso8601(document.fetch("expires_at"))
      expected = {
        "controller_sha" => @controller_sha, "candidate_sha" => @candidate_sha,
        "invocation_id" => @invocation_id, "image" => @image,
        "project_binding_sha256" => @project_binding.fetch("digest"),
        "observations_sha256" => @project_binding.fetch("observations_sha256"),
        "provider" => "openrouter", "model" => "openai/gpt-5.6-terra"
      }
      valid = expected.all? { |key, value| document.fetch(key) == value } &&
        SAFE_ID.match?(document.fetch("nonce").to_s) && issued_at.utc_offset.zero? &&
        expires_at.utc_offset.zero? && issued_at <= now && now < expires_at &&
        expires_at > issued_at && expires_at - issued_at <= AUTHORIZATION_MAX_AGE
      raise AuthorityError.new("manual_authority_missing", "manual authorization scope is invalid") unless valid

      document.freeze
    rescue JSON::ParserError, KeyError, ArgumentError, TypeError
      raise AuthorityError.new("manual_authority_missing", "manual authorization is invalid"), cause: nil
    end

    def authorization_template(now, nonce)
      unless SAFE_ID.match?(nonce.to_s)
        raise AuthorityError.new("manual_authority_missing", "manual authorization nonce is invalid")
      end
      Result.canonical(
        "schema" => AUTHORIZATION_SCHEMA,
        "schema_version" => 1,
        "controller_sha" => @controller_sha,
        "candidate_sha" => @candidate_sha,
        "invocation_id" => @invocation_id,
        "image" => @image,
        "project_binding_sha256" => @project_binding.fetch("digest"),
        "observations_sha256" => @project_binding.fetch("observations_sha256"),
        "provider" => "openrouter",
        "model" => "openai/gpt-5.6-terra",
        "issued_at" => now.iso8601(6),
        "expires_at" => (now + 900).iso8601(6),
        "nonce" => nonce.to_s
      )
    end

    def build_project_binding
      project = owned_directory!(@project_root, "disposable project")
      hive_home = owned_directory!(@hive_home, "Hive registry root")
      registry_path = File.join(hive_home, "config.yml")
      registry_bytes = read_regular_file!(registry_path, "Hive project registry", 1024 * 1024)
      registry = YAML.safe_load(registry_bytes, permitted_classes: [], permitted_symbols: [], aliases: false)
      rows = registry.is_a?(Hash) ? Array(registry["registered_projects"]) : []
      matches = rows.select do |row|
        next false unless row.is_a?(Hash) && row["path"].is_a?(String)

        File.realpath(File.expand_path(row.fetch("path"))) == project
      rescue SystemCallError
        false
      end
      unless matches.one?
        raise AuthorityError.new("authority_binding", "disposable project registration is unavailable")
      end
      registration = admit_registration(matches.fetch(0), project)
      repository_root = git(project, "rev-parse", "--show-toplevel").strip
      unless File.realpath(repository_root) == project
        raise AuthorityError.new("authority_binding", "disposable project is not a repository root")
      end
      repository_head = git(project, "rev-parse", "HEAD").strip
      raise AuthorityError.new("authority_binding", "disposable project HEAD is invalid") unless
        SAFE_SHA.match?(repository_head)
      origin = git(project, "remote", "get-url", "origin").strip
      repository_identity = Hive::RepositoryIdentity.normalize(origin, base_path: project)
      unless repository_identity && repository_identity == registration.fetch("repository_identity")
        raise AuthorityError.new("authority_binding", "disposable project repository identity differs")
      end
      state_root = File.join(project, ".hive-state")
      state_stat = owned_directory_stat!(state_root, "disposable Hive state")
      config_path = File.join(state_root, "config.yml")
      config_bytes = read_regular_file!(config_path, "disposable project configuration", 1024 * 1024)
      config = YAML.safe_load(config_bytes, permitted_classes: [], permitted_symbols: [], aliases: false)
      unless config.is_a?(Hash) && File.expand_path(config.fetch("hive_state_path", ".hive-state"), project) == state_root
        raise AuthorityError.new("authority_binding", "disposable project configuration escapes its state root")
      end
      observations = file_binding!(@observations_path, "prepared observations", INPUT_FILE_MAX_BYTES)
      state_tree = tree_binding!(state_root)
      project_stat = File.lstat(project)
      payload = {
        "project_path_sha256" => Digest::SHA256.hexdigest(project),
        "project_identity" => stat_identity(project_stat),
        "registration_sha256" => digest_json(registration),
        "registry_sha256" => Digest::SHA256.hexdigest(registry_bytes),
        "repository_identity_sha256" => Digest::SHA256.hexdigest(repository_identity),
        "repository_head" => repository_head,
        "state_identity" => stat_identity(state_stat),
        "state_tree_sha256" => state_tree,
        "config_sha256" => Digest::SHA256.hexdigest(config_bytes),
        "observations_identity" => observations.fetch("identity"),
        "observations_sha256" => observations.fetch("sha256")
      }
      payload.merge("digest" => digest_json(payload)).freeze
    rescue Psych::Exception, KeyError, TypeError, SystemCallError
      raise AuthorityError.new("authority_binding", "disposable project binding is invalid"), cause: nil
    end

    def admit_registration(row, project)
      state = File.join(project, ".hive-state")
      values = row.values_at(
        "name", "path", "hive_state_path", "project_id", "registration_id",
        "registered_at", "repository_identity"
      )
      valid = values.all? { |value| value.is_a?(String) && !value.empty? } &&
        File.expand_path(row.fetch("path")) == project &&
        File.expand_path(row.fetch("hive_state_path"), project) == state &&
        (!row.key?("real_path") || File.expand_path(row.fetch("real_path")) == project)
      raise AuthorityError.new("authority_binding", "disposable project registration is malformed") unless valid

      row.slice(
        "name", "path", "real_path", "hive_state_path", "project_id", "registration_id",
        "registered_at", "repository_identity"
      ).sort.to_h
    end

    def tree_binding!(root)
      count = 0
      bytes = 0
      rows = []
      walk = lambda do |directory, prefix|
        Dir.children(directory).sort.each do |name|
          raise AuthorityError.new("input_bound", "disposable state path is oversized") if
            name.bytesize > 240 || name == "." || name == ".."
          path = File.join(directory, name)
          relative = prefix.empty? ? name : File.join(prefix, name)
          stat = File.lstat(path)
          count += 1
          raise AuthorityError.new("input_bound", "disposable state tree has too many entries") if
            count > PROJECT_TREE_MAX_FILES
          if stat.directory? && !stat.symlink?
            rows << [ relative, "directory", stat.mode & 0o777 ]
            walk.call(path, relative)
          elsif stat.file? && !stat.symlink? && stat.nlink == 1 && stat.uid == Process.uid
            bytes += stat.size
            raise AuthorityError.new("input_bound", "disposable state tree is oversized") if
              bytes > PROJECT_TREE_MAX_BYTES
            content = read_regular_file!(
              path, "disposable state file", PROJECT_TREE_MAX_BYTES, allow_empty: true
            )
            rows << [ relative, "file", stat.mode & 0o777, stat.size, Digest::SHA256.hexdigest(content) ]
          else
            raise AuthorityError.new("authority_binding", "disposable state tree contains an unsafe entry")
          end
        end
      end
      walk.call(root, "")
      digest_json(rows)
    end

    def file_binding!(path, label, limit)
      bytes = read_regular_file!(path, label, limit)
      stat = File.lstat(File.expand_path(path))
      { "identity" => stat_identity(stat), "sha256" => Digest::SHA256.hexdigest(bytes) }
    end

    def stat_identity(stat)
      %i[dev ino uid mode nlink size].to_h { |field| [ field.to_s, stat.public_send(field) ] }
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

    def with_store_lock
      root = owned_directory!(@evidence_root, "evidence store")
      File.open(root, File::RDONLY) do |directory|
        directory.flock(File::LOCK_EX)
        yield
      ensure
        directory.flock(File::LOCK_UN) rescue nil
      end
    rescue EvidenceError, AuthorityError
      raise
    rescue SystemCallError
      raise EvidenceError.new("evidence_custody", "evidence store lock is unavailable"), cause: nil
    end

    def reject_authorization_replay!(digest)
      Dir.each_child(@evidence_root) do |name|
        path = File.join(@evidence_root, name, "result.json")
        next unless File.file?(path)

        bytes = read_regular_file!(path, "retained result", Result::MAX_RESULT_BYTES)
        document = JSON.parse(bytes)
        next unless Result.canonical(document) == bytes
        next unless document.dig("authority", "authorization_sha256") == digest

        raise AuthorityError.new("manual_authority_missing", "manual authorization was already used")
      end
    rescue JSON::ParserError, KeyError, TypeError
      raise EvidenceError.new("evidence_custody", "retained evidence is malformed"), cause: nil
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

    def create_transient_root!
      path = Dir.mktmpdir("hive-patrol-u3c-")
      File.chmod(0o700, path)
      stat = File.lstat(path)
      unless stat.directory? && !stat.symlink? && stat.uid == Process.uid && (stat.mode & 0o777) == 0o700
        raise EvidenceError.new("path_custody", "transient workspace custody failed")
      end
      @transient_identity = stat_identity(stat)
      path
    rescue SystemCallError
      raise EvidenceError.new("path_custody", "transient workspace is unavailable"), cause: nil
    end

    def remove_transient_root!(path)
      absolute = File.expand_path(path)
      stat = File.lstat(absolute)
      unless @transient_identity && stat_identity(stat) == @transient_identity &&
             stat.directory? && !stat.symlink? && stat.uid == Process.uid
        raise EvidenceError.new("path_custody", "transient workspace identity changed")
      end
      FileUtils.remove_entry_secure(absolute)
      @transient_identity = nil
      true
    rescue Errno::ENOENT
      raise EvidenceError.new("path_custody", "transient workspace disappeared"), cause: nil
    rescue EvidenceError
      raise
    rescue SystemCallError
      raise EvidenceError.new("path_custody", "transient workspace cleanup failed"), cause: nil
    end

    def prepared_candidate_record(candidate)
      keys = %w[
        archive_member_count archive_sha256 archive_total_bytes candidate_sha
        module_manifest_sha256 source_tree_sha256
      ]
      row = candidate.slice(*keys)
      unless row.keys.sort == keys.sort
        raise EvidenceError.new("candidate_identity", "prepared candidate custody is incomplete")
      end
      row.merge("status" => "prepared").freeze
    rescue NoMethodError, TypeError
      raise EvidenceError.new("candidate_identity", "prepared candidate custody is malformed"), cause: nil
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
        "control_tree_sha256" => @control_tree_sha256,
        "authorization_sha256" => Digest::SHA256.hexdigest(@authorization),
        "authorization_nonce_sha256" => Digest::SHA256.hexdigest(@authorization_record.fetch("nonce")),
        "authorization_expires_at" => @authorization_record.fetch("expires_at"),
        "invocation_id" => @invocation_id,
        "image" => @image,
        "observations_sha256" => @project_binding.fetch("observations_sha256"),
        "project_binding_sha256" => @project_binding.fetch("digest")
      }
    end

    def run_id(time)
      suffix = Digest::SHA256.hexdigest(
        [ @controller_sha, @candidate_sha, @invocation_id, Digest::SHA256.hexdigest(@authorization) ].join("\0")
      )[0, 12]
      "u3c-#{time.utc.strftime('%Y%m%dT%H%M%S%6NZ')}-#{suffix}"
    end

    def reverify_phase_bindings!(authority)
      verify_control_tree!(@repo_root)
      valid = Digest::SHA256.file(__FILE__).hexdigest == authority.fetch("runner_sha256") &&
        controller_script_digest == authority.fetch("controller_script_sha256") &&
        @control_tree_sha256 == authority.fetch("control_tree_sha256") &&
        build_project_binding == @project_binding
      raise AuthorityError.new("authority_binding", "controller or project authority changed during the run") unless valid
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

    def owned_directory_stat!(path, label)
      stat = File.lstat(path)
      unless stat.directory? && !stat.symlink? && stat.uid == Process.uid
        raise AuthorityError.new("authority_binding", "#{label} is not an owned directory")
      end
      stat
    rescue Errno::ENOENT, Errno::EACCES
      raise AuthorityError.new("authority_binding", "#{label} is unavailable")
    end

    def read_regular_file!(path, label, limit, allow_empty: false)
      File.open(File.expand_path(path), READ_FLAGS) do |file|
        stat = file.stat
        minimum = allow_empty ? 0 : 1
        unless stat.file? && stat.nlink == 1 && stat.uid == Process.uid &&
               (stat.mode & 0o022).zero? && stat.size.between?(minimum, limit)
          raise AuthorityError.new("authority_binding", "#{label} is unsafe")
        end
        bytes = file.read(limit + 1)
        current = File.lstat(File.expand_path(path))
        unless %i[dev ino uid mode nlink size].all? do |field|
          current.public_send(field) == stat.public_send(field)
        end
          raise AuthorityError.new("authority_binding", "#{label} identity changed")
        end
        bytes
      end
    rescue Errno::ENOENT, Errno::ELOOP, Errno::EACCES
      raise AuthorityError.new("authority_binding", "#{label} is unavailable"), cause: nil
    end

    def git(repo, *arguments)
      stdout, _stderr, status = capture_git(repo, *arguments)
      raise AuthorityError.new("authority_binding", "git authority check failed") unless status.success?
      stdout
    rescue SystemCallError
      raise AuthorityError.new("authority_binding", "git authority check is unavailable")
    end

    def capture_git(repo, *arguments)
      Timeout.timeout(10) do
        Open3.capture3(
          GIT_ENV, "git", "-c", "core.hooksPath=/dev/null", "-C", repo, *arguments,
          unsetenv_others: true
        )
      end
    rescue Timeout::Error, SystemCallError
      raise AuthorityError.new("authority_binding", "git authority check is unavailable"), cause: nil
    end

    def digest_json(value)
      Digest::SHA256.hexdigest(JSON.generate(canonical_value(value)))
    end

    def canonical_value(value)
      case value
      when Hash then value.keys.sort.to_h { |key| [ key, canonical_value(value.fetch(key)) ] }
      when Array then value.map { |item| canonical_value(item) }
      else value
      end
    end

    def fsync_directory(path)
      File.open(path, File::RDONLY) { |directory| directory.fsync }
    end
  end
end
