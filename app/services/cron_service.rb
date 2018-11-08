require 'json'
require 'socket'

class CronService
  attr_reader :session_store

  def initialize
    @session_store = new_session_store

    # check this is redis via duck typing
    redis.connected?
  end

  def logger
    Rails.logger
  end

  # Generate a lock identifier that communicates enough useful information for
  # debugging. We'll log this identifier when acquiring the lock.
  #
  # This identifier includes the hostname, PID, a random UUID, and the time.
  #
  # @return [String]
  #
  def generate_identifier
    {
      host: Socket.gethostname,
      pid: Process.pid,
      rand: SecureRandom.uuid,
      # rubocop:disable Rails/TimeZone -- using a zone with utc is dumb
      time: Time.now.utc,
      # rubocop:enable Rails/TimeZone
    }.to_json
  end

  # Call block if it hasn't run in the last +seconds+.
  #
  # @param [Integer] seconds The minimum number of seconds between runs.
  # @param [String] lock_label A label for the block that will be used as the
  #   key name for the lock recording the last run time.
  #
  # @example Run a job if it hasn't run in the last 5 minutes
  #   run_if_cron_due(lock_label: 'my-5min-job', seconds: 300) do
  #     do_the_thing
  #   end
  #
  def run_if_cron_due(lock_label:, seconds:)
    raise ArgumentError, 'must pass block' unless block_given?

    if acquire_lock(full_label: label_for(lock_label), expiration_seconds: seconds)
      logger.info("Running job for #{lock_label.inspect}")
      yield
    else
      logger.info("Job for #{lock_label.inspect} is not due to be run yet")
      false
    end
  end

  # Get the time remaining until the next run of the given job. This is
  # equivalent to the TTL remaining on the Redis key. The result may be
  # negative if the key does not exist or has no TTL.
  #
  # @param [String] lock_label A label for the job
  # @return [Integer]
  #
  def time_until_next_run(lock_label:)
    label = label_for(lock_label)
    logger.debug("Checking time until next run of #{label.inspect}")
    redis.ttl(label)
  end

  # Get the current holder of the lock for the given job.
  #
  # @param [String] lock_label A label for the job
  # @return [String, nil]
  #
  def get_current_lock_id(lock_label:)
    label = label_for(lock_label)
    logger.debug("Getting any current lock held for #{label.inspect}")
    redis.get(label)
  end

  # @return [Redis]
  def redis
    session_store.send(:redis)
  end

  private

  # Add the custom prefix to the lock label so it doesn't conflict with any
  # other Redis keys.
  def label_for(label)
    'cron-lock:' + label
  end

  def acquire_lock(full_label:, expiration_seconds:)
    logger.info("Attempting to acquire lock on #{full_label} for #{expiration_seconds} seconds")
    id = generate_identifier
    result = redis.set(full_label, id, ex: expiration_seconds, nx: true)

    if result
      logger.info("Acquired lock, id: #{id}")
    else
      logger.info('Failed to acquire lock')
      logger.info("Lock currently held by: #{redis.get(full_label)}")
    end

    result
  end

  def new_session_store
    config = Rails.application.config
    config.session_store.new({}, config.session_options)
  end
end
