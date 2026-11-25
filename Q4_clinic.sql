-- ICT371 Q4 Clinic Appointment Scheduling (PostgreSQL + pg_cron)
CREATE EXTENSION IF NOT EXISTS pg_cron;
DROP TABLE IF EXISTS clinic_summary, appointments, doctors, patients CASCADE;

-- (a) Tables
CREATE TABLE patients (patient_id SERIAL PRIMARY KEY, full_name VARCHAR(100) NOT NULL);
CREATE TABLE doctors  (doctor_id  SERIAL PRIMARY KEY, full_name VARCHAR(100) NOT NULL);
CREATE TABLE appointments (
  appointment_id  SERIAL PRIMARY KEY,
  patient_id      INT  NOT NULL REFERENCES patients(patient_id),
  doctor_id       INT  NOT NULL REFERENCES doctors(doctor_id),
  appointment_day DATE NOT NULL,
  slot_time       TIME NOT NULL CHECK (slot_time IN ('09:00','10:00','11:00','12:00')),
  status          VARCHAR(10) NOT NULL DEFAULT 'BOOKED'
                  CHECK (status IN ('BOOKED','ATTENDED','CANCELLED'))
);
CREATE TABLE clinic_summary (
  summary_date    DATE PRIMARY KEY,
  booked_count    INT NOT NULL,
  attended_count  INT NOT NULL,
  cancelled_count INT NOT NULL
);
-- Safety net against concurrent sessions slipping past the trigger
CREATE UNIQUE INDEX uq_active_slot ON appointments(doctor_id, appointment_day, slot_time)
WHERE status <> 'CANCELLED';

-- (b) Function
CREATE OR REPLACE FUNCTION fn_daily_load(p_doctor_id INT, p_day DATE)
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE v_n INT;
BEGIN
  PERFORM 1 FROM doctors WHERE doctor_id = p_doctor_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown doctor_id: %', p_doctor_id;
  END IF;
  SELECT COUNT(*) INTO v_n FROM appointments
  WHERE doctor_id = p_doctor_id AND appointment_day = p_day AND status <> 'CANCELLED';
  RETURN v_n;                      -- COUNT returns 0 when there are no bookings
END $$;

-- (d) Trigger (created before the procedure and seed data)
CREATE OR REPLACE FUNCTION trg_check_clash() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.status <> 'CANCELLED' THEN
    PERFORM 1 FROM appointments a
    WHERE a.doctor_id = NEW.doctor_id
      AND a.appointment_day = NEW.appointment_day
      AND a.slot_time = NEW.slot_time
      AND a.status <> 'CANCELLED'
      AND a.appointment_id <> NEW.appointment_id;   -- excludes the row being changed
    IF FOUND THEN
      RAISE EXCEPTION 'Doctor % already has an appointment on % at %',
                      NEW.doctor_id, NEW.appointment_day, NEW.slot_time;
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_appointments_clash
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW EXECUTE FUNCTION trg_check_clash();

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_book_appointment(p_patient_id INT, p_doctor_id INT, p_day DATE, p_slot TIME)
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM 1 FROM patients WHERE patient_id = p_patient_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown patient_id: %', p_patient_id; END IF;
  PERFORM 1 FROM doctors WHERE doctor_id = p_doctor_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown doctor_id: %', p_doctor_id; END IF;
  IF p_day IS NULL OR p_day < CURRENT_DATE THEN
    RAISE EXCEPTION 'Appointment date % is in the past or missing', p_day;
  END IF;
  IF p_slot IS NULL OR p_slot NOT IN ('09:00','10:00','11:00','12:00') THEN
    RAISE EXCEPTION 'Unsupported slot: %', p_slot;
  END IF;
  INSERT INTO appointments(patient_id, doctor_id, appointment_day, slot_time, status)
  VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');
END $$;

