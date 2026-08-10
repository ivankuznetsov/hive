require "test_helper"
require "json"
require "yaml"
require "hive/agent_skills/canonical_skill"
require "hive/commands/answer"
require "hive/daemon/dispatcher"

class BrainstormAnsweringSkillContractTest < Minitest::Test
  include HiveTestHelper

  FIXTURE_ROOT = File.expand_path("../fixtures/brainstorm_skill", __dir__)
  SCENARIO_REFERENCE = "references/brainstorm-answering-scenarios.md"
  UNKNOWN_PROJECT_ERRORS = %w[
    missing_project_path not_initialised project_load_failed
  ].freeze
  BETA_SLUG = "beta-brainstorm-260810-bbbb"
  ALPHA_SLUG = "alpha-brainstorm-260810-aaaa"

  def test_transcripts_are_explicit_sanitized_and_identical_in_all_projections
    scenarios = transcript_scenarios
    assert_equal ("S01".."S12").to_a, scenarios.map { |scenario| scenario.fetch("id") }
    scenarios.each do |scenario|
      assert_equal %w[
        expected_message final_slot_state id input mutation_count observed_binding
      ], scenario.keys.sort
      assert_kind_of Integer, scenario.fetch("mutation_count")
      assert_operator scenario.fetch("mutation_count"), :>=, 0
    end

    july = scenarios.find { |scenario| scenario.fetch("id") == "S12" }
    serialized = JSON.generate(july)
    refute_match(/chat[_ -]?id|message[_ -]?id|username|@[a-z0-9_]+|telegram/i, serialized)

    skill = Hive::AgentSkills::CanonicalSkill.new
    assert_equal "0.1.4", skill.version
    assert_includes skill.reference_paths, SCENARIO_REFERENCE
    canonical = skill.rendered_canonical_files.fetch(SCENARIO_REFERENCE)
    scenarios.each { |scenario| assert_includes canonical, scenario.fetch("id") }

    projected = %w[openclaw claude codex pi].map do |platform|
      skill.render(platform).files.fetch(SCENARIO_REFERENCE)
    end
    assert_equal [ canonical ], projected.uniq
  end

  def test_status_only_inventory_is_read_only_preserves_order_and_uses_slot_truth
    with_fleet do |fleet|
      original = waiting_set(status_fixture("status-original.json"))
      reordered = waiting_set(status_fixture("status-reordered.json"))

      assert_equal [
        [ "beta", BETA_SLUG ], [ "alpha", ALPHA_SLUG ]
      ], original.fetch(:rows).map { |row| [ row.fetch("project"), row.fetch("slug") ] }
      assert_equal [
        [ "alpha", ALPHA_SLUG ], [ "beta", BETA_SLUG ]
      ], reordered.fetch(:rows).map { |row| [ row.fetch("project"), row.fetch("slug") ] }
      assert_equal [
        [ "broken-load", "project_load_failed" ],
        [ "missing", "missing_project_path" ],
        [ "plain", "not_initialised" ]
      ], original.fetch(:unknown)

      before = fleet_state(fleet)
      inventories = original.fetch(:rows).map do |row|
        inventory(project: row.fetch("project"), slug: row.fetch("slug"))
      end

      assert_equal [ 0, 9 ], original.fetch(:rows).map { |row| row.fetch("unanswered_questions") }
      assert_equal [ 4, 1 ], inventories.map { |payload| payload.fetch("unanswered_count") }
      preview = inventories.first.fetch("slots").find { |slot| !slot.fetch("answered") }
      assert_equal [ 1, 5 ], [ preview.fetch("ordinal"), inventories.first.fetch("slot_count") ]
      assert_equal before, fleet_state(fleet)
      fleet.each_value do |project|
        project.fetch(:tasks).each_value do |task|
          refute File.exist?(File.join(task.fetch(:folder), ".lock"))
        end
      end
    end
  end

  def test_guided_approve_replacement_pause_resume_idempotency_and_stale_reply
    with_fleet do |fleet|
      alpha = fleet.fetch("alpha")
      original_first = waiting_set(status_fixture("status-original.json"))
                       .fetch(:rows).first
      assert_equal [ "beta", BETA_SLUG ],
                   [ original_first.fetch("project"), original_first.fetch("slug") ]
      approve_path = fleet.dig("beta", :tasks, BETA_SLUG, :path)
      presented = first_unanswered(inventory(project: "beta", slug: BETA_SLUG))

      # A later status reorder does not replace the already presented binding.
      assert_equal "alpha", waiting_set(status_fixture("status-reordered.json"))
                           .fetch(:rows).first.fetch("project")
      approved = write_answer(
        project: "beta", slug: BETA_SLUG,
        binding: presented.fetch("binding"), answer: "Developers lead the launch."
      )
      assert_equal "written", approved.fetch("outcome")
      assert_equal "Developers lead the launch.", parsed_answers(approve_path).first

      repeated = write_answer(
        project: "beta", slug: BETA_SLUG,
        binding: presented.fetch("binding"), answer: "Developers lead the launch.\n"
      )
      assert_equal "idempotent", repeated.fetch("outcome")
      assert_equal false, repeated.fetch("written")

      replacement = create_task(
        alpha.fetch(:root), slug: "guided-replacement-260810-dddd", id: 103,
        fixture: "guided-single.md"
      )
      replacement_slot = first_unanswered(inventory(
        project: "alpha", slug: "guided-replacement-260810-dddd"
      ))
      literal = "Use $(touch never) and `echo never`.\nKeep both lines."
      replaced = write_answer(
        project: "alpha", slug: "guided-replacement-260810-dddd",
        binding: replacement_slot.fetch("binding"), answer: literal
      )
      assert_equal "written", replaced.fetch("outcome")
      assert_equal literal, parsed_answers(replacement.fetch(:path)).first

      paused = create_task(
        alpha.fetch(:root), slug: "guided-paused-260810-eeee", id: 104,
        fixture: "guided-single.md"
      )
      before_pause = File.binread(paused.fetch(:path))
      %w[skip later].each do |input|
        scenario = transcript_scenarios.find do |candidate|
          candidate.fetch("id") == "S05"
        end
        assert_equal 0, scenario.fetch("mutation_count"), input
        assert_equal before_pause, File.binread(paused.fetch(:path)), input
      end
      resumed_slot = first_unanswered(inventory(
        project: "alpha", slug: "guided-paused-260810-eeee"
      ))
      resumed = write_answer(
        project: "alpha", slug: "guided-paused-260810-eeee",
        binding: resumed_slot.fetch("binding"), answer: "Resume with a fresh binding."
      )
      assert_equal "written", resumed.fetch("outcome")

      stale = create_task(
        alpha.fetch(:root), slug: "guided-stale-260810-ffff", id: 105,
        fixture: "guided-single.md"
      )
      stale_slot = first_unanswered(inventory(
        project: "alpha", slug: "guided-stale-260810-ffff"
      ))
      File.write(
        stale.fetch(:path),
        File.read(stale.fetch(:path)).sub("Which mode", "Which changed mode")
      )
      before_stale_write = File.binread(stale.fetch(:path))
      rejected = write_answer(
        project: "alpha", slug: "guided-stale-260810-ffff",
        binding: stale_slot.fetch("binding"), answer: "Stale recommendation"
      )
      assert_equal "stale", rejected.fetch("outcome")
      assert_equal "question_changed", rejected.fetch("reason")
      assert_equal before_stale_write, File.binread(stale.fetch(:path))
    end
  end

  def test_yolo_zero_write_and_mixed_scan_continue_past_ambiguity_in_original_order
    with_fleet do |fleet|
      snapshot = status_fixture("status-original.json")
      before = fleet_state(fleet)
      zero = yolo_scan(snapshot, answers: {})

      assert_equal({ scanned: 5, written: 0, escalated: 5 }, zero.slice(
        :scanned, :written, :escalated
      ))
      assert_equal before, fleet_state(fleet)

      status_refreshes = 0
      answers = {
        "Should this answer flow publish a release?" =>
          "No. Publication remains out of scope.",
        "Which native surfaces remain literal?" =>
          "Native answer and web forms remain literal.",
        "Which mode should answer one approved slot per turn?" =>
          "Guided is the default."
      }
      mixed = yolo_scan(
        snapshot,
        answers: answers,
        status_refresh: lambda do
          status_refreshes += 1
          status_fixture("status-reordered.json")
        end
      )

      assert_equal({ scanned: 5, written: 3, escalated: 2 }, mixed.slice(
        :scanned, :written, :escalated
      ))
      assert_equal 3, status_refreshes
      assert_equal [
        [ "beta", BETA_SLUG, 3 ],
        [ "beta", BETA_SLUG, 4 ],
        [ "alpha", ALPHA_SLUG, 1 ]
      ], mixed.fetch(:write_order)

      beta_answers = parsed_answers(fleet.dig("beta", :tasks, BETA_SLUG, :path))
      assert_nil beta_answers.fetch(0)
      assert_equal "Use the supported bound answer command.", beta_answers.fetch(1)
      assert_equal "No. Publication remains out of scope.", beta_answers.fetch(2)
      assert_equal "Native answer and web forms remain literal.", beta_answers.fetch(3)
      assert_nil beta_answers.fetch(4)

      before_pause = fleet_state(fleet)
      escalation_queue = mixed.fetch(:escalations).dup
      presented = [ escalation_queue.shift ]
      assert_equal 1, presented.size
      assert_equal 1, escalation_queue.size
      assert_equal before_pause, fleet_state(fleet), "later must not write"

      continued = [ escalation_queue.shift ]
      assert_equal 1, continued.size
      assert_empty escalation_queue
      refute_equal presented.first.dig("slot", "fingerprint"),
                   continued.first.dig("slot", "fingerprint")
      # `continue` presents the next ambiguity; it is not answer text.
      assert_equal before_pause, fleet_state(fleet), "continue must not write"
    end
  end

  def test_literal_boundary_closes_fixture_repairs_relocation_and_identity_changes
    with_fleet do |fleet|
      alpha = fleet.fetch("alpha")

      missing = create_task(
        alpha.fetch(:root), slug: "missing-header-260810-gggg", id: 106,
        fixture: "missing-answer-header.md"
      )
      missing_slot = first_unanswered(inventory(project: "alpha", slug: missing.fetch(:slug)))
      repaired = write_answer(
        project: "alpha", slug: missing.fetch(:slug),
        binding: missing_slot.fetch("binding"), answer: "Repair only this slot."
      )
      assert_equal "written", repaired.fetch("outcome")
      assert_match(/Q1.*\n+### A1\.\nRepair only this slot\.\n### Q2/m,
                   File.read(missing.fetch(:path)))
      assert_nil parsed_answers(missing.fetch(:path)).fetch(1)

      renumbered = create_task(
        alpha.fetch(:root), slug: "renumbered-260810-hhhh", id: 107,
        fixture: "renumber-source.md"
      )
      renumber_binding = first_unanswered(inventory(
        project: "alpha", slug: renumbered.fetch(:slug)
      )).fetch("binding")
      content = File.read(renumbered.fetch(:path)).sub("Q1.", "Q9.").sub("A1.", "A9.")
      File.write(renumbered.fetch(:path), content)
      relocated = write_answer(
        project: "alpha", slug: renumbered.fetch(:slug),
        binding: renumber_binding, answer: "Unique relocation."
      )
      assert_equal "written", relocated.fetch("outcome")
      assert_equal true, relocated.fetch("relocated")
      assert_equal 9, relocated.dig("slot", "question_number")

      duplicate = create_task(
        alpha.fetch(:root), slug: "duplicate-260810-iiii", id: 108,
        fixture: "renumber-source.md"
      )
      duplicate_binding = first_unanswered(inventory(
        project: "alpha", slug: duplicate.fetch(:slug)
      )).fetch("binding")
      FileUtils.cp(fixture_path("duplicate-fingerprint.md"), duplicate.fetch(:path))
      before_duplicate = File.binread(duplicate.fetch(:path))
      ambiguous = write_answer(
        project: "alpha", slug: duplicate.fetch(:slug),
        binding: duplicate_binding, answer: "Do not guess."
      )
      assert_equal "ambiguous", ambiguous.fetch("outcome")
      assert_equal "multiple_matches", ambiguous.fetch("reason")
      assert_equal before_duplicate, File.binread(duplicate.fetch(:path))

      moved = create_task(
        alpha.fetch(:root), slug: "moved-260810-jjjj", id: 109,
        fixture: "guided-single.md"
      )
      moved_binding = first_unanswered(inventory(
        project: "alpha", slug: moved.fetch(:slug)
      )).fetch("binding")
      destination = moved.fetch(:folder).sub("2-brainstorm", "3-plan")
      FileUtils.mkdir_p(File.dirname(destination))
      File.rename(moved.fetch(:folder), destination)
      moved_outcome = write_answer(
        project: "alpha", slug: moved.fetch(:slug),
        binding: moved_binding, answer: "Too late."
      )
      assert_equal "stale", moved_outcome.fetch("outcome")
      assert_equal "task_moved", moved_outcome.fetch("reason")
      refute Dir.exist?(moved.fetch(:folder))
      assert_nil parsed_answers(File.join(destination, "brainstorm.md")).first

      changed = create_task(
        alpha.fetch(:root), slug: "generation-260810-kkkk", id: 110,
        fixture: "guided-single.md"
      )
      generation_binding = first_unanswered(inventory(
        project: "alpha", slug: changed.fetch(:slug)
      )).fetch("binding")
      Hive::TaskMeta.write(
        changed.fetch(:folder), id: 110, slug: changed.fetch(:slug),
        display_name: "Replacement generation", input_fingerprint: "f" * 64,
        idempotency_key: "replacement-generation"
      )
      before_generation = File.binread(changed.fetch(:path))
      generation_outcome = write_answer(
        project: "alpha", slug: changed.fetch(:slug),
        binding: generation_binding, answer: "Wrong generation."
      )
      assert_equal "stale", generation_outcome.fetch("outcome")
      assert_equal "generation_changed", generation_outcome.fetch("reason")
      assert_equal before_generation, File.binread(changed.fetch(:path))

      occupied = create_task(
        alpha.fetch(:root), slug: "occupied-260810-llll", id: 111,
        fixture: "guided-single.md"
      )
      occupied_binding = first_unanswered(inventory(
        project: "alpha", slug: occupied.fetch(:slug)
      )).fetch("binding")
      first = write_answer(
        project: "alpha", slug: occupied.fetch(:slug),
        binding: occupied_binding, answer: "First write wins."
      )
      after_first = File.binread(occupied.fetch(:path))
      identical = write_answer(
        project: "alpha", slug: occupied.fetch(:slug),
        binding: occupied_binding, answer: "First write wins.\n"
      )
      conflict = write_answer(
        project: "alpha", slug: occupied.fetch(:slug),
        binding: occupied_binding, answer: "Overwrite it."
      )
      assert_equal "written", first.fetch("outcome")
      assert_equal "idempotent", identical.fetch("outcome")
      assert_equal "conflict", conflict.fetch("outcome")
      assert_equal after_first, File.binread(occupied.fetch(:path))
    end
  end

  def test_final_slot_completion_does_not_dispatch_or_move_the_task
    with_fleet do |fleet|
      alpha = fleet.fetch("alpha")
      final = create_task(
        alpha.fetch(:root), slug: "final-slot-260810-mmmm", id: 112,
        fixture: "guided-single.md"
      )
      before_mtime = File.mtime(final.fetch(:path))
      pending_before = daemon_answers_pending?(final)
      held = Hive::Daemon::Policy.decide(
        action: "needs_input", stage: "2-brainstorm", workflow: "coding",
        command: "hive brainstorm #{final.fetch(:slug)} --from 2-brainstorm",
        state_file_mtime: before_mtime,
        last_dispatched_state_file_mtime: before_mtime - 60,
        now: before_mtime + 31, answers_pending: pending_before
      )
      slot = first_unanswered(inventory(project: "alpha", slug: final.fetch(:slug)))
      outcome = write_answer(
        project: "alpha", slug: final.fetch(:slug),
        binding: slot.fetch("binding"), answer: "The final approved answer."
      )
      proof = inventory(project: "alpha", slug: final.fetch(:slug))
      after_mtime = File.mtime(final.fetch(:path))
      pending_after = daemon_answers_pending?(final)
      eligible = Hive::Daemon::Policy.decide(
        action: "needs_input", stage: "2-brainstorm", workflow: "coding",
        command: "hive brainstorm #{final.fetch(:slug)} --from 2-brainstorm",
        state_file_mtime: after_mtime,
        last_dispatched_state_file_mtime: after_mtime - 60,
        now: after_mtime + 31, answers_pending: pending_after
      )

      assert_equal true, pending_before
      assert_equal :wait_for_answers, held
      assert_equal "written", outcome.fetch("outcome")
      assert_equal true, outcome.fetch("complete")
      assert_equal 0, proof.fetch("unanswered_count")
      assert_equal true, proof.fetch("complete")
      assert_equal false, pending_after
      assert_equal :dispatch, eligible,
                   "normal daemon policy becomes eligible after the final answer and debounce"
      assert Dir.exist?(final.fetch(:folder))
      refute Dir.exist?(final.fetch(:folder).sub("2-brainstorm", "3-plan"))
    end
  end

  private

  def fixture_path(name)
    File.join(FIXTURE_ROOT, name)
  end

  def status_fixture(name)
    JSON.parse(File.read(fixture_path(name)))
  end

  def transcript_scenarios
    YAML.safe_load(
      File.read(fixture_path("transcripts.yml")),
      permitted_classes: [], aliases: false
    ).fetch("scenarios")
  end

  def waiting_set(snapshot)
    raise "status snapshot failed" unless snapshot["schema"] == "hive-status" && snapshot["ok"] == true

    rows = []
    unknown = []
    snapshot.fetch("projects").each do |project|
      if UNKNOWN_PROJECT_ERRORS.include?(project["error"])
        unknown << [ project.fetch("name"), project.fetch("error") ]
        next
      end

      project.fetch("tasks").each do |task|
        next unless task["workflow"] == "coding" &&
                    task["stage"] == "2-brainstorm" &&
                    task["action"] == "needs_input"

        rows << task.merge("project" => project.fetch("name"))
      end
    end
    { rows: rows, unknown: unknown }
  end

  def yolo_scan(snapshot, answers:, status_refresh: -> { snapshot })
    counts = { scanned: 0, written: 0, escalated: 0 }
    escalations = []
    write_order = []

    waiting_set(snapshot).fetch(:rows).each do |row|
      initial = inventory(project: row.fetch("project"), slug: row.fetch("slug"))
      initial.fetch("slots").reject { |slot| slot.fetch("answered") }.each do |slot|
        counts[:scanned] += 1
        answer = answers[slot.fetch("text")]
        unless answer
          escalations << { "row" => row, "slot" => slot }
          counts[:escalated] += 1
          next
        end

        fresh = inventory(project: row.fetch("project"), slug: row.fetch("slug"))
        matches = fresh.fetch("slots").select do |candidate|
          !candidate.fetch("answered") &&
            candidate.fetch("fingerprint") == slot.fetch("fingerprint")
        end
        unless matches.one?
          escalations << { "row" => row, "slot" => slot }
          counts[:escalated] += 1
          next
        end

        current = matches.first
        outcome = write_answer(
          project: row.fetch("project"), slug: row.fetch("slug"),
          binding: current.fetch("binding"), answer: answer
        )
        status_refresh.call
        if outcome.fetch("outcome") == "written"
          counts[:written] += 1
          write_order << [
            row.fetch("project"), row.fetch("slug"), outcome.dig("slot", "ordinal")
          ]
        else
          escalations << { "row" => row, "slot" => slot, "outcome" => outcome }
          counts[:escalated] += 1
        end
      end
    end

    counts.merge(escalations: escalations, write_order: write_order)
  end

  def with_fleet
    with_tmp_global_config do
      with_tmp_dir do |root|
        beta = create_project(root, "beta")
        beta[:tasks][BETA_SLUG] = create_task(
          beta.fetch(:root), slug: BETA_SLUG, id: 202,
          fixture: "mixed-multi-round.md"
        )
        alpha = create_project(root, "alpha")
        alpha[:tasks][ALPHA_SLUG] = create_task(
          alpha.fetch(:root), slug: ALPHA_SLUG, id: 101,
          fixture: "guided-single.md"
        )
        yield({ "beta" => beta, "alpha" => alpha })
      end
    end
  end

  def create_project(root, name)
    project_root = File.join(root, name)
    hive_state = File.join(project_root, ".hive-state")
    FileUtils.mkdir_p(File.join(hive_state, "stages"))
    File.write(File.join(hive_state, "config.yml"), {}.to_yaml)
    Hive::Config.register_project(name: name, path: project_root)
    { root: project_root, tasks: {} }
  end

  def create_task(project_root, slug:, id:, fixture:)
    folder = File.join(project_root, ".hive-state", "stages", "2-brainstorm", slug)
    FileUtils.mkdir_p(folder)
    Hive::TaskMeta.write(
      folder, id: id, slug: slug, display_name: slug,
      input_fingerprint: id.to_s(16).rjust(64, "0"),
      idempotency_key: "brainstorm-skill-#{id}"
    )
    path = File.join(folder, "brainstorm.md")
    FileUtils.cp(fixture_path(fixture), path)
    { slug: slug, folder: folder, path: path }
  end

  def inventory(project:, slug:)
    call_answer(project: project, slug: slug)
  end

  def write_answer(project:, slug:, binding:, answer:)
    call_answer(project: project, slug: slug, binding: binding, answer: answer)
  end

  def call_answer(project:, slug:, binding: nil, answer: "")
    output = StringIO.new
    Hive::Commands::Answer.new(
      slug, project: project, binding: binding, json: true,
      input: StringIO.new(answer), output: output
    ).call
    JSON.parse(output.string)
  end

  def first_unanswered(payload)
    payload.fetch("slots").find { |slot| !slot.fetch("answered") }
  end

  def parsed_answers(path)
    Hive::BrainstormParser.parse(path).map(&:answer)
  end

  def fleet_state(fleet)
    fleet.values.flat_map do |project|
      project.fetch(:tasks).values.map do |task|
        [ task.fetch(:path), File.binread(task.fetch(:path)) ]
      end
    end.sort.to_h
  end

  def daemon_answers_pending?(task)
    row = Struct.new(
      :action, :workflow, :stage, :state_file, :project, :slug,
      keyword_init: true
    ).new(
      action: "needs_input", workflow: "coding", stage: "2-brainstorm",
      state_file: task.fetch(:path), project: "alpha", slug: task.fetch(:slug)
    )
    dispatcher = Hive::Daemon::Dispatcher.allocate
    dispatcher.instance_variable_set(:@brainstorm_parse_errors, {})
    dispatcher.send(:brainstorm_answers_pending?, row)
  end
end
