require "test_helper"
require "hive/web/session_secret"

# SessionSecret.load_or_create resolves the cookie-signing secret from an
# existing long-enough on-disk secret file, or a freshly generated one
# persisted with 0600 perms. The generate-and-persist branch is the one a
# fresh install hits on first boot.
class WebSessionSecretTest < Minitest::Test
  include HiveTestHelper

  def test_generates_and_persists_a_secret_when_none_exists
    with_tmp_dir do |dir|
      path = File.join(dir, "nested", "secret")
      secret = Hive::Web::SessionSecret.load_or_create(path)

      assert_operator secret.bytesize, :>=, 32, "a generated secret must be long enough to sign cookies"
      assert File.file?(path), "the generated secret must be persisted for the next boot"
      assert_equal secret, File.read(path), "the persisted file must hold the returned secret"
      assert_equal 0o600, File.stat(path).mode & 0o777, "the secret file must be owner-only"
    end
  end

  def test_reuses_a_persisted_secret_on_a_later_boot
    with_tmp_dir do |dir|
      path = File.join(dir, "secret")
      File.write(path, "p" * 48)
      assert_equal "p" * 48, Hive::Web::SessionSecret.load_or_create(path),
                   "an existing long-enough secret file must be reused, not regenerated"
    end
  end

  def test_replaces_a_persisted_secret_that_is_too_short
    with_tmp_dir do |dir|
      path = File.join(dir, "secret")
      File.write(path, "short")
      secret = Hive::Web::SessionSecret.load_or_create(path)

      assert_operator secret.bytesize, :>=, 32
      assert_equal secret, File.read(path)
    end
  end
end
