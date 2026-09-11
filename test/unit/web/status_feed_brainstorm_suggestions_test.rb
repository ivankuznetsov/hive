require "test_helper"
require "hive/web/status_feed"

class StatusFeedBrainstormSuggestionsTest < Minitest::Test
  include HiveTestHelper

  def test_suggestion_sidecar_read_error_has_a_bounded_identity
    with_tmp_dir do |root|
      path = File.join(root, Hive::BrainstormSuggestions::STORE_FILENAME)
      File.write(path, "{}", mode: "w", perm: 0o600)
      feed = Hive::Web::StatusFeed.new
      original_open = File.method(:open)

      replacement = lambda do |candidate, *args, **kwargs, &block|
        raise Errno::EIO, "read failed" if candidate == path

        original_open.call(candidate, *args, **kwargs, &block)
      end
      with_replaced_singleton_method(File, :open, replacement) do
        assert_equal "unavailable", feed.send(:suggestion_sidecar_digest, root)
      end
    ensure
      feed&.stop
    end
  end

  def test_brainstorm_sidecar_changes_wake_consumers_without_entering_status_payload
    with_tmp_dir do |root|
      sidecar = File.join(root, Hive::BrainstormSuggestions::STORE_FILENAME)
      File.write(sidecar, "first")
      File.chmod(0o600, sidecar)
      payload = {
        "projects" => [ {
          "name" => "demo",
          "tasks" => [ { "slug" => "task", "stage" => "2-brainstorm", "folder" => root } ]
        } ]
      }
      feed = Hive::Web::StatusFeed.new
      token = feed.prime(payload)

      File.write(sidecar, "second")
      File.chmod(0o600, sidecar)
      feed.send(:publish, payload)

      refute feed.current_version?(token)
      refute payload.dig("projects", 0, "tasks", 0).key?("brainstorm_suggestion"),
             "owner-private advisory state must not enter the fleet payload"
    ensure
      feed&.stop
    end
  end
end
