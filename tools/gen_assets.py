#!/usr/bin/env python3
"""Generates the lab's static content (SVG art, PDFs, intake paperwork, seed log).
Run once from the lab root:  python3 tools/gen_assets.py
"""
import os

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'app')


def w(rel, data, mode='w'):
    p = os.path.join(ROOT, rel)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, mode) as f:
        f.write(data)


def pdf(rel, title, lines):
    def esc(s):
        return s.replace('\\', '\\\\').replace('(', '\\(').replace(')', '\\)')
    stream = 'BT /F2 20 Tf 56 760 Td (Willowbrook Veterinary Clinic) Tj ET\n'
    stream += '0.18 0.49 0.38 RG 2 w 56 748 m 556 748 l S\n'
    stream += 'BT /F2 15 Tf 56 722 Td (%s) Tj ET\n' % esc(title)
    y = 696
    for line in lines:
        stream += 'BT /F1 11 Tf 56 %d Td (%s) Tj ET\n' % (y, esc(line))
        y -= 17
    stream += 'BT /F1 8 Tf 56 40 Td (2280 SE Willow Creek Rd, Portland, OR 97202  -  (503) 555-0100  -  willowbrookvets.com) Tj ET\n'
    objs = [
        '<< /Type /Catalog /Pages 2 0 R >>',
        '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
        '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R '
        '/Resources << /Font << /F1 5 0 R /F2 6 0 R >> >> >>',
        '<< /Length %d >>\nstream\n%sendstream' % (len(stream), stream),
        '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
        '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold >>',
    ]
    out = '%PDF-1.4\n'
    offsets = []
    for i, o in enumerate(objs, 1):
        offsets.append(len(out))
        out += '%d 0 obj\n%s\nendobj\n' % (i, o)
    xref = len(out)
    out += 'xref\n0 %d\n0000000000 65535 f \n' % (len(objs) + 1)
    for off in offsets:
        out += '%010d 00000 n \n' % off
    out += 'trailer\n<< /Size %d /Root 1 0 R /Info << /Producer (PawPortal ReportKit 1.4) >> >>\nstartxref\n%d\n%%%%EOF\n' % (len(objs) + 1, xref)
    w(rel, out.encode('latin-1'), 'wb')


# ---------------------------------------------------------------- SVG art
PAW = ('<g fill="{c}"><ellipse cx="32" cy="42" rx="12" ry="10"/><circle cx="18" cy="26" r="5.5"/>'
       '<circle cx="28" cy="18" r="5.5"/><circle cx="40" cy="18" r="5.5"/><circle cx="48" cy="27" r="5.5"/></g>')
w('public/assets/img/logo.svg',
  '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><circle cx="32" cy="32" r="31" fill="#2f7d62"/>'
  + PAW.format(c='#fff') + '</svg>')
w('public/assets/img/favicon.svg',
  '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="14" fill="#2f7d62"/>'
  + PAW.format(c='#fff') + '</svg>')
w('public/assets/img/pet-placeholder.svg',
  '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><circle cx="32" cy="32" r="32" fill="#dcece4"/>'
  + PAW.format(c='#2f7d62') + '</svg>')
w('public/assets/img/hero.svg', '''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 420 320">
<circle cx="210" cy="170" r="140" fill="#cfe5d9"/><circle cx="320" cy="70" r="36" fill="#efe7d8"/>
<g transform="translate(110 70) scale(3.2)" opacity=".9">''' + PAW.format(c='#2f7d62') + '''</g>
<path d="M60 290 Q210 230 360 290" stroke="#2f7d62" stroke-width="6" fill="none" stroke-linecap="round"/>
</svg>''')
for name, colour, initials in [('vet-hart', '#c98b5f', 'AH'), ('vet-mehta', '#5f8fc9', 'RM'), ('vet-lindqvist', '#9b6fc2', 'SL')]:
    w('public/assets/img/%s.svg' % name,
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 96 96"><circle cx="48" cy="48" r="48" fill="%s"/>'
      '<text x="48" y="58" font-family="Arial, sans-serif" font-size="32" font-weight="700" fill="#fff" text-anchor="middle">%s</text></svg>'
      % (colour, initials))

