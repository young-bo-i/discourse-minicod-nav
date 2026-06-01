# frozen_string_literal: true

module Jobs
  # Ack-and-defer counterpart to the webhook controller. The controller writes
  # the raw payload to a WebhookReceipt row with status='queued' and enqueues
  # this job; the heavy Synchronizer.process! call (PostCreator / PostRevisor /
  # cook / DiscourseTagging) runs here so upstream sees a sub-millisecond ack
  # and doesn't trigger its 1m → 6h backoff on slow-but-eventually-fine work.
  class MinicodNavProcessWebhook < ::Jobs::Base
    sidekiq_options queue: "low"

    MAX_RACE_RETRIES = 3

    def execute(args)
      receipt = DiscourseMinicodNav::WebhookReceipt.find_by(id: args[:receipt_id])
      return unless receipt
      return unless receipt.status.to_s == "queued"

      payload_raw = receipt.payload.to_s
      if payload_raw.blank?
        finalize!(receipt, status: "error", message: "missing payload", start_at: nil)
        return
      end

      start_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      attempts = 0

      begin
        attempts += 1
        payload = JSON.parse(payload_raw)
        result = DiscourseMinicodNav::Synchronizer.from_site_settings.process!(payload)
        finalize!(
          receipt,
          status: result[:skipped] ? "skipped" : "ok",
          message: nil,
          start_at: start_at,
        )
      rescue DiscourseMinicodNav::SyncError => e
        Rails.logger.warn("[minicodnav] sync error in job: #{e.message}")
        finalize!(receipt, status: "error", message: e.message, start_at: start_at)
      rescue JSON::ParserError => e
        finalize!(receipt, status: "error", message: "invalid json: #{e.message}", start_at: start_at)
      rescue ActiveRecord::RecordNotUnique => e
        # Concurrent webhooks can race on shared rows — most commonly the
        # Tag(name:) unique index when two journals share a keyword, or
        # ResourceMap(resource_id:) when created+updated for the same resource
        # land in parallel workers. Discourse's internal find_or_create paths
        # don't always recover; inline retry with jitter does, because the
        # race winner has already committed by the time we retry.
        if attempts < MAX_RACE_RETRIES
          delay = 0.1 + (attempts * 0.15) + rand(0.2)
          Rails.logger.info(
            "[minicodnav] record race in job (attempt #{attempts}/#{MAX_RACE_RETRIES}): " \
              "#{e.message.lines.first&.chomp}",
          )
          sleep(delay)
          retry
        end
        Rails.logger.warn(
          "[minicodnav] record race exhausted after #{attempts} attempts: #{e.message}",
        )
        finalize!(
          receipt,
          status: "error",
          message: "record race: #{e.message}",
          start_at: start_at,
        )
      rescue StandardError => e
        Rails.logger.error(
          "[minicodnav] internal error in job: #{e.class}: #{e.message}\n" \
            "#{e.backtrace&.first(12)&.join("\n")}",
        )
        finalize!(receipt, status: "error", message: "#{e.class}: #{e.message}", start_at: start_at)
      end
    end

    private

    def finalize!(receipt, status:, message:, start_at:)
      elapsed_ms =
        if start_at
          ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_at) * 1000).to_i
        else
          0
        end

      # Free payload bytes after successful processing; keep them on error so an
      # admin can inspect what came in or replay.
      payload_after =
        case status
        when "ok", "skipped"
          nil
        else
          receipt.payload
        end

      receipt.update!(
        status: status,
        error_message: message&.first(2000),
        duration_ms: elapsed_ms,
        processed_at: Time.zone.now,
        payload: payload_after,
      )
    end
  end
end
