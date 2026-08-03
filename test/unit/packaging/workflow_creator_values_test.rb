require "test_helper"
require "json"
require "open3"
require "rbconfig"
require "ripper"
require_relative "../../../packaging/live_agent_skills/workflow_creator_values"
require_relative "../../../packaging/live_agent_skills/workflow_creator_text_safety"

class WorkflowCreatorValuesTest < Minitest::Test
  ROOT = File.expand_path("../../..", __dir__)
  Values = HiveLiveAgentProof::WorkflowCreator::Values
  TextSafety = HiveLiveAgentProof::WorkflowCreator::TextSafety
  DECISION_NODES = %i[
    if unless elsif if_mod unless_mod ifop when in rescue rescue_mod
    while until for while_mod until_mod
  ].freeze

  def test_capture_returns_a_fresh_frozen_snapshot_and_canonical_bytes
    input = { "z" => [ true, nil ], "a" => { "count" => 2 } }
    captured = Values.capture(input)

    assert_equal({ "a" => { "count" => 2 }, "z" => [ true, nil ] }, captured.value)
    assert_equal "#{JSON.pretty_generate(captured.value)}\n", captured.canonical_bytes
    refute_same input, captured.value
    assert captured.frozen?
    assert_deeply_frozen captured.value
    assert captured.canonical_bytes.frozen?
  end

  def test_snapshot_construction_and_update_bypasses_are_non_public
    snapshot = Values.capture("safe")
    type = Values::Snapshot

    refute_respond_to type, :new
    refute_respond_to type, :[]
    refute_respond_to type, :allocate
    refute_respond_to snapshot, :with
    assert type.singleton_class.private_method_defined?(:new)
    assert type.singleton_class.private_method_defined?(:[])
    assert type.singleton_class.private_method_defined?(:allocate)
    assert type.private_method_defined?(:with)
    assert_raises(NoMethodError) { type.new(value: [], canonical_bytes: +"mutable") }
    assert_raises(NoMethodError) { type[value: [], canonical_bytes: +"mutable"] }
    assert_raises(NoMethodError) { type.allocate }
    assert_raises(NoMethodError) { snapshot.with(value: []) }
  end

  def test_ascii_only_canonical_bytes_are_utf8_and_can_be_captured_again
    captured = Values.capture({ "ascii" => [ "only", true ] })

    assert_equal Encoding::UTF_8, captured.canonical_bytes.encoding
    recaptured = Values.capture(captured.canonical_bytes)
    assert_equal captured.canonical_bytes, recaptured.value
    assert_equal Encoding::UTF_8, recaptured.value.encoding
    assert_equal captured.canonical_bytes, Values.capture(JSON.parse(captured.canonical_bytes)).canonical_bytes
  end

  def test_capture_covers_every_json_type_and_generator_boundary
    values = [
      {}, [], "", 0, -7, 0.0, -0.0, 1e20, 1e-6, 1e-7,
      true, false, nil,
      { "quote" => "\"", "slash" => "\\", "controls" => "\0\b\f\n\r\t\x1f", "unicode" => "é😀" }
    ]

    values.each do |value|
      captured = Values.capture(value)
      assert_equal "#{JSON.pretty_generate(captured.value)}\n", captured.canonical_bytes, value.inspect
    end
  end

  def test_canonical_bytes_match_pretty_generate_for_a_deterministic_property_corpus
    random = Random.new(0xC0FFEE)

    200.times do |index|
      captured = Values.capture(property_value(random))
      assert_equal "#{JSON.pretty_generate(captured.value)}\n", captured.canonical_bytes, "case #{index}"
    end
  end

  def test_capture_rejects_subclasses_cycles_and_non_json_scalars
    subclass_values = [
      Class.new(Hash)["key" => "value"],
      Class.new(Array)["value"],
      Class.new(String).new("value"),
      Class.new(Integer),
      Object.new,
      :symbol
    ]
    subclass_values.each { |value| assert_raises(Values::Error) { Values.capture(value) } }

    array_cycle = []
    array_cycle << array_cycle
    hash_cycle = {}
    hash_cycle["self"] = hash_cycle
    assert_raises(Values::Error) { Values.capture(array_cycle) }
    assert_raises(Values::Error) { Values.capture(hash_cycle) }
  end

  def test_exact_values_with_direct_and_module_hooks_cannot_interpose
    exploding = Module.new do
      def class = raise("class dispatched")
      def each = raise("each dispatched")
      def each_pair = raise("each_pair dispatched")
      def encode(*) = raise("encode dispatched")
      def bytesize = raise("bytesize dispatched")
      def to_json(*) = raise("to_json dispatched")
      def respond_to_missing?(*) = raise("respond_to_missing dispatched")
      def method_missing(*) = raise("method_missing dispatched")

      protected :bytesize
      private :method_missing, :respond_to_missing?
    end
    hooked_key = +"key"
    hooked_key.extend(exploding)
    hooked_value = +"value"
    hooked_value.define_singleton_method(:valid_encoding?) { raise "valid_encoding dispatched" }
    hooked_value.singleton_class.undef_method(:to_json)
    hooked_array = [ hooked_value ]
    hooked_array.extend(exploding)
    hooked_hash = { hooked_key => hooked_array }
    hooked_hash.extend(exploding)

    captured = Values.capture(hooked_hash)

    assert_equal({ "key" => [ "value" ] }, captured.value)
    assert_equal "#{JSON.pretty_generate(captured.value)}\n", captured.canonical_bytes
  end

  def test_singleton_class_include_and_prepend_hooks_cannot_interpose
    poison = Module.new do
      def each_pair = raise("each_pair dispatched")
      def each = raise("each dispatched")
      def encode(*) = raise("encode dispatched")
      def ==(*) = raise("equality dispatched")

      private :each_pair, :==
      protected :each
    end
    value = +"value"
    value.singleton_class.prepend(poison)
    list = [ value ]
    list.singleton_class.include(poison)
    input = { "key" => list }
    input.singleton_class.prepend(poison)

    captured = Values.capture(input)

    assert_equal({ "key" => [ "value" ] }, captured.value)
    assert_equal "#{JSON.pretty_generate(captured.value)}\n", captured.canonical_bytes
  end

  def test_capture_is_stable_after_caller_and_extension_module_mutation
    extension = Module.new do
      def to_json(*) = "\"forged\""
    end
    child = { "message" => +"original" }
    child.extend(extension)
    input = [ child, child ]
    captured = Values.capture(input)

    child["message"].replace("changed")
    child["new"] = true
    extension.module_eval { define_method(:each_pair) { raise "late interposition" } }

    assert_equal [ { "message" => "original" }, { "message" => "original" } ], captured.value
    refute_same captured.value.fetch(0), captured.value.fetch(1), "shared acyclic nodes are copied per occurrence"
    assert_equal "#{JSON.pretty_generate(captured.value)}\n", captured.canonical_bytes
  end

  def test_ruby_refinements_are_a_negative_control
    values_path = File.expand_path("../../../packaging/live_agent_skills/workflow_creator_values", __dir__)
    script = <<~'RUBY'
      module Poison
        refine Hash do
          def each_pair = raise("refined Hash#each_pair")
        end
        refine Array do
          def each = raise("refined Array#each")
        end
        refine String do
          def encode(*) = raise("refined String#encode")
          def to_json(*) = raise("refined String#to_json")
        end
      end
      using Poison
      require ARGV.fetch(0)
      captured = HiveLiveAgentProof::WorkflowCreator::Values.capture({ "b" => ["value"], "a" => 1 })
      STDOUT.write(captured.canonical_bytes)
    RUBY
    out, err, status = Open3.capture3(RbConfig.ruby, "-e", script, values_path)

    assert status.success?, err
    assert_equal "{\n  \"a\": 1,\n  \"b\": [\n    \"value\"\n  ]\n}\n", out
  end

  def test_load_captured_operations_resist_post_load_core_replacement
    values_path = File.expand_path("../../../packaging/live_agent_skills/workflow_creator_values", __dir__)
    script = <<~'RUBY'
      require ARGV.fetch(0)
      values = { "z" => [1e20, "value"], "a" => -7 }
      token = "sk-" + "ant-abcdefghijklmnopqrstuvwxyz"
      text = HiveLiveAgentProof::WorkflowCreator::Values.capture("value=#{token}").value
      secrets = HiveLiveAgentProof::WorkflowCreator::Values.capture([token]).value
      io_write = IO.instance_method(:write)
      Array.define_singleton_method(:new) { |*| raise "post-load Array.new" }
      Regexp.define_singleton_method(:last_match) { |*| raise "post-load Regexp.last_match" }
      poisons = {
        Hash => %i[each_pair key? []= delete],
        Array => %i[initialize each [] []= << index length sort! each_with_index],
        String => %i[initialize valid_encoding? encoding bytesize encode each_byte to_json << <=> == hash eql?
                     byteslice scrub match? include? byteindex scan b],
        Integer => %i[+ - * > === zero? bit_length to_s hash eql? times between? clamp],
        Float => %i[finite? to_json], Encoding => %i[dummy?], MatchData => %i[bytebegin byteend],
        Object => %i[class freeze], BasicObject => %i[equal? __id__], Class => %i[new allocate],
        Proc => %i[call], Method => %i[call]
      }
      poisons.to_a.reverse_each do |owner, names|
        names.reverse_each do |name|
          owner.define_method(name) { |*| raise "post-load #{owner}##{name}" }
        end
      end
      captured = HiveLiveAgentProof::WorkflowCreator::Values.capture(values)
      redacted = HiveLiveAgentProof::WorkflowCreator::TextSafety.redact(text, exact_secrets: secrets)
      String.class_eval { define_method(:initialize) { |*| raise "post-load String#initialize" } }
      initialized = HiveLiveAgentProof::WorkflowCreator::Values.capture(values)
      io_write.bind_call(STDOUT, captured.canonical_bytes)
      io_write.bind_call(STDOUT, redacted)
      io_write.bind_call(STDOUT, initialized.canonical_bytes)
    RUBY
    out, err, status = Open3.capture3(RbConfig.ruby, "-e", script, values_path)

    assert status.success?, err
    canonical = <<~JSON
      {
        "a": -7,
        "z": [
          1e+20,
          "value"
        ]
      }
    JSON
    assert_equal canonical + "value=[REDACTED]" + canonical, out
  end

  def test_encoding_normalization_collision_and_numeric_limits_fail_closed
    latin = "é".encode(Encoding::ISO_8859_1)
    normalized = Values.capture(latin)
    assert_equal "é", normalized.value
    assert_equal Encoding::UTF_8, normalized.value.encoding

    collision = { "é" => 1, latin => 2 }
    invalid_utf8 = "\xFF".dup.force_encoding(Encoding::UTF_8)
    ambiguous = "\xFE\xFF\0a".b.force_encoding(Encoding::UTF_16)
    binary = "\xFF".b
    ascii_binary = "ascii".b
    [ collision, invalid_utf8, ambiguous, binary, ascii_binary ].each do |value|
      assert_raises(Values::Error) { Values.capture(value) }
    end

    max_integer = (1 << (Values::MAX_INTEGER_BITS - 1)) - 1
    assert_equal max_integer, Values.capture(max_integer).value
    assert_raises(Values::Error) { Values.capture(1 << Values::MAX_INTEGER_BITS) }
    [ Float::NAN, Float::INFINITY, -Float::INFINITY ].each do |value|
      assert_raises(Values::Error) { Values.capture(value) }
    end
  end

  def test_graph_and_projection_resource_ceilings_are_enforced_before_serialization
    at_input_limit = "x" * Values::MAX_INPUT_BYTES
    assert_equal at_input_limit, Values.capture(at_input_limit).value
    assert_raises(Values::Error) { Values.capture("x" * (Values::MAX_INPUT_BYTES + 1)) }
    assert_raises(Values::Error) { Values.capture("\0" * Values::MAX_INPUT_BYTES) }

    too_many_nodes = Array.new(Values::MAX_NODES, nil)
    assert_raises(Values::Error) { Values.capture(too_many_nodes) }

    near_limit_hash = (0...((Values::MAX_NODES / 2) - 1)).to_h { |index| [ "key-#{index}", nil ] }
    assert_equal near_limit_hash.length, Values.capture(near_limit_hash).value.length

    impossible_hash = (0...(Values::MAX_NODES / 2)).to_h { |index| [ "key-#{index}", nil ] }
    encode_calls = 0
    trace = TracePoint.new(:c_call) do |event|
      encode_calls += 1 if event.defined_class == String && event.method_id == :encode
    end
    trace.enable { assert_raises(Values::Error) { Values.capture(impossible_hash) } }
    assert_equal 0, encode_calls, "impossible direct cardinality must fail before key encoding"

    nested = nil
    (Values::MAX_DEPTH + 1).times { nested = [ nested ] }
    assert_raises(Values::Error) { Values.capture(nested) }
  end

  def test_allocation_ceiling_is_distinct_from_input_output_node_and_depth_ceilings
    within = "x" * 50_000
    Values::MAX_DEPTH.times { within = [ within ] }
    captured = Values.capture(within)
    assert_operator captured.canonical_bytes.bytesize, :<, Values::MAX_PROJECTED_BYTES

    over = "x" * 55_000
    Values::MAX_DEPTH.times { over = [ over ] }
    assert_raises(Values::Error) { Values.capture(over) }
  end

  def test_text_safety_projects_only_captured_values
    captured = Values.capture("prefix secret-token suffix")
    secret = Values.capture([ "secret-token" ])

    assert_equal "prefix", TextSafety.text(captured.value, limit: 6)
    assert TextSafety.safe_relative_path?(Values.capture("dir/file.json").value)
    assert_equal [ "exact-secret:0" ],
                 TextSafety.secret_findings(captured.value, exact_secrets: secret.value)
    assert_equal "prefix [REDACTED] suffix",
                 TextSafety.redact(captured.value, exact_secrets: secret.value, limit: 1_000)
    unicode = Values.capture("é secret-token suffix").value
    assert_equal "é [REDACTED] suffix",
                 TextSafety.redact(unicode, exact_secrets: secret.value, limit: 1_000)
  end

  def test_text_and_path_limits_are_utf8_safe_and_separator_bounded
    assert_equal "é", TextSafety.text(Values.capture("éé").value, limit: 3)
    assert_equal "x" * 4_096, TextSafety.text(Values.capture("x" * 4_096).value, limit: 4_096)
    assert_raises(TextSafety::Error) do
      TextSafety.text(Values.capture("x" * 4_097).value, limit: 4_096)
    end
    assert_raises(TextSafety::Error) do
      TextSafety.text(Values.capture("x" * 100_000).value, limit: 4_096)
    end

    safe = [ "file", "dir/file", "dir/.hidden", "...", ([ "a" ] * 1_000).join("/") ]
    unsafe = [ "", ".", "..", "/root", "C:/root", "C:root", "~", "~/x", "-rf", "dir//file", "dir/../file",
               "./file", "dir/", "dir\\file", "nul\0file", "line\nbreak", "tab\tpath", "del\x7Fpath",
               ([ "a" ] * 2_100).join("/") ]
    assert safe.all? { |path| TextSafety.safe_relative_path?(Values.capture(path).value) }
    assert unsafe.none? { |path| TextSafety.safe_relative_path?(Values.capture(path).value) }
  end

  def test_secret_findings_and_redaction_merge_original_overlaps_at_high_frequency
    token = "sk-" + "ant-abcdefghijklmnopqrstuvwxyz"
    text = Values.capture("token=#{token} suffix").value
    secrets = Values.capture([ "sk-ant-abc", "ant-abcdefghijklmnopqrstuvwxyz" ]).value
    assert_equal %w[exact-secret:0 exact-secret:1 pattern:anthropic],
                 TextSafety.secret_findings(text, exact_secrets: secrets)
    assert_equal "token=[REDACTED] suffix", TextSafety.redact(text, exact_secrets: secrets, limit: 1_000)

    repeated = Values.capture("a" * 4_096).value
    overlaps = Values.capture(%w[aa aaa aaaa]).value
    assert_equal "[REDACTED]", TextSafety.redact(repeated, exact_secrets: overlaps, limit: 1_000)
    assert_equal %w[exact-secret:0 exact-secret:1 exact-secret:2],
                 TextSafety.secret_findings(repeated, exact_secrets: overlaps)

    multibyte = Values.capture("ééé").value
    multibyte_overlap = Values.capture([ "éé" ]).value
    assert_equal [ "exact-secret:0" ], TextSafety.secret_findings(multibyte, exact_secrets: multibyte_overlap)
    assert_equal "[REDACTED]", TextSafety.redact(multibyte, exact_secrets: multibyte_overlap)

    long_overlaps = Values.capture(Array.new(64, "a" * 2_048)).value
    assert_equal "[REDACTED]", TextSafety.redact(repeated, exact_secrets: long_overlaps)

    separated = Values.capture("a." * 2_048).value
    expanded = TextSafety.redact(separated, exact_secrets: Values.capture([ "a" ]).value)
    assert_operator expanded.bytesize, :<=, TextSafety::MAX_OUTPUT_BYTES
    assert expanded.valid_encoding?
  end

  def test_supported_token_patterns_detect_and_redact_to_utf8
    tokens = {
      "pattern:openai" => [ "sk-#{"a" * 20}", "sk-proj-#{"b" * 20}" ],
      "pattern:github-token" => %w[ghp_ ghs_ gho_ ghu_].map { |prefix| "#{prefix}#{"c" * 36}" },
      "pattern:github-pat" => [ "github_pat_#{"d" * 20}" ]
    }
    no_exact_secrets = Values.capture([]).value

    tokens.each do |label, examples|
      examples.each do |token|
        text = Values.capture("before #{token} after").value
        assert_equal [ label ], TextSafety.secret_findings(text, exact_secrets: no_exact_secrets), token
        redacted = TextSafety.redact(text, exact_secrets: no_exact_secrets)
        assert_equal "before [REDACTED] after", redacted, token
        assert_equal Encoding::UTF_8, redacted.encoding, token
      end
    end
  end

  def test_private_key_patterns_redact_complete_and_truncated_envelopes
    envelopes = [ "PRIVATE KEY", "RSA PRIVATE KEY", "EC PRIVATE KEY", "OPENSSH PRIVATE KEY",
                  "DSA PRIVATE KEY", "PGP PRIVATE KEY BLOCK" ]
    no_exact_secrets = Values.capture([]).value

    envelopes.each do |envelope|
      body = "sensitive-body-#{envelope.delete(" ")}"
      footer = "-----END #{envelope}-----"
      complete = Values.capture("before\n-----BEGIN #{envelope}-----\n#{body}\n#{footer}\nafter").value
      truncated_footer = "-----END #{envelope}"
      truncated = Values.capture("before\n-----BEGIN #{envelope}-----\n#{body}\n#{truncated_footer}").value

      [ [ complete, "before\n[REDACTED]\nafter" ], [ truncated, "before\n[REDACTED]" ] ].each do |text, expected|
        assert_equal [ "pattern:private-key" ], TextSafety.secret_findings(text, exact_secrets: no_exact_secrets), envelope
        redacted = TextSafety.redact(text, exact_secrets: no_exact_secrets)
        assert_equal expected, redacted, envelope
        refute_includes redacted, body, envelope
        refute_includes redacted, "-----END", envelope
      end
    end
  end

  def test_exact_secret_count_and_byte_ceilings_are_exact
    value = Values.capture("a" * 4_096).value
    sixty_four = Values.capture(Array.new(64, "a")).value
    findings = TextSafety.secret_findings(value, exact_secrets: sixty_four)
    assert_equal 64, findings.length
    assert_equal "exact-secret:0", findings.first
    assert_equal "exact-secret:63", findings.last

    sixty_five = Values.capture(Array.new(65, "a")).value
    assert_raises(TextSafety::Error) { TextSafety.secret_findings(value, exact_secrets: sixty_five) }
    max_secret = Values.capture([ "a" * 4_096 ]).value
    assert_equal [ "exact-secret:0" ], TextSafety.secret_findings(value, exact_secrets: max_secret)
    too_long = Values.capture([ "a" * 4_097 ]).value
    assert_raises(TextSafety::Error) { TextSafety.secret_findings(value, exact_secrets: too_long) }
  end

  def test_static_decision_counter_counts_every_budgeted_form
    fixtures = {
      conditional: "if flag\n  true\nend\n",
      modifier: "work if flag\n",
      case_arm: "case value\nwhen 1\n  true\nend\n",
      ternary: "flag ? true : false\n",
      rescue_clause: "begin\n  work\nrescue Error\n  false\nend\n",
      loop: "while flag\n  work\nend\n",
      boolean_and: "left && right\n",
      boolean_or: "left || right\n"
    }

    fixtures.each do |name, source|
      assert_equal 1, static_metrics(source).fetch(:decisions), name
    end
  end

  def test_production_files_stay_inside_u1a1v_hard_caps
    caps = {
      "workflow_creator_values.rb" => { lines: 190, methods: 8, decisions: 22 },
      "workflow_creator_text_safety.rb" => { lines: 90, methods: 4, decisions: 10 }
    }
    observed = caps.to_h do |name, limits|
      source = File.read(File.join(ROOT, "packaging", "live_agent_skills", name))
      metrics = static_metrics(source).merge(lines: source.lines.length)
      limits.each { |metric, limit| assert_operator metrics.fetch(metric), :<=, limit, "#{name} #{metric}" }
      [ name, metrics ]
    end
    totals = observed.values.each_with_object(Hash.new(0)) do |metrics, sum|
      metrics.each { |metric, value| sum[metric] += value }
    end
    { lines: 280, methods: 12, decisions: 32 }.each do |metric, limit|
      assert_operator totals.fetch(metric), :<=, limit, "aggregate #{metric}"
    end
  end

  private

  def assert_deeply_frozen(value)
    assert value.frozen?
    value.each { |key, nested| assert_deeply_frozen(key); assert_deeply_frozen(nested) } if value.instance_of?(Hash)
    value.each { |nested| assert_deeply_frozen(nested) } if value.instance_of?(Array)
  end

  def property_value(random, depth = 0)
    strings = [ "", "plain", "quote=\" slash=\\ control=\0\n", "é😀" ]
    floats = [ 0.0, -0.0, 1e20, 1e-6, 1e-7, 3.141592653589793 ]
    scalars = [ nil, true, false, random.rand(-1_000_000..1_000_000),
                floats.fetch(random.rand(floats.length)), strings.fetch(random.rand(strings.length)) ]
    return scalars.fetch(random.rand(scalars.length)) if depth >= 3 || random.rand(3).zero?

    return Array.new(random.rand(5)) { property_value(random, depth + 1) } if random.rand(2).zero?

    Array.new(random.rand(5)) do |index|
      [ "k#{depth}-#{index}-#{random.rand(1_000_000)}", property_value(random, depth + 1) ]
    end.to_h
  end

  def static_metrics(source)
    syntax = Ripper.sexp(source) or raise "invalid Ruby fixture"
    counts = { methods: 0, decisions: 0 }
    walk = lambda do |node|
      next unless node.instance_of?(Array)
      type = node.first
      counts[:methods] += 1 if %i[def defs].include?(type)
      counts[:decisions] += 1 if DECISION_NODES.include?(type)
      counts[:decisions] += 1 if type == :binary && %i[&& ||].include?(node[2])
      node.each { |child| walk.call(child) }
    end
    walk.call(syntax)
    counts
  end
end