# ---------------------------------------------------------------- records
pdf('storage/records/common/welcome-pack.pdf', 'New patient welcome pack', [
    'Thank you for choosing Willowbrook Veterinary Clinic.',
    '',
    'Your first visit: please arrive 5 minutes early and bring any previous records.',
    'Vaccination schedule: puppies/kittens at 8, 12 and 16 weeks, then annually.',
    'Parasite control: monthly flea/tick prevention recommended year-round in Oregon.',
    'Cancellations: please give at least 24 hours notice via PawPortal.',
    'Emergencies: call our 24/7 line on (503) 555-0199.',
])
RECORDS = {
    'pet-1': [('wellness-exam-2026-03-14.pdf', 'Annual wellness exam - Bella', ['Patient: Bella (Labrador Retriever, F/S, 6y)', 'Weight 29.4 kg (BCS 6/9). Heart/lungs NAD.', 'Mild tartar on upper premolars - dental in 6-12 months.', 'Vaccines: DHPP and rabies boosters given.', 'Clinician: Dr. Amelia Hart'])],
    'pet-2': [('bloodwork-2026-07-02.pdf', 'Senior blood panel - Milo', ['Patient: Milo (Domestic Shorthair, M/N, 11y)', 'CREA 1.9 mg/dL (ref 0.8-2.4), SDMA 13 ug/dL', 'T4 2.1 ug/dL - within normal limits.', 'Recommend renal diet trial and recheck in 6 months.', 'Clinician: Dr. Amelia Hart'])],
    'pet-3': [('radiograph-report-2026-05-20.pdf', 'Radiograph report - Pepper', ['Patient: Pepper (Beagle, M/N, 5y)', 'Study: left stifle, 2 views', 'Findings: cranial tibial thrust, joint effusion consistent with CCL rupture.', 'Plan: TPLO surgery scheduled with Dr. Rohan Mehta.']),
              ('surgery-discharge-2026-06-03.pdf', 'Surgical discharge - Pepper', ['Procedure: left TPLO', 'Medication: carprofen 50 mg BID x 14d, gabapentin 100 mg TID x 7d', 'Strict cage rest 8 weeks. Suture removal in 14 days.', 'Surgeon: Dr. Rohan Mehta'])],
    'pet-4': [('allergy-workup-2026-08-11.pdf', 'Dermatology consult - Luna', ['Patient: Luna (Maine Coon, F/S, 4y)', 'Miliary dermatitis, over-grooming of ventral abdomen.', 'Skin cytology: no yeast; flea comb negative.', 'Plan: 8-week elimination diet trial (hydrolysed protein).', 'Clinician: Dr. Sofia Lindqvist'])],
    'pet-5': [('avian-exam-2026-04-09.pdf', 'Avian wellness exam - Kiwi', ['Patient: Kiwi (Cockatiel, M, 3y)', 'Weight 92 g. Feathering good, beak and nails trimmed.', 'Diet advice: reduce seed, increase pellets/vegetables.'])],
    'pet-6': [('vaccination-cert-2026-09-30.pdf', 'Vaccination certificate - Rex', ['Patient: Rex (German Shepherd, M, 2y) - microchip 985112004417733', 'Rabies (3-year) - batch RB2291 - due 2029-09-30', 'DHPP - batch DH8810 - due 2027-09-30', 'Leptospirosis - batch LP0412 - due 2027-09-30'])],
}
for d, files in RECORDS.items():
    for fname, title, lines in files:
        pdf('storage/records/%s/%s' % (d, fname), title, lines)

