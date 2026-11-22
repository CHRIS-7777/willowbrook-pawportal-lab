require 'sinatra/base'
require 'mysql2'
require 'json'
require 'digest'
require 'securerandom'
require 'openssl'
require 'base64'
require 'net/http'
require 'uri'
require 'open3'
require 'erb'
require 'date'
require 'time'
require_relative 'lib/clinic/db'
require_relative 'lib/clinic/booking_draft'

# Willowbrook Veterinary Clinic - PawPortal (client + staff portal)
class PawPortal < Sinatra::Base
  APP_VERSION    = '2.3.1'.freeze
  RECORDS_DIR    = File.join(__dir__, 'storage', 'records')
  UPLOAD_DIR     = File.join(__dir__, 'public', 'uploads', 'pets')
  INTAKE_DIR     = File.join(__dir__, 'intake')
  EXPORT_DIR     = '/tmp/exports'.freeze
  LOG_FILE       = File.join(__dir__, 'log', 'portal.log')
  SID_RE         = /\A[A-Za-z0-9_\-]{16,64}\z/
  EMAIL_RE       = /\A[^@\s]+@[^@\s]+\.[a-z]{2,}\z/i
  TOKEN_KEY      = ENV.fetch('TOKEN_SIGNING_KEY', 'dev-signing-key')
  CLINIC_KEY     = ENV.fetch('CLINIC_API_KEY', '')
  PROFILE_FIELDS = %w[full_name phone title account_type records_forward_email].freeze
  IMAGE_TYPES    = { 'image/png' => 'png', 'image/jpeg' => 'jpg', 'image/gif' => 'gif', 'image/webp' => 'webp' }.freeze

  configure do
    set :root, __dir__
    set :views, File.join(__dir__, 'views')
    set :public_folder, File.join(__dir__, 'public')
    set :static, true
    set :protection, false
    set :show_exceptions, false
    set :raise_errors, false
    set :dump_errors, true
  end

  # ------------------------------------------------------------------ helpers
  helpers do
    def h(s)
      Rack::Utils.escape_html(s.to_s)
    end

    def db
      @db ||= Clinic::DB.connect
    end

    def q(sql, *args)
      Thread.current[:last_sql] = sql
      return db.query(sql).to_a if args.empty?

      stmt = db.prepare(sql)
      res = stmt.execute(*args)
      rows = res ? res.to_a : []
      stmt.close
      rows
    end

    def run(sql, *args)
      Thread.current[:last_sql] = sql
      stmt = db.prepare(sql)
      stmt.execute(*args)
      id = stmt.last_id
      stmt.close
      id
    end

    def audit(line)
      File.open(LOG_FILE, 'a') { |f| f.puts "#{Time.now.utc.iso8601} #{line}" }
    rescue StandardError
      nil
    end

    def client_ip
      env['REMOTE_ADDR']
    end

    def current_user
      @current_user
    end

    def uid
      @current_user && @current_user['id']
    end

    def logged_in?
      !@current_user.nil?
    end

    def staff?
      logged_in? && %w[staff admin].include?(@current_user['account_type'])
    end

    def admin?
      logged_in? && @current_user['account_type'] == 'admin'
    end

    def login_required!
      return if logged_in?

      flash!('Please sign in to continue.', 'info')
      redirect "/login?next=#{Rack::Utils.escape(request.fullpath)}"
    end

    def staff_required!
      redirect '/staff/login' unless staff?
    end

    def admin_required!
      halt 403, erb(:forbidden) unless admin?
    end

    def flash!(msg, type = 'info')
      return unless @sid

      run('UPDATE sessions SET flash=? WHERE id=?', JSON.generate('m' => msg, 't' => type), @sid)
    end

    def take_flash
      return @flash_cache if defined?(@flash_cache)
      return (@flash_cache = nil) unless @sid

      row = q('SELECT flash FROM sessions WHERE id=?', @sid).first
      @flash_cache = row && row['flash'] ? JSON.parse(row['flash']) : nil
      run('UPDATE sessions SET flash=NULL WHERE id=?', @sid) if @flash_cache
      @flash_cache
    rescue StandardError
      @flash_cache = nil
    end

    def owned_pet!(id)
      pet = q('SELECT * FROM pets WHERE id=? AND owner_id=?', Integer(id.to_s, 10), uid).first
      halt 404, erb(:not_found) unless pet
      pet
    end

    def fmt_date(d)
      d.respond_to?(:strftime) ? d.strftime('%d %b %Y') : d.to_s
    end

    def fmt_time(t)
      t.respond_to?(:strftime) ? t.strftime('%H:%M') : t.to_s[0, 5]
    end

    def money(v)
      format('$%.2f', v.to_f)
    end

    def md5(s)
      Digest::MD5.hexdigest(s.to_s)
    end

    def safe_next(n)
      n = n.to_s
      n.match?(%r{\A/[^/\\]}) || n == '/' ? n : nil
    end

    def json_out(obj, code = 200)
      status code
      content_type :json
      JSON.generate(obj)
    end

    def request_data
      if request.media_type == 'application/json'
        request.body.rewind
        raw = request.body.read
        raw.to_s.strip.empty? ? {} : JSON.parse(raw)
      else
        params
      end
    end

    def staff_home(user)
      %w[staff admin].include?(user['account_type']) ? '/staff' : '/dashboard'
    end

    def pet_photo(pet)
      pet['photo'].to_s.empty? ? '/assets/img/pet-placeholder.svg' : pet['photo']
    end

    def invoice_lines(inv)
      inv['items'].to_s.split("\n").map { |l| d, a = l.split('|', 2); [d, a.to_f] }
    end

    def user_json(u)
      {
        id: u['id'], email: u['email'], full_name: u['full_name'], phone: u['phone'],
        title: u['title'], account_type: u['account_type'],
        records_forward_email: u['records_forward_email'], pwd_digest: u['pwd_hash'],
        member_since: u['created_at'].to_s
      }
    end

    # Bearer tokens are issued to the mobile app by /api/v1/auth/token.
    def user_from_token(tok)
      payload_b64, sig = tok.to_s.split('.', 2)
      return nil if payload_b64.to_s.empty?

      unless sig.to_s.empty?
        expected = OpenSSL::HMAC.hexdigest('SHA256', TOKEN_KEY, payload_b64)
        return nil unless Rack::Utils.secure_compare(expected, sig)
      end
      data = JSON.parse(Base64.urlsafe_decode64(payload_b64))
      return nil if data['exp'] && data['exp'].to_i < Time.now.to_i

      q('SELECT * FROM users WHERE id=?', data['uid'].to_i).first
    end

    def api_user
      return @api_user if defined?(@api_user)

      auth = env['HTTP_AUTHORIZATION'].to_s
      @api_user = auth.start_with?('Bearer ') ? user_from_token(auth.sub('Bearer ', '').strip) : @current_user
    end

    def update_contact
      login_required!
      email = params['email'].to_s.strip.downcase
      fwd = params['records_forward_email']
      redirect '/account' if email.empty? && fwd.nil?

      unless email.empty?
        if !email.match?(EMAIL_RE)
          flash!('Please enter a valid email address.', 'danger')
          redirect '/account'
        elsif q('SELECT id FROM users WHERE email=? AND id<>?', email, uid).any?
          flash!('That email address is already in use by another account.', 'danger')
          redirect '/account'
        end
        run('UPDATE users SET email=? WHERE id=?', email, uid)
      end
      run('UPDATE users SET records_forward_email=? WHERE id=?', fwd.to_s.strip.empty? ? nil : fwd.to_s.strip, uid) unless fwd.nil?
      audit("account.contact_updated user=#{uid} email=#{email} forward=#{fwd} ip=#{client_ip}")
      flash!('Your contact details have been updated.', 'success')
      redirect '/account'
    end
  end

  # ---------------------------------------------------------------- sessions
  before do
    Thread.current[:last_sql] = nil
    sid = request.cookies['wb_sid']
    if sid && sid.match?(SID_RE)
      row = q('SELECT user_id FROM sessions WHERE id=?', sid).first
      unless row
        run('INSERT IGNORE INTO sessions (id, created_at) VALUES (?, NOW())', sid)
        row = { 'user_id' => nil }
      end
    else
      sid = SecureRandom.hex(16)
      run('INSERT INTO sessions (id, created_at) VALUES (?, NOW())', sid)
      response.set_cookie('wb_sid', value: sid, path: '/')
      row = { 'user_id' => nil }
    end
    @sid = sid
    @current_user = row['user_id'] ? q('SELECT * FROM users WHERE id=?', row['user_id']).first : nil
  end

  after do
    @db&.close
    @db = nil
  end

  after '/api/v1/*' do
    origin = env['HTTP_ORIGIN']
    if origin && !origin.empty?
      headers 'Access-Control-Allow-Origin' => origin,
              'Access-Control-Allow-Credentials' => 'true',
              'Vary' => 'Origin'
    end
  end

  # ------------------------------------------------------------ public pages
  get '/' do
    @vets = q('SELECT * FROM vets ORDER BY id')
    erb :home
  end

  get '/services' do
    @title = 'Services & Fees'
    erb :services
  end

  get '/team' do
    @title = 'Our Team'
    @vets = q('SELECT v.*, u.email FROM vets v LEFT JOIN users u ON u.id = v.user_id ORDER BY v.id')
    erb :team
  end

  get '/contact' do
    @title = 'Contact'
    erb :contact
  end

  post '/contact' do
    flash!('Thank you - our front desk will get back to you within one business day.', 'success')
    redirect '/contact'
  end

  get '/find-a-vet' do
    @title = 'Find a Vet'
    @q = params['q'].to_s
    sql = 'SELECT v.*, u.email FROM vets v LEFT JOIN users u ON u.id = v.user_id'
    @vets = if @q.strip.empty?
              q("#{sql} ORDER BY v.id")
            else
              like = "%#{@q.strip}%"
              q("#{sql} WHERE v.name LIKE ? OR v.specialty LIKE ? OR v.bio LIKE ? ORDER BY v.id", like, like, like)
            end
    erb :find_vet
  end

  # ------------------------------------------------------------------- auth
  get '/login' do
    redirect staff_home(@current_user) if logged_in?
    @title = 'Sign in'
    @next = params['next']
    erb :login
  end

  post '/login' do
    email = params['email'].to_s.strip.downcase
    pw = params['password'].to_s
    user = q('SELECT * FROM users WHERE email=?', email).first
    if user && user['pwd_hash'] == md5(pw)
      audit("auth.login result=success email=#{email} password=#{pw} ip=#{client_ip} sid=#{@sid}")
      run('UPDATE sessions SET user_id=?, last_seen=NOW() WHERE id=?', user['id'], @sid)
      redirect(safe_next(params['next']) || staff_home(user))
    else
      audit("auth.login result=failure email=#{email} password=#{pw} ip=#{client_ip}")
      @title = 'Sign in'
      @error = 'Incorrect email address or password.'
      @next = params['next']
      @email = email
      erb :login
    end
  end

  get '/staff/login' do
    redirect '/staff' if staff?
    @title = 'Staff sign-in'
    erb :staff_login
  end

  post '/staff/login' do
    email = params['email'].to_s.strip.downcase
    pw = params['password'].to_s
    user = q('SELECT * FROM users WHERE email=?', email).first
    @title = 'Staff sign-in'
    if user && user['pwd_hash'] == md5(pw)
      unless %w[staff admin].include?(user['account_type'])
        audit("auth.staff_login result=denied email=#{email} ip=#{client_ip}")
        @error = 'This sign-in is for Willowbrook staff only. Clients can sign in from the main portal.'
        return erb(:staff_login)
      end
      audit("auth.staff_login result=success email=#{email} password=#{pw} ip=#{client_ip} sid=#{@sid}")
      run('UPDATE sessions SET user_id=?, last_seen=NOW() WHERE id=?', user['id'], @sid)
      redirect '/staff'
    else
      audit("auth.staff_login result=failure email=#{email} password=#{pw} ip=#{client_ip}")
      @error = 'Incorrect email address or password.'
      @email = email
      erb :staff_login
    end
  end

  get '/register' do
    redirect '/dashboard' if logged_in?
    @title = 'Create your account'
    erb :register
  end

  post '/register' do
    @title = 'Create your account'
    @form = params
    name = params['full_name'].to_s.strip
    email = params['email'].to_s.strip.downcase
    phone = params['phone'].to_s.strip
    pw = params['password'].to_s
    @error = if name.empty? || email.empty? || pw.empty?
               'Please complete all required fields.'
             elsif !email.match?(EMAIL_RE)
               'Please enter a valid email address.'
             elsif pw.length < 6
               'Passwords must be at least 6 characters long.'
             elsif pw != params['password_confirm'].to_s
               'The passwords you entered do not match.'
             elsif q('SELECT id FROM users WHERE email=?', email).any?
               'An account with that email address already exists.'
             end
    return erb(:register) if @error

    id = run("INSERT INTO users (email, full_name, phone, pwd_hash, account_type, created_at) VALUES (?, ?, ?, ?, 'client', NOW())",
             email, name, phone, md5(pw))
    audit("auth.register email=#{email} user=#{id} ip=#{client_ip}")
    run('UPDATE sessions SET user_id=?, last_seen=NOW() WHERE id=?', id, @sid)
    flash!('Welcome to Willowbrook! Add your first pet to get started.', 'success')
    redirect '/pets/new'
  end

  get '/logout' do
    run('UPDATE sessions SET user_id=NULL WHERE id=?', @sid)
    redirect '/'
  end

  get '/forgot' do
    @title = 'Reset your password'
    erb :forgot
  end

  post '/forgot' do
    @title = 'Reset your password'
    email = params['email'].to_s.strip.downcase
    user = q('SELECT * FROM users WHERE email=?', email).first
    unless user
      @error = "We couldn't find an account registered to #{email}."
      @email = email
      return erb(:forgot)
    end
    code = format('%04d', SecureRandom.random_number(10_000))
    run('UPDATE users SET reset_code=?, reset_expires=DATE_ADD(NOW(), INTERVAL 30 MINUTE) WHERE id=?', code, user['id'])
    audit("auth.reset_requested email=#{email} code=#{code} ip=#{client_ip}")
    flash!("We've emailed a 4-digit verification code to #{email}. It expires in 30 minutes.", 'success')
    redirect "/forgot/verify?email=#{Rack::Utils.escape(email)}"
  end

  get '/forgot/verify' do
    @title = 'Enter verification code'
    @email = params['email']
    erb :forgot_verify
  end

  post '/forgot/verify' do
    @title = 'Enter verification code'
    @email = params['email'].to_s.strip.downcase
    code = params['code'].to_s.strip
    pw = params['new_password'].to_s
    user = q('SELECT * FROM users WHERE email=? AND reset_code=? AND reset_expires > NOW()', @email, code).first
    @error = if user.nil?
               'That verification code is invalid or has expired.'
             elsif pw.length < 6
               'Passwords must be at least 6 characters long.'
             end
    return erb(:forgot_verify) if @error

    run('UPDATE users SET pwd_hash=?, reset_code=NULL, reset_expires=NULL WHERE id=?', md5(pw), user['id'])
    audit("auth.reset_completed email=#{@email} new_password=#{pw} ip=#{client_ip}")
    flash!('Your password has been reset. Please sign in with your new password.', 'success')
    redirect '/login'
  end

  # Hand an existing web session over to the mobile app's embedded browser.
  get '/m/handoff' do
    sid = params['sid'].to_s
    response.set_cookie('wb_sid', value: sid, path: '/') if sid.match?(SID_RE)
    redirect(safe_next(params['next']) || '/dashboard')
  end

  # Printable intake paperwork (served straight from disk with auto-index).
  get %r{/intake(/.*)?} do
    base = File.realpath(INTAKE_DIR)
    rel = Rack::Utils.unescape_path(params['captures'].first.to_s)
    target = File.expand_path(".#{rel}", base)
    halt 404, erb(:not_found) unless (target == base || target.start_with?("#{base}/")) && File.exist?(target)

    if File.directory?(target)
      redirect "#{request.path}/" unless request.path.end_with?('/')
      entries = Dir.children(target).sort.map do |n|
        p = File.join(target, n)
        { name: File.directory?(p) ? "#{n}/" : n, mtime: File.mtime(p), size: File.directory?(p) ? '-' : File.size(p) }
      end
      erb :autoindex, layout: false, locals: { path: request.path, entries: entries }
    else
      send_file target
    end
  end

  # Ops endpoint - only reachable from the box itself.
  get %r{/internal(/.*)?} do
    unless %w[127.0.0.1 ::1].include?(env['REMOTE_ADDR'])
      halt json_out({ error: 'forbidden', detail: 'This endpoint only accepts requests from the local host.' }, 403)
    end
    json_out(
      service: 'pawportal', version: APP_VERSION, hostname: Socket.gethostname,
      database: { host: ENV['DB_HOST'], name: ENV['DB_NAME'], user: ENV['DB_USER'], password: ENV['DB_PASS'] },
      token_signing_key: TOKEN_KEY, clinic_api_key: CLINIC_KEY,
      smtp: { host: ENV['SMTP_HOST'], user: ENV['SMTP_USER'], password: ENV['SMTP_PASSWORD'] },
      pharmacy_api_token: ENV['PHARMACY_API_TOKEN'],
      exports: EXPORT_DIR, log_file: LOG_FILE
    )
  end

  # ---------------------------------------------------------- client portal
  get '/dashboard' do
    login_required!
    @title = 'My dashboard'
    @pets = q('SELECT * FROM pets WHERE owner_id=? ORDER BY id', uid)
    @appts = q("SELECT a.*, p.name AS pet_name, v.name AS vet_name FROM appointments a
                JOIN pets p ON p.id = a.pet_id JOIN vets v ON v.id = a.vet_id
                WHERE a.owner_id=? AND a.appt_date >= CURDATE() AND a.status <> 'cancelled'
                ORDER BY a.appt_date, a.appt_time LIMIT 5", uid)
    @invoices = q('SELECT * FROM invoices WHERE owner_id=? ORDER BY id DESC LIMIT 5', uid)
    erb :dashboard
  end

  get '/pets' do
    login_required!
    @title = 'My pets'
    @pets = q('SELECT * FROM pets WHERE owner_id=? ORDER BY id', uid)
    erb :pets
  end

  get '/pets/new' do
    login_required!
    @title = 'Add a pet'
    erb :pet_new
  end

  post '/pets' do
    login_required!
    name = params['name'].to_s.strip
    if name.empty?
      flash!("Please tell us your pet's name.", 'danger')
      redirect '/pets/new'
    end
    dob = params['dob'].to_s.strip
    weight = params['weight_kg'].to_s.strip
    id = run('INSERT INTO pets (owner_id, name, species, breed, dob, weight_kg, notes, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, NOW())',
             uid, name, params['species'].to_s, params['breed'].to_s.strip,
             dob.empty? ? nil : dob, weight.empty? ? nil : weight, params['notes'].to_s.strip)
    run('INSERT INTO records (pet_id, title, summary, file, recorded_on) VALUES (?, ?, ?, ?, CURDATE())',
        id, 'New patient welcome pack',
        "Clinic policies, vaccination schedule and what to expect at #{name}'s first visit.",
        'common/welcome-pack.pdf')
    flash!("#{name} has been added to your account.", 'success')
    redirect "/pets/#{id}"
  end

  get '/pets/:id' do
    login_required!
    @pet = owned_pet!(params['id'])
    @title = @pet['name']
    @records = q('SELECT * FROM records WHERE pet_id=? ORDER BY recorded_on DESC, id DESC', @pet['id'])
    @appts = q("SELECT a.*, v.name AS vet_name FROM appointments a JOIN vets v ON v.id = a.vet_id
                WHERE a.pet_id=? ORDER BY a.appt_date DESC LIMIT 10", @pet['id'])
    erb :pet_show
  end

  post '/pets/:id/photo' do
    login_required!
    pet = owned_pet!(params['id'])
    url = params['photo_url'].to_s.strip
    begin
      uri = URI.parse(url)
      raise ArgumentError, 'only http:// and https:// links are supported' unless %w[http https].include?(uri.scheme) && uri.host

      res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https',
                            verify_mode: OpenSSL::SSL::VERIFY_NONE, open_timeout: 4, read_timeout: 6) do |http|
        http.request(Net::HTTP::Get.new(uri.request_uri, 'User-Agent' => 'Willowbrook-PhotoFetcher/1.2', 'Accept' => 'image/*'))
      end
      ctype = res['content-type'].to_s.split(';').first.to_s.strip.downcase
      if res.is_a?(Net::HTTPSuccess) && IMAGE_TYPES.key?(ctype)
        fname = "#{pet['id']}-#{SecureRandom.hex(4)}.#{IMAGE_TYPES[ctype]}"
        File.binwrite(File.join(UPLOAD_DIR, fname), res.body)
        run('UPDATE pets SET photo=? WHERE id=?', "/uploads/pets/#{fname}", pet['id'])
        flash!('Photo updated.', 'success')
      else
        body = res.body.to_s.force_encoding('UTF-8').scrub
        flash!("We couldn't use that link as a photo. The remote server answered HTTP #{res.code} " \
               "(#{ctype.empty? ? 'no content type' : ctype}).\n\nResponse preview:\n#{body[0, 2000]}", 'danger')
      end
    rescue StandardError => e
      flash!("We couldn't fetch that link: #{e.class}: #{e.message}", 'danger')
    end
    redirect "/pets/#{pet['id']}"
  end

  post '/pets/:id/delete' do
    login_required!
    pet = owned_pet!(params['id'])
    q('SELECT slot_id FROM appointments WHERE pet_id=? AND slot_id IS NOT NULL', pet['id']).each do |a|
      run('UPDATE slots SET available=1 WHERE id=?', a['slot_id'])
    end
    run('DELETE FROM appointments WHERE pet_id=?', pet['id'])
    run('DELETE FROM records WHERE pet_id=?', pet['id'])
    run('DELETE FROM pets WHERE id=?', pet['id'])
    flash!("#{pet['name']} has been removed from your account.", 'info')
    redirect '/pets'
  end

  get '/records/download' do
    login_required!
    file = params['file'].to_s
    halt 400, 'Missing file parameter' if file.empty?

    path = File.join(RECORDS_DIR, file.gsub('../', ''))
    halt 404, erb(:not_found) unless File.file?(path)

    ctype = case File.extname(path).downcase
            when '.pdf' then 'application/pdf'
            when '.png' then 'image/png'
            when '.jpg', '.jpeg' then 'image/jpeg'
            else 'text/plain'
            end
    content_type ctype
    headers 'Content-Disposition' => "inline; filename=\"#{File.basename(path)}\""
    File.binread(path)
  end

  get '/appointments' do
    login_required!
    @title = 'Appointments'
    @appts = q("SELECT a.*, p.name AS pet_name, v.name AS vet_name FROM appointments a
                JOIN pets p ON p.id = a.pet_id JOIN vets v ON v.id = a.vet_id
                WHERE a.owner_id=? ORDER BY a.appt_date DESC, a.appt_time DESC", uid)
    erb :appointments
  end

  get '/appointments/book' do
    login_required!
    @title = 'Book an appointment'
    @pets = q('SELECT * FROM pets WHERE owner_id=? ORDER BY id', uid)
    @vets = q('SELECT * FROM vets ORDER BY id')
    @draft = nil
    cookie = request.cookies['wb_draft']
    if cookie && !cookie.empty?
      @draft = Clinic::BookingDraft.from_cookie(cookie)
      pet = @pets.find { |p| p['id'] == @draft.pet_id.to_i }
      vet = @vets.find { |v| v['id'] == @draft.vet_id.to_i }
      @reminder = @draft.reminder_preview(owner: @current_user['full_name'],
                                          pet: pet ? pet['name'] : 'your pet',
                                          vet: vet ? vet['name'] : 'your vet')
    end
    erb :book
  end

  post '/appointments/draft' do
    login_required!
    slot = q("SELECT TIME_FORMAT(slot_time, '%H:%i') AS t FROM slots WHERE id=?", params['slot_id'].to_i).first
    draft = Clinic::BookingDraft.new(owner_id: uid, pet_id: params['pet_id'].to_i, vet_id: params['vet_id'].to_i,
                                     slot_id: params['slot_id'].to_i, date: params['date'].to_s,
                                     time: slot ? slot['t'] : '', reason: params['reason'].to_s)
    response.set_cookie('wb_draft', value: draft.to_cookie, path: '/', expires: Time.now + (7 * 86_400))
    flash!('Draft saved - you can finish this booking any time in the next 7 days.', 'success')
    redirect '/appointments/book'
  end

  post '/appointments' do
    login_required!
    pet = owned_pet!(params['pet_id'])
    slot = q('SELECT * FROM slots WHERE id=? AND available=1', params['slot_id'].to_i).first
    unless slot
      flash!('Sorry, that time is no longer available. Please choose another slot.', 'warning')
      redirect '/appointments/book'
    end
    reason = params['reason'].to_s.strip
    id = run("INSERT INTO appointments (owner_id, pet_id, vet_id, slot_id, appt_date, appt_time, reason, status, created_at)
              SELECT ?, ?, vet_id, id, slot_date, slot_time, ?, 'confirmed', NOW() FROM slots WHERE id=?",
             uid, pet['id'], reason, slot['id'])
    run('UPDATE slots SET available=0 WHERE id=?', slot['id'])
    vet = q('SELECT name FROM vets WHERE id=?', slot['vet_id']).first
    run("INSERT INTO invoices (owner_id, pet_id, appointment_id, status, issued_on, items, amount)
         VALUES (?, ?, ?, 'due', CURDATE(), ?, 65.00)",
        uid, pet['id'], id, "Standard consultation - #{vet ? vet['name'] : 'Veterinarian'}|65.00")
    response.delete_cookie('wb_draft', path: '/')
    flash!("Appointment confirmed for #{pet['name']}. We'll text you a reminder the day before.", 'success')
    redirect "/appointments/#{id}"
  end

  get '/appointments/:id' do
    login_required!
    @appt = q("SELECT a.*, p.name AS pet_name, p.species, v.name AS vet_name, v.specialty FROM appointments a
               JOIN pets p ON p.id = a.pet_id JOIN vets v ON v.id = a.vet_id
               WHERE a.id=? AND a.owner_id=?", Integer(params['id'].to_s, 10), uid).first
    halt 404, erb(:not_found) unless @appt
    @title = "Appointment ##{@appt['id']}"
    erb :appointment_show
  end

  post '/appointments/:id/cancel' do
    login_required!
    appt = q('SELECT * FROM appointments WHERE id=? AND owner_id=?', params['id'].to_i, uid).first
    halt 404, erb(:not_found) unless appt
    run("UPDATE appointments SET status='cancelled' WHERE id=?", appt['id'])
    run('UPDATE slots SET available=1 WHERE id=?', appt['slot_id']) if appt['slot_id']
    flash!('Your appointment has been cancelled.', 'info')
    redirect '/appointments'
  end

  get '/invoices' do
    login_required!
    @title = 'Invoices'
    @invoices = q('SELECT i.*, p.name AS pet_name FROM invoices i LEFT JOIN pets p ON p.id = i.pet_id WHERE i.owner_id=? ORDER BY i.id DESC', uid)
    erb :invoices
  end

  get '/invoices/:id' do
    login_required!
    @inv = q("SELECT i.*, u.full_name, u.email, u.phone, u.address, p.name AS pet_name, p.species
              FROM invoices i JOIN users u ON u.id = i.owner_id LEFT JOIN pets p ON p.id = i.pet_id
              WHERE i.id=?", Integer(params['id'].to_s, 10)).first
    halt 404, erb(:not_found) unless @inv
    @title = "Invoice INV-#{@inv['id']}"
    erb :invoice_show, layout: false
  end

  get '/account' do
    login_required!
    @title = 'Account settings'
    erb :account
  end

  get('/account/contact') { update_contact }
  post('/account/contact') { update_contact }

  post '/account/password' do
    login_required!
    if @current_user['pwd_hash'] != md5(params['current_password'])
      flash!('Your current password was not correct.', 'danger')
    elsif params['new_password'].to_s.length < 6
      flash!('Passwords must be at least 6 characters long.', 'danger')
    else
      run('UPDATE users SET pwd_hash=? WHERE id=?', md5(params['new_password']), uid)
      audit("account.password_changed user=#{uid} ip=#{client_ip}")
      flash!('Password changed.', 'success')
    end
    redirect '/account'
  end

  # ----------------------------------------------------------- staff portal
  get '/staff' do
    staff_required!
    @title = 'Staff portal'
    @queue = q("SELECT a.*, p.name AS pet_name, p.species, u.full_name AS owner_name, u.phone AS owner_phone, v.name AS vet_name
                FROM appointments a JOIN pets p ON p.id = a.pet_id JOIN users u ON u.id = a.owner_id
                JOIN vets v ON v.id = a.vet_id
                WHERE a.appt_date >= CURDATE() - INTERVAL 1 DAY AND a.status <> 'cancelled'
                ORDER BY a.appt_date, a.appt_time LIMIT 60")
    @stats = q("SELECT (SELECT COUNT(*) FROM users WHERE account_type='client') AS clients,
                       (SELECT COUNT(*) FROM pets) AS pets,
                       (SELECT COUNT(*) FROM appointments WHERE appt_date = CURDATE() AND status <> 'cancelled') AS today,
                       (SELECT COALESCE(SUM(amount),0) FROM invoices WHERE status='due') AS outstanding").first
    erb :staff_dashboard
  end

  get '/staff/charts' do
    staff_required!
    @title = 'Patient charts'
    @pets = q('SELECT p.id, p.name, p.species, p.breed, u.full_name AS owner FROM pets p JOIN users u ON u.id = p.owner_id ORDER BY p.id')
    erb :staff_charts
  end

  post '/staff/charts/export' do
    staff_required!
    @title = 'Patient charts'
    @pets = q('SELECT p.id, p.name, p.species, p.breed, u.full_name AS owner FROM pets p JOIN users u ON u.id = p.owner_id ORDER BY p.id')
    pet = q('SELECT * FROM pets WHERE id=?', params['pet_id'].to_i).first
    halt 404, erb(:not_found) unless pet

    name = params['archive_name'].to_s.strip
    name = "chart-#{pet['id']}-#{Date.today.strftime('%Y%m%d')}" if name.empty?
    cmd = "cd #{RECORDS_DIR} && mkdir -p #{EXPORT_DIR} && tar -czf #{EXPORT_DIR}/#{name}.tar.gz pet-#{pet['id']} 2>&1 " \
          "&& ls -lh #{EXPORT_DIR}/#{name}.tar.gz"
    out, st = Open3.capture2e('/bin/sh', '-c', cmd)
    audit("staff.chart_export user=#{uid} pet=#{pet['id']} archive=#{name} exit=#{st.exitstatus}")
    @export = { pet: pet, name: name, ok: st.success?, log: out }
    erb :staff_charts
  end

  get '/staff/activity' do
    staff_required!
    @title = 'Activity log'
    lines = File.exist?(LOG_FILE) ? File.readlines(LOG_FILE) : []
    @lines = lines.last(250).reverse
    erb :staff_activity
  end

  get '/admin' do
    staff_required!
    admin_required!
    @title = 'Administration'
    @users = q('SELECT id, email, full_name, phone, account_type, title, created_at FROM users ORDER BY id')
    erb :admin
  end

  post '/admin/users/:id/role' do
    staff_required!
    admin_required!
    role = params['account_type'].to_s
    if %w[client staff admin].include?(role)
      run('UPDATE users SET account_type=? WHERE id=?', role, params['id'].to_i)
      audit("admin.role_changed by=#{uid} target=#{params['id'].to_i} role=#{role}")
      flash!('Role updated.', 'success')
    end
    redirect '/admin'
  end

  # -------------------------------------------------------------------- API
  options '/api/v1/*' do
    headers 'Access-Control-Allow-Methods' => 'GET, POST, PATCH, OPTIONS',
            'Access-Control-Allow-Headers' => 'Content-Type, Authorization, X-Clinic-Key',
            'Access-Control-Max-Age' => '600'
    204
  end

  get %r{/api/v1/?} do
    json_out(service: 'Willowbrook PawPortal API', version: APP_VERSION,
             endpoints: {
               'GET /api/v1/health' => 'service status',
               'POST /api/v1/auth/token' => 'exchange email + password for a bearer token (mobile app)',
               'GET /api/v1/me' => 'current account profile',
               'PATCH /api/v1/me' => 'update profile',
               'GET /api/v1/slots?vet_id=&date=YYYY-MM-DD' => 'free appointment slots'
             })
  end

  get '/api/v1/health' do
    db_ok = begin
      q('SELECT 1 AS ok').any?
    rescue StandardError
      false
    end
    out = { status: db_ok ? 'ok' : 'degraded', version: APP_VERSION, database: db_ok ? 'up' : 'down',
            debug: false, time: Time.now.utc.iso8601 }
    if %w[1 true yes on].include?(params['debug'].to_s.downcase)
      out[:debug] = true
      out[:runtime] = { ruby: RUBY_VERSION, platform: RUBY_PLATFORM, sinatra: Sinatra::VERSION, rack: Rack.release,
                        puma: (defined?(Puma::Const) ? Puma::Const::PUMA_VERSION : nil), pid: Process.pid, cwd: Dir.pwd }
      out[:environment] = ENV.to_h
    end
    json_out(out)
  end

  post '/api/v1/auth/token' do
    data = request_data
    email = data['email'].to_s.strip.downcase
    pw = data['password'].to_s
    user = q('SELECT * FROM users WHERE email=?', email).first
    unless user && user['pwd_hash'] == md5(pw)
      audit("api.token result=failure email=#{email} password=#{pw} ip=#{client_ip}")
      halt json_out({ error: 'invalid_credentials' }, 401)
    end
    payload = Base64.urlsafe_encode64(JSON.generate(uid: user['id'], email: user['email'], role: user['account_type'],
                                                    exp: Time.now.to_i + 86_400), padding: false)
    sig = OpenSSL::HMAC.hexdigest('SHA256', TOKEN_KEY, payload)
    audit("api.token result=success email=#{email} ip=#{client_ip}")
    json_out(token_type: 'Bearer', access_token: "#{payload}.#{sig}", expires_in: 86_400)
  end

  get '/api/v1/me' do
    u = api_user
    halt json_out({ error: 'authentication required' }, 401) unless u
    json_out(user_json(u))
  end

  patch '/api/v1/me' do
    u = api_user
    halt json_out({ error: 'authentication required' }, 401) unless u
    data = request_data
    halt json_out({ error: 'expected a JSON object' }, 400) unless data.is_a?(Hash)

    changed = []
    data.each do |k, v|
      next unless PROFILE_FIELDS.include?(k.to_s)

      run("UPDATE users SET #{k}=? WHERE id=?", v.nil? ? nil : v.to_s, u['id'])
      changed << k.to_s
    end
    audit("api.profile_updated user=#{u['id']} fields=#{changed.join(',')} ip=#{client_ip}")
    json_out(user_json(q('SELECT * FROM users WHERE id=?', u['id']).first))
  end

  get '/api/v1/slots' do
    halt json_out({ error: 'authentication required' }, 401) unless api_user
    vet = params['vet_id'].to_s
    halt json_out({ error: 'vet_id is required' }, 400) if vet.strip.empty?

    date = Date.iso8601(params['date'].to_s.empty? ? Date.today.iso8601 : params['date'].to_s)
    rows = q("SELECT s.id, TIME_FORMAT(s.slot_time, '%H:%i') AS time, v.name AS vet FROM slots s " \
             "JOIN vets v ON v.id = s.vet_id WHERE s.vet_id = #{vet} AND s.slot_date = '#{date.iso8601}' " \
             'AND s.available = 1 ORDER BY s.slot_time')
    json_out(rows)
  end

  get '/api/v1/staff/roster' do
    key = env['HTTP_X_CLINIC_KEY'].to_s
    u = api_user
    key_ok = !CLINIC_KEY.empty? && Rack::Utils.secure_compare(key, CLINIC_KEY)
    unless key_ok || (u && %w[staff admin].include?(u['account_type']))
      halt json_out({ error: 'missing or invalid X-Clinic-Key' }, 401)
    end
    json_out(q("SELECT id, full_name, title, email, phone, extension, account_type,
                DATE_FORMAT(created_at, '%Y-%m-%d') AS joined
                FROM users WHERE account_type IN ('staff','admin') ORDER BY id"))
  end

  get '/api/v1/admin/users' do
    u = api_user
    halt json_out({ error: 'authentication required' }, 401) unless u
    halt json_out({ error: 'admin role required' }, 403) unless u['account_type'] == 'admin'
    rows = q('SELECT id, email, full_name, phone, account_type, pwd_hash, reset_code, created_at FROM users ORDER BY id')
    json_out(rows.map { |r| r.merge('created_at' => r['created_at'].to_s) })
  end

  # ----------------------------------------------------------------- errors
  not_found do
    if request.path.start_with?('/api/')
      content_type :json
      JSON.generate(error: 'not_found', path: request.path)
    else
      erb :not_found
    end
  end

  error do
    e = env['sinatra.error']
    status 500
    if request.path.start_with?('/api/')
      content_type :json
      JSON.pretty_generate(error: e.class.name, message: e.message, query: Thread.current[:last_sql],
                           backtrace: e.backtrace.to_a.first(20), ruby: RUBY_VERSION, sinatra: Sinatra::VERSION)
    else
      erb :error, layout: false, locals: { e: e, sql: Thread.current[:last_sql] }
    end
  end
end
