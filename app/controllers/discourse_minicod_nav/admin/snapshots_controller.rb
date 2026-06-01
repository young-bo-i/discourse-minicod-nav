# frozen_string_literal: true

module DiscourseMinicodNav
  module Admin
    class SnapshotsController < ::Admin::AdminController
      requires_plugin "discourse-minicod-nav"

      ALLOWED_SOURCES = DiscourseMinicodNav::SnapshotFetcher::SOURCES

      def show
        source = params[:source].to_s
        unless ALLOWED_SOURCES.include?(source)
          return render json: { error: "invalid source" }, status: 400
        end

        latest = SnapshotRun.where(source: source).order(created_at: :desc).first
        render json: { run: serialize_run(latest) }
      end

      # Idempotent: returns the existing queued/running run if there is one,
      # otherwise creates a new one and enqueues the Sidekiq job. Multiple
      # admin clicks won't spawn parallel runs.
      def create
        source = params[:source].to_s
        unless ALLOWED_SOURCES.include?(source)
          return render json: { error: "invalid source" }, status: 400
        end

        active = SnapshotRun.where(source: source).active.first
        if active
          return render json: { run: serialize_run(active), reused: true }, status: 200
        end

        run = SnapshotRun.create!(source: source, status: "queued")
        Jobs.enqueue(:minicod_nav_run_snapshot, run_id: run.id)
        render json: { run: serialize_run(run), reused: false }, status: 202
      end

      private

      def serialize_run(run)
        return nil unless run

        {
          id: run.id,
          source: run.source,
          status: run.status,
          next_offset: run.next_offset,
          total_items: run.total_items,
          applied: run.applied,
          skipped: run.skipped,
          failed: run.failed,
          error_message: run.error_message,
          started_at: run.started_at,
          finished_at: run.finished_at,
          created_at: run.created_at,
        }
      end
    end
  end
end
