# frozen_string_literal: true

module DiscourseMinicodNav
  class SnapshotRun < ActiveRecord::Base
    self.table_name = "minicod_nav_snapshot_runs"

    ACTIVE_STATUSES = %w[queued running].freeze
    TERMINAL_STATUSES = %w[completed error cancelled].freeze

    scope :active, -> { where(status: ACTIVE_STATUSES) }
  end
end
