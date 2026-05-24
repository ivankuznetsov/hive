require "eval/eval_helper"

class HiveEvalPersonasTest < Minitest::Test
  def test_scripted_persona_returns_replies_in_order
    persona = Hive::Eval::ScriptedPersona.new(replies: [ "yes", "no" ])

    assert_equal "yes", persona.respond(bot_message: "First?")
    assert_equal "no", persona.respond(bot_message: "Second?")
    assert_raises(RuntimeError) { persona.respond(bot_message: "Third?") }
  end

  def test_codex_persona_returns_non_empty_reply
    persona = Hive::Eval::CodexPersona.new(
      role_prompt: "You are a terse user answering a bot question. Keep the reply under six words."
    )

    reply = persona.respond(bot_message: "Should Hive continue?")

    refute_empty reply.strip
  end

  def test_programmable_status_watcher_returns_queued_batches_then_empty
    watcher = Hive::Eval::ProgrammableStatusWatcher.new
    first = [ Hive::Bot::StatusWatcher::Row.new(project: "hive", slug: "a", action: "needs_input") ]
    second = [ Hive::Bot::StatusWatcher::Row.new(project: "hive", slug: "b", action: "agent_running") ]
    watcher.queue(rows: first)
    watcher.queue(rows: second)

    assert_equal first, watcher.fetch.rows
    assert_equal second, watcher.fetch.rows
    assert_empty watcher.fetch.rows
  end
end
