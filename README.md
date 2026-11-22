# Willowbrook PawPortal — Web Application Penetration-Test Lab

A deliberately vulnerable **veterinary-clinic customer & staff portal**, built to simulate an
internal web-application penetration-test exam. Treat it as a **real client engagement**: you are
given a URL and nothing else.

> ⚠️ **Insecure by design.** Run it only inside your own isolated lab/VM. Never expose it to a
> shared network, the internet, or any machine holding real data.

---

## 1. Engagement brief

| Item | Value |
|---|---|
| Client | Willowbrook Veterinary Clinic (fictional) |
| Application | "PawPortal" — online booking, records, billing and a staff back-office |
| Target | `http://192.168.255.133:8095/` |
| Type | Black-box web application penetration test |
| Credentials provided | **None.** The portal has open self-registration. |
| Expected findings | **25** distinct vulnerabilities |
| Time suggestion | 6–8 hours (exam pace) |

### In scope
* Everything reachable over HTTP on port **8095** of the target host.
* Anything you can reach **through** the application (that is part of the test).

### Out of scope
* Denial of service / resource exhaustion; mass brute-forcing beyond what is needed to prove a finding.
* Attacking the Docker host, SSH, or other ports/containers directly.
* **Reading the lab's own source** (`app/`, `db/`, `Dockerfile`, `docker-compose.yml`, `tests/`) —
  that turns it into a white-box exercise and spoils the challenge. Open `SOLUTIONS.md` only **after**
  you are finished, to mark your work.

---

## 2. What the findings look like

The 25 findings cover the same vulnerability families you will meet across the other PolyVuln labs,
but they live in **different features**, use **different parameter names**, and often behave
differently — do **not** expect a 1:1 endpoint match with any other lab. Discovery (crawling,
fuzzing, reading the client-side JavaScript, tampering with parameters and cookies) is part of the work.

Everything that is vulnerable is **genuinely exploitable inside the container** — there are no
"simulated" bugs that only return a canned string, no `/debug` giveaway routes, and no HTML comments
pointing you at the answers.

Coverage, by OWASP Top 10:2025 category:

| Category | Count |
|---|---|
| A01 Broken Access Control | 6 |
| A02 Security Misconfiguration | 3 |
| A03 Software Supply Chain Failures | 1 |
| A04 Cryptographic Failures | 2 |
| A05 Injection | 4 |
| A06 Insecure Design | 2 |
| A07 Authentication Failures | 4 |
| A08 Software or Data Integrity Failures | 1 |
| A09 Security Logging & Alerting Failures | 1 |
| A10 Mishandling of Exceptional Conditions | 1 |
| **Total** | **25** |

---

## 3. Running the lab (host/admin only)

The application and its database run in Docker. From this folder:

```bash
docker compose up -d --build      # build and start
docker compose logs -f web        # tail application logs
docker compose down               # stop (keeps data)
```

Then browse to `http://<vm-ip>:8095/`.

### Reset to a clean state

```bash
./reset.sh                        # wipes DB/uploads/exports/logs and rebuilds
```

Run this between candidates so seed data, accounts and the activity log are pristine.

### Architecture

* `web` — the application, published on host port **8095**.
* `db` — the database, on an **internal** Docker network with **no host port** and no route to the
  internet. You cannot reach it directly; reaching it is part of the test.

---

## 4. Seed data

The clinic ships with staff accounts and a handful of client accounts with pets, appointments,
medical records and invoices, so every feature works immediately. Finding and abusing these is part
of the exercise — no credentials are handed to you.

---

## 5. Deliverable

Produce a report that, for each finding, states the vulnerability class, the affected
request/parameter, a reproduction (request + payload), the impact, and a remediation. Aim to find
all **25**. When you are done, check yourself against `SOLUTIONS.md`.

---

## ⚖️ Legal

For authorized training and education only. Run on systems you own or are authorized to test. The
authors accept no liability for misuse.
