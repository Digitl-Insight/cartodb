# encoding: utf-8

module Carto
  class UsersMetadataRedisCache

    DB_SIZE_IN_BYTES_EXPIRATION = 2.days

    UPDATE_PROPAGATION_THRESHOLD = 8.hours

    BATCH_SIZE = 100

    def initialize(redis_cache = $users_metadata)
      @redis = redis_cache
    end

    def update_if_old(user)
      if user.dashboard_viewed_at.nil? || user.dashboard_viewed_at < (Time.now.utc - UPDATE_PROPAGATION_THRESHOLD)
        set_db_size_in_bytes(user)
      end
    end

    def db_size_in_bytes(user)
      @redis.get(db_size_in_bytes_key(user.username)).to_i
    end

    def db_size_in_bytes_change_users
      keys = $users_metadata.scan_each(match: db_size_in_bytes_key('*')).to_a.uniq

      db_size_in_bytes_change_users = {}

      keys.each_slice(BATCH_SIZE) do |key_batch|
        usernames = key_batch.map { |key| extract_username_from_key(key) }
        db_size_in_bytes_change_users.merge!(Hash[usernames.zip($users_metadata.mget(key_batch).map(&:to_i))])
      end

      db_size_in_bytes_change_users
    end

    private

    def set_db_size_in_bytes(user)
      @redis.setex(db_size_in_bytes_key(user.username), DB_SIZE_IN_BYTES_EXPIRATION.to_i, user.db_size_in_bytes)
    end

    def db_size_in_bytes_key(username)
      "rails:users:#{username}:db_size_in_bytes"
    end

    def extract_username_from_key(key)
      /#{db_size_in_bytes_key('(.*)')}/.match(key)[1]
    end
  end
end
