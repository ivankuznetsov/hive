require "test_helper"
require "hive/digest"

class HiveDigestRunTest < Minitest::Test
  FakeCollector = Struct.new(:grouped) do
    def for_date(_date) = grouped
  end

  FakeCategorizer = Struct.new(:categorized, :error) do
    def categorize(_grouped, date:)
      raise error if error

      categorized
    end
  end

  FakeSender = Struct.new(:deliveries) do
    def preflight! = nil

    def deliver(text, dry_run:)
      deliveries << { text: text, dry_run: dry_run }
      # Honor SendResult's invariant: a real send carries a resolved chat_id,
      # only a dry-run leaves it nil.
      Hive::Digest::Sender::SendResult.new(
        chat_id: dry_run ? nil : 1, responses: [], dry_run: dry_run, text: text
      )
    end
  end

  # Records the order of preflight!/deliver so a test can assert EnvFile.load!
  # ran before them (the timing the fix depends on).
  OrderingSender = Struct.new(:order) do
    def preflight! = order << :preflight

    def deliver(text, dry_run:)
      order << :deliver
      Hive::Digest::Sender::SendResult.new(
        chat_id: dry_run ? nil : 1, responses: [], dry_run: dry_run, text: text
      )
    end
  end

  def test_empty_digest_sends_nothing_shipped_message
    sender = FakeSender.new([])
    result = Hive::Digest.run(
      date: Date.new(2026, 6, 13),
      dry_run: false,
      cfg: {},
      collector: FakeCollector.new({}),
      sender: sender
    )

    assert_equal :empty, result.status
    assert_equal "Nothing shipped today 🌙", sender.deliveries.first.fetch(:text)
  end

  def test_successful_digest_categorizes_renders_and_sends
    item = shipped_item
    categorized = { "alpha" => [ Hive::Digest::CategorizedItem.new(item: item, category: "feature", summary: "Adds digest.") ] }
    sender = FakeSender.new([])

    result = Hive::Digest.run(
      date: Date.new(2026, 6, 13),
      dry_run: true,
      cfg: {},
      collector: FakeCollector.new({ "alpha" => [ item ] }),
      categorizer: FakeCategorizer.new(categorized, nil),
      sender: sender
    )

    assert_equal :sent, result.status
    assert_equal true, sender.deliveries.first.fetch(:dry_run)
    # Assert the categorized summary and display label reached the message,
    # not the renderer's exact link markdown (which renderer_test owns).
    delivered = sender.deliveries.first.fetch(:text)
    assert_includes delivered, "Adds digest"
    assert_includes delivered, "Task"
  end

  def test_model_error_sends_failed_notice
    sender = FakeSender.new([])
    result = Hive::Digest.run(
      date: Date.new(2026, 6, 13),
      dry_run: false,
      cfg: {},
      collector: FakeCollector.new({ "alpha" => [ shipped_item ] }),
      categorizer: FakeCategorizer.new(nil, Hive::Digest::ModelError.new("model down")),
      sender: sender
    )

    assert_equal :failed_notice, result.status
    assert_includes sender.deliveries.first.fetch(:text), "2026\\-06\\-13 failed"
  end

  def test_result_guard_rejects_an_unknown_status
    assert_raises(ArgumentError) do
      Hive::Digest::Result.new(
        status: :bogus, date: Date.new(2026, 6, 13), message: "x", delivery: nil
      )
    end
  end

  def test_real_run_loads_env_file_so_daemon_dispatched_send_can_authenticate
    # The daemon dispatches `hive digest` with no HIVE_TELEGRAM_BOT_TOKEN in
    # its environment, so a real run must load ~/.config/hive/.env itself
    # (mirroring `hive bot start`) or preflight/deliver fail with exit 78.
    loaded = count_env_file_loads do
      Hive::Digest.run(
        date: Date.new(2026, 6, 13),
        dry_run: false,
        cfg: {},
        collector: FakeCollector.new({}),
        sender: FakeSender.new([])
      )
    end

    assert_equal 1, loaded, "a real digest run must load the env file before sending"
  end

  def test_dry_run_does_not_load_env_file
    # A dry-run never sends, so it must not touch the env file — matching the
    # dry-run "no token/chat lookup" contract.
    loaded = count_env_file_loads do
      Hive::Digest.run(
        date: Date.new(2026, 6, 13),
        dry_run: true,
        cfg: {},
        collector: FakeCollector.new({}),
        sender: FakeSender.new([])
      )
    end

    assert_equal 0, loaded, "a dry-run must not load the env file"
  end

  def test_env_file_loads_before_preflight_so_the_token_is_present
    # The bug this PR fixes is timing: the token must be in ENV BEFORE
    # Sender#preflight! reads it. A test that only counts that load! ran would
    # still pass if a refactor moved the load after preflight, silently
    # reintroducing the exit-78 failure. Pin the order.
    order = []
    sender = OrderingSender.new(order)
    original = Hive::EnvFile.method(:load!)
    Hive::EnvFile.define_singleton_method(:load!) do |*|
      order << :load
      []
    end

    Hive::Digest.run(
      date: Date.new(2026, 6, 13),
      dry_run: false,
      cfg: {},
      collector: FakeCollector.new({ "alpha" => [ shipped_item ] }),
      categorizer: FakeCategorizer.new(
        { "alpha" => [ Hive::Digest::CategorizedItem.new(item: shipped_item, category: "feature", summary: "x") ] },
        nil
      ),
      sender: sender
    )

    assert_equal :load, order.first,
                 "env must load before preflight/send so the token is present when preflight reads it"
    assert_operator order.index(:load), :<, order.index(:preflight),
                    "EnvFile.load! must run before Sender#preflight!"
  ensure
    Hive::EnvFile.define_singleton_method(:load!, original)
  end

  def test_default_date_is_yesterday_local
    result = Hive::Digest.run(
      dry_run: true,
      cfg: {},
      clock: -> { Time.local(2026, 6, 14, 0, 10, 0) },
      collector: FakeCollector.new({}),
      sender: FakeSender.new([])
    )

    assert_equal Date.new(2026, 6, 13), result.date
  end

  private

  # Singleton override instead of minitest/mock (not bundled): count how many
  # times Hive::EnvFile.load! is invoked inside the block, then restore the
  # original module method so other tests see the real loader.
  def count_env_file_loads
    loaded = 0
    original = Hive::EnvFile.method(:load!)
    Hive::EnvFile.define_singleton_method(:load!) do |*|
      loaded += 1
      []
    end
    yield
    loaded
  ensure
    Hive::EnvFile.define_singleton_method(:load!, original)
  end

  def shipped_item
    Hive::Digest::ShippedItem.new(
      project_name: "alpha",
      slug: "slug",
      display_name: "Task",
      pr_url: "https://example.test/pulls/10",
      pr_number: 10,
      pr_title: "Task",
      pr_body: "body",
      shipped_at: Time.utc(2026, 6, 13, 12)
    )
  end
end
