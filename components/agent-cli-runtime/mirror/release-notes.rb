#!/usr/bin/env ruby
# frozen_string_literal: true

module AgentCliRuntimeMirrorReleaseNotes
  VERSION = /\Av\d+\.\d+\.\d+\z/

  module_function

  def run(arguments)
    version, changelog_path, output_path, *extra = arguments
    usage! unless version && changelog_path && output_path && extra.empty?
    abort "invalid version: #{version.inspect}" unless version.match?(VERSION)

    release_version = version.delete_prefix("v")
    highlights = extract_highlights(changelog_path, release_version)
    File.write(output_path, release_notes(release_version, highlights))
  end

  def usage!
    abort "usage: release-notes.rb VERSION CHANGELOG OUTPUT"
  end

  def extract_highlights(changelog_path, version)
    heading = "## #{version}"
    found = false
    lines = []

    File.foreach(changelog_path) do |line|
      title = line.chomp
      if !found && (title == heading || title.start_with?("#{heading} - "))
        found = true
        next
      end
      break if found && title.start_with?("## ")

      lines << line if found
    end

    abort "CHANGELOG.md has no section for #{version}" unless found

    first_content = lines.index { |line| line.match?(/[^\p{Space}]/) }
    abort "CHANGELOG.md section for #{version} has no content" unless first_content

    last_content = lines.rindex { |line| line.match?(/[^\p{Space}]/) }

    lines[first_content..last_content].join.chomp
  end

  def release_notes(version, highlights)
    <<~MARKDOWN
      Read-only source snapshot of the component release from the Hive monorepo.

      ## Highlights

      #{highlights}

      ## Install

      ```sh
      gem install agent-cli-runtime --version #{version}
      ```

      Canonical development and release authority remain in https://github.com/ivankuznetsov/hive.
    MARKDOWN
  end
end

if $PROGRAM_NAME == __FILE__
  AgentCliRuntimeMirrorReleaseNotes.run(ARGV)
end
