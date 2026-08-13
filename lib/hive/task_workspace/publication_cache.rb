require "digest"
require "fileutils"
require "json"
require "openssl"
require "time"
require "uri"
require "hive/atomic_file"
require "hive/gh"
require "hive/paths"
require "hive/secret_patterns"
require "hive/task_workspace"

module Hive
  module TaskWorkspace
    # Credential- and registration-scoped advisory GitHub observations. Reads
    # never create directories or contact GitHub; only an explicit refresh
    # enters the private cache, takes the per-identity lock, and invokes the
    # supplied one-read transport.
    class PublicationCache
      SCHEMA = "hive-task-publication-cache".freeze
      VERSION = 1
      DIGEST_RE = /\A[0-9a-f]{64}\z/.freeze
      OID_RE = /\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/.freeze
      MAX_CACHE_DIRS = 1_024
      MAX_CACHE_FILES = 8_192

      class RefreshError < StandardError
        attr_reader :reason, :retry_after

        def initialize(reason, message = nil, retry_after: nil)
          @reason = reason.to_s
          @retry_after = retry_after
          super(message || reason.to_s)
        end
      end

      class << self
        def principal_id(credential, secret:)
          value = credential.to_s
          raise ArgumentError, "publication credential is unavailable" if value.empty?
          raise ArgumentError, "publication cache secret is unavailable" if secret.to_s.empty?

          OpenSSL::HMAC.hexdigest("SHA256", secret.to_s, value)
        end

        def project_fingerprint(project)
          values = project.to_h.transform_keys(&:to_s)
          payload = %w[name project_id registration_id repository_identity].to_h do |key|
            [ key, values[key].to_s ]
          end
          Digest::SHA256.hexdigest(JSON.generate(payload))
        end
      end

      def initialize(principal_id:, project_fingerprint:,
                     root: File.join(Hive::Paths.data_home, "task-workspace", "publication"),
                     limits: Limits.new, clock: -> { Time.now.utc })
        @principal_id = validated_digest(principal_id, "credential principal")
        @project_fingerprint = validated_digest(project_fingerprint, "project fingerprint")
        @root = File.expand_path(root)
        @limits = limits
        @clock = clock
      end

      def read(identity)
        identity = normalize_identity(identity)
        entry = read_entry(entry_path(identity), identity)
        return unavailable("not_observed") unless entry

        present_entry(entry)
      rescue SourceError => e
        unavailable(e.reason, diagnostic: e.diagnostic)
      rescue StandardError => e
        unavailable(
          "cache_invalid",
          diagnostic: diagnostic("cache_invalid", e.class.name)
        )
      end

      def refresh(identity)
        identity = normalize_identity(identity)
        ensure_private_tree!
        path = entry_path(identity)
        lock_path = "#{path}.lock"
        lock = open_lock(lock_path)
        unless lock.flock(File::LOCK_EX | File::LOCK_NB)
          return read(identity).merge(
            "refresh_state" => "busy",
            "diagnostics" => [ diagnostic("refresh_in_progress") ]
          )
        end

        existing = read_entry(path, identity)
        now = utc_time(@clock.call)
        if existing && (next_refresh = next_refresh_at(existing)) && now < next_refresh
          retry_at = next_refresh.iso8601(6)
          reason = server_retry_at(existing) == next_refresh ? "server_retry_after" : "refresh_interval"
          return present_entry(existing).merge(
            "refresh_state" => "retry-after", "retry_at" => retry_at,
            "diagnostics" => [ diagnostic(reason, nil, "retry_at" => retry_at) ]
          )
        end

        begin
          observation = normalize_observation(yield, identity)
          entry = cache_entry(
            identity, observation: observation,
            observed_at: now.iso8601(6), refreshed_at: now.iso8601(6), last_error: nil
          )
        rescue StandardError => e
          error = refresh_diagnostic(e, now)
          entry = cache_entry(
            identity,
            observation: existing && existing["observation"],
            observed_at: existing && existing["observed_at"],
            refreshed_at: now.iso8601(6), last_error: error
          )
        end
        write_entry(path, entry)
        eviction = evict_principal!
        presented = present_entry(entry)
        presented["diagnostics"] = Array(presented["diagnostics"]) + [ eviction ] if eviction
        presented
      rescue SourceError => e
        unavailable(e.reason, diagnostic: e.diagnostic).merge("refresh_state" => "failed")
      ensure
        lock&.flock(File::LOCK_UN) rescue nil
        lock&.close rescue nil
      end

      private

      def normalize_identity(value)
        input = value.to_h.transform_keys(&:to_s)
        repository = input.fetch("repository").to_s.downcase
        host, owner, name = repository.split("/", 3)
        Hive::Gh::RepositoryIdentity.validated_github_host(host)
        slug = Hive::Gh::RepositoryIdentity.validated_repository_slug("#{owner}/#{name}").downcase
        number = Integer(input.fetch("number"))
        raise ArgumentError, "pull request number must be positive" unless number.positive?
        head = input.fetch("expected_head").to_s.downcase
        raise ArgumentError, "expected head must be a full commit OID" unless head.match?(OID_RE)

        { "repository" => "#{host.downcase}/#{slug}", "number" => number, "expected_head" => head }
      rescue KeyError, ArgumentError, TypeError, Hive::GhError => e
        raise SourceError.new(
          source: "publication_cache", reason: "identity_invalid", message: e.class.name
        )
      end

      def normalize_observation(value, identity)
        input = value.to_h.transform_keys(&:to_s)
        unless input["repository"].to_s.downcase == identity.fetch("repository") &&
               Integer(input["number"], exception: false) == identity.fetch("number")
          raise RefreshError.new("identity_mismatch", "GitHub returned a different pull request identity")
        end

        parsed_url = Hive::Gh.parse_pull_request_url(input["url"])
        expected_slug = identity.fetch("repository").split("/", 2).last
        unless parsed_url && parsed_url.fetch("repository") == expected_slug &&
               parsed_url.fetch("number") == identity.fetch("number")
          raise RefreshError.new("identity_mismatch", "GitHub returned a foreign pull request URL")
        end

        text_budget = @limits.fetch(:github_pr_text_bytes)
        title = bounded_text(input["title"], [ text_budget, 4 * 1024 ].min)
        text_budget -= title.bytesize
        body = bounded_text(input["body"], [ text_budget, 0 ].max)
        checks = Array(input["checks"]).first(@limits.fetch(:github_checks)).filter_map do |check|
          next unless check.is_a?(Hash)

          row = check.transform_keys(&:to_s)
          {
            "name" => bounded_text(row["name"], 256),
            "status" => bounded_text(row["status"], 64),
            "conclusion" => bounded_text(row["conclusion"], 64),
            "url" => safe_https_url(row["url"])
          }
        end
        observation = {
          "repository" => identity.fetch("repository"),
          "number" => identity.fetch("number"),
          "url" => parsed_url.fetch("url"),
          "state" => enum(input["state"], %w[OPEN CLOSED MERGED], "UNKNOWN"),
          "is_draft" => input["is_draft"] == true,
          "title" => title,
          "body" => body,
          "base_branch" => bounded_text(input["base_branch"], 256),
          "base_oid" => valid_oid_or_nil(input["base_oid"]),
          "head_branch" => bounded_text(input["head_branch"], 256),
          "head_oid" => valid_oid_or_nil(input["head_oid"]),
          "expected_head" => identity.fetch("expected_head"),
          "head_matches" => valid_oid_or_nil(input["head_oid"]) == identity.fetch("expected_head"),
          "head_branch_present" => input["head_branch_present"] != false,
          "merge_state" => bounded_text(input["merge_state"], 64),
          "review_decision" => bounded_text(input["review_decision"], 64),
          "merged_at" => valid_time_or_nil(input["merged_at"]),
          "merge_commit_oid" => valid_oid_or_nil(input["merge_commit_oid"]),
          "checks" => checks,
          "checks_truncated" => input["checks_truncated"] == true ||
                                Array(input["checks"]).length > checks.length
        }
        fit_observation(observation)
      rescue TypeError
        raise RefreshError.new("response_invalid", "GitHub response was not a mapping")
      end

      def fit_observation(observation)
        maximum = @limits.fetch(:publication_cache_entry_bytes) / 2
        copy = observation.merge("checks" => observation.fetch("checks").dup)
        while JSON.generate(copy).bytesize > maximum && copy["checks"].any?
          copy["checks"].pop
          copy["checks_truncated"] = true
        end
        if JSON.generate(copy).bytesize > maximum
          excess = JSON.generate(copy).bytesize - maximum
          body = copy["body"].to_s
          copy["body"] = utf8_prefix(body, [ body.bytesize - excess - 64, 0 ].max)
        end
        if JSON.generate(copy).bytesize > maximum
          raise RefreshError.new("response_oversized", "normalized GitHub response exceeds cache limit")
        end
        copy
      end

      def cache_entry(identity, observation:, observed_at:, refreshed_at:, last_error:)
        {
          "schema" => SCHEMA, "schema_version" => VERSION,
          "identity" => identity, "observation" => observation,
          "observed_at" => observed_at, "refreshed_at" => refreshed_at,
          "last_error" => last_error
        }
      end

      def present_entry(entry)
        now = utc_time(@clock.call)
        observed_at = parse_time(entry["observed_at"])
        error = entry["last_error"]
        unless entry["observation"] && observed_at
          return unavailable(
            error ? error.fetch("reason", "refresh_failed") : "not_observed",
            diagnostic: error
          ).merge("refresh_state" => error ? "failed" : "idle")
        end

        age = [ now - observed_at, 0 ].max
        cache_state = if age <= @limits.fetch(:publication_fresh_seconds)
          "fresh"
        elsif age <= @limits.fetch(:publication_stale_seconds)
          "stale"
        else
          "expired"
        end
        return unavailable("cache_expired").merge(
          "cache_state" => cache_state, "observed_at" => entry["observed_at"]
        ) if cache_state == "expired"

        {
          "state" => error ? "partial" : (cache_state == "fresh" ? "current" : "stale"),
          "cache_state" => cache_state,
          "refresh_state" => error ? "failed" : "idle",
          "observation" => entry["observation"],
          "observed_at" => entry["observed_at"],
          "refreshed_at" => entry["refreshed_at"],
          "retry_at" => future_retry_at(entry, now)&.iso8601(6),
          "diagnostics" => error ? [ error ] : []
        }
      end

      def unavailable(reason, diagnostic: nil)
        {
          "state" => "unavailable", "cache_state" => "unavailable",
          "refresh_state" => "idle", "observation" => nil,
          "observed_at" => nil, "refreshed_at" => nil, "retry_at" => nil,
          "diagnostics" => [ diagnostic || self.diagnostic(reason) ]
        }
      end

      def entry_path(identity)
        File.join(project_root, "#{identity_digest(identity)}.json")
      end

      def identity_digest(identity)
        Digest::SHA256.hexdigest(JSON.generate(identity))
      end

      def principal_root
        File.join(@root, @principal_id)
      end

      def project_root
        File.join(principal_root, @project_fingerprint)
      end

      def read_entry(path, expected_identity)
        return nil unless File.exist?(path)

        before = File.lstat(path)
        unless private_regular?(before)
          raise SourceError.new(source: "publication_cache", reason: "cache_permissions_invalid")
        end
        flags = File::RDONLY
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        raw = File.open(path, flags) do |file|
          opened = file.stat
          unless opened.dev == before.dev && opened.ino == before.ino && private_regular?(opened)
            raise SourceError.new(source: "publication_cache", reason: "cache_descriptor_changed")
          end
          value = file.read(@limits.fetch(:publication_cache_entry_bytes) + 1).to_s
          if value.bytesize > @limits.fetch(:publication_cache_entry_bytes)
            raise SourceError.new(
              source: "publication_cache", reason: "cache_entry_oversized",
              details: {
                "cap" => "publication_cache_entry_bytes",
                "limit" => @limits.fetch(:publication_cache_entry_bytes),
                "observed_bytes" => value.bytesize
              }
            )
          end
          value
        end
        entry = JSON.parse(raw)
        unless entry.is_a?(Hash) && entry["schema"] == SCHEMA &&
               entry["schema_version"] == VERSION && entry["identity"] == expected_identity
          raise SourceError.new(source: "publication_cache", reason: "cache_identity_invalid")
        end
        entry
      rescue JSON::ParserError
        raise SourceError.new(source: "publication_cache", reason: "cache_json_invalid")
      rescue Errno::ELOOP
        raise SourceError.new(source: "publication_cache", reason: "cache_symlink_refused")
      end

      def write_entry(path, entry)
        bytes = JSON.generate(entry)
        if bytes.bytesize > @limits.fetch(:publication_cache_entry_bytes)
          raise SourceError.new(
            source: "publication_cache", reason: "cache_entry_oversized",
            details: {
              "cap" => "publication_cache_entry_bytes",
              "limit" => @limits.fetch(:publication_cache_entry_bytes),
              "observed_bytes" => bytes.bytesize
            }
          )
        end
        Hive::AtomicFile.write(path, "#{bytes}\n", mode: 0o600)
        File.chmod(0o600, path)
      end

      def ensure_private_tree!
        current = @root
        ensure_private_directory(current)
        [ @principal_id, @project_fingerprint ].each do |part|
          current = File.join(current, part)
          ensure_private_directory(current)
        end
      end

      def ensure_private_directory(path)
        begin
          stat = File.lstat(path)
          unless stat.directory? && !stat.symlink? && stat.uid == Process.uid
            raise SourceError.new(source: "publication_cache", reason: "cache_directory_unsafe")
          end
        rescue Errno::ENOENT
          FileUtils.mkdir_p(path, mode: 0o700)
          stat = File.lstat(path)
          unless stat.directory? && !stat.symlink? && stat.uid == Process.uid
            raise SourceError.new(source: "publication_cache", reason: "cache_directory_unsafe")
          end
        end
        File.chmod(0o700, path)
      rescue SystemCallError => e
        raise SourceError.new(
          source: "publication_cache", reason: "cache_directory_unavailable",
          message: e.class.name
        )
      end

      def open_lock(path)
        flags = File::RDWR | File::CREAT
        flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
        file = File.open(path, flags, 0o600)
        stat = file.stat
        unless private_regular?(stat)
          file.close
          raise SourceError.new(source: "publication_cache", reason: "cache_lock_unsafe")
        end
        File.chmod(0o600, path)
        file
      rescue Errno::ELOOP
        raise SourceError.new(source: "publication_cache", reason: "cache_symlink_refused")
      end

      def evict_principal!
        files = cache_files
        total = files.sum { |row| row.fetch(:size) }
        observed_total = total
        cap = @limits.fetch(:publication_cache_principal_bytes)
        return if total <= cap

        removed = 0
        files.sort_by { |row| [ row.fetch(:mtime), row.fetch(:path) ] }.each do |row|
          break if total <= cap

          File.unlink(row.fetch(:path))
          total -= row.fetch(:size)
          removed += 1
        rescue Errno::ENOENT
          nil
        end
        diagnostic(
          "principal_cache_evicted", nil,
          "cap" => "publication_cache_principal_bytes", "limit" => cap,
          "observed_bytes" => observed_total, "retained_bytes" => total,
          "removed_entries" => removed
        )
      end

      def cache_files
        return [] unless File.directory?(principal_root)

        directories = Dir.children(principal_root).sort.first(MAX_CACHE_DIRS + 1)
        if directories.length > MAX_CACHE_DIRS
          raise SourceError.new(source: "publication_cache", reason: "cache_inventory_exhausted")
        end
        files = []
        directories.each do |directory|
          next unless directory.match?(DIGEST_RE)

          root = File.join(principal_root, directory)
          stat = File.lstat(root)
          next unless stat.directory? && !stat.symlink? && stat.uid == Process.uid

          Dir.children(root).sort.each do |name|
            next unless name.match?(/\A[0-9a-f]{64}\.json\z/)

            path = File.join(root, name)
            child = File.lstat(path)
            next unless private_regular?(child)

            files << { path: path, size: child.size, mtime: child.mtime.to_f }
            if files.length > MAX_CACHE_FILES
              raise SourceError.new(source: "publication_cache", reason: "cache_inventory_exhausted")
            end
          rescue Errno::ENOENT
            nil
          end
        rescue Errno::ENOENT
          nil
        end
        files
      end

      def next_refresh_at(entry)
        refreshed = parse_time(entry["refreshed_at"])
        return unless refreshed

        [
          refreshed + @limits.fetch(:publication_refresh_interval_seconds),
          server_retry_at(entry, refreshed: refreshed)
        ].compact.max
      end

      def server_retry_at(entry, refreshed: parse_time(entry["refreshed_at"]))
        value = entry.dig("last_error", "details", "retry_after")
        return if value.to_s.empty? || !refreshed

        if value.to_s.match?(/\A\d+\z/)
          refreshed + Integer(value)
        else
          parse_time(value)
        end
      rescue ArgumentError, TypeError
        nil
      end

      def future_retry_at(entry, now)
        retry_at = server_retry_at(entry)
        retry_at if retry_at && retry_at > now
      end

      def refresh_diagnostic(error, now)
        reason = error.respond_to?(:reason) ? error.reason : "refresh_failed"
        details = { "failed_at" => now.iso8601(6) }
        if error.respond_to?(:retry_after) && error.retry_after
          details["retry_after"] = error.retry_after.to_s
        end
        diagnostic(reason, error.class.name, details)
      end

      def diagnostic(reason, message = nil, details = {})
        {
          "source" => "publication_cache", "reason" => reason.to_s,
          "message" => Hive::SecretPatterns.redact(message.to_s),
          "details" => details
        }
      end

      def bounded_text(value, bytes)
        Hive::SecretPatterns.redact(utf8_prefix(value.to_s, bytes))
      end

      def utf8_prefix(value, bytes)
        return "" if bytes <= 0

        value.to_s.b.byteslice(0, bytes).to_s.force_encoding(Encoding::UTF_8).scrub("")
      end

      def enum(value, allowed, fallback)
        string = value.to_s.upcase
        allowed.include?(string) ? string : fallback
      end

      def valid_oid_or_nil(value)
        oid = value.to_s.downcase
        oid.match?(OID_RE) ? oid : nil
      end

      def valid_time_or_nil(value)
        time = parse_time(value)
        time&.iso8601(6)
      end

      def safe_https_url(value)
        uri = URI.parse(value.to_s)
        return nil unless uri.scheme == "https" && uri.host && uri.userinfo.nil?

        uri.to_s.byteslice(0, 2_048)
      rescue URI::InvalidURIError
        nil
      end

      def parse_time(value)
        Time.iso8601(value.to_s).utc
      rescue ArgumentError, TypeError
        nil
      end

      def utc_time(value)
        value.respond_to?(:utc) ? value.utc : Time.parse(value.to_s).utc
      end

      def private_regular?(stat)
        stat.file? && !stat.symlink? && stat.uid == Process.uid && (stat.mode & 0o077).zero?
      end

      def validated_digest(value, label)
        string = value.to_s
        raise ArgumentError, "#{label} is invalid" unless string.match?(DIGEST_RE)

        string
      end
    end
  end
end
