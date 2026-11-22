/*!
 * Willowbrook PawPortal - front-end helpers
 * v2.3.1
 */
(function ($) {
  'use strict';

  // Footer status indicator
  function refreshStatus() {
    $.getJSON('/api/v1/health')
      .done(function (d) {
        $('#portal-status').text('Portal online · v' + d.version).addClass('ok');
      })
      .fail(function () {
        $('#portal-status').text('Portal status unavailable').addClass('down');
      });
  }

  // Booking form: load free slots for the selected vet + date
  function loadSlots() {
    var vet = $('#vet_id').val(), date = $('#date').val(), $slot = $('#slot_id');
    if (!vet || !date) { return; }
    $slot.prop('disabled', true).html('<option value="">Loading available times…</option>');
    $.getJSON('/api/v1/slots', { vet_id: vet, date: date })
      .done(function (rows) {
        $slot.empty();
        if (!rows.length) {
          $slot.append('<option value="">No free times on this day - try another date</option>');
        } else {
          $.each(rows, function (_, r) {
            $slot.append($('<option>').val(r.id).text(r.time + ' – ' + r.vet));
          });
          var pre = $slot.data('selected');
          if (pre) { $slot.val(String(pre)); }
        }
        $slot.prop('disabled', false);
      })
      .fail(function () {
        $slot.html('<option value="">Could not load times - please refresh</option>');
      });
  }

  // Account page: profile is saved through the JSON API
  function bindProfileForm() {
    $('#profile-form').on('submit', function (e) {
      e.preventDefault();
      var payload = { full_name: $('#full_name').val(), phone: $('#phone').val() };
      $.ajax({ url: '/api/v1/me', method: 'PATCH', contentType: 'application/json', data: JSON.stringify(payload) })
        .done(function () {
          $('#profile-msg').removeClass('text-danger').addClass('text-success').text('Profile saved.');
        })
        .fail(function (xhr) {
          $('#profile-msg').removeClass('text-success').addClass('text-danger').text('Could not save profile (' + xhr.status + ').');
        });
    });
  }

  /*
   * Staff roster widget - parked until the reception kiosk rollout (WB-412).
   * The kiosk build authenticates with the shared clinic key, not a user session.
   *
   * var CLINIC_KEY = 'wbk_live_5d0e8a7c41f94b2e9c3a';
   * function loadRoster() {
   *   $.ajax({ url: '/api/v1/staff/roster', headers: { 'X-Clinic-Key': CLINIC_KEY } })
   *     .done(function (rows) { renderRoster(rows); });
   * }
   */

  $(function () {
    refreshStatus();
    if ($('#booking-form').length) {
      $('#vet_id, #date').on('change', loadSlots);
      loadSlots();
    }
    bindProfileForm();
  });
})(jQuery);
