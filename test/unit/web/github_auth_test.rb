require "test_helper"
require "hive/web/github_auth"

class GithubAuthTest < Minitest::Test
  def test_authorize_url_contains_callback_and_state
    auth = Hive::Web::GithubAuth.new(
      config: {
        "origin" => "https://box.example",
        "github" => { "client_id" => "abc", "owner" => "octo" }
      }
    )

    url = auth.authorize_url(state: "state123")

    assert_match(%r{\Ahttps://github\.com/login/oauth/authorize\?}, url)
    assert_match(/client_id=abc/, url)
    assert_match(/state=state123/, url)
    assert_match(/redirect_uri=https%3A%2F%2Fbox\.example%2Fauth%2Fgithub%2Fcallback/, url)
  end

  def test_owner_match_is_case_insensitive
    auth = Hive::Web::GithubAuth.new(
      config: { "origin" => "http://localhost", "github" => { "owner" => "Alice", "client_id" => "id" } }
    )

    assert auth.owner?("alice")
    refute auth.owner?("bob")
  end
end
