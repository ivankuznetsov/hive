require "test_helper"

class HiveBrainstormSuggestionsPromptContractTest < Minitest::Test
  def test_first_pass_prompt_declares_suggestion_envelopes_inert
    prompt = File.read(File.expand_path("../../../templates/brainstorm_prompt.md.erb", __dir__))

    assert_includes prompt, "hive-suggestion:v1"
    assert_includes prompt, "never a filled answer"
    assert_includes prompt, "must not cause `## Requirements`"
    assert_includes prompt, "must not cause `<!-- COMPLETE -->`"
  end
end
