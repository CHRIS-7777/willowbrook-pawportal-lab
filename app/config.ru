require_relative 'app'

Clinic::DB.wait_and_prepare!

# keep the booking calendar rolling forward
Thread.new do
  loop do
    sleep 6 * 3600
    begin
      Clinic::DB.ensure_slots!
    rescue StandardError => e
      warn "[slots] refresh failed: #{e.message}"
    end
  end
end

run PawPortal
