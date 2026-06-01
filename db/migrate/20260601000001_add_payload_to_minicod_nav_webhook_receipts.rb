# frozen_string_literal: true

class AddPayloadToMinicodNavWebhookReceipts < ActiveRecord::Migration[7.0]
  def change
    add_column :minicod_nav_webhook_receipts, :payload, :text
    add_column :minicod_nav_webhook_receipts, :processed_at, :datetime
    add_index :minicod_nav_webhook_receipts,
              %i[status created_at],
              name: "idx_minicodnav_receipts_status_created"
  end
end
