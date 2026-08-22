require "test_helper"
require "open3"

class BinTestTest < Minitest::Test
  include HiveTestHelper

  ROOT = File.expand_path("../..", __dir__)

  def test_runs_every_supplied_test_file_and_forwards_minitest_options
    assert_runs_both("BUNDLE_GEMFILE" => File.join(ROOT, "Gemfile"))
  end

  def test_plain_ruby_fallback_keeps_the_same_multiple_file_contract
    assert_runs_both("PATH" => "/usr/bin:/bin") do |output|
      assert_includes output, "bundle unavailable or incomplete"
    end
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
