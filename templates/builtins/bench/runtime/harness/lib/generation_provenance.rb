# frozen_string_literal: true

require "json"
require "fileutils"
require "securerandom"
require "digest"
require "time"
require "pathname"
require "lib/result_evidence"

module HiveBench
  # Attempt identity lives beside the candidate checkout, never in its mount.
  # Artifact digests verify an attempt; identical bytes do not identify one.
  module GenerationProvenance
    class Mismatch < StandardError; end
    MANIFEST = "generation-attempt.json"
    module_function

    def load(out_dir)
      path = File.join(out_dir, MANIFEST)
      File.file?(path) ? JSON.parse(File.read(path)) : nil
    end

    def persist(out_dir, manifest)
      FileUtils.mkdir_p(out_dir)
      path = File.join(out_dir, MANIFEST)
      next_path = "#{path}.#{SecureRandom.hex(6)}.next"
      File.write(next_path, "#{JSON.pretty_generate(manifest)}\n")
      File.rename(next_path, path)
      manifest
    ensure
      FileUtils.rm_f(next_path) if next_path
    end

    def start!(out_dir:, entry:, agent_id:)
      manifest = { "schema" => "hive-bench-generation-attempt", "schema_version" => 1,
                   "generation_id" => SecureRandom.uuid, "task_id" => entry.fetch("task_id"),
                   "agent_id" => agent_id, "base_commit" => entry.dig("source", "base_commit"),
                   "state" => "started", "started_at" => Time.now.utc.iso8601 }
      persist(out_dir, manifest)
      %w[candidate.patch generation-plan.md target/candidate.patch].each { |rel| FileUtils.rm_f(File.join(out_dir, rel)) }
      manifest
    end

    def digest(text) = Digest::SHA256.hexdigest(text)

    def finalize!(out_dir:, manifest:, diff_path:, plan:, status:, telemetry: {}, state: "finalized")
      plan_path = File.join(out_dir, "generation-plan.md")
      File.write(plan_path, plan.to_s)
      binding = if diff_path && File.file?(diff_path)
                  { "task_id" => manifest.fetch("task_id"), "base_commit" => manifest.fetch("base_commit"),
                    "patch_sha256" => digest(File.binread(diff_path)), "plan_sha256" => digest(plan.to_s) }
                end
      patch_relative = diff_path && Pathname.new(File.expand_path(diff_path)).relative_path_from(Pathname.new(File.expand_path(out_dir))).to_s
      persist(out_dir, manifest.merge("state" => state, "run_status" => status, "artifact_binding" => binding,
                                      "patch_path" => patch_relative, "plan_path" => "generation-plan.md", "efficiency" => telemetry))
    end

    def finalize_cell!(cell, out_dir:, manifest:, plan:, state: "finalized")
      finalized = finalize!(out_dir: out_dir, manifest: manifest, diff_path: cell.diff_path, plan: plan,
                            status: cell.status, telemetry: cell.telemetry, state: state)
      cell.with(generation_id: finalized.fetch("generation_id"), artifact_binding: finalized["artifact_binding"])
    end

    def artifact_path(out_dir, relative)
      return nil unless relative.is_a?(String)

      root = File.realpath(out_dir)
      path = File.realpath(File.join(root, relative))
      raise Mismatch, "artifact path escapes generation bundle" unless path.start_with?("#{root}/")

      path
    rescue Errno::ENOENT
      nil
    end

    def verify!(out_dir, entry:, agent_id:)
      manifest = load(out_dir)
      raise Mismatch, "generation manifest missing" unless manifest
      unless manifest["task_id"] == entry["task_id"] && manifest["agent_id"] == agent_id &&
             manifest["base_commit"] == entry.dig("source", "base_commit") && !manifest["generation_id"].to_s.empty?
        raise Mismatch, "generation manifest task/agent/base mismatch"
      end
      binding = manifest["artifact_binding"]
      patch = artifact_path(out_dir, manifest["patch_path"])
      plan = artifact_path(out_dir, manifest["plan_path"])
      unless binding && patch && plan && binding["patch_sha256"] == digest(File.binread(patch)) &&
             binding["plan_sha256"] == digest(File.binread(plan)) &&
             binding["task_id"] == manifest["task_id"] && binding["base_commit"] == manifest["base_commit"]
        raise Mismatch, "generation artifacts missing or digest mismatch; recover artifacts before rejudging"
      end
      manifest
    end

    def read_plan(entry)
      rel = entry.dig("spec", "plan")
      path = rel && File.join(entry.fetch("entry_dir"), rel)
      path && File.file?(path) ? File.read(path) : ""
    end

    def candidate_plan(work, task_id)
      paths = Dir.glob(File.join(work, ".hive-state", "stages", "**", task_id, "plan.md"))
      raise Mismatch, "ambiguous candidate plans in artifact bundle" if paths.size > 1

      paths.empty? ? "" : File.read(paths.first)
    end

    def context(plan:, reference:, withheld:)
      { "plan_sha256" => digest(plan.to_s), "reference_mode" => withheld ? "withheld" : (reference.nil? ? "unavailable" : "provided") }
        .tap { |value| value["reference_sha256"] = digest(reference) if !withheld && reference }
    end
  end
end
