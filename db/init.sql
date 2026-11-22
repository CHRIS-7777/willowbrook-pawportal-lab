-- Willowbrook Veterinary Clinic - PawPortal schema + seed data
CREATE DATABASE IF NOT EXISTS willowbrook CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

CREATE USER IF NOT EXISTS 'wb_portal'@'%' IDENTIFIED WITH mysql_native_password BY 'Pawp0rtal_Db!4471';
GRANT SELECT, INSERT, UPDATE, DELETE ON willowbrook.* TO 'wb_portal'@'%';
FLUSH PRIVILEGES;

USE willowbrook;

CREATE TABLE users (
  id INT AUTO_INCREMENT PRIMARY KEY,
  email VARCHAR(190) NOT NULL UNIQUE,
  full_name VARCHAR(120) NOT NULL,
  phone VARCHAR(40) NULL,
  address VARCHAR(255) NULL,
  pwd_hash CHAR(32) NOT NULL,
  account_type VARCHAR(20) NOT NULL DEFAULT 'client',
  title VARCHAR(80) NULL,
  extension VARCHAR(10) NULL,
  records_forward_email VARCHAR(190) NULL,
  reset_code VARCHAR(10) NULL,
  reset_expires DATETIME NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

CREATE TABLE sessions (
  id VARCHAR(64) PRIMARY KEY,
  user_id INT NULL,
  flash TEXT NULL,
  created_at DATETIME NOT NULL,
  last_seen DATETIME NULL
) ENGINE=InnoDB;

CREATE TABLE vets (
  id INT AUTO_INCREMENT PRIMARY KEY,
  user_id INT NULL,
  name VARCHAR(120) NOT NULL,
  specialty VARCHAR(120) NOT NULL,
  bio TEXT,
  photo VARCHAR(120)
) ENGINE=InnoDB;

CREATE TABLE pets (
  id INT AUTO_INCREMENT PRIMARY KEY,
  owner_id INT NOT NULL,
  name VARCHAR(60) NOT NULL,
  species VARCHAR(30),
  breed VARCHAR(60),
  dob DATE NULL,
  weight_kg DECIMAL(5,2) NULL,
  notes TEXT,
  photo VARCHAR(190) NULL,
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
  INDEX (owner_id)
) ENGINE=InnoDB;

CREATE TABLE slots (
  id INT AUTO_INCREMENT PRIMARY KEY,
  vet_id INT NOT NULL,
  slot_date DATE NOT NULL,
  slot_time TIME NOT NULL,
  available TINYINT(1) NOT NULL DEFAULT 1,
  UNIQUE KEY uq_slot (vet_id, slot_date, slot_time)
) ENGINE=InnoDB;

CREATE TABLE appointments (
  id INT AUTO_INCREMENT PRIMARY KEY,
  owner_id INT NOT NULL,
  pet_id INT NOT NULL,
  vet_id INT NOT NULL,
  slot_id INT NULL,
  appt_date DATE NOT NULL,
  appt_time TIME NOT NULL,
  reason TEXT,
  status VARCHAR(20) NOT NULL DEFAULT 'confirmed',
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

CREATE TABLE records (
  id INT AUTO_INCREMENT PRIMARY KEY,
  pet_id INT NOT NULL,
  title VARCHAR(160) NOT NULL,
  summary TEXT,
  file VARCHAR(190) NULL,
  recorded_on DATE NOT NULL
) ENGINE=InnoDB;

CREATE TABLE invoices (
  id INT AUTO_INCREMENT PRIMARY KEY,
  owner_id INT NOT NULL,
  pet_id INT NULL,
  appointment_id INT NULL,
  status VARCHAR(20) NOT NULL DEFAULT 'due',
  issued_on DATE NOT NULL,
  items TEXT,
  amount DECIMAL(8,2) NOT NULL,
  card_brand VARCHAR(20) NULL,
  card_last4 CHAR(4) NULL
) ENGINE=InnoDB AUTO_INCREMENT=1001;

CREATE TABLE clinic_settings (
  setting_key VARCHAR(60) PRIMARY KEY,
  setting_value TEXT NOT NULL,
  updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

-- ------------------------------------------------------------------ users
INSERT INTO users (id, email, full_name, phone, address, pwd_hash, account_type, title, extension, created_at) VALUES
 (1, 'olivia.grant@willowbrookvets.com',   'Olivia Grant',        '+1 (503) 555-0110', NULL, MD5('Kestrel#Wb-Adm1n-7731'), 'admin', 'Practice Manager',          '100', '2022-01-10 09:00:00'),
 (2, 'amelia.hart@willowbrookvets.com',    'Dr. Amelia Hart',     '+1 (503) 555-0121', NULL, MD5('welcome123'),            'staff', 'Senior Veterinarian',       '121', '2022-01-10 09:05:00'),
 (3, 'rohan.mehta@willowbrookvets.com',    'Dr. Rohan Mehta',     '+1 (503) 555-0122', NULL, MD5('Mehta#Vet!8842'),        'staff', 'Veterinary Surgeon',        '122', '2022-06-01 09:00:00'),
 (4, 'sofia.lindqvist@willowbrookvets.com','Dr. Sofia Lindqvist', '+1 (503) 555-0123', NULL, MD5('L1ndqv!st-Derm-55'),     'staff', 'Veterinary Dermatologist',  '123', '2023-03-15 09:00:00'),
 (5, 'frontdesk@willowbrookvets.com',      'Tom Becker',          '+1 (503) 555-0100', NULL, MD5('Fr0ntDesk!Wb2026'),      'staff', 'Reception Lead',            '101', '2023-08-21 09:00:00'),
 (6, 'jessica.moore@example.net', 'Jessica Moore', '+1 (503) 555-0187', '1420 SE Alder St, Portland, OR 97214',    MD5('tigger'),         'client', NULL, NULL, '2024-03-12 17:22:10'),
 (7, 'd.chen@example.org',        'David Chen',    '+1 (503) 555-0142', '88 NW Hoyt St Apt 5, Portland, OR 97209', MD5('basketball'),     'client', NULL, NULL, '2024-05-02 08:10:44'),
 (8, 'priya.nair@example.com',    'Priya Nair',    '+1 (971) 555-0164', '3315 N Williams Ave, Portland, OR 97227', MD5('Priya#Secure91'), 'client', NULL, NULL, '2025-01-19 12:40:02'),
 (9, 'marcus.webb@example.net',   'Marcus Webb',   '+1 (503) 555-0123', '7720 SW Capitol Hwy, Portland, OR 97219', MD5('football1'),      'client', NULL, NULL, '2025-07-08 19:05:31');
ALTER TABLE users AUTO_INCREMENT = 20;

-- ------------------------------------------------------------------- vets
INSERT INTO vets (id, user_id, name, specialty, bio, photo) VALUES
 (1, 2, 'Dr. Amelia Hart', 'General Practice & Preventive Care',
  'Amelia founded Willowbrook''s wellness programme and has spent 14 years in small-animal practice. She has a special interest in senior pet care, nutrition and kidney disease in cats.', 'vet-hart.svg'),
 (2, 3, 'Dr. Rohan Mehta', 'Soft-tissue & Orthopaedic Surgery',
  'Rohan leads our surgical team. He performs cruciate repairs (TPLO), fracture fixation and complex soft-tissue procedures, and is a member of the American College of Veterinary Surgeons.', 'vet-mehta.svg'),
 (3, 4, 'Dr. Sofia Lindqvist', 'Dermatology & Allergy',
  'Sofia trained in Uppsala and Davis. She treats itchy pets, chronic ear infections and food allergies, and also sees rabbits and birds on Thursday afternoons.', 'vet-lindqvist.svg');

-- ------------------------------------------------------------------- pets
INSERT INTO pets (id, owner_id, name, species, breed, dob, weight_kg, notes, photo) VALUES
 (1, 6, 'Bella',  'Dog',  'Labrador Retriever', '2020-04-18', 29.40, 'Food motivated - treats help. Allergic to chicken.', NULL),
 (2, 6, 'Milo',   'Cat',  'Domestic Shorthair', '2015-02-02', 5.10,  'Hides under the chair; please be gentle.', NULL),
 (3, 7, 'Pepper', 'Dog',  'Beagle',             '2021-01-30', 13.20, 'Post-TPLO left stifle (June 2026).', NULL),
 (4, 8, 'Luna',   'Cat',  'Maine Coon',         '2022-06-14', 6.80,  'Elimination diet trial in progress.', NULL),
 (5, 9, 'Kiwi',   'Bird', 'Cockatiel',          '2023-03-01', 0.09,  NULL, NULL),
 (6, 9, 'Rex',    'Dog',  'German Shepherd',    '2024-02-11', 34.00, 'Muzzle trained. Nervous around other dogs.', NULL);
ALTER TABLE pets AUTO_INCREMENT = 20;

-- ---------------------------------------------------------------- records
INSERT INTO records (pet_id, title, summary, file, recorded_on) VALUES
 (1, 'Annual wellness exam', 'Weight 29.4 kg, vaccines boosted, dental recommended within 12 months.', 'pet-1/wellness-exam-2026-03-14.pdf', '2026-03-14'),
 (2, 'Senior blood panel', 'Renal values at upper end of normal - recheck in 6 months.', 'pet-2/bloodwork-2026-07-02.pdf', '2026-07-02'),
 (3, 'Radiograph report - left stifle', 'Findings consistent with cranial cruciate ligament rupture.', 'pet-3/radiograph-report-2026-05-20.pdf', '2026-05-20'),
 (3, 'Surgical discharge - TPLO', 'Medication plan and 8-week rest instructions.', 'pet-3/surgery-discharge-2026-06-03.pdf', '2026-06-03'),
 (4, 'Dermatology consult', 'Miliary dermatitis - elimination diet started.', 'pet-4/allergy-workup-2026-08-11.pdf', '2026-08-11'),
 (5, 'Avian wellness exam', 'Healthy. Diet changes advised.', 'pet-5/avian-exam-2026-04-09.pdf', '2026-04-09'),
 (6, 'Vaccination certificate', 'Rabies (3y), DHPP, Leptospirosis.', 'pet-6/vaccination-cert-2026-09-30.pdf', '2026-09-30');

-- ----------------------------------------------------------- appointments
INSERT INTO appointments (owner_id, pet_id, vet_id, slot_id, appt_date, appt_time, reason, status) VALUES
 (6, 1, 1, NULL, CURDATE() + INTERVAL 1 DAY, '09:30:00', 'Itchy ears again, shaking her head since the weekend.', 'confirmed'),
 (7, 3, 2, NULL, CURDATE() + INTERVAL 1 DAY, '11:00:00', 'TPLO 6-month post-op check and radiographs.', 'confirmed'),
 (8, 4, 3, NULL, CURDATE() + INTERVAL 2 DAY, '14:30:00', 'Diet trial review - still over-grooming belly.', 'confirmed'),
 (9, 6, 1, NULL, CURDATE() + INTERVAL 3 DAY, '10:00:00', 'Annual booster. Please use the quiet room - he gets anxious.', 'confirmed'),
 (6, 2, 1, NULL, CURDATE() - INTERVAL 40 DAY, '15:00:00', 'Senior blood panel follow-up.', 'completed'),
 (9, 5, 3, NULL, CURDATE() - INTERVAL 20 DAY, '16:00:00', 'Nail and beak trim.', 'completed');

-- --------------------------------------------------------------- invoices
INSERT INTO invoices (id, owner_id, pet_id, status, issued_on, items, amount, card_brand, card_last4) VALUES
 (1001, 6, 1, 'paid', '2026-03-14', 'Annual wellness exam|85.00\nDHPP booster|45.00\nRabies vaccination|38.00', 168.00, 'Visa', '4417'),
 (1002, 7, 3, 'paid', '2026-05-20', 'Orthopaedic consultation|95.00\nDigital radiography - stifle (2 views)|190.00', 285.00, 'Mastercard', '9902'),
 (1003, 7, 3, 'due',  '2026-06-03', 'TPLO surgery - left stifle|2850.00\nHospitalisation (1 night)|140.00\nDischarge medication|95.00\nPayment received - deposit|-1700.00', 1385.00, NULL, NULL),
 (1004, 6, 2, 'paid', '2026-07-02', 'Senior consultation|65.00\nComprehensive blood panel + SDMA|185.00', 250.00, 'Visa', '4417'),
 (1005, 8, 4, 'due',  '2026-08-11', 'Dermatology consultation|140.00', 140.00, NULL, NULL),
 (1006, 9, 6, 'paid', '2026-09-30', 'Rabies (3-year)|38.00\nDHPP booster|45.00\nLeptospirosis|32.00\nMicrochip registration update|15.00', 130.00, 'Amex', '1009');

-- ---------------------------------------------------------------- settings
INSERT INTO clinic_settings (setting_key, setting_value) VALUES
 ('clinic_name', 'Willowbrook Veterinary Clinic'),
 ('smtp_relay', 'smtp://reminders%40willowbrookvets.com:Smtp!Willow-2026@mail.willowbrookvets.com:587'),
 ('sms_gateway_token', 'sms_live_51b8e0c7a2d94f36'),
 ('pharmacy_api_token', 'rxp_live_8c1f2e7a9d3b46e0'),
 ('backup_passphrase', 'Willow-Backups-Oct2026!'),
 ('reminder_hours_before', '24');
