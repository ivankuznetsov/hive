require "test_helper"
require "hive/betterleaks"
require "hive/gh"
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

  def test_package_bundles_verified_binaries_and_license_for_every_platform
    package_fixture do |root|
      HiveBetterleaksPackage.build(root: root)
      Hive::Betterleaks::ASSETS.each_key do |platform|
        binary = File.join(root, platform, "betterleaks")
        assert File.executable?(binary)
        assert_equal "license", File.read(File.join(root, platform, "LICENSE"))
      end
    end
  end

  def test_package_refuses_download_checksum_and_extraction_failures
    %i[download checksum extraction].each do |failure|
      package_fixture(failure: failure) do |root|
        assert_raises(RuntimeError) { HiveBetterleaksPackage.build(root: root) }
        assert_empty Dir.glob(File.join(root, "*", "betterleaks"))
      end
    end
  end

  private

  def package_fixture(failure: nil)
    Dir.mktmpdir do |root|
      platform = nil
      assert_contains = method(:assert_includes)
      capture = lambda do |*argv|
        status = Hive::Gh::CommandStatus.new(exitstatus: 0)
        if argv.first == "curl"
          platform = Hive::Betterleaks::ASSETS.keys.find { |key| argv.last.include?(key) }
          assert_contains.call(argv, "=https")
          status = Hive::Gh::CommandStatus.new(exitstatus: 1) if failure == :download
        else
          destination = argv.fetch(argv.index("-C") + 1)
          File.write(File.join(destination, "betterleaks"), "binary")
          File.write(File.join(destination, "LICENSE"), "license")
          status = Hive::Gh::CommandStatus.new(exitstatus: 1) if failure == :extraction
        end
        [ "", "", status ]
      end
      checksum = lambda do |*|
        Struct.new(:hexdigest).new(failure == :checksum ? "wrong" : Hive::Betterleaks::ASSETS.fetch(platform))
      end
      with_replaced_singleton_method(Open3, :capture3, capture) do
        with_replaced_singleton_method(Digest::SHA256, :file, checksum) { yield root }
      end
    end
  end
end
