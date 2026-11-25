-- ICT371 Q10 Scholarship Application Assessment (PostgreSQL + pg_cron)
CREATE EXTENSION IF NOT EXISTS pg_cron;
DROP TABLE IF EXISTS decision_audit, applications, students CASCADE;

-- (a) Tables
CREATE TABLE students (
  student_id     SERIAL PRIMARY KEY,
  student_number VARCHAR(20) NOT NULL UNIQUE,
  full_name      VARCHAR(100) NOT NULL
);
CREATE TABLE applications (
  application_id     SERIAL PRIMARY KEY,
  student_id         INT NOT NULL REFERENCES students(student_id),
  age_at_application INT NOT NULL CHECK (age_at_application > 0),
  monthly_income     NUMERIC(10,2) NOT NULL CHECK (monthly_income >= 0),
  average_mark       NUMERIC(5,2)  NOT NULL CHECK (average_mark BETWEEN 0 AND 100),
  submitted_on       DATE NOT NULL,
  status             VARCHAR(10) NOT NULL DEFAULT 'PENDING'
                     CHECK (status IN ('PENDING','APPROVED','REJECTED'))
);
CREATE TABLE decision_audit (
  audit_id       SERIAL PRIMARY KEY,
  application_id INT NOT NULL REFERENCES applications(application_id),
  old_status     VARCHAR(10) NOT NULL,
  new_status     VARCHAR(10) NOT NULL,
  changed_at     TIMESTAMP NOT NULL DEFAULT now()
);

-- (b) Function
CREATE OR REPLACE FUNCTION fn_scholarship_eligible(p_age INT, p_income NUMERIC, p_mark NUMERIC)
RETURNS BOOLEAN LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
    RAISE EXCEPTION 'Age, income and mark must not be NULL';
  END IF;
  IF p_age <= 0 THEN RAISE EXCEPTION 'Age must be positive, got %', p_age; END IF;
  IF p_income < 0 THEN RAISE EXCEPTION 'Income cannot be negative, got %', p_income; END IF;
  IF p_mark < 0 OR p_mark > 100 THEN RAISE EXCEPTION 'Mark must be 0-100, got %', p_mark; END IF;
  RETURN p_age BETWEEN 18 AND 25 AND p_income <= 3000 AND p_mark >= 70;
END $$;

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id INT)
LANGUAGE plpgsql AS $$
DECLARE v_age INT; v_income NUMERIC; v_mark NUMERIC; v_status VARCHAR(10);
BEGIN
  SELECT age_at_application, monthly_income, average_mark, status
  INTO v_age, v_income, v_mark, v_status
  FROM applications WHERE application_id = p_application_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown application_id: %', p_application_id;
  END IF;
  IF v_status <> 'PENDING' THEN
    RAISE EXCEPTION 'Application % has already been assessed (status %)', p_application_id, v_status;
  END IF;
  UPDATE applications
  SET status = CASE WHEN fn_scholarship_eligible(v_age, v_income, v_mark)
                    THEN 'APPROVED' ELSE 'REJECTED' END
  WHERE application_id = p_application_id;
END $$;

-- (d) Trigger
CREATE OR REPLACE FUNCTION trg_decision_audit() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO decision_audit(application_id, old_status, new_status, changed_at)
  VALUES (OLD.application_id, OLD.status, NEW.status, now());
  RETURN NEW;
END $$;
CREATE TRIGGER trg_applications_decision_audit
AFTER UPDATE ON applications
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status)
EXECUTE FUNCTION trg_decision_audit();

-- (a) Seed: six PENDING applications, three students, boundary cases
INSERT INTO students(student_number, full_name) VALUES
 ('SC001','Alick Mwanza'), ('SC002','Beatrice Phiri'), ('SC003','Collins Tembo');
INSERT INTO applications(student_id, age_at_application, monthly_income, average_mark, submitted_on) VALUES
 (1, 18, 3000.00, 70.00, CURRENT_DATE - 20),  -- all three boundaries: qualifies
 (1, 25, 2500.00, 90.50, CURRENT_DATE - 18),  -- upper age boundary: qualifies
 (2, 21, 1500.00, 85.00, CURRENT_DATE - 15),  -- clearly qualifies
 (2, 26, 1000.00, 80.00, CURRENT_DATE - 12),  -- too old
 (3, 22, 3000.01, 75.00, CURRENT_DATE - 10),  -- income just above limit
 (3, 20, 2000.00, 69.99, CURRENT_DATE - 5);   -- mark just below limit

-- (e) View: income deliberately omitted
CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT s.student_number, s.full_name, a.average_mark, a.status
FROM applications a JOIN students s ON s.student_id = a.student_id
WHERE a.status = 'APPROVED';

-- (f) Equality column first (status), range column second (submitted_on)
CREATE INDEX idx_app_status_submitted ON applications(status, submitted_on);

-- (g) Batch procedure
CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql AS $$
DECLARE r RECORD;
BEGIN
  FOR r IN SELECT application_id FROM applications WHERE status = 'PENDING' ORDER BY application_id
  LOOP
    CALL pr_assess_application(r.application_id);
  END LOOP;
END $$;

SELECT cron.schedule('assess-pending', '0 8 * * 1', $$CALL pr_assess_pending()$$);

---------------------------- TESTS / EVIDENCE ----------------------------
SELECT fn_scholarship_eligible(18, 3000, 70);      -- t
SELECT fn_scholarship_eligible(26, 1000, 80);      -- f
DO $$ BEGIN PERFORM fn_scholarship_eligible(NULL, 1, 1);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_scholarship_eligible(20, -1, 80);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_scholarship_eligible(20, 100, 101);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
CALL pr_assess_application(1);                     -- APPROVED
DO $$ BEGIN CALL pr_assess_application(1);        -- already assessed
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_assess_application(99);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
CALL pr_assess_pending();                          -- processes applications 2-6
CALL pr_assess_pending();                          -- rerun: nothing pending, no new audit rows
SELECT application_id, status FROM applications ORDER BY 1;   -- 1,2,3 APPROVED; 4,5,6 REJECTED
SELECT * FROM decision_audit ORDER BY audit_id;               -- exactly 6 rows
UPDATE applications SET submitted_on = submitted_on WHERE application_id = 1;  -- no audit row
SELECT * FROM v_approved_applicants;
SET enable_seqscan = off;
EXPLAIN SELECT * FROM applications
WHERE status = 'PENDING' AND submitted_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
RESET enable_seqscan;
SELECT jobid, jobname, schedule FROM cron.job;
