# frozen_string_literal: true

module Jobs
  # Drives a SnapshotRun to completion in the background. Replaces the previous
  # admin-thread inline pull that would die on Puma worker timeout for any
  # non-trivial dataset and re-fetch from offset 0 on retry.
  #
  # Concurrency:
  #   - DistributedMutex per source serializes runs across workers; a second
  #     run for the same source waits for the first one's lock.
  #   - The job is safe to retry: it skips if the row is already terminal, and
  #     resumes from row.next_offset if it's still queued/running.
  class MinicodNavRunSnapshot < ::Jobs::Base
    sidekiq_options queue: "low"

    def execute(args)
      run = DiscourseMinicodNav::SnapshotRun.find_by(id: args[:run_id])
      return unless run
      return if DiscourseMinicodNav::SnapshotRun::TERMINAL_STATUSES.include?(run.status)

      DistributedMutex.synchronize("minicodnav_snapshot_#{run.source}", validity: 1.hour) do
        # Re-check after acquiring lock; another worker may have completed the run.
        run.reload
        return if DiscourseMinicodNav::SnapshotRun::TERMINAL_STATUSES.include?(run.status)

        run.update!(status: "running", started_at: run.started_at || Time.zone.now)

        begin
          DiscourseMinicodNav::SnapshotFetcher.new(source: run.source).run!(run)
          run.update!(status: "completed", finished_at: Time.zone.now, error_message: nil)
        rescue StandardError => e
          Rails.logger.error(
            "[minicodnav] snapshot run #{run.id} (#{run.source}) failed at " \
              "offset=#{run.next_offset}: #{e.class}: #{e.message}",
          )
          run.update!(
            status: "error",
            error_message: "#{e.class}: #{e.message}"[0, 2000],
            finished_at: Time.zone.now,
          )
          # Surface in admin UI; operator can re-enqueue to resume from
          # next_offset. Don't re-raise — Sidekiq retries would just bash the
          # same error and we already preserved checkpoint state.
        end
      end
    end
  end
end
