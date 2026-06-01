# frozen_string_literal: true

# Pull a snapshot for a source as a one-off run. Resumes any existing
# queued/running run for that source, otherwise creates a fresh one.
# Usage (inside the Discourse container):
#   SOURCE=pavlovia sudo -H -E -u discourse bash -lc \
#     'cd /var/www/discourse && bin/rails runner plugins/discourse-minicod-nav/scripts/pull_snapshot.rb'

source = ENV["SOURCE"].to_s
unless DiscourseMinicodNav::SnapshotFetcher::SOURCES.include?(source)
  puts "[minicodnav] SOURCE must be one of: #{DiscourseMinicodNav::SnapshotFetcher::SOURCES.join(", ")}"
  exit 1
end

run = DiscourseMinicodNav::SnapshotRun.where(source: source).active.first
if run
  puts "[minicodnav] resuming run id=#{run.id} from offset=#{run.next_offset}"
else
  run = DiscourseMinicodNav::SnapshotRun.create!(source: source, status: "queued")
  puts "[minicodnav] starting new run id=#{run.id}"
end

run.update!(status: "running", started_at: run.started_at || Time.zone.now)

begin
  DiscourseMinicodNav::SnapshotFetcher.new(source: source).run!(run)
  run.update!(status: "completed", finished_at: Time.zone.now, error_message: nil)
  puts "[minicodnav] snapshot #{source} done: applied=#{run.applied} skipped=#{run.skipped} failed=#{run.failed}"
rescue StandardError => e
  run.update!(status: "error", error_message: e.message[0, 2000], finished_at: Time.zone.now)
  puts "[minicodnav] snapshot #{source} failed at offset=#{run.next_offset}: #{e.message}"
  exit 2
end