-- (a) Seed (via the procedure, so the trigger validates every row)
INSERT INTO patients(full_name) VALUES ('Mary Chileshe'), ('John Kapambwe'), ('Grace Mulenga');
INSERT INTO doctors(full_name)  VALUES ('Dr. Banda'), ('Dr. Zimba'), ('Dr. Mwansa');
CALL pr_book_appointment(1, 1, CURRENT_DATE,     '09:00');
CALL pr_book_appointment(2, 1, CURRENT_DATE,     '10:00');
CALL pr_book_appointment(3, 2, CURRENT_DATE,     '09:00');   -- different doctor, same slot: allowed
CALL pr_book_appointment(1, 3, CURRENT_DATE + 1, '11:00');
CALL pr_book_appointment(2, 2, CURRENT_DATE + 1, '12:00');
CALL pr_book_appointment(3, 1, CURRENT_DATE + 2, '09:00');
UPDATE appointments SET status = 'ATTENDED'  WHERE appointment_id = 2;
UPDATE appointments SET status = 'CANCELLED' WHERE appointment_id = 5;

-- (e) View: no patient IDs or other personal data beyond the name
CREATE OR REPLACE VIEW v_today_appointments AS
SELECT p.full_name AS patient_name, d.full_name AS doctor_name, a.slot_time
FROM appointments a
JOIN patients p ON p.patient_id = a.patient_id
JOIN doctors  d ON d.doctor_id  = a.doctor_id
WHERE a.appointment_day = CURRENT_DATE AND a.status = 'BOOKED';

-- (f) Non-unique composite index
CREATE INDEX idx_appt_day_doctor ON appointments(appointment_day, doctor_id);

-- (g) Refresh procedure
CREATE OR REPLACE PROCEDURE pr_refresh_clinic_summary(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO clinic_summary(summary_date, booked_count, attended_count, cancelled_count)
  SELECT p_day,
         COUNT(*) FILTER (WHERE status = 'BOOKED'),
         COUNT(*) FILTER (WHERE status = 'ATTENDED'),
         COUNT(*) FILTER (WHERE status = 'CANCELLED')
  FROM appointments WHERE appointment_day = p_day
  ON CONFLICT (summary_date) DO UPDATE
    SET booked_count = EXCLUDED.booked_count,
        attended_count = EXCLUDED.attended_count,
        cancelled_count = EXCLUDED.cancelled_count;
END $$;

SELECT cron.schedule('refresh-clinic-summary', '0 1 * * *',
                     $$CALL pr_refresh_clinic_summary(CURRENT_DATE - 1)$$);

---------------------------- TESTS / EVIDENCE ----------------------------
SELECT fn_daily_load(1, CURRENT_DATE);        -- 2
SELECT fn_daily_load(3, CURRENT_DATE + 30);   -- 0
DO $$ BEGIN PERFORM fn_daily_load(99, CURRENT_DATE);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_book_appointment(1, 1, CURRENT_DATE, '09:00');       -- clash
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_book_appointment(1, 1, CURRENT_DATE - 1, '09:00');   -- past
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_book_appointment(1, 1, CURRENT_DATE + 1, '13:00');   -- bad slot
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
-- UPDATE clash (moving appointment 3 to doctor 1's 09:00 slot) is rejected:
DO $$ BEGIN UPDATE appointments SET doctor_id = 1 WHERE appointment_id = 3;
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
-- Updating a row without changing its slot is NOT a clash with itself:
UPDATE appointments SET status = 'BOOKED' WHERE appointment_id = 1;
SELECT * FROM v_today_appointments;
CALL pr_refresh_clinic_summary(CURRENT_DATE);
CALL pr_refresh_clinic_summary(CURRENT_DATE);   -- rerun replaces
SELECT * FROM clinic_summary;
SET enable_seqscan = off;
EXPLAIN SELECT * FROM appointments WHERE appointment_day = CURRENT_DATE AND doctor_id = 1;
RESET enable_seqscan;
SELECT jobid, jobname, schedule FROM cron.job;
