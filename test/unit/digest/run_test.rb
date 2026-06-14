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
    def deliver(text, dry_run:)
      deliveries << { text: text, dry_run: dry_run }
      Hive::Digest::Sender::SendResult.new(chat_id: nil, responses: [], dry_run: dry_run, text: text)
    end
  end

  def test_empty_digest_sends_nothing_shipped_message
    sender = FakeSender.new([])
    result = Hive::Digest.run(
      date: Date.new(2026, 6, 13),
      dry_run: false,
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
      collector: FakeCollector.new({ "alpha" => [ item ] }),
      categorizer: FakeCategorizer.new(categorized, nil),
      sender: sender
    )

    assert_equal :sent, result.status
    assert_equal true, sender.deliveries.first.fetch(:dry_run)
    assert_includes sender.deliveries.first.fetch(:text), "[Task](https://example.test/pulls/10)"
  end

  def test_model_error_sends_failed_notice
    sender = FakeSender.new([])
    result = Hive::Digest.run(
      date: Date.new(2026, 6, 13),
      dry_run: false,
      collector: FakeCollector.new({ "alpha" => [ shipped_item ] }),
      categorizer: FakeCategorizer.new(nil, Hive::Digest::ModelError.new("model down")),
      sender: sender
    )

    assert_equal :failed_notice, result.status
    assert_includes sender.deliveries.first.fetch(:text), "2026\\-06\\-13 failed"
  end

  def test_default_date_is_yesterday_local
    result = Hive::Digest.run(
      dry_run: true,
      clock: -> { Time.local(2026, 6, 14, 0, 10, 0) },
      collector: FakeCollector.new({}),
      sender: FakeSender.new([])
    )

    assert_equal Date.new(2026, 6, 13), result.date
  end

  private

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
