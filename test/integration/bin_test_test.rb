require "test_helper"
require "open3"

class BinTestTest < Minitest::Test
  include HiveTestHelper

  ROOT = File.expand_path("../..", __dir__)

  def test_runs_every_supplied_test_file_and_forwards_minitest_options
    assert_runs_both("BUNDLE_GEMFILE" => File.join(ROOT, "Gemfile"))
  end

  def test_plain_ruby_fallback_drops_parent_bundle_activation
    Dir.mktmpdir("bin-test-plain") do |dir|
      first = File.join(dir, "first.rb")
      second = File.join(dir, "second.rb")
      poison = File.join(dir, "poison.rb")
      File.write(first, 'puts "loaded plain first"')
      File.write(second, 'puts "loaded plain second"')
      File.write(poison, 'abort "plain fallback inherited RUBYOPT"')

      output, status = Open3.capture2e(
        { "PATH" => "/usr/bin:/bin", "RUBYOPT" => "-r#{poison}" },
        File.join(ROOT, "bin", "test"), first, second,
        chdir: ROOT,
      )

      assert status.success?, output
      assert_includes output, "bundle unavailable or incomplete"
      assert_includes output, "loaded plain first"
      assert_includes output, "loaded plain second"
    end
  end

  def test_authoritative_mode_refuses_an_unlocked_fallback
    output, status = Open3.capture2e(
      { "HIVE_TEST_REQUIRE_BUNDLE" => "1", "PATH" => "/usr/bin:/bin" },
      File.join(ROOT, "bin", "test"),
      "test/test_helper.rb",
      chdir: ROOT,
    )

    refute status.success?, output
    assert_includes output, "locked bundle is required"
  end

  private

  def assert_runs_both(environment)
    Dir.mktmpdir("bin-test-multiple") do |dir|
      first = File.join(dir, "first_test.rb")
      second = File.join(dir, "second_test.rb")
      File.write(first, <<~RUBY)
        require "minitest/autorun"
        class BinTestFirst < Minitest::Test
          def test_first = assert true
        end
      RUBY
      File.write(second, <<~RUBY)
        class BinTestSecond < Minitest::Test
          def test_second = assert true
        end
      RUBY

      output, status = Open3.capture2e(
        environment,
        File.join(ROOT, "bin", "test"), first, second, "--seed", "123", "--verbose",
        chdir: ROOT,
      )

      assert status.success?, output
      yield output if block_given?
      assert_includes output, "BinTestFirst#test_first"
      assert_includes output, "BinTestSecond#test_second"
      assert_match(/2 runs?, 2 assertions?/, output)
    end
  end
end
