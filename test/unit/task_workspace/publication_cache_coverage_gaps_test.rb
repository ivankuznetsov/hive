require "test_helper"
require "hive/task_workspace/publication_cache"

class TaskWorkspacePublicationCacheCoverageGapsTest < Minitest::Test
  include HiveTestHelper

  Cache = Hive::TaskWorkspace::PublicationCache

  class TypeFailure
    def to_h
      raise TypeError, "not a mapping"
    end
  end

  class FakeFile
    def initialize(stat)
      @stat = stat
    end

    def stat = @stat
    def read(*) = "{}"
  end

  def test_default_clock_and_read_failures_are_fail_closed
    with_tmp_dir do |root|
      cache = build_cache(root, clock: :default)
      assert_kind_of Time, cache.instance_variable_get(:@clock).call
      assert_equal "identity_invalid", cache.read({}).dig("diagnostics", 0, "reason")

      with_replaced_singleton_method(cache, :normalize_identity, ->(*) { raise "bad cache" }) do
        assert_equal "cache_invalid", cache.read(identity).dig("diagnostics", 0, "reason")
      end
    end
  end

  def test_observation_identity_type_and_size_failures
    with_tmp_dir do |root|
      cache = build_cache(root)
      normalized = cache.send(:normalize_identity, identity)

      foreign = observation.merge("url" => "https://github.com/other/repo/pull/42")
      assert_raises(Cache::RefreshError) do
        cache.send(:normalize_observation, foreign, normalized)
      end
      error = assert_raises(Cache::RefreshError) do
        cache.send(:normalize_observation, TypeFailure.new, normalized)
      end
      assert_equal "response_invalid", error.reason

      small = build_cache(
        root, limits: Hive::TaskWorkspace::Limits.new(publication_cache_entry_bytes: 1_000)
      )
      fitted = small.send(
        :fit_observation,
        "title" => "t", "body" => "b" * 600,
        "checks" => [ { "name" => "x" * 600 } ]
      )
      assert_empty fitted.fetch("checks")
      assert fitted.fetch("checks_truncated")
      assert_operator fitted.fetch("body").bytesize, :<, 600

      assert_raises(Cache::RefreshError) do
        small.send(
          :fit_observation,
          "title" => "t", "body" => "", "checks" => [], "immutable" => "x" * 1_000
        )
      end
    end
  end

  def test_read_and_write_entry_validate_permissions_descriptor_size_and_identity
    with_tmp_dir do |root|
      cache = build_cache(root)
      normalized = cache.send(:normalize_identity, identity)
      path = cache.send(:entry_path, normalized)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "{}")

      File.chmod(0o644, path)
      assert_equal "cache_permissions_invalid", assert_raises(Hive::TaskWorkspace::SourceError) {
        cache.send(:read_entry, path, normalized)
      }.reason

      File.chmod(0o600, path)
      before = File.lstat(path)
      changed = Struct.new(:dev, :ino, :file?, :symlink?, :uid, :mode).new(
        before.dev, before.ino + 1, true, false, Process.uid, 0o100600
      )
      with_replaced_singleton_method(File, :open, ->(*, &block) { block.call(FakeFile.new(changed)) }) do
        assert_equal "cache_descriptor_changed", assert_raises(Hive::TaskWorkspace::SourceError) {
          cache.send(:read_entry, path, normalized)
        }.reason
      end

      limits = Hive::TaskWorkspace::Limits.new(publication_cache_entry_bytes: 20)
      small = build_cache(root, limits: limits)
      File.write(path, "x" * 21)
      File.chmod(0o600, path)
      assert_equal "cache_entry_oversized", assert_raises(Hive::TaskWorkspace::SourceError) {
        small.send(:read_entry, path, normalized)
      }.reason

      File.write(path, JSON.generate("schema" => "wrong"))
      File.chmod(0o600, path)
      assert_equal "cache_identity_invalid", assert_raises(Hive::TaskWorkspace::SourceError) {
        cache.send(:read_entry, path, normalized)
      }.reason

      with_replaced_singleton_method(File, :lstat, ->(*) { raise Errno::ELOOP }) do
        assert_equal "cache_symlink_refused", assert_raises(Hive::TaskWorkspace::SourceError) {
          cache.send(:read_entry, path, normalized)
        }.reason
      end

      assert_equal "cache_entry_oversized", assert_raises(Hive::TaskWorkspace::SourceError) {
        small.send(:write_entry, path, "payload" => "x" * 100)
      }.reason
    end
  end

  def test_private_directories_and_locks_reject_unsafe_files
    with_tmp_dir do |root|
      cache = build_cache(root)
      directory = File.join(root, "directory")
      Dir.mkdir(directory)
      with_replaced_singleton_method(File, :chmod, ->(*) { raise Errno::EACCES }) do
        assert_equal "cache_directory_unavailable", assert_raises(Hive::TaskWorkspace::SourceError) {
          cache.send(:ensure_private_directory, directory)
        }.reason
      end

      unsafe = File.join(root, "unsafe-after-create")
      with_replaced_singleton_method(
        FileUtils, :mkdir_p, ->(path, **) { File.write(path, "not a directory") }
      ) do
        assert_equal "cache_directory_unsafe", assert_raises(Hive::TaskWorkspace::SourceError) {
          cache.send(:ensure_private_directory, unsafe)
        }.reason
      end

      lock = File.join(root, "lock")
      File.write(lock, "")
      File.chmod(0o644, lock)
      assert_equal "cache_lock_unsafe", assert_raises(Hive::TaskWorkspace::SourceError) {
        cache.send(:open_lock, lock)
      }.reason

      FileUtils.rm_f(lock)
      target = File.join(root, "target")
      File.write(target, "")
      File.symlink(target, lock)
      assert_equal "cache_symlink_refused", assert_raises(Hive::TaskWorkspace::SourceError) {
        cache.send(:open_lock, lock)
      }.reason
    end
  end

  def test_eviction_and_inventory_caps_are_bounded
    original_limit = Cache::MAX_CACHE_DIRS
    with_tmp_dir do |root|
      cache = build_cache(
        root, limits: Hive::TaskWorkspace::Limits.new(publication_cache_principal_bytes: 10)
      )
      project_root = cache.send(:project_root)
      FileUtils.mkdir_p(project_root)
      two_files(project_root).each do |path|
        File.write(path, "x" * 20)
        File.chmod(0o600, path)
      end
      diagnostic = cache.send(:evict_principal!)
      assert_equal "principal_cache_evicted", diagnostic.fetch("reason")
      assert_operator diagnostic.dig("details", "removed_entries"), :>=, 1

      two_files(project_root).each do |path|
        File.write(path, "x" * 20)
        File.chmod(0o600, path)
      end
      first = true
      original = File.method(:unlink)
      with_replaced_singleton_method(File, :unlink, lambda { |path|
        if first
          first = false
          raise Errno::ENOENT
        end
        original.call(path)
      }) do
        assert_equal "principal_cache_evicted", cache.send(:evict_principal!).fetch("reason")
      end

      Cache.send(:remove_const, :MAX_CACHE_DIRS)
      Cache.const_set(:MAX_CACHE_DIRS, 0)
      assert_equal "cache_inventory_exhausted", assert_raises(Hive::TaskWorkspace::SourceError) {
        cache.send(:cache_files)
      }.reason
    ensure
      Cache.send(:remove_const, :MAX_CACHE_DIRS)
      Cache.const_set(:MAX_CACHE_DIRS, original_limit) if original_limit
    end
  end

  def test_inventory_missing_entries_and_safe_urls
    original_limit = Cache::MAX_CACHE_FILES
    with_tmp_dir do |root|
      cache = build_cache(root)
      principal = cache.send(:principal_root)
      project = cache.send(:project_root)
      FileUtils.mkdir_p(project)
      path = two_files(project).first
      File.write(path, "x")
      File.chmod(0o600, path)

      original = File.method(:lstat)
      with_replaced_singleton_method(File, :lstat, lambda { |candidate|
        raise Errno::ENOENT if candidate == path

        original.call(candidate)
      }) do
        assert_empty cache.send(:cache_files)
      end
      with_replaced_singleton_method(File, :lstat, lambda { |candidate|
        raise Errno::ENOENT if candidate == project

        original.call(candidate)
      }) do
        assert_empty cache.send(:cache_files)
      end
      assert File.directory?(principal)

      File.chmod(0o600, path)
      Cache.send(:remove_const, :MAX_CACHE_FILES)
      Cache.const_set(:MAX_CACHE_FILES, 0)
      assert_equal "cache_inventory_exhausted", assert_raises(Hive::TaskWorkspace::SourceError) {
        cache.send(:cache_files)
      }.reason

      bad_retry = Object.new
      bad_retry.define_singleton_method(:to_s) { raise ArgumentError, "bad retry" }
      assert_nil cache.send(
        :server_retry_at,
        {
          "refreshed_at" => "2026-08-12T12:00:00Z",
          "last_error" => { "details" => { "retry_after" => bad_retry } }
        }
      )

      assert_equal "https://example.com/path", cache.send(:safe_https_url, "https://example.com/path")
      assert_nil cache.send(:safe_https_url, "https://[")
    end
  ensure
    Cache.send(:remove_const, :MAX_CACHE_FILES)
    Cache.const_set(:MAX_CACHE_FILES, original_limit) if original_limit
  end

  private

  def build_cache(root, limits: Hive::TaskWorkspace::Limits.new,
                  clock: -> { Time.utc(2026, 8, 12, 12) })
    clock = nil if clock == :default
    options = {
      principal_id: Cache.principal_id("credential", secret: "secret"),
      project_fingerprint: Cache.project_fingerprint("name" => "demo"),
      root: root, limits: limits
    }
    options[:clock] = clock if clock
    Cache.new(**options)
  end

  def identity
    {
      "repository" => "github.com/acme/demo", "number" => 42,
      "expected_head" => "a" * 40
    }
  end

  def observation
    {
      "repository" => "github.com/acme/demo", "number" => 42,
      "url" => "https://github.com/acme/demo/pull/42", "state" => "OPEN",
      "title" => "Title", "body" => "Body", "head_oid" => "a" * 40,
      "checks" => []
    }
  end

  def two_files(root)
    [ "a", "b" ].map { |name| File.join(root, "#{name * 64}.json") }
  end
end
