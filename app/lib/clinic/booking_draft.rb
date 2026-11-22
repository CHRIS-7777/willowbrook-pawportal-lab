require 'erb'
require 'base64'

module Clinic
  # A half-finished booking that the client can come back to later.
  # Persisted client-side so drafts survive across devices/sessions.
  class BookingDraft
    DEFAULT_REMINDER = 'Hi <%= owner %>, just a reminder that <%= pet %> is booked in with ' \
                       '<%= vet %> on <%= date %> at <%= time %>. Reply STOP to opt out of SMS reminders.'.freeze

    attr_accessor :owner_id, :pet_id, :vet_id, :slot_id, :date, :time, :reason, :reminder_template, :saved_at

    def initialize(attrs = {})
      attrs.each { |k, v| instance_variable_set("@#{k}", v) }
      @reminder_template ||= DEFAULT_REMINDER
      @saved_at ||= Time.now.to_i
    end

    def to_cookie
      Base64.urlsafe_encode64(Marshal.dump(self))
    end

    def self.from_cookie(value)
      Marshal.load(Base64.urlsafe_decode64(value.to_s.tr(' ', '+')))
    end

    # Renders the SMS reminder exactly as the client will receive it.
    def reminder_preview(owner:, pet:, vet:)
      date = @date
      time = @time
      ERB.new(@reminder_template.to_s).result(binding)
    end
  end
end
