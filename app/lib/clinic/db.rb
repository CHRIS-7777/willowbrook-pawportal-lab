require 'mysql2'
require 'date'

module Clinic
  module DB
    SLOT_TIMES = %w[09:00 09:30 10:00 10:30 11:00 11:30 13:30 14:00 14:30 15:00 15:30 16:00 16:30].freeze

    module_function

    def config
      {
        host: ENV.fetch('DB_HOST', 'db'),
        port: ENV.fetch('DB_PORT', '3306').to_i,
        username: ENV.fetch('DB_USER', 'wb_portal'),
        password: ENV.fetch('DB_PASS', ''),
        database: ENV.fetch('DB_NAME', 'willowbrook'),
        encoding: 'utf8mb4',
        connect_timeout: 5
      }
    end

    def connect
      Mysql2::Client.new(config)
    end

    # Keeps a rolling window of bookable slots for every vet.
    def ensure_slots!(days = 45)
      c = connect
      vets = c.query('SELECT id FROM vets').map { |r| r['id'] }
      (0..days).each do |d|
        date = Date.today + d
        next if date.sunday?

        values = vets.flat_map { |v| SLOT_TIMES.map { |t| "(#{v.to_i},'#{date.iso8601}','#{t}:00',1)" } }
        next if values.empty?

        c.query("INSERT IGNORE INTO slots (vet_id, slot_date, slot_time, available) VALUES #{values.join(',')}")
      end
      c.close
      true
    end

    def wait_and_prepare!
      40.times do
        begin
          return ensure_slots!
        rescue Mysql2::Error => e
          warn "[boot] database not ready (#{e.message}) - retrying"
          sleep 2
        end
      end
      false
    end
  end
end
