require "test_helper"
require "hive/betterleaks"
require "hive/gh"
require "rubygems/package"
require "zlib"
require_relative "../../packaging/betterleaks"

class BetterleaksTest < Minitest::Test
  include HiveTestHelper

  def test_prefers_the_bundled_binary_and_allows_a_source_checkout_fallback
    with_replaced_singleton_method(File, :executable?, ->(*) { true }) do
      assert_match %r{/assets/betterleaks/(linux|darwin)_(x64|arm64)/betterleaks\z}, Hive::Betterleaks.executable
    end
    with_replaced_singleton_method(File, :executable?, ->(*) { false }) do
      assert_equal "betterleaks", Hive::Betterleaks.executable
    end
  end

  def test_unconfigured_and_empty_cache_build_all_platforms_with_original_modes
    [ nil, "" ].each do |setting|
      package_fixture do |root, _cache, requests|
        with_env("HIVE_BETTERLEAKS_CACHE_DIR" => setting) { HiveBetterleaksPackage.build(root: root) }
        assert_equal Hive::Betterleaks::ASSETS.keys, requests
        assert_bundle(root)
      end
    end
  end

  def test_warm_cache_verifies_all_four_archives_without_downloading
    package_fixture(warm: true) do |root, cache, requests|
      with_env("HIVE_BETTERLEAKS_CACHE_DIR" => cache) { HiveBetterleaksPackage.build(root: root) }
      assert_empty requests
      assert_bundle(root)
    end
  end

  def test_mixed_cache_fetches_only_missing_and_corrupt_entries_and_repairs_them
    package_fixture(warm: true) do |root, cache, requests|
      missing, corrupt = Hive::Betterleaks::ASSETS.keys.first(2)
      File.unlink(cache_path(cache, missing))
      File.write(cache_path(cache, corrupt), "corrupt archive")
      _out, err = capture_io { HiveBetterleaksPackage.build(root: root, cache_dir: cache) }
      assert_equal [ missing, corrupt ], requests
      assert_includes err, "cache checksum mismatch"
      assert_bundle(root)
      assert_cache(cache)
    end
  end

  def test_cache_read_and_publication_errors_still_install_verified_downloads
    %i[read copy mkdir rename].each do |failure|
      package_fixture(warm: true) do |root, cache, requests|
        receiver, name = case failure
        when :read, :copy then [ FileUtils, :cp ]
        when :mkdir then [ FileUtils, :mkdir_p ]
        when :rename then [ File, :rename ]
        end
        original = receiver.method(name)
        replacement = lambda do |*args, **kwargs|
          cache_operation = if failure == :read
            args.first.start_with?(cache + "/")
          elsif failure == :copy
            args[1].to_s.start_with?(cache + "/")
          else
            args.last == cache || args.last.to_s.start_with?(cache + "/")
          end
          raise Errno::EACCES, "synthetic private detail" if cache_operation
          original.call(*args, **kwargs)
        end
        # Read errors use populated entries; publication errors use misses.
        FileUtils.rm_rf(cache) unless failure == :read
        with_replaced_singleton_method(receiver, name, replacement) do
          _out, err = capture_io { HiveBetterleaksPackage.build(root: root, cache_dir: cache) }
          assert_includes err, "Betterleaks cache"
          refute_includes err, "synthetic private detail"
        end
        assert_equal Hive::Betterleaks::ASSETS.keys, requests
        assert_bundle(root)
        assert_empty Dir.glob(File.join(cache, ".betterleaks-*"))
      end
    end
  end

  def test_non_directory_cache_is_diagnosed_and_falls_back
    package_fixture do |root, cache, requests|
      File.write(cache, "not a directory")
      _out, err = capture_io { HiveBetterleaksPackage.build(root: root, cache_dir: cache) }
      assert_includes err, "Betterleaks cache"
      assert_equal 4, requests.size
      assert_bundle(root)
    end
  end

  def test_bad_download_never_replaces_a_corrupt_cache_or_installs_a_binary
    package_fixture(failure: :checksum, warm: true) do |root, cache, requests|
      first = Hive::Betterleaks::ASSETS.keys.first
      File.write(cache_path(cache, first), "corrupt")
      capture_io do
        assert_raises(RuntimeError) { HiveBetterleaksPackage.build(root: root, cache_dir: cache) }
      end
      assert_equal [ first ], requests
      assert_equal "corrupt", File.read(cache_path(cache, first))
      assert_empty Dir.glob(File.join(root, "*", "betterleaks"))
      assert_empty Dir.glob(File.join(cache, ".betterleaks-*"))
    end
  end

  def test_download_and_extraction_failures_stop_before_installation
    %i[download extraction].each do |failure|
      package_fixture(failure: failure) do |root, cache, requests|
        assert_raises(RuntimeError) { HiveBetterleaksPackage.build(root: root, cache_dir: cache) }
        assert_equal 1, requests.size
        assert_empty Dir.glob(File.join(root, "*", "betterleaks"))
      end
    end
  end

  private

  def assert_bundle(root)
    Hive::Betterleaks::ASSETS.each_key do |platform|
      binary = File.join(root, platform, "betterleaks")
      license = File.join(root, platform, "LICENSE")
      assert_equal "binary #{platform}", File.read(binary)
      assert_equal "license #{platform}", File.read(license)
      assert_equal 0o755, File.stat(binary).mode & 0o777
      assert_equal 0o644, File.stat(license).mode & 0o777
    end
  end

  def cache_path(cache, platform)
    File.join(cache, "#{Hive::Betterleaks::ASSETS.fetch(platform)}.tar.gz")
  end

  def assert_cache(cache)
    assert_equal Hive::Betterleaks::ASSETS.values.map { |digest| "#{digest}.tar.gz" }.sort, Dir.children(cache).sort
    Hive::Betterleaks::ASSETS.each do |platform, digest|
      assert_equal digest, Digest::SHA256.file(cache_path(cache, platform)).hexdigest
    end
  end

  def package_fixture(failure: nil, warm: false)
    Dir.mktmpdir do |temporary|
      root = File.join(temporary, "bundle")
      cache = File.join(temporary, "cache")
      archives = Hive::Betterleaks::ASSETS.keys.to_h do |platform|
        tar = StringIO.new
        Gem::Package::TarWriter.new(tar) do |writer|
          { "betterleaks" => "binary #{platform}", "LICENSE" => "license #{platform}" }.each do |name, bytes|
            writer.add_file_simple(name, 0o600, bytes.bytesize) { |file| file.write(bytes) }
          end
        end
        gzip = StringIO.new
        Zlib::GzipWriter.wrap(gzip) { |writer| writer.write(tar.string) }
        [ platform, gzip.string ]
      end
      assets = archives.transform_values { |bytes| Digest::SHA256.hexdigest(bytes) }.freeze
      original_assets = Hive::Betterleaks::ASSETS
      Hive::Betterleaks.send(:remove_const, :ASSETS)
      Hive::Betterleaks.const_set(:ASSETS, assets)
      if warm
        FileUtils.mkdir_p(cache)
        archives.each { |platform, bytes| File.binwrite(cache_path(cache, platform), bytes) }
      end
      requests = []
      original_capture = Open3.method(:capture3)
      capture = lambda do |*argv, **options|
        if argv.first == "curl"
          platform = assets.keys.find { |key| argv.last.include?(key) }
          requests << platform
          bytes = failure == :checksum ? "wrong bytes" : archives.fetch(platform)
          File.binwrite(argv.fetch(argv.index("--output") + 1), bytes)
          [ "", "private transport detail", Hive::Gh::CommandStatus.new(exitstatus: failure == :download ? 1 : 0) ]
        elsif argv.first == "tar" && failure == :extraction
          [ "", "private extraction detail", Hive::Gh::CommandStatus.new(exitstatus: 1) ]
        else
          original_capture.call(*argv, **options)
        end
      end
      with_env("HIVE_BETTERLEAKS_CACHE_DIR" => nil, "GITHUB_TOKEN" => nil, "GH_TOKEN" => nil) do
        with_replaced_singleton_method(Open3, :capture3, capture) { yield root, cache, requests }
      end
    ensure
      if original_assets
        Hive::Betterleaks.send(:remove_const, :ASSETS)
        Hive::Betterleaks.const_set(:ASSETS, original_assets)
      end
    end
  end
end
