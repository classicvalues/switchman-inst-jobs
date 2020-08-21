describe SwitchmanInstJobs::JobsMigrator do
  let(:shard1) { Switchman::Shard.create }

  before do
    # Since we can explicitly clear the cache, this makes specs run in a reasonable length of time
    described_class.instance_variable_set(:@skip_cache_wait, true)
    # Pin the default shard as a jobs shard to ensure the default shard is used as a jobs shard when it is active
    Switchman::Shard.default.delayed_jobs_shard_id = Switchman::Shard.default.id
    Switchman::Shard.default.save!
    shard1.delayed_jobs_shard_id = shard1.id
    shard1.save!
  end

  it "should move strand'd jobs, and not non-strand'd jobs" do
    # bad other specs for leaving stuff in here
    starting_count = Delayed::Job.count

    Switchman::Shard.activate(primary: shard1, delayed_jobs: Switchman::Shard.default) do
      expect(Switchman::Shard.current(:delayed_jobs)).to eq Switchman::Shard.default
      5.times { Kernel.send_later_enqueue_args(:sleep, { strand: 'strand1' }, 0.1) }
      6.times { Kernel.send_later_enqueue_args(:sleep, { strand: 'strand2' }, 0.2) }
      7.times { Kernel.send_later_enqueue_args(:sleep, {}, 0.3) }
    end
    4.times { Kernel.send_later_enqueue_args(:sleep, {}, 0.4) }

    shard1.activate(:primary, :delayed_jobs) do
      3.times { Kernel.send_later_enqueue_args(:sleep, { strand: 'strand1' }, 0.5) }
      expect(Delayed::Job.count).to eq 3
    end

    # 5 + 6 + 7 + 4
    expect(Delayed::Job.count).to eq starting_count + 22
    described_class.run
    # 4
    expect(Delayed::Job.count).to eq starting_count + 4

    shard1.activate(:delayed_jobs) do
      # 5 + 6 + 3 + 7
      expect(Delayed::Job.count).to eq 21
      # 0.1 jobs come before 0.5 jobs
      strand = Delayed::Job.where(strand: 'strand1')
      first_job = strand.next_in_strand_order.first
      expect(first_job.payload_object.args).to eq [0.1]
      # when the current running job on other shard finishes it will set next_in_strand
      expect(first_job.next_in_strand).to be_falsy
      expect(strand.where(next_in_strand: true).count).to eq 1
    end
  end

  it 'should create a blocker strand if a job is currently running' do
    Switchman::Shard.activate(primary: shard1, delayed_jobs: Switchman::Shard.default) do
      5.times { Kernel.send_later_enqueue_args(:sleep, { strand: 'strand1' }, 0.1) }
    end
    Delayed::Job.where(shard_id: shard1.id, strand: 'strand1').next_in_strand_order.first
      .update(locked_by: 'specs', locked_at: DateTime.now)

    expect(Delayed::Job.where(strand: 'strand1').count).to eq 5
    described_class.run
    # The currently running job is kept
    expect(Delayed::Job.count).to eq 1

    shard1.activate(:delayed_jobs) do
      strand = Delayed::Job.where(strand: 'strand1')
      # There should be the 4 non-running jobs + 1 blocker
      expect(strand.count).to eq 5
      first_job = strand.next_in_strand_order.first
      expect(first_job.source).to eq 'JobsMigrator::StrandBlocker'
      # when the current running job on other shard finishes it will set next_in_strand
      expect(first_job.next_in_strand).to be_falsy
      expect(strand.where(next_in_strand: true).count).to eq 0
    end
  end

  context 'before_move_callbacks' do
    it 'Should pass the original job record to a callback' do
      @old_job = nil
      # rubocop:todo Lint/UnusedBlockArgument
      described_class.add_before_move_callback(->(old_job:, new_job:) { @old_job = old_job })
      # rubocop:enable Lint/UnusedBlockArgument
      Switchman::Shard.activate(primary: shard1, delayed_jobs: Switchman::Shard.default) do
        Kernel.send_later_enqueue_args(:sleep, strand: 'strand', no_delay: true)
      end
      described_class.run
      expect(@old_job.shard).to eq(Switchman::Shard.default)
    end

    it 'Should pass the new job record to a callback' do
      @new_job = nil
      # rubocop:todo Lint/UnusedBlockArgument
      described_class.add_before_move_callback(->(old_job:, new_job:) { @new_job = new_job })
      # rubocop:enable Lint/UnusedBlockArgument
      Switchman::Shard.activate(primary: shard1, delayed_jobs: Switchman::Shard.default) do
        Kernel.send_later_enqueue_args(:sleep, strand: 'strand', no_delay: true)
      end
      described_class.run
      expect(@new_job.shard).to eq(shard1)
    end

    it 'Should call before the new job record is saved' do
      @new_job = nil
      # rubocop:todo Lint/UnusedBlockArgument
      described_class.add_before_move_callback(->(old_job:, new_job:) { @new_job = new_job })
      # rubocop:enable Lint/UnusedBlockArgument
      Switchman::Shard.activate(primary: shard1, delayed_jobs: Switchman::Shard.default) do
        Kernel.send_later_enqueue_args(:sleep, strand: 'strand', no_delay: true)
      end
      described_class.run
      expect(@new_job.new_record?).to be true
    end
  end
end
