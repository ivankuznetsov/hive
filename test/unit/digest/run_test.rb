require "test_helper"
require "hive/digest"

class HiveDigestRunTest < Minitest::Test
  FakeCollector = Struct.new(:grouped) do
    def for_date(_date) = grouped
  end

  FakeCategorizer = Struct.new(:categorized, :error, :summary) do
    def categorize(_grouped, date:)
      raise error if error

      Hive::Digest::Output.new(
        by_project: categorized, summary: summary || "Overall summary."
      )
    end
  end

  FakeStats = Struct.new(:totals) do
    def for_items(_items) = totals
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

    totals = Hive::Digest::Totals.new(prs: 1, commits: 3, additions: 10, deletions: 2, measured_prs: 1)
    result = Hive::Digest.run(
      date: Date.new(2026, 6, 13),
      dry_run: true,
      cfg: {},
      collector: FakeCollector.new({ "alpha" => [ item ] }),
      categorizer: FakeCategorizer.new(categorized, nil, "Shipped the digest."),
      sender: sender,
      stats: FakeStats.new(totals)
    )

    assert_equal :sent, result.status
    assert_equal true, sender.deliveries.first.fetch(:dry_run)
    # Assert the categorized summary, the overall summary, and the footer
    # totals reached the message — not the renderer's exact markdown (which
    # renderer_test owns).
    delivered = sender.deliveries.first.fetch(:text)
    assert_includes delivered, "Adds digest"
    assert_includes delivered, "Task"
    assert_includes delivered, "Shipped the digest"
    assert_includes delivered, "PRs 1"
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
