# frozen_string_literal: true

class CreateMinicodNavTables < ActiveRecord::Migration[7.0]
  def change
    create_table :minicod_nav_resource_maps do |t|
      t.string :resource_id, limit: 64, null: false
      t.bigint :topic_id, null: false
      t.bigint :post_id, null: false
      t.integer :last_synced_version, null: false
      t.datetime :last_synced_at
      t.string :checksum, limit: 64
      t.timestamps
    end

    add_index :minicod_nav_resource_maps, :resource_id, unique: true
    add_index :minicod_nav_resource_maps, :topic_id, unique: true

    create_table :minicod_nav_webhook_receipts do |t|
      t.string :delivery_id, limit: 64, null: false
      t.datetime :created_at, null: false
    end
    add_index :minicod_nav_webhook_receipts, :delivery_id, unique: true
  end
end
