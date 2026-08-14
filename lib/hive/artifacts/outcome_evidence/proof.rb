require "digest"
require "fileutils"
require "json"
require "pathname"
require "tmpdir"
require "hive/atomic_file"
require "hive/artifacts/outcome_evidence/document"
require "hive/artifacts/outcome_evidence/identity"
require "hive/invoked_binary"
require "hive/secret_patterns"
require "hive/web/project_capture_provider"

module Hive
  module Artifacts
    module OutcomeEvidence
      # Closed, reviewer-facing proof contract. Every admitted original is
      # paired with a bounded review representation, and every retained byte
      # is rechecked at publication time.
      module Proof
        KINDS = %w[screenshot video terminal document].freeze
        ROLES = %w[original review storyboard].freeze
        SOURCE_TYPES = %w[task project_provider].freeze
        MAX_ORIGINAL_BYTES = 256 * 1024 * 1024
        MAX_REVIEW_BYTES = 16 * 1024 * 1024
        MAX_REPRESENTATIONS = 8
        MAX_CLAIMS = 5
        MAX_TEXT_BYTES = 4 * 1024 * 1024
        MAX_VIDEO_DURATION_SECONDS = 30
        SAFE_NAME = /\A[a-z][a-z0-9_-]{0,63}\z/
        SAFE_CLAIM = /\A[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\z/
        DIGEST = /\A[0-9a-f]{64}\z/
        OID = Identity::OID
        MEDIA_TYPES = {
          "screenshot" => {
            "original" => %w[image/png image/jpeg image/webp],
            "review" => %w[image/png image/jpeg image/webp]
          },
          "video" => {
            "original" => %w[video/webm video/mp4],
            "review" => %w[video/webm video/mp4],
            "storyboard" => %w[image/png image/jpeg image/webp]
          },
          "terminal" => {
            "original" => [ "application/x-asciinema+json" ],
            "review" => [ "text/plain" ]
          },
          "document" => {
            "original" => %w[
              text/plain text/markdown application/json image/png image/jpeg image/webp
            ],
            "review" => %w[text/plain image/png image/jpeg image/webp]
          }
        }.freeze
        ACTIVE_DOCUMENT = /\A\s*(?:<!doctype\s+html|<html\b|<svg\b)/i

        module_function

        def admit!(value, task_folder:, expected_head:)
          entry = object!(value, "outcome evidence")
          reject_unknown!(
            entry, %w[kind summary claims source representations], "outcome evidence"
          )
          kind = entry.fetch("kind").to_s
          raise StoreError, "unsupported outcome proof kind #{kind.inspect}" unless KINDS.include?(kind)

          summary = bounded_text!(entry.fetch("summary"), "outcome evidence summary", 4096)
          reject_secrets!(summary, "outcome evidence summary")
          claims = canonical_claims(entry.fetch("claims"))
          source = canonical_source(
            entry.fetch("source"), task_folder: task_folder,
            expected_head: expected_head
          )
          representations = canonical_representations(
            entry.fetch("representations"), kind: kind, task_folder: task_folder
          )
          validate_provider_originals!(
            source, representations, task_folder: task_folder
          ) if source.fetch("type") == "project_provider"

          {
            "kind" => kind,
            "summary" => summary,
            "claims" => claims,
            "source" => source,
            "representations" => representations
          }
        rescue KeyError => e
          raise StoreError, "outcome evidence is missing #{e.key}"
        rescue ArgumentError, TypeError, ResolutionError => e
          raise StoreError, e.message
        end

        # Move producer-owned task evidence across a controller custody
        # boundary before the independent reviewer sees it. The copy is read
        # through a no-follow descriptor, must reproduce the producer's exact
        # byte count and digest, and is admitted again from its immutable
        # generation/attempt path. Project-provider files already live in the
        # controller-owned media store and remain bound to their manifest.
        def materialize!(value, task_folder:, expected_head:, destination_root:)
          admitted = admit!(
            value, task_folder: task_folder, expected_head: expected_head
          )
          return admitted if admitted.dig("source", "type") == "project_provider"

          relative_root = Identity.validate_changed_path!(destination_root)
          task_root = File.realpath(task_folder)
          destination = File.join(task_root, relative_root)
          prepare_materialization_root!(task_root, destination)
          copied = admitted.merge(
            "representations" => admitted.fetch("representations").map.with_index do |representation, index|
              relative = File.join(
                relative_root, format("representation-%02d-%s", index + 1, representation.fetch("role"))
              )
              copy_representation!(
                task_root, representation, File.join(task_root, relative)
              ).merge("path" => relative)
            end
          )
          canonical = admit!(
            copied, task_folder: task_folder, expected_head: expected_head
          )
          Hive::AtomicFile.fsync_directory(destination)
          canonical
        rescue StoreError, SystemCallError
          FileUtils.remove_entry_secure(destination) if destination && File.directory?(destination)
          raise
        end

        # Convert the producer's semantic-only task descriptor into the full
        # byte contract. Hashes, sizes, source identity, and rendering are
        # controller observations, not values an LLM needs to calculate or
        # echo. Existing project-provider descriptors retain their separately
        # authenticated source contract.
        def materialize_producer!(value, task_folder:, expected_head:, destination_root:)
          raw = object!(value, "producer outcome evidence")
          materialized = if raw.key?("source")
            materialize!(
              raw, task_folder: task_folder, expected_head: expected_head,
              destination_root: destination_root
            )
          else
            reject_unknown!(
              raw, %w[kind summary claims representations], "producer outcome evidence"
            )
            representations = Array(raw.fetch("representations")).map do |value|
              item = object!(value, "producer outcome evidence representation")
              reject_unknown!(
                item, %w[role media_type path], "producer outcome evidence representation"
              )
              if item.fetch("role").to_s == "storyboard"
                raise StoreError, "producer must not supply controller review storyboards"
              end
              path = Identity.validate_changed_path!(item.fetch("path"))
              candidate, stat = retained_regular_file!(task_folder, path)
              {
                "role" => item.fetch("role").to_s,
                "media_type" => item.fetch("media_type").to_s,
                "path" => path,
                "sha256" => secure_digest(candidate),
                "bytes" => stat.size
              }
            end
            described = raw.merge(
              "source" => {
                "type" => "task", "name" => "hive-producer",
                "source_sha" => expected_head.to_s
              },
              "representations" => representations
            )
            materialize!(
              described, task_folder: task_folder, expected_head: expected_head,
              destination_root: destination_root
            )
          end
          return materialized unless materialized.fetch("kind") == "video"

          add_controller_storyboard!(
            materialized, task_folder: task_folder, expected_head: expected_head,
            destination_root: destination_root
          )
        rescue KeyError => e
          raise StoreError, "producer outcome evidence is missing #{e.key}"
        end

        def add_controller_storyboard!(entry, task_folder:, expected_head:, destination_root:)
          relative_root = Identity.validate_changed_path!(destination_root)
          task_root = File.realpath(task_folder)
          destination = File.join(task_root, relative_root)
          prepare_materialization_root!(task_root, destination) unless File.directory?(destination)
          review = entry.fetch("representations").find { |item| item.fetch("role") == "review" }
          source, = retained_regular_file!(task_folder, review.fetch("path"))
          duration = inspect_media!(source, media_type: review.fetch("media_type"))
          storyboard_relative = File.join(relative_root, "controller-storyboard.png")
          storyboard = File.join(task_root, storyboard_relative)
          rate = [ 6.0 / duration, 0.2 ].max
          ffmpeg = Hive::InvokedBinary.which("ffmpeg")
          raise StoreError, "ffmpeg is required to derive video review frames" unless ffmpeg

          media_command(
            [ ffmpeg, "-nostdin", "-v", "error", "-i", source,
              "-vf", "fps=#{rate},scale=480:-2:flags=lanczos," \
                     "tile=3x2:nb_frames=6:padding=4:margin=4",
              "-frames:v", "1", storyboard ],
            source_root: destination
          )
          stat = File.lstat(storyboard)
          unless stat.file? && !stat.symlink? && stat.size.positive? &&
                 stat.size <= MAX_REVIEW_BYTES
            raise StoreError, "controller video storyboard is unavailable"
          end
          representations = entry.fetch("representations")
            .reject { |item| item.fetch("role") == "storyboard" }
          representations << {
            "role" => "storyboard", "media_type" => "image/png",
            "path" => storyboard_relative, "sha256" => secure_digest(storyboard),
            "bytes" => stat.size
          }
          admit!(
            entry.merge("representations" => representations),
            task_folder: task_folder, expected_head: expected_head
          )
        rescue Errno::ENOENT, Errno::ELOOP
          raise StoreError, "controller video storyboard is unavailable"
        end
        private_class_method :add_controller_storyboard!

        def canonical_claims(value)
          claims = Array(value).map(&:to_s)
          unless claims.length.between?(1, MAX_CLAIMS) && claims.all? { |claim| claim.match?(SAFE_CLAIM) }
            raise StoreError, "outcome evidence claims must contain 1-#{MAX_CLAIMS} safe claim IDs"
          end
          unless claims.uniq.length == claims.length
            raise StoreError, "outcome evidence claim IDs must be unique"
          end

          claims.sort
        end
        private_class_method :canonical_claims

        def canonical_source(value, task_folder:, expected_head:)
          source = object!(value, "outcome evidence source")
          type = source.fetch("type").to_s
          if type == "hivebox" || source["diagnostic_only"] == true
            raise StoreError, "built-in synthetic Hivebox capture is diagnostic-only"
          end
          raise StoreError, "unsupported outcome evidence source #{type.inspect}" unless SOURCE_TYPES.include?(type)

          allowed = %w[type name source_sha]
          allowed << "manifest_path" if type == "project_provider"
          reject_unknown!(source, allowed, "outcome evidence source")
          name = source.fetch("name").to_s
          raise StoreError, "outcome evidence source name is invalid" unless name.match?(SAFE_NAME)
          source_sha = source.fetch("source_sha").to_s.downcase
          raise StoreError, "outcome evidence source SHA is invalid" unless source_sha.match?(OID)
          unless source_sha == expected_head.to_s.downcase
            raise StoreError, "outcome evidence source does not match the implementation head"
          end

          result = { "type" => type, "name" => name, "source_sha" => source_sha }
          if type == "project_provider"
            manifest_path = Identity.validate_changed_path!(source.fetch("manifest_path"))
            manifest = capture_manifest!(task_folder, manifest_path)
            unless manifest["evidence_role"] == "claim_evidence" &&
                   manifest.dig("recorder", "kind") == "project_provider" &&
                   manifest.dig("recorder", "name") == name &&
                   manifest["source_sha"] == source_sha &&
                   manifest.dig("evidence", "type") == "project_provider"
              raise StoreError, "project-provider capture source identity does not match"
            end
            result["manifest_path"] = manifest_path
          end
          result
        end
        private_class_method :canonical_source

        def canonical_representations(value, kind:, task_folder:)
          representations = Array(value)
          unless representations.length.between?(2, MAX_REPRESENTATIONS)
            raise StoreError,
                  "outcome evidence requires 2-#{MAX_REPRESENTATIONS} representations"
          end
          if kind == "video"
            review = representations.find do |item|
              item.respond_to?(:to_h) && item.to_h.transform_keys(&:to_s)["role"].to_s == "review"
            end
            unless review && review.to_h.transform_keys(&:to_s)["media_type"].to_s.start_with?("video/")
              raise StoreError,
                    "video outcome evidence requires an actual temporal review representation; " \
                    "storyboard frames are supplemental only"
            end
          end
          canonical = representations.map do |item|
            canonical_representation(item, kind: kind, task_folder: task_folder)
          end
          roles = canonical.map { |item| item.fetch("role") }
          unless roles.count("original") == 1 && roles.count("review") == 1
            raise StoreError, "outcome evidence requires exactly one original and one review representation"
          end
          paths = canonical.map { |item| item.fetch("path") }
          raise StoreError, "outcome evidence representation paths must be unique" unless paths.uniq == paths

          canonical.sort_by { |item| [ role_order(item.fetch("role")), item.fetch("path") ] }
        end
        private_class_method :canonical_representations

        def canonical_representation(value, kind:, task_folder:)
          item = object!(value, "outcome evidence representation")
          reject_unknown!(
            item, %w[role media_type rendering path sha256 bytes],
            "outcome evidence representation"
          )
          role = item.fetch("role").to_s
          raise StoreError, "unsupported outcome evidence representation role" unless ROLES.include?(role)
          allowed_types = MEDIA_TYPES.fetch(kind).fetch(role, [])
          media_type = item.fetch("media_type").to_s.downcase
          path = Identity.validate_changed_path!(item.fetch("path"))
          if kind == "document" &&
             (media_type.match?(%r{(?:html|svg)}) || File.extname(path).downcase.match?(/\A\.(?:html?|xhtml|svg)\z/))
            raise StoreError, "active SVG or HTML cannot be admitted as document evidence"
          end
          if kind == "video" && role == "review" && !media_type.start_with?("video/")
            raise StoreError,
                  "video outcome evidence requires an actual temporal review representation; " \
                  "storyboard frames are supplemental only"
          end
          unless allowed_types.include?(media_type)
            raise StoreError, "#{kind} #{role} representation has an unsafe media type"
          end
          candidate, stat = retained_regular_file!(task_folder, path)
          limit = role == "original" ? MAX_ORIGINAL_BYTES : MAX_REVIEW_BYTES
          bytes = Integer(item.fetch("bytes"))
          unless bytes.positive? && bytes <= limit && stat.size == bytes
            raise StoreError, "outcome evidence representation #{path.inspect} has an invalid size"
          end
          sha256 = item.fetch("sha256").to_s.downcase
          unless sha256.match?(DIGEST) && secure_digest(candidate) == sha256
            raise StoreError, "outcome evidence representation #{path.inspect} digest does not match"
          end
          rendering = rendering_for(kind, role, media_type)
          if item.key?("rendering") && item.fetch("rendering").to_s != rendering
            raise StoreError, "outcome evidence representation rendering does not match its media type"
          end
          inspect_representation!(candidate, kind: kind, role: role, media_type: media_type)
          {
            "role" => role, "media_type" => media_type, "rendering" => rendering,
            "path" => path, "sha256" => sha256, "bytes" => bytes
          }
        end
        private_class_method :canonical_representation

        def retained_regular_file!(task_folder, path)
          root = File.realpath(task_folder)
          candidate = File.join(root, path)
          stat = File.lstat(candidate)
          unless stat.file? && !stat.symlink?
            raise StoreError, "outcome evidence representation #{path.inspect} must be a regular file"
          end
          real = File.realpath(candidate)
          unless real.start_with?("#{root}#{File::SEPARATOR}")
            raise StoreError, "outcome evidence representation #{path.inspect} escapes the task folder"
          end
          [ real, stat ]
        rescue Errno::ENOENT, Errno::ENOTDIR, Errno::ELOOP
          raise StoreError, "outcome evidence representation #{path.inspect} is unavailable"
        end
        private_class_method :retained_regular_file!

        def secure_digest(path)
          digest = Digest::SHA256.new
          File.open(path, File::RDONLY | File::NOFOLLOW) do |file|
            while (chunk = file.read(1024 * 1024))
              digest << chunk
            end
          end
          digest.hexdigest
        rescue Errno::ELOOP
          raise StoreError, "outcome evidence representation must not be a symlink"
        end
        private_class_method :secure_digest

        def prepare_materialization_root!(task_root, destination)
          parent = File.realpath(File.dirname(destination))
          unless parent == task_root || parent.start_with?("#{task_root}#{File::SEPARATOR}")
            raise StoreError, "outcome evidence custody root escapes the task folder"
          end
          begin
            File.lstat(destination)
            raise StoreError, "outcome evidence custody root already exists"
          rescue Errno::ENOENT
            nil
          end
          Dir.mkdir(destination, 0o700)
          stat = File.lstat(destination)
          unless stat.directory? && !stat.symlink?
            raise StoreError, "outcome evidence custody root is not a directory"
          end
          Hive::AtomicFile.fsync_directory(parent)
        rescue Errno::EEXIST, Errno::ELOOP
          raise StoreError, "outcome evidence custody root is unavailable"
        end
        private_class_method :prepare_materialization_root!

        def copy_representation!(task_root, representation, destination)
          source, = retained_regular_file!(task_root, representation.fetch("path"))
          digest = Digest::SHA256.new
          total = 0
          File.open(source, File::RDONLY | File::NOFOLLOW) do |input|
            before = input.stat
            raise StoreError, "producer evidence must be a regular file" unless before.file?

            File.open(
              destination,
              File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW,
              0o600
            ) do |output|
              while (chunk = input.read(1024 * 1024))
                total += chunk.bytesize
                if total > representation.fetch("bytes")
                  raise StoreError, "producer evidence changed during custody transfer"
                end
                digest << chunk
                output.write(chunk)
              end
              output.flush
              output.fsync
            end
            after = input.stat
            unless [ before.dev, before.ino, before.size ] == [ after.dev, after.ino, after.size ]
              raise StoreError, "producer evidence changed during custody transfer"
            end
          end
          unless total == representation.fetch("bytes") &&
                 digest.hexdigest == representation.fetch("sha256")
            raise StoreError, "producer evidence changed during custody transfer"
          end
          Hive::AtomicFile.fsync_directory(File.dirname(destination))
          representation.merge("bytes" => total, "sha256" => digest.hexdigest)
        rescue Errno::EEXIST, Errno::ELOOP, Errno::ENOENT, Errno::ENOTDIR
          raise StoreError, "producer evidence is unavailable for custody transfer"
        rescue StoreError
          FileUtils.rm_f(destination)
          raise
        end
        private_class_method :copy_representation!

        def inspect_representation!(path, kind:, role:, media_type:)
          case media_type
          when "image/png", "image/jpeg", "image/webp", "video/webm", "video/mp4"
            duration = inspect_media!(path, media_type: media_type)
            inspect_visual_secrets!(path, media_type: media_type, duration: duration)
          when "application/x-asciinema+json"
            inspect_terminal_cast!(path)
          when "text/plain", "text/markdown", "application/json"
            inspect_safe_text!(
              path,
              json: media_type == "application/json",
              reject_active_document: kind == "document"
            )
          else
            raise StoreError, "unsupported #{kind} #{role} representation"
          end
        end
        private_class_method :inspect_representation!

        def inspect_terminal_cast!(path)
          lines = File.binread(path, MAX_TEXT_BYTES + 1)
          raise StoreError, "terminal cast exceeds #{MAX_TEXT_BYTES} bytes" if lines.bytesize > MAX_TEXT_BYTES
          reject_secrets!(lines, "terminal cast")
          records = lines.each_line.map.with_index do |line, index|
            JSON.parse(line)
          rescue JSON::ParserError
            raise StoreError, "terminal cast contains malformed JSON at line #{index + 1}"
          end
          header = records.shift
          unless header.is_a?(Hash) && header["version"] == 2 &&
                 Integer(header["width"], exception: false)&.positive? &&
                 Integer(header["height"], exception: false)&.positive?
            raise StoreError, "terminal cast has an invalid asciinema v2 header"
          end
          previous = -Float::INFINITY
          unless records.all? do |record|
                   timestamp = record.is_a?(Array) && Float(record[0], exception: false)
                   valid = record.length == 3 && timestamp&.finite? &&
                           timestamp >= 0 && timestamp >= previous &&
                           record[1] == "o" && record[2].is_a?(String)
                   previous = timestamp if valid
                   valid
                 end
            raise StoreError, "terminal cast contains an invalid output event"
          end
        end
        private_class_method :inspect_terminal_cast!

        def inspect_safe_text!(path, json: false, reject_active_document: false)
          source = File.binread(path, MAX_TEXT_BYTES + 1)
          raise StoreError, "text review exceeds #{MAX_TEXT_BYTES} bytes" if source.bytesize > MAX_TEXT_BYTES
          text = source.dup.force_encoding(Encoding::UTF_8)
          raise StoreError, "text review is not valid UTF-8" unless text.valid_encoding?
          if text.match?(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/)
            raise StoreError, "text review contains unsafe control characters"
          end
          if reject_active_document && text.match?(ACTIVE_DOCUMENT)
            raise StoreError, "active SVG or HTML cannot be admitted as document evidence"
          end
          reject_secrets!(text, "text review")
          JSON.parse(text) if json
        rescue JSON::ParserError
          raise StoreError, "document JSON original is malformed"
        end
        private_class_method :inspect_safe_text!

        def inspect_media!(path, media_type:)
          ffprobe = Hive::InvokedBinary.which("ffprobe")
          ffmpeg = Hive::InvokedBinary.which("ffmpeg")
          raise StoreError, "ffprobe and ffmpeg are required to inspect proof media" unless ffprobe && ffmpeg

          probe = media_command(
            [ ffprobe, "-v", "error", "-show_entries",
              "format=format_name,duration:stream=codec_name,codec_type", "-of", "json", path ],
            source_root: File.dirname(path)
          )
          document = JSON.parse(probe)
          stream = Array(document["streams"]).find do |candidate|
            candidate.is_a?(Hash) && candidate["codec_type"] == "video"
          end
          codec = stream && stream["codec_name"]
          format = document["format"].is_a?(Hash) ? document["format"] : {}
          valid = case media_type
          when "image/png" then codec == "png"
          when "image/jpeg" then codec == "mjpeg"
          when "image/webp" then codec == "webp"
          when "video/webm"
            codec && format.fetch("format_name", "").include?("webm") &&
              Float(format["duration"], exception: false)&.positive?
          when "video/mp4"
            codec && format.fetch("format_name", "").match?(/(?:\A|,)(?:mov|mp4)(?:,|\z)/) &&
              Float(format["duration"], exception: false)&.positive?
          end
          raise StoreError, "proof media is not valid decodable #{media_type}" unless valid

          duration = if media_type.start_with?("video/")
            Float(format["duration"], exception: false)
          end
          if duration && duration > MAX_VIDEO_DURATION_SECONDS
            raise StoreError,
                  "proof video exceeds #{MAX_VIDEO_DURATION_SECONDS} seconds"
          end

          media_command(
            [ ffmpeg, "-nostdin", "-v", "error", "-i", path, "-map", "0:v:0",
              "-frames:v", "1", "-f", "null", "-" ],
            source_root: File.dirname(path)
          )
          duration
        rescue JSON::ParserError, KeyError, TypeError
          raise StoreError, "proof media is not valid decodable #{media_type}"
        end
        private_class_method :inspect_media!

        def inspect_visual_secrets!(path, media_type:, duration:)
          tesseract = Hive::InvokedBinary.which("tesseract")
          raise StoreError, "tesseract is required to inspect visual proof for secrets" unless tesseract

          text = if media_type.start_with?("video/")
            ffmpeg = Hive::InvokedBinary.which("ffmpeg")
            raise StoreError, "ffmpeg is required to inspect visual proof for secrets" unless ffmpeg

            Dir.mktmpdir("hive-proof-ocr") do |directory|
              pattern = File.join(directory, "frame-%03d.png")
              ocr_command(
                [ ffmpeg, "-nostdin", "-v", "error", "-i", path, "-vf",
                  "fps=1,scale=1280:-2", "-frames:v", MAX_VIDEO_DURATION_SECONDS.to_s,
                  pattern ],
                source_root: directory, failure: "proof video keyframe extraction failed"
              )
              frames = Dir.glob(File.join(directory, "frame-*.png")).sort
              if frames.empty?
                first = File.join(directory, "frame-001.png")
                ocr_command(
                  [ ffmpeg, "-nostdin", "-v", "error", "-i", path,
                    "-frames:v", "1", first ],
                  source_root: directory, failure: "proof video keyframe extraction failed"
                )
                frames = [ first ]
              end
              frames.map do |frame|
                ocr_command(
                  [ tesseract, frame, "stdout", "--psm", "11" ],
                  source_root: directory, failure: "proof visual secret inspection failed"
                )
              end.join("\n")
            end
          else
            ocr_command(
              [ tesseract, path, "stdout", "--psm", "11" ],
              source_root: File.dirname(path), failure: "proof visual secret inspection failed"
            )
          end
          reject_secrets!(text, "visual proof OCR")
        end
        private_class_method :inspect_visual_secrets!

        def ocr_command(argv, source_root:, failure:)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
          result = Hive::Web::ProjectCaptureProvider.capture_command_with_custody(
            argv: argv, source_root: source_root,
            environment: { "PATH" => ENV.fetch("PATH", "/usr/local/bin:/usr/bin:/bin") },
            deadline: deadline
          )
          status = result["status"] || {}
          unless !result["internal_error"] && !result["timed_out"] &&
                 !result["cleanup_failed"] && !result["stdout_overflow"] &&
                 !result["stderr_overflow"] && !result["leftover_processes"] &&
                 status["success"]
            raise StoreError, failure
          end
          result.fetch("stdout")
        rescue Hive::Web::ProjectCaptureProvider::ProviderError, SystemCallError
          raise StoreError, failure
        end
        private_class_method :ocr_command

        def media_command(argv, source_root:)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
          result = Hive::Web::ProjectCaptureProvider.capture_command_with_custody(
            argv: argv, source_root: source_root,
            environment: { "PATH" => ENV.fetch("PATH", "/usr/local/bin:/usr/bin:/bin") },
            deadline: deadline
          )
          status = result["status"] || {}
          unless !result["internal_error"] && !result["timed_out"] &&
                 !result["cleanup_failed"] && !result["stdout_overflow"] &&
                 !result["stderr_overflow"] && !result["leftover_processes"] &&
                 status["success"]
            raise StoreError, "proof media decode failed"
          end
          result.fetch("stdout")
        rescue Hive::Web::ProjectCaptureProvider::ProviderError, SystemCallError
          raise StoreError, "proof media decode failed"
        end
        private_class_method :media_command

        def validate_provider_originals!(source, representations, task_folder:)
          manifest = capture_manifest!(task_folder, source.fetch("manifest_path"))
          artifacts = manifest.fetch("artifacts").to_h do |artifact|
            [ File.join("media", artifact.fetch("file")), artifact ]
          end
          representations.select { |item| item.fetch("role") == "original" }.each do |item|
            artifact = artifacts[item.fetch("path")]
            unless artifact && artifact.values_at("bytes", "sha256") ==
                               item.values_at("bytes", "sha256")
              raise StoreError, "project-provider original is not bound by its capture manifest"
            end
          end
        end
        private_class_method :validate_provider_originals!

        def capture_manifest!(task_folder, relative)
          path, = retained_regular_file!(task_folder, relative)
          source = File.open(path, File::RDONLY | File::NOFOLLOW) do |file|
            value = file.read(Hive::ARTIFACT_CAPTURE_MANIFEST_MAX_BYTES + 1)
            if value.bytesize > Hive::ARTIFACT_CAPTURE_MANIFEST_MAX_BYTES
              raise StoreError, "project-provider capture manifest is oversized"
            end
            value
          end
          Document.parse(
            source, schema: "hive-artifact-capture", version: 2,
            label: "project-provider capture manifest"
          )
        end
        private_class_method :capture_manifest!

        def rendering_for(kind, role, media_type)
          return "original" if role == "original"
          return "supplemental" if role == "storyboard"
          return "temporal" if kind == "video"
          return "escaped_text" if media_type.start_with?("text/")

          "raster"
        end
        private_class_method :rendering_for

        def role_order(role)
          { "original" => 0, "review" => 1, "storyboard" => 2 }.fetch(role)
        end
        private_class_method :role_order

        def object!(value, label)
          raise StoreError, "#{label} must be an object" unless value.respond_to?(:to_h)

          value.to_h.transform_keys(&:to_s)
        end
        private_class_method :object!

        def reject_unknown!(object, allowed, label)
          unknown = object.keys - allowed
          raise StoreError, "#{label} contains unknown keys: #{unknown.sort.join(', ')}" unless unknown.empty?
        end
        private_class_method :reject_unknown!

        def bounded_text!(value, label, max_bytes)
          text = value.to_s
          unless text.bytesize.between?(1, max_bytes) && text.valid_encoding?
            raise StoreError, "#{label} is empty, invalid, or oversized"
          end
          text
        end
        private_class_method :bounded_text!

        def reject_secrets!(text, label)
          hits = Hive::SecretPatterns.scan(text)
          return if hits.empty?

          names = hits.map { |hit| hit.fetch(:name) }.uniq.join(", ")
          raise StoreError, "#{label} contains secret-shaped content: #{names}"
        end
        private_class_method :reject_secrets!
      end
    end
  end
end
