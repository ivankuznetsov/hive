require "test_helper"
require "hive/llm_wiki_bootstrap"

class LlmWikiBootstrapTest < Minitest::Test
  include HiveTestHelper

  def test_git_common_dir_reports_git_resolution_failure
    status = Object.new
    status.define_singleton_method(:success?) { false }

    error = with_replaced_singleton_method(
      Open3, :capture3, ->(*_argv) { [ "", "not a Git repository", status ] }
    ) do
      assert_raises(ArgumentError) do
        Hive::LlmWikiBootstrap.git_common_dir("/tmp/not-a-repository")
      end
    end

    assert_match(/cannot resolve Git common directory/, error.message)
    assert_match(/not a Git repository/, error.message)
  end
end
