require "test_helper"
require "hive/findings"

class FindingsTest < Minitest::Test
  include HiveTestHelper

  REVIEW_BODY = <<~MD
    # ce-review pass 02

    ## High
    - [ ] memory leak in worker pool: process_pool doesn't drain on shutdown
    - [x] missing rate limit on /api/upload: 100req/s burst seen in load test

    ## Medium
    - [ ] redundant validation in form_helper.rb: server-side already validates
    - [ ] N+1 query on dashboard: profile run shows 250 SELECTs

    ## Nit
    - [ ] typo in error message
  MD

  def with_review_file
    Dir.mktmpdir("hive-findings-unit") do |dir|
      path = File.join(dir, "ce-review-02.md")
      File.write(path, REVIEW_BODY)
      yield path
    end
  end

  def test_parses_findings_in_document_order_with_severity_and_state
    with_review_file do |path|
      doc = Hive::Findings::Document.new(path)
      assert_equal 5, doc.findings.size

      assert_equal [ 1, "high", false, "memory leak in worker pool" ],
                   doc.findings[0].to_h.values_at("id", "severity", "accepted", "title")
      assert_equal "process_pool doesn't drain on shutdown",
                   doc.findings[0].justification

      assert_equal [ 2, "high", true, "missing rate limit on /api/upload" ],
                   doc.findings[1].to_h.values_at("id", "severity", "accepted", "title")

      assert_equal "medium", doc.findings[2].severity
      assert_equal "medium", doc.findings[3].severity
      assert_equal "nit", doc.findings[4].severity
    end
  end

  def test_finding_with_no_justification_keeps_title_intact
    with_review_file do |path|
      doc = Hive::Findings::Document.new(path)
      nit = doc.findings.last
      assert_equal "typo in error message", nit.title
      assert_nil nit.justification
    end
  end

  def test_summary_counts_accepted_and_by_severity
    with_review_file do |path|
      summary = Hive::Findings::Document.new(path).summary
      assert_equal 5, summary["total"]
      assert_equal 1, summary["accepted"]
      assert_equal({ "high" => 2, "medium" => 2, "nit" => 1 }, summary["by_severity"])
    end
  end

  def test_toggle_flips_a_specific_finding_and_round_trips_through_write
    with_review_file do |path|
      doc = Hive::Findings::Document.new(path)
      doc.toggle!(1, accepted: true)
      doc.toggle!(2, accepted: false)
      doc.write!

      reloaded = Hive::Findings::Document.new(path)
      assert reloaded.findings[0].accepted, "id 1 must now be accepted"
      refute reloaded.findings[1].accepted, "id 2 must now be rejected"
      # Other findings untouched.
      refute reloaded.findings[2].accepted
      refute reloaded.findings[3].accepted
      refute reloaded.findings[4].accepted
    end
  end

  def test_toggle_preserves_surrounding_lines_byte_for_byte
    with_review_file do |path|
      original = File.read(path)
      doc = Hive::Findings::Document.new(path)
      doc.toggle!(1, accepted: true)
      doc.write!
      after = File.read(path)

      # Only the checkbox character on line 4 should differ.
      assert_equal original.lines.length, after.lines.length
      original.lines.each_with_index do |orig_line, i|
        next if i == doc.findings[0].line_index

        assert_equal orig_line, after.lines[i],
                     "non-target line #{i} must be byte-identical"
      end
    end
  end

  def test_toggle_idempotent_does_not_change_disk
    with_review_file do |path|
      original = File.read(path)
      doc = Hive::Findings::Document.new(path)
      result = doc.toggle!(2, accepted: true) # already true
      doc.write!

      assert_nil result, "idempotent toggle returns nil"
      assert_equal original, File.read(path)
    end
  end

  def test_unknown_id_raises_typed_error
    with_review_file do |path|
      doc = Hive::Findings::Document.new(path)
      err = assert_raises(Hive::UnknownFinding) { doc.toggle!(99, accepted: true) }
      assert_equal 99, err.id
      assert_equal Hive::ExitCodes::USAGE, err.exit_code
    end
  end

  def test_no_review_file_raises_typed_error
    Dir.mktmpdir do |dir|
      path = File.join(dir, "missing.md")
      err = assert_raises(Hive::NoReviewFile) { Hive::Findings::Document.new(path) }
      assert_equal Hive::ExitCodes::USAGE, err.exit_code
    end
  end

  def test_review_path_for_picks_latest_when_pass_unspecified
    Dir.mktmpdir do |dir|
      reviews = File.join(dir, "reviews")
      FileUtils.mkdir_p(reviews)
      File.write(File.join(reviews, "ce-review-01.md"), "")
      File.write(File.join(reviews, "ce-review-02.md"), "")
      File.write(File.join(reviews, "ce-review-10.md"), "") # numeric sort keeps lex order

      task = Struct.new(:reviews_dir).new(reviews)
      assert_equal File.join(reviews, "ce-review-10.md"),
                   Hive::Findings.review_path_for(task)
      assert_equal File.join(reviews, "ce-review-02.md"),
                   Hive::Findings.review_path_for(task, pass: 2)
    end
  end

  def test_review_path_for_raises_when_pass_missing
    Dir.mktmpdir do |dir|
      reviews = File.join(dir, "reviews")
      FileUtils.mkdir_p(reviews)
      File.write(File.join(reviews, "ce-review-01.md"), "")
      task = Struct.new(:reviews_dir).new(reviews)
      assert_raises(Hive::NoReviewFile) { Hive::Findings.review_path_for(task, pass: 5) }
    end
  end

  # CRLF input: every non-target line must round-trip identically; the
  # toggled line must keep its CRLF instead of being flattened to LF.
  def test_toggle_preserves_crlf_line_endings
    Dir.mktmpdir do |dir|
      path = File.join(dir, "ce-review-03.md")
      crlf_body = "## High\r\n- [ ] one: x\r\n- [ ] two: y\r\n"
      File.binwrite(path, crlf_body)

      doc = Hive::Findings::Document.new(path)
      doc.toggle!(1, accepted: true)
      doc.write!

      bytes = File.binread(path)
      assert_equal "## High\r\n- [x] one: x\r\n- [ ] two: y\r\n", bytes,
                   "CRLF must round-trip; only the checkbox character should change"
    end
  end

  # No-trailing-newline input: toggling the LAST line must not introduce
  # an extra newline that would change file size.
  def test_toggle_preserves_missing_trailing_newline
    Dir.mktmpdir do |dir|
      path = File.join(dir, "ce-review-04.md")
      body = "## High\n- [ ] alone: no eol"
      File.binwrite(path, body)

      doc = Hive::Findings::Document.new(path)
      doc.toggle!(1, accepted: true)
      doc.write!

      assert_equal "## High\n- [x] alone: no eol", File.binread(path),
                   "missing trailing newline must be preserved"
    end
  end

  # A non-canonical heading (anything other than high/medium/low/nit)
  # must clear the current severity instead of leaking the prior section's
  # value into the findings that follow. Multi-word headings like
  # `## Detailed Analysis` failed both checks before this fix:
  # SEVERITY_HEADING_RE didn't match (so prior severity carried over) and
  # `## Notes` matched but wasn't a real severity.
  def test_non_severity_heading_resets_current_severity
    Dir.mktmpdir do |dir|
      path = File.join(dir, "ce-review-05.md")
      File.write(path, <<~MD)
        ## High
        - [ ] real high finding: should stay tagged high

        ## Detailed Analysis
        - [ ] post-analysis finding: must NOT inherit 'high'

        ## Notes
        - [ ] notes finding: also not a severity
      MD

      doc = Hive::Findings::Document.new(path)
      assert_equal "high", doc.findings[0].severity
      assert_nil doc.findings[1].severity,
                 "## Detailed Analysis must clear severity (multi-word heading)"
      assert_nil doc.findings[2].severity,
                 "## Notes is not a canonical severity; must clear current_severity"
    end
  end

  # Pass extraction lives on the Hive::Findings module so the two
  # commands don't carry duplicated `pass_from_path` helpers.
  def test_pass_from_path_extracts_integer
    assert_equal 1, Hive::Findings.pass_from_path("/x/reviews/ce-review-01.md")
    assert_equal 12, Hive::Findings.pass_from_path("ce-review-12.md")
    assert_nil Hive::Findings.pass_from_path("not-a-review.md")
  end

  # Headings and finding-shaped lines inside a fenced code block are
  # content (e.g. an example in justification), not structure. Skipping
  # them in the parser closes a latent bug where a future reviewer
  # template that emits fenced examples would silently produce phantom
  # findings or carry-over the wrong severity.
  def test_fenced_code_block_lines_are_ignored_by_parser
    Dir.mktmpdir do |dir|
      path = File.join(dir, "ce-review-06.md")
      File.write(path, <<~MD)
        ## High
        - [ ] real high finding: production code

        Example reviewer output that mentions a checkbox in fenced code:

        ```
        ## High
        - [ ] this is example text inside a fence, not a finding
        - [x] also example, definitely not accepted
        ```

        ## Medium
        - [ ] real medium finding: keep me
      MD

      doc = Hive::Findings::Document.new(path)
      assert_equal 2, doc.findings.size,
                   "fenced-block lines must not register as findings"
      assert_equal "high", doc.findings[0].severity
      assert_equal "real high finding", doc.findings[0].title
      assert_equal "medium", doc.findings[1].severity,
                   "fenced ## High must not leak severity into the next real heading"
      assert_equal "real medium finding", doc.findings[1].title
    end
  end

  def test_tilde_fenced_code_block_also_ignored
    Dir.mktmpdir do |dir|
      path = File.join(dir, "ce-review-07.md")
      File.write(path, <<~MD)
        ## High
        - [ ] real: yes

        ~~~
        - [ ] tilde-fenced example
        ~~~

        - [ ] another real one: post-fence
      MD

      doc = Hive::Findings::Document.new(path)
      assert_equal 2, doc.findings.size
    end
  end
end
