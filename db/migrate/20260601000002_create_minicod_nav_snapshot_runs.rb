# frozen_string_literal: true

class CreateMinicodNavSnapshotRuns < ActiveRecord::Migration[7.0]
  def change
    create_table :minicod_nav_snapshot_runs do |t|
      t.string :source, limit: 16, null: false
      t.string :status, limit: 16, null: false, default: "queued"
      t.integer :next_offset, null: false, default: 0
      t.integer :total_items
      t.integer :applied, null: false, default: 0
      t.integer :skipped, null: false, default: 0
      t.integer :failed, null: false, default: 0
      t.text :error_message
      t.datetime :started_at
      t.datetime :finished_at
      t.timestamps
    end

    add_index :minicod_nav_snapshot_runs, %i[source status]
    add_index :minicod_nav_snapshot_runs, :created_at
  end
end
