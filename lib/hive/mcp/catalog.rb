require "hive/operational_action"

module Hive
  module Mcp
    # Tool schemas for the Grok connector. Names stay unprefixed; Grok
    # namespaces them with the server name from the plugin manifest.
    module Catalog
      MAX_TARGET_LENGTH = 512
      MAX_PROJECT_LENGTH = 256
      MAX_BINDING_BYTES = 8 * 1024
      MAX_ANSWER_BYTES = 64 * 1024

      TOOLS = {
        "status" => {
          description: "Read a fresh Hive operational snapshot (hive-operational-status JSON). " \
                       "Call this before claiming task state or taking an action.",
          required: [],
          properties: {}
        },
        "task" => {
          description: "Read one registered task's semantic workspace, or its current " \
                       "receipt-correlated diagnostic log when log is true.",
          required: [ "target" ],
          properties: {
            "target" => {
              "type" => "string",
              "minLength" => 1,
              "maxLength" => MAX_TARGET_LENGTH,
              "description" => "Task slug, numeric id, or folder target accepted by hive task."
            },
            "project" => {
              "type" => "string",
              "minLength" => 1,
              "maxLength" => MAX_PROJECT_LENGTH,
              "description" => "Registered project name when the target is not globally unique."
            },
            "log" => {
              "type" => "boolean",
              "description" => "Return the current diagnostic log tail instead of the JSON workspace."
            }
          }
        },
        "doctor" => {
          description: "Read Hive doctor JSON. This does not install skills or change configuration.",
          required: [],
          properties: {}
        },
        "answer_inventory" => {
          description: "List coding-brainstorm question slots and their opaque bindings. " \
                       "This does not write an answer or advance the task.",
          required: [ "target" ],
          properties: {
            "target" => {
              "type" => "string",
              "minLength" => 1,
              "maxLength" => MAX_TARGET_LENGTH,
              "description" => "Brainstorm task slug or numeric id."
            },
            "project" => {
              "type" => "string",
              "minLength" => 1,
              "maxLength" => MAX_PROJECT_LENGTH,
              "description" => "Registered project name when the target is not globally unique."
            }
          }
        },
        "answer_write" => {
          description: "Write one final literal brainstorm answer using a binding from a fresh " \
                       "answer_inventory. This does not advance the task.",
          required: [ "target", "binding", "answer" ],
          properties: {
            "target" => {
              "type" => "string",
              "minLength" => 1,
              "maxLength" => MAX_TARGET_LENGTH
            },
            "project" => {
              "type" => "string",
              "minLength" => 1,
              "maxLength" => MAX_PROJECT_LENGTH
            },
            "binding" => {
              "type" => "string",
              "minLength" => 1,
              "maxLength" => MAX_BINDING_BYTES,
              "description" => "Opaque binding copied from answer_inventory."
            },
            "answer" => {
              "type" => "string",
              "minLength" => 1,
              "maxLength" => MAX_ANSWER_BYTES,
              "description" => "The operator's final answer text for that exact slot."
            }
          }
        },
        "act" => {
          description: "Execute one fresh routine action copied from the same operational snapshot. " \
                       "Accepted action_id values are workflow.advance and workflow.retry. " \
                       "A stale observation does not mutate.",
          required: [ "action_id", "target", "observation" ],
          properties: {
            "action_id" => {
              "type" => "string",
              "enum" => Hive::OperationalAction::EXECUTABLE_ACTION_IDS
            },
            "target" => {
              "type" => "string",
              "pattern" => "\\A[^:\\s\\\\/]+:[^:\\s\\\\/]+\\z",
              "description" => "Exact project:slug from the operational snapshot."
            },
            "observation" => {
              "type" => "string",
              "pattern" => "\\A[0-9a-f]{64}\\z",
              "description" => "64-character observation token from that same snapshot."
            }
          }
        }
      }.freeze
    end
  end
end
