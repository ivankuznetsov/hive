require "test_helper"
require "hive/web/session_secret"

# SessionSecret.load_or_create resolves the cookie-signing secret from, in
# order: a long-enough HIVEBOX_SESSION_SECRET env var, an existing on-disk
# secret file, or a freshly generated one persisted with 0600 perms. The
# generate-and-persist branch is the one a fresh box hits on first boot.
class WebSessionSecretTest < Minitest::Test
  include HiveTestHelper

  def test_env_secret_wins_when_long_enough
    with_tmp_dir do |dir|
      path = File.join(dir, "secret")
      with_env("HIVEBOX_SESSION_SECRET" => "e" * 40) do
        assert_equal "e" * 40, Hive::Web::SessionSecret.load_or_create(path)
        refute File.exist?(path), "a usable env secret must not write a file"
      end
    end
  end

  def test_generates_and_persists_a_secret_when_none_exists
    with_tmp_dir do |dir|
      path = File.join(dir, "nested", "secret")
      with_env("HIVEBOX_SESSION_SECRET" => "") do
        secret = Hive::Web::SessionSecret.load_or_create(path)

        assert_operator secret.bytesize, :>=, 32, "a generated secret must be long enough to sign cookies"
        assert File.file?(path), "the generated secret must be persisted for the next boot"
        assert_equal secret, File.read(path), "the persisted file must hold the returned secret"
        assert_equal 0o600, File.stat(path).mode & 0o777, "the secret file must be owner-only"
      end
    end
  end

  def test_reuses_a_persisted_secret_on_a_later_boot
    with_tmp_dir do |dir|
      path = File.join(dir, "secret")
      File.write(path, "p" * 48)
      with_env("HIVEBOX_SESSION_SECRET" => "") do
        assert_equal "p" * 48, Hive::Web::SessionSecret.load_or_create(path),
                     "an existing long-enough secret file must be reused, not regenerated"
      end
    end
  end
end
