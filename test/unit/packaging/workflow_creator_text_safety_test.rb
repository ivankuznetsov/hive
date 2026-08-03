# frozen_string_literal: true

require "test_helper"
require "bundler"
require "open3"
require "rbconfig"
require_relative "../../../packaging/live_agent_skills/workflow_creator_text_safety"

class WorkflowCreatorTextSafetyTest < Minitest::Test
  ROOT = File.expand_path("../../..", __dir__)
  VALUES_REQUIRE = "packaging/live_agent_skills/workflow_creator_values"
  TEXT_SAFETY_REQUIRE = "packaging/live_agent_skills/workflow_creator_text_safety"
  TEXT_SAFETY_PATH = File.join(ROOT, "packaging", "live_agent_skills", "workflow_creator_text_safety.rb")
  Values = HiveLiveAgentProof::WorkflowCreator::Values
  TextSafety = HiveLiveAgentProof::WorkflowCreator::TextSafety
  MAX_BYTES = 4_096
  POISONED_CHILD_ENV = %w[HIVE_COVERAGE HIVE_COVERAGE_ROOT HIVE_COVERAGE_RUN_ID RUBYOPT]
    .to_h { |name| [ name, nil ] }.freeze

  def test_text_projects_owned_values_to_frozen_utf8_and_clamps_byte_limits
    assert_equal "hello", TextSafety.text(owned("hello"))
    assert_equal "", TextSafety.text(owned("éx"), limit: owned(-1))
    assert_equal "", TextSafety.text(owned("éx"), limit: owned(1))
    assert_equal "é", TextSafety.text(owned("éx"), limit: owned(2))
    assert_equal "éx", TextSafety.text(owned("éx"), limit: owned(MAX_BYTES + 1))

    boundary = TextSafety.text(owned("x" * MAX_BYTES))
    assert_equal MAX_BYTES, boundary.bytesize
    assert_predicate boundary, :frozen?
    assert_equal Encoding::UTF_8, boundary.encoding
    assert_projection_error { TextSafety.text(owned("x" * (MAX_BYTES + 1))) }
  end

  def test_safe_relative_path_accepts_only_bounded_non_ambiguous_paths
    safe = [ "workflow.yml", "dir/workflow.yml", ".github/workflows/ci.yml", "é/plan.md", "a" * MAX_BYTES ]
    unsafe = [ "", "/root", "C:/root", "c:relative", "~/plan", "-option", ".", "..", "./plan",
              "dir/../plan", "dir//plan", "dir/", "dir\\plan", "dir/\nplan" ]
    separator_heavy = owned(Array.new(512, "segment").join("/"))
    split_calls = 0
    trace = TracePoint.new(:c_call) do |event|
      split_calls += 1 if event.defined_class == String && event.method_id == :split
    end

    safe.each { |path| assert TextSafety.safe_relative_path?(owned(path)), path }
    unsafe.each { |path| refute TextSafety.safe_relative_path?(owned(path)), path }
    assert trace.enable { TextSafety.safe_relative_path?(separator_heavy) }
    assert_equal 0, split_calls
    refute TextSafety.safe_relative_path?(owned("a" * (MAX_BYTES + 1)))
  end

  def test_duplicate_exact_secrets_keep_index_findings_but_scan_each_unique_needle_once
    value = owned("token token")
    secrets = owned([ "token", "token", "missing" ])
    byteindex_calls = 0
    trace = TracePoint.new(:c_call) do |event|
      byteindex_calls += 1 if event.defined_class == String && event.method_id == :byteindex
    end

    findings = trace.enable { TextSafety.secret_findings(value, exact_secrets: secrets) }

    assert_equal [ "exact-secret:0", "exact-secret:1" ], findings
    assert_equal 4, byteindex_calls
    assert_predicate findings, :frozen?
    findings.each { |finding| assert_predicate finding, :frozen? }
  end

  def test_overlapping_multibyte_exact_secrets_use_byte_offsets_without_splitting_codepoints
    value = owned("ééé")
    secrets = owned([ "éé" ])

    assert_equal [ "exact-secret:0" ], TextSafety.secret_findings(value, exact_secrets: secrets)
    assert_equal "[REDACTED]", TextSafety.redact(value, exact_secrets: secrets)
  end

  def test_pattern_findings_follow_exact_indexes_in_fixed_pattern_order
    anthropic = "sk-ant-abcdefghijkl"
    openai = "sk-proj-#{'o' * 20}"
    github_token = "ghp_#{'g' * 20}"
    github_pat = "github_pat_#{'p' * 20}"
    private_key = "-----BEGIN PRIVATE KEY-----\ntruncated"
    value = owned([ "needle", anthropic, openai, github_token, github_pat, private_key ].join(" "))

    findings = TextSafety.secret_findings(value, exact_secrets: owned([ "needle" ]))

    assert_equal %w[
      exact-secret:0
      pattern:anthropic
      pattern:openai
      pattern:github-token
      pattern:github-pat
      pattern:private-key
    ], findings
  end

  def test_overlapping_github_tokens_redact_the_complete_union
    overlapping_tokens = owned("ghp_#{'A' * 17}ghp_#{'B' * 20}")

    assert_equal [ "pattern:github-token" ],
                 TextSafety.secret_findings(overlapping_tokens, exact_secrets: owned([]))
    assert_equal "[REDACTED]", TextSafety.redact(overlapping_tokens, exact_secrets: owned([]))
  end

  def test_nested_truncated_private_key_envelopes_are_scanned_once_per_begin_with_a_fixed_bound
    nested_keys = owned(
      "-----BEGIN PRIVATE KEY-----\nouter\n-----BEGIN RSA PRIVATE KEY-----\ninner"
    )
    match_calls = 0
    private_matches = 0
    trace = TracePoint.new(:c_return) do |event|
      next unless event.defined_class == Regexp && event.method_id == :match

      match_calls += 1
      private_matches += 1 if event.return_value
    end

    findings = trace.enable { TextSafety.secret_findings(nested_keys, exact_secrets: owned([])) }

    assert_equal [ "pattern:private-key" ], findings
    assert_equal 2, private_matches
    assert_equal 7, match_calls
    assert_equal "[REDACTED]", TextSafety.redact(nested_keys, exact_secrets: owned([]))
  end

  def test_complete_nested_different_label_private_keys_redact_through_the_outer_end
    nested_keys = owned([
      "before -----BEGIN PRIVATE KEY-----", "outer-before",
      "-----BEGIN RSA PRIVATE KEY-----", "inner-secret", "-----END RSA PRIVATE KEY-----",
      "outer-secret-after", "-----END PRIVATE KEY----- after"
    ].join("\n"))

    assert_equal "before [REDACTED] after", TextSafety.redact(nested_keys, exact_secrets: owned([]))
  end

  def test_complete_nested_same_label_private_keys_redact_through_the_outer_end
    nested_keys = owned([
      "before -----BEGIN PRIVATE KEY-----", "outer-before",
      "-----BEGIN PRIVATE KEY-----", "inner-secret", "-----END PRIVATE KEY-----",
      "outer-secret-after", "-----END PRIVATE KEY----- after"
    ].join("\n"))

    assert_equal "before [REDACTED] after", TextSafety.redact(nested_keys, exact_secrets: owned([]))
  end

  def test_mismatched_private_key_labels_redact_conservatively_through_the_last_end
    mismatched_keys = owned([
      "before -----BEGIN RSA PRIVATE KEY-----", "outer-before",
      "-----BEGIN EC PRIVATE KEY-----", "inner-secret", "-----END DSA PRIVATE KEY-----",
      "outer-secret-after", "-----END OPENSSH PRIVATE KEY----- after"
    ].join("\n"))

    assert_equal "before [REDACTED] after", TextSafety.redact(mismatched_keys, exact_secrets: owned([]))
  end

  def test_exact_secret_count_and_byte_boundaries_accept_their_declared_maxima
    maximum_list = owned(Array.new(64) { |index| "absent-#{index}" })
    maximum_secret = "s" * MAX_BYTES

    assert_empty TextSafety.secret_findings(owned("nothing matches"), exact_secrets: maximum_list)
    assert_equal [ "exact-secret:0" ],
                 TextSafety.secret_findings(owned(maximum_secret), exact_secrets: owned([ maximum_secret ]))
    assert_equal "[REDACTED]",
                 TextSafety.redact(owned(maximum_secret), exact_secrets: owned([ maximum_secret ]))
  end

  def test_redaction_merges_overlapping_exact_and_pattern_ranges_and_preserves_utf8
    overlapped = TextSafety.redact(
      owned("é secret-token-tail ok"),
      exact_secrets: owned([ "secret-token", "token-tail" ])
    )
    token = "ghp_#{'a' * 20}"
    pattern_overlap = TextSafety.redact(owned(token), exact_secrets: owned([ "a" * 10 ]))
    repeated_overlap = TextSafety.redact(owned("ababa"), exact_secrets: owned([ "aba" ]))

    assert_equal "é [REDACTED] ok", overlapped
    assert_equal "[REDACTED]", pattern_overlap
    assert_equal "[REDACTED]", repeated_overlap
    assert_predicate overlapped, :frozen?
    assert_equal Encoding::UTF_8, overlapped.encoding
    assert_equal "[REDA", TextSafety.redact(owned("secret"), exact_secrets: owned([ "secret" ]), limit: owned(5))
  end

  def test_private_key_patterns_redact_complete_and_truncated_envelopes
    complete = owned(
      "before -----BEGIN RSA PRIVATE KEY-----\nbody\n-----END RSA PRIVATE KEY----- after"
    )
    truncated = owned("before -----BEGIN OPENSSH PRIVATE KEY-----\nbody")

    assert_equal "before [REDACTED] after", TextSafety.redact(complete, exact_secrets: owned([]))
    assert_equal "before [REDACTED]", TextSafety.redact(truncated, exact_secrets: owned([]))
  end

  def test_no_match_redaction_is_frozen_utf8_and_output_is_bounded
    unchanged = TextSafety.redact(owned("é safe"), exact_secrets: owned([]))
    expanded = TextSafety.redact(owned("x " * 2_048), exact_secrets: owned([ "x" ]), limit: owned(MAX_BYTES))
    split_input = owned("x#{'a' * 4_085}é")
    split_output = TextSafety.redact(split_input, exact_secrets: owned([ "x" ]), limit: owned(MAX_BYTES))

    assert_equal "é safe", unchanged
    assert_predicate unchanged, :frozen?
    assert_equal Encoding::UTF_8, unchanged.encoding
    assert_operator expanded.bytesize, :<=, MAX_BYTES
    assert_predicate expanded, :valid_encoding?
    assert_equal "[REDACTED]#{'a' * 4_085}", split_output
    assert_equal MAX_BYTES - 1, split_output.bytesize
    assert_predicate split_output, :frozen?
    assert_predicate split_output, :valid_encoding?
  end

  def test_projection_rejects_invalid_shapes_and_limits_with_fixed_secret_free_errors
    invalid_utf8 = "secret-\xFF".dup.force_encoding(Encoding::UTF_8).freeze
    utf16 = "secret".encode(Encoding::UTF_16LE).freeze
    binary = "secret".b.freeze
    string_subclass = Class.new(String).new("secret").freeze
    array_subclass = Class.new(Array).new.freeze
    cases = [
      -> { TextSafety.text(+"mutable-secret") },
      -> { TextSafety.text(string_subclass) },
      -> { TextSafety.text(invalid_utf8) },
      -> { TextSafety.text(utf16) },
      -> { TextSafety.text(binary) },
      -> { TextSafety.text(owned("safe"), limit: owned("4")) },
      -> { TextSafety.safe_relative_path?(+"mutable-secret") },
      -> { TextSafety.safe_relative_path?(invalid_utf8) },
      -> { TextSafety.secret_findings(+"mutable-secret", exact_secrets: owned([])) },
      -> { TextSafety.secret_findings(invalid_utf8, exact_secrets: owned([])) },
      -> { TextSafety.secret_findings(owned("safe"), exact_secrets: []) },
      -> { TextSafety.secret_findings(owned("safe"), exact_secrets: array_subclass) },
      -> { TextSafety.secret_findings(owned("safe"), exact_secrets: owned([ 1 ])) },
      -> { TextSafety.secret_findings(owned("safe"), exact_secrets: owned([ "" ])) },
      -> { TextSafety.secret_findings(owned("safe"), exact_secrets: owned([ "x" * (MAX_BYTES + 1) ])) },
      -> { TextSafety.secret_findings(owned("safe"), exact_secrets: owned(Array.new(65, "x"))) },
      -> { TextSafety.secret_findings(owned("x" * (MAX_BYTES + 1)), exact_secrets: owned([])) },
      -> { TextSafety.redact(+"mutable-secret", exact_secrets: owned([])) },
      -> { TextSafety.redact(invalid_utf8, exact_secrets: owned([])) },
      -> { TextSafety.redact(owned("safe"), exact_secrets: []) },
      -> { TextSafety.redact(owned("safe"), exact_secrets: owned([]), limit: owned("4")) }
    ]

    errors = cases.map { |projection| assert_projection_error(&projection) }
    errors.each do |error|
      refute_includes error.full_message, "mutable-secret"
      refute_includes error.full_message, "secret-"
    end
    refute_same errors.fetch(0), errors.fetch(1)
  end

  def test_substantially_oversized_values_fail_before_projection_work
    large = owned("x" * 100_000)

    assert_projection_error { TextSafety.text(large) }
    assert_projection_error { TextSafety.secret_findings(large, exact_secrets: owned([])) }
    assert_projection_error { TextSafety.redact(large, exact_secrets: owned([])) }
    refute TextSafety.safe_relative_path?(large)
  end

  def test_public_surface_is_frozen_and_captured_handles_are_private
    assert TextSafety.frozen?
    assert TextSafety::Error.frozen?
    assert_equal [ :Error ], TextSafety.constants(false)
    assert_equal %i[redact safe_relative_path? secret_findings text], TextSafety.singleton_methods(false).sort
    refute_respond_to TextSafety, :scan
    assert TextSafety.const_defined?(:STRING_BYTESIZE, false)
    assert TextSafety.const_defined?(:STRING_BINARY, false)
    assert TextSafety.const_defined?(:PATTERNS, false)
    assert_raises(NameError) { TextSafety::STRING_BYTESIZE }
    assert_raises(NameError) { TextSafety::STRING_BINARY }
    assert_raises(NameError) { TextSafety::PATTERNS }
  end

  def test_text_safety_entrypoint_loads_both_public_modules_without_gems_or_json
    script = <<~'RUBY'
      require ARGV.fetch(0)
      abort("JSON loaded") if defined?(JSON)
      values = HiveLiveAgentProof::WorkflowCreator::Values
      safety = HiveLiveAgentProof::WorkflowCreator::TextSafety
      input = values.capture("hello").value
      abort("wrong projection") unless safety.text(input) == "hello"
      STDOUT.write("ok")
    RUBY

    out, err, status = clean_child(script, TEXT_SAFETY_REQUIRE)

    assert status.success?, "stdout=#{out.inspect} stderr=#{err.inspect}"
    assert_equal "ok", out
  end

  def test_values_first_then_text_safety_load_order_keeps_both_modules_available
    script = <<~'RUBY'
      require ARGV.fetch(0)
      abort("early TextSafety") if defined?(HiveLiveAgentProof::WorkflowCreator::TextSafety)
      require ARGV.fetch(1)
      values = HiveLiveAgentProof::WorkflowCreator::Values
      safety = HiveLiveAgentProof::WorkflowCreator::TextSafety
      path = values.capture("dir/workflow.yml").value
      abort("wrong path result") unless safety.safe_relative_path?(path)
      STDOUT.write("ok")
    RUBY

    out, err, status = clean_child(script, VALUES_REQUIRE, TEXT_SAFETY_REQUIRE)

    assert status.success?, "stdout=#{out.inspect} stderr=#{err.inspect}"
    assert_equal "ok", out
  end

  def test_post_load_core_replacement_cannot_redirect_projection_or_fixed_failures
    script = <<~'RUBY'
      require ARGV.fetch(0)
      values = HiveLiveAgentProof::WorkflowCreator::Values
      safety = HiveLiveAgentProof::WorkflowCreator::TextSafety
      value = values.capture("prefix secret suffix").value
      secrets = values.capture([ "secret" ]).value
      path = values.capture("dir/workflow.yml").value
      string_equal = String.instance_method(:==)
      object_class = Object.instance_method(:class)
      object_equal = BasicObject.instance_method(:equal?)
      module_case = Module.instance_method(:===)
      class_case = Class.instance_method(:===)

      Object.class_eval do
        define_method(:class) { Process.exit!(71) }
        define_method(:clone) { |*| Process.exit!(72) }
        define_method(:freeze) { Process.exit!(73) }
        define_method(:frozen?) { Process.exit!(74) }
      end
      BasicObject.class_eval { define_method(:equal?) { |*| Process.exit!(70) } }
      Kernel.module_eval { define_method(:raise) { |*| Process.exit!(75) } }
      Module.class_eval { define_method(:===) { |*| Process.exit!(76) } }
      Class.class_eval { define_method(:===) { |*| Process.exit!(77) } }
      Array.class_eval do
        define_method(:each) { |*| Process.exit!(78) }
        define_method(:[]) { |*| Process.exit!(79) }
        define_method(:index) { |*| Process.exit!(80) }
        define_method(:length) { Process.exit!(81) }
        define_method(:*) { |*| Process.exit!(82) }
        define_method(:<<) { |*| Process.exit!(83) }
        define_method(:[]=) { |*| Process.exit!(84) }
      end
      String.class_eval do
        define_method(:<<) { |*| Process.exit!(85) }
        define_method(:b) { Process.exit!(85) }
        define_method(:byteindex) { |*| Process.exit!(86) }
        define_method(:bytesize) { Process.exit!(87) }
        define_method(:byteslice) { |*| Process.exit!(88) }
        define_method(:encoding) { Process.exit!(89) }
        define_method(:==) { |*| Process.exit!(90) }
        define_method(:scrub) { |*| Process.exit!(91) }
        define_method(:valid_encoding?) { Process.exit!(92) }
      end
      Regexp.class_eval { define_method(:match) { |*| Process.exit!(93) } }
      MatchData.class_eval do
        define_method(:begin) { |*| Process.exit!(94) }
        define_method(:bytebegin) { |*| Process.exit!(94) }
        define_method(:byteend) { |*| Process.exit!(95) }
      end
      Integer.class_eval do
        define_method(:+) { |*| Process.exit!(97) }
        define_method(:>) { |*| Process.exit!(98) }
        define_method(:times) { |*| Process.exit!(99) }
      end
      Exception.class_eval do
        define_method(:backtrace) { Process.exit!(100) }
        define_method(:cause) { Process.exit!(100) }
        define_method(:exception) { |*| Process.exit!(101) }
        define_method(:initialize_clone) { |*| Process.exit!(102) }
        define_method(:initialize_copy) { |*| Process.exit!(102) }
        define_method(:message) { Process.exit!(103) }
        define_method(:set_backtrace) { |*| Process.exit!(103) }
        define_method(:to_s) { Process.exit!(103) }
      end

      redacted = safety.redact(value, exact_secrets: secrets)
      Process.exit!(104) unless string_equal.bind_call(redacted, "prefix [REDACTED] suffix")
      Process.exit!(105) unless safety.safe_relative_path?(path)
      error = nil
      begin
        begin
          safety.text("unowned")
        ensure
          Module.class_eval { define_method(:===, module_case) }
          Class.class_eval { define_method(:===, class_case) }
        end
      rescue safety::Error => caught
        error = caught
      end
      Process.exit!(106) unless error
      Process.exit!(107) unless object_equal.bind_call(object_class.bind_call(error), safety::Error)
      Process.exit!(108) unless string_equal.bind_call(error.message, "workflow-creator text cannot be projected")
      Process.exit!(109) unless error.cause.nil?
      error.backtrace
      error.set_backtrace(error.backtrace)
      Process.exit!(110) unless string_equal.bind_call(error.to_s, "workflow-creator text cannot be projected")
      STDOUT.write("ok")
    RUBY

    out, err, status = clean_child(script, TEXT_SAFETY_REQUIRE)

    assert status.success?, "status=#{status.exitstatus} stdout=#{out.inspect} stderr=#{err.inspect}"
    assert_equal "ok", out
  end

  def test_source_has_one_way_values_load_and_no_private_handle_borrowing_or_callable_compression
    source = File.read(TEXT_SAFETY_PATH)

    assert_equal 1, source.lines.count { |line| line == "require_relative \"workflow_creator_values\"\n" }
    refute_match(/Values::|Values\.const_get/, source)
    refute_match(/\b(?:lambda|proc)\b|\bProc\.new\b/, source)
    refute_match(/\.(?:split)\b/, source)
    refute_match(/\b(?:LOWER_MASK|UPPER_MASK|TRANSITIONS)\b/, source)
    refute_match(/\b(?:Importer|Data|JSON)\b/, source)
    assert_includes source, "internal Values ownership contract, not origin authentication"
  end

  private

  def owned(value)
    Values.capture(value).value
  end

  def assert_projection_error
    error = assert_raises(TextSafety::Error) { yield }
    assert_equal "workflow-creator text cannot be projected", error.message
    assert_nil error.cause
    error
  end

  def clean_child(script, *arguments)
    Bundler.with_unbundled_env do
      Open3.capture3(
        POISONED_CHILD_ENV,
        RbConfig.ruby,
        "--disable-gems",
        "-I#{ROOT}",
        "-e",
        script,
        *arguments
      )
    end
  end
end
