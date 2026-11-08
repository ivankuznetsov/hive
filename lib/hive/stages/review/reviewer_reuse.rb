require "digest"
require "json"
require "hive/atomic_file"

module Hive
  module Stages
    module Review
      # Single-use receipt that lets the cooled retry of a provider-limited
      # pass reuse reviewer outputs the pass already produced, instead of
      # re-spending every healthy reviewer's quota each hour.
      #
      # Written only when triage hits a provider limit (`limits_reached`):
      # the receipt names each reviewer output that succeeded at `head`, with
      # its SHA-256 as captured just before the triage spawn. Triage edits
      # reviewer files in place, so an output triage already touched no longer
      # matches and is re-run rather than reused half-classified.
      #
      # The next reviewers phase consumes (reads and deletes) the receipt.
      # A reviewer is skipped only when the receipt's pass and HEAD match the
      # current run and its output file still hashes to the recorded digest.
      # Every other path — genuine errors, a moved HEAD, an edited file, an
      # unreadable receipt — re-runs reviewers exactly as before.
      module ReviewerReuse
        VERSION = 1

        module_function

        def path(task_folder, pass)
          File.join(task_folder, "reviews", "reviewer-reuse-#{format('%02d', pass)}.json")
        end

        def output_path(ctx, output_basename)
          File.join(ctx.task_folder, "reviews", "#{output_basename}-#{format('%02d', ctx.pass)}.md")
        end

        def digest_of(file)
          Digest::SHA256.file(file).hexdigest
        rescue SystemCallError
          nil
        end

        # {output_basename => sha256} for the named outputs present on disk.
        def digests(ctx, output_basenames)
          output_basenames.each_with_object({}) do |basename, acc|
            digest = digest_of(output_path(ctx, basename))
            acc[basename] = digest if digest
          end
        end

        # Read and delete the pass's receipt. Returns the reusable
        # {output_basename => sha256} map, or {} when there is nothing
        # trustworthy to reuse.
        def consume(ctx, head:)
          file = path(ctx.task_folder, ctx.pass)
          raw = File.read(file)
          File.delete(file)
          data = JSON.parse(raw)
          return {} unless data.is_a?(Hash) && data["version"] == VERSION && data["pass"] == ctx.pass
          return {} if head.to_s.empty? || data["head"] != head.to_s

          outputs = data["outputs"]
          return {} unless outputs.is_a?(Hash)

          outputs.select { |basename, digest| basename.is_a?(String) && digest.is_a?(String) }
        rescue SystemCallError, JSON::ParserError
          {}
        end

        def reusable?(ctx, output_basename, reuse)
          digest = reuse[output_basename.to_s]
          !digest.nil? && digest_of(output_path(ctx, output_basename)) == digest
        end

        # Record the outputs still byte-identical to their pre-triage digests.
        def record(ctx, head:, pre_triage_digests:)
          outputs = pre_triage_digests.select do |basename, digest|
            digest_of(output_path(ctx, basename)) == digest
          end
          return if head.to_s.empty? || outputs.empty?

          Hive::AtomicFile.write(
            path(ctx.task_folder, ctx.pass),
            "#{JSON.generate('version' => VERSION, 'pass' => ctx.pass, 'head' => head.to_s, 'outputs' => outputs)}\n"
          )
        rescue SystemCallError => e
          # Reuse is an optimization: losing the receipt only means the next
          # cooled retry re-runs every reviewer, as it did before receipts.
          warn "[hive.review] could not record reviewer reuse receipt: #{e.class}: #{e.message}"
        end
      end
    end
  end
end
