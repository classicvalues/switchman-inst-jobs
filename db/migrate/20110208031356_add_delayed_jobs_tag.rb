class AddDelayedJobsTag < ActiveRecord::Migration[4.2]
  def connection
    Delayed::Backend::ActiveRecord::AbstractJob.connection
  end

  def up
    add_column :delayed_jobs, :tag, :string
    add_index :delayed_jobs, [:tag]
  end

  def down
    remove_column :delayed_jobs, :tag
  end
end