# ---------------------------------------------------------------- intake paperwork
pdf('intake/forms/new-patient-registration.pdf', 'New patient registration', [
    'Owner name: ______________________   Phone: ________________',
    'Address: ______________________________________________',
    'Pet name: ____________  Species: ________  Breed: ____________',
    'Date of birth: ________  Sex: M / F  Neutered: Y / N',
    'Previous clinic: ______________________________________',
    'Current medication / allergies: ________________________',
    '',
    'Signature: ______________________   Date: ____________',
])
pdf('intake/forms/surgical-consent.pdf', 'Consent for anaesthesia and surgery', [
    'I consent to the procedure(s) described below and to the use of general anaesthesia.',
    'Procedure: ____________________________________________',
    'Estimated cost: $__________ (a 50% deposit is required on admission)',
    'Emergency contact during surgery: _______________________',
    'Signature: ______________________   Date: ____________',
])
pdf('intake/forms/records-release.pdf', 'Authorisation to release medical records', [
    'I authorise Willowbrook Veterinary Clinic to release the records of the pet named below to:',
    'Clinic / insurer: ______________________________________',
    'Pet name: _____________________  Owner: _____________________',
    'Signature: ______________________   Date: ____________',
])
w('intake/archive/client-export-2026-09.csv',
  'client_id,full_name,email,phone,address,pets,balance_due\n'
  '6,Jessica Moore,jessica.moore@example.net,+1 (503) 555-0187,"1420 SE Alder St, Portland, OR 97214","Bella;Milo",0.00\n'
  '7,David Chen,d.chen@example.org,+1 (503) 555-0142,"88 NW Hoyt St Apt 5, Portland, OR 97209",Pepper,1385.00\n'
  '8,Priya Nair,priya.nair@example.com,+1 (971) 555-0164,"3315 N Williams Ave, Portland, OR 97227",Luna,140.00\n'
  '9,Marcus Webb,marcus.webb@example.net,+1 (503) 555-0123,"7720 SW Capitol Hwy, Portland, OR 97219","Kiwi;Rex",0.00\n')
w('intake/archive/frontdesk-handover.txt',
  'FRONT DESK HANDOVER - week 39\n'
  '=============================\n'
  '- Mailchimp export of the client list is in this folder (client-export-2026-09.csv) for the\n'
  '  vaccination reminder campaign. Delete once the campaign has been sent.\n'
  '- New staff accounts are created by Olivia. Clinicians sign in at /staff/login.\n'
  '- Reception kiosk (WB-412) is still waiting on IT - it will use the shared clinic key, not a login.\n'
  '- Guest Wi-Fi: WB-Guest / pawsandclaws26\n'
  '- Pepper (Chen) balance outstanding - payment plan agreed, do not send to collections.\n')

# ---------------------------------------------------------------- seed log
w('data/portal.log.seed', '''2026-09-28T08:31:07Z boot pawportal 2.3.0 env=production
2026-09-28T08:42:19Z auth.staff_login result=success email=frontdesk@willowbrookvets.com password=Fr0ntDesk!Wb2026 ip=10.20.0.15 sid=9a1f0c55e2d84b7f8c0e11a2b3c4d5e6
2026-09-28T09:02:51Z auth.login result=failure email=jessica.moore@example.net password=Tigger ip=73.25.118.4
2026-09-28T09:03:10Z auth.login result=success email=jessica.moore@example.net password=tigger ip=73.25.118.4 sid=b77c2a9de0f14c3aa1b2c3d4e5f60718
2026-09-29T07:55:44Z auth.staff_login result=failure email=rohan.mehta@willowbrookvets.com password=Mehta#Vet!8824 ip=10.20.0.31
2026-09-29T07:56:02Z auth.staff_login result=success email=rohan.mehta@willowbrookvets.com password=Mehta#Vet!8842 ip=10.20.0.31 sid=0c4e8d2a6b1f49e3a5c7d9e1f3a5b7c9
2026-09-30T11:20:37Z auth.reset_requested email=d.chen@example.org code=7314 ip=24.20.55.190
2026-09-30T11:22:05Z auth.reset_completed email=d.chen@example.org new_password=basketball ip=24.20.55.190
2026-10-01T18:04:12Z staff.chart_export user=3 pet=3 archive=pepper-tplo-referral exit=0
2026-10-02T08:15:29Z auth.staff_login result=failure email=olivia.grant@willowbrookvets.com password=Kestrel#Wb-Adm1n-773 ip=10.20.0.10
2026-10-02T08:15:41Z auth.staff_login result=success email=olivia.grant@willowbrookvets.com password=Kestrel#Wb-Adm1n-7731 ip=10.20.0.10 sid=5e1d9c7b3a2f48e6b0c4d8e2f6a0b4c8
2026-10-02T08:16:03Z admin.role_changed by=1 target=5 role=staff
2026-10-03T14:48:55Z api.token result=success email=marcus.webb@example.net ip=172.58.12.40
2026-10-04T10:11:21Z auth.login result=failure email=priya.nair@example.com password=Priya#Secure19 ip=67.171.20.8
2026-10-04T10:11:39Z auth.login result=success email=priya.nair@example.com password=Priya#Secure91 ip=67.171.20.8 sid=e2c4a6b8d0f2416385a7c9e1b3d5f7a9
''')
print('assets generated')
