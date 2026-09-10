require "test_helper"
require "open3"
require "tmpdir"

class ExamplesSystemdUserTemplatesTest < Minitest::Test
  TEMPLATE_DIR = File.expand_path("../../examples/systemd", __dir__)
  FORBIDDEN_TARGETS = %w[network.target network-online.target].freeze
  DEPENDENCY_DIRECTIVES = %w[After Wants Requires BindsTo PartOf].freeze
  INSTALL_DIRECTIVES = %w[WantedBy RequiredBy].freeze

  def test_every_shipped_user_template_has_the_user_manager_contract
    templates.each do |path|
      directives = parse_directives(File.binread(path))
      forbidden = directives.filter_map do |section, key, values|
        next unless DEPENDENCY_DIRECTIVES.include?(key) ||
                    (section == "Install" && INSTALL_DIRECTIVES.include?(key))

        targets = values.split(/\s+/) & FORBIDDEN_TARGETS
        "#{section}.#{key}=#{targets.join(' ')}" unless targets.empty?
      end

      assert_empty forbidden, "#{relative(path)} has system-manager-only dependencies: #{forbidden.join(', ')}"
      wanted_by = directives.filter_map do |section, key, value|
        value if section == "Install" && key == "WantedBy"
      end.flat_map { |value| value.split(/\s+/) }
      assert_equal [ "default.target" ], wanted_by,
                   "#{relative(path)} must install only under the user manager default.target"
    end
  end

  def test_every_shipped_template_keeps_a_single_hive_execstart_placeholder
    templates.each do |path|
      exec_starts = parse_directives(File.binread(path)).filter_map do |section, key, value|
        value if section == "Service" && key == "ExecStart"
      end

      assert_equal 1, exec_starts.length, "#{relative(path)} must have one Service.ExecStart"
      assert_match(/\A%h\/\.local\/bin\/hive(?:\s|\z)/, exec_starts.fetch(0),
                   "#{relative(path)} must retain the installer-rendered Hive placeholder")
    end
  end

  def test_directive_parser_rejects_future_forbidden_dependencies_but_ignores_comments
    directives = parse_directives(<<~UNIT)
      # network-online.target is safe in an explanatory comment.
      [Unit]
      Wants=default.target network-online.target
      [Install]
      WantedBy=default.target
    UNIT

    offending = directives.find do |_section, key, value|
      DEPENDENCY_DIRECTIVES.include?(key) &&
        !(value.split(/\s+/) & FORBIDDEN_TARGETS).empty?
    end
    refute_nil offending
  end

  def test_rendered_templates_pass_systemd_user_verification_when_gate_is_required
    skip "real user-manager verification belongs to the declared Linux gate" unless systemd_gate_required?

    preflight_systemd_user_gate!
    Dir.mktmpdir("hive-systemd-user-verify-") do |dir|
      templates.each do |source|
        rendered = File.binread(source).sub(/^ExecStart=.*$/, "ExecStart=/usr/bin/true")
        target = File.join(dir, File.basename(source))
        File.binwrite(target, rendered)
        _stdout, stderr, status = Open3.capture3("systemd-analyze", "--user", "verify", target)
        assert status.success?, "#{relative(source)} failed user verification: #{stderr.strip}"
      end
    end
  end

  private

  def templates
    paths = Dir[File.join(TEMPLATE_DIR, "*.service")].sort
    refute_empty paths, "expected shipped examples/systemd/*.service templates"
    paths
  end

  def parse_directives(bytes)
    section = nil
    bytes.each_line.filter_map do |line|
      stripped = line.strip
      next if stripped.empty? || stripped.start_with?("#", ";")
      if (match = stripped.match(/\A\[(.+)\]\z/))
        section = match[1]
        next
      end
      next unless (match = stripped.match(/\A([^=]+)=(.*)\z/))

      [ section, match[1].strip, match[2].strip ]
    end
  end

  def systemd_gate_required?
    ENV["HIVE_REQUIRE_SYSTEMD_USER_GATE"] == "1"
  end

  def preflight_systemd_user_gate!
    assert RbConfig::CONFIG["host_os"].match?(/linux/i), "systemd user verification requires Linux"
    assert ENV["XDG_RUNTIME_DIR"] && File.directory?(ENV.fetch("XDG_RUNTIME_DIR", "")),
           "XDG_RUNTIME_DIR must name a provisioned user runtime directory"
    assert system("systemctl", "--user", "show-environment", out: File::NULL, err: File::NULL),
           "a functional systemd user manager is required"
    assert system("systemd-analyze", "--version", out: File::NULL, err: File::NULL),
           "systemd-analyze is required"
  end

  def relative(path)
    path.delete_prefix(File.expand_path("../..", __dir__) + File::SEPARATOR)
  end
end
