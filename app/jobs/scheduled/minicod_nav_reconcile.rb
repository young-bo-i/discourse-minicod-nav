# frozen_string_literal: true

module Jobs
  # Catches two stuck states the ack-and-defer architecture introduces:
  #   1. WebhookReceipt rows that were committed with status='queued' but whose
  #      MinicodNavProcessWebhook Sidekiq job never executed (Redis was down
  #      when Discourse called Jobs.enqueue, worker crash after dequeue but
  #      before update, etc.). We re-enqueue everything queued > 5 minutes.
  #   2. SnapshotRun rows stuck in status='running' with no checkpoint
  #      progress for 30+ minutes. Likely a worker died mid-page. Mark them
  #      'error' so a new run can be queued; the operator can inspect the
  #      checkpointed next_offset to decide whether to resume.
  class MinicodNavReconcile < ::Jobs::Scheduled
    every 10.minutes

    QUEUED_RECEIPT_GRACE = 5.minutes
    STALLED_SNAPSHOT_GRACE = 30.minutes

    def execute(_args)
      return unless SiteSetting.minicodnav_plugin_enabled

      requeue_stuck_receipts
      mark_stalled_snapshot_runs
    end

    private

    def requeue_stuck_receipts
      cutoff = QUEUED_RECEIPT_GRACE.ago
      stuck = DiscourseMinicodNav::WebhookReceipt
        .where(status: "queued")
        .where("created_at < ?", cutoff)

      count = 0
      stuck.find_each(batch_size: 200) do |receipt|
        Rails.logger.warn(
          "[minicodnav] reconcile: re-enqueueing receipt id=#{receipt.id} " \
            "delivery=#{receipt.delivery_id} queued_at=#{receipt.created_at.iso8601}",
        )
        Jobs.enqueue(:minicod_nav_process_webhook, receipt_id: receipt.id)
        count += 1
      end

      Rails.logger.info("[minicodnav] reconcile: requeued #{count} stuck webhook receipts") if count.positive?
    end

    def mark_stalled_snapshot_runs
      cutoff = STALLED_SNAPSHOT_GRACE.ago
      stalled = DiscourseMinicodNav::SnapshotRun
        .where(status: "running")
        .where("updated_at < ?", cutoff)

      count = 0
      stalled.find_each(batch_size: 50) do |run|
        Rails.logger.warn(
          "[minicodnav] reconcile: marking stalled snapshot run id=#{run.id} " \
            "source=#{run.source} next_offset=#{run.next_offset} " \
            "last_progress_at=#{run.updated_at.iso8601}",
        )
        run.update!(
          status: "error",
          error_message: "marked by reconcile job: no checkpoint progress for #{STALLED_SNAPSHOT_GRACE.inspect}",
          finished_at: Time.zone.now,
        )
        count += 1
      end

      Rails.logger.info("[minicodnav] reconcile: marked #{count} stalled snapshot runs") if count.positive?
    end
  end
end
