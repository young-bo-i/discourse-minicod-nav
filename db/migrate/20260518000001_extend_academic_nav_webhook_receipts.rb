# frozen_string_literal: true

class ExtendAcademicNavWebhookReceipts < ActiveRecord::Migration[7.0]
  def change
    add_column :academic_nav_webhook_receipts, :event, :string, limit: 50
    add_column :academic_nav_webhook_receipts, :resource_id, :bigint
    add_column :academic_nav_webhook_receipts, :status, :string, limit: 20
    add_column :academic_nav_webhook_receipts, :error_message, :text
    add_column :academic_nav_webhook_receipts, :duration_ms, :integer

    add_index :academic_nav_webhook_receipts, :created_at
    add_index :academic_nav_webhook_receipts, :status
  end
end
