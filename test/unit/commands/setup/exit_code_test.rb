require "test_helper"
require "hive/commands/setup"
require "hive/setup/diagnostics"

# The setup exit-code contract (plan U6 / AE5): exit 0 only when diagnostics
# have no hard failure AND every provisioning phase reported ok.
class SetupExitCodeTest < Minitest::Test
  include HiveTestHelper

  def diag(*rows)
    Hive::Setup::Diagnostics::Aggregate.new(results: rows)
  end

  def ok_row
    Hive::Setup::Diagnostics::Result.new(name: "ruby", status: "ok", detail: "x",
                                         fix_command: nil, bootstrappable: false)
  end

  def hard_failure_row
    Hive::Setup::Diagnostics::Result.new(name: "git", status: "missing", detail: "x",
                                         fix_command: "install", bootstrappable: false)
  end

  def setup_with_phases(*phases)
    setup = Hive::Commands::Setup.new(json: true, output: StringIO.new)
    phases.each { |name, ok| setup.send(:add_phase, name, ok) }
    setup
  end

  def test_successful_when_no_hard_failures_and_all_phases_ok
    setup = setup_with_phases([ "web_bundle", true ], [ "daemon_service", true ])
    assert setup.send(:successful?, diag(ok_row))
  end

  def test_unsuccessful_when_a_phase_failed_even_with_clean_diagnostics
    setup = setup_with_phases([ "web_bundle", false ], [ "daemon_service", true ])
    refute setup.send(:successful?, diag(ok_row)),
           "a failed provisioning phase must fail the exit-code contract"
  end

  def test_unsuccessful_when_diagnostics_have_a_hard_failure
    setup = setup_with_phases([ "web_bundle", true ])
    refute setup.send(:successful?, diag(ok_row, hard_failure_row))
  end

  def test_bootstrappable_diagnostics_row_does_not_fail_setup
    bootstrappable = Hive::Setup::Diagnostics::Result.new(
      name: "qmd", status: "missing", detail: "x", fix_command: nil, bootstrappable: true
    )
    setup = setup_with_phases([ "web_bundle", true ])
    assert setup.send(:successful?, diag(ok_row, bootstrappable))
  end
end
