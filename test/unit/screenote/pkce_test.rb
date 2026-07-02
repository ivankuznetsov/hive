require "test_helper"
require "hive/screenote/pkce"

class ScreenotePKCETest < Minitest::Test
  def test_challenge_matches_rfc_7636_vector
    verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"

    assert_equal "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
                 Hive::Screenote::PKCE.challenge(verifier)
  end

  def test_verifier_is_urlsafe_and_within_pkce_length
    verifier = Hive::Screenote::PKCE.verifier

    assert_operator verifier.length, :>=, 43
    assert_operator verifier.length, :<=, 128
    assert_match(/\A[A-Za-z0-9_-]+\z/, verifier)
  end
end
