-- ICT371 Q6 Monthly Payroll Processing (PostgreSQL + pg_cron)
CREATE EXTENSION IF NOT EXISTS pg_cron;
DROP TABLE IF EXISTS salary_audit, payroll, employees CASCADE;

-- (a) Tables
CREATE TABLE employees (
  employee_id  SERIAL PRIMARY KEY,
  full_name    VARCHAR(100) NOT NULL,
  basic_salary NUMERIC(12,2) NOT NULL CHECK (basic_salary >= 0),
  allowance    NUMERIC(12,2) NOT NULL CHECK (allowance >= 0),
  deduction    NUMERIC(12,2) NOT NULL CHECK (deduction >= 0),
  active       BOOLEAN NOT NULL DEFAULT TRUE
);
CREATE TABLE payroll (
  payroll_id  SERIAL PRIMARY KEY,
  employee_id INT  NOT NULL REFERENCES employees(employee_id),
  pay_month   DATE NOT NULL CHECK (EXTRACT(DAY FROM pay_month) = 1),
  gross_pay   NUMERIC(12,2) NOT NULL CHECK (gross_pay >= 0),
  net_pay     NUMERIC(12,2) NOT NULL CHECK (net_pay >= 0),
  CONSTRAINT uq_employee_month UNIQUE (employee_id, pay_month)
);
CREATE TABLE salary_audit (
  audit_id    SERIAL PRIMARY KEY,
  employee_id INT NOT NULL REFERENCES employees(employee_id),
  old_salary  NUMERIC(12,2) NOT NULL,
  new_salary  NUMERIC(12,2) NOT NULL,
  changed_at  TIMESTAMP NOT NULL DEFAULT now()
);

-- (b) Function
CREATE OR REPLACE FUNCTION fn_net_pay(p_employee_id INT)
RETURNS NUMERIC LANGUAGE plpgsql AS $$
DECLARE v_basic NUMERIC; v_allow NUMERIC; v_ded NUMERIC; v_net NUMERIC;
BEGIN
  SELECT basic_salary, allowance, deduction INTO v_basic, v_allow, v_ded
  FROM employees WHERE employee_id = p_employee_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown employee_id: %', p_employee_id;
  END IF;
  v_net := v_basic + v_allow - v_ded;
  IF v_net < 0 THEN
    RAISE EXCEPTION 'Negative net pay (%) for employee %', v_net, p_employee_id;
  END IF;
  RETURN v_net;
END $$;

-- (c) Procedure: query FOR loop; any exception aborts the entire call (all-or-nothing)
CREATE OR REPLACE PROCEDURE pr_process_payroll(p_month DATE)
LANGUAGE plpgsql AS $$
DECLARE r RECORD; v_net NUMERIC;
BEGIN
  IF p_month IS NULL OR EXTRACT(DAY FROM p_month) <> 1 THEN
    RAISE EXCEPTION 'p_month must be the first day of a month, got %', p_month;
  END IF;
  FOR r IN SELECT employee_id, basic_salary, allowance FROM employees WHERE active ORDER BY employee_id
  LOOP
    v_net := fn_net_pay(r.employee_id);          -- raises on an invalid calculation
    INSERT INTO payroll(employee_id, pay_month, gross_pay, net_pay)
    VALUES (r.employee_id, p_month, r.basic_salary + r.allowance, v_net)
    ON CONFLICT (employee_id, pay_month) DO NOTHING;   -- existing rows stay unchanged
  END LOOP;
END $$;

-- (d) Trigger
CREATE OR REPLACE FUNCTION trg_salary_audit() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO salary_audit(employee_id, old_salary, new_salary)
  VALUES (OLD.employee_id, OLD.basic_salary, NEW.basic_salary);
  RETURN NEW;
END $$;
CREATE TRIGGER trg_employees_salary_audit
AFTER UPDATE ON employees
FOR EACH ROW
WHEN (OLD.basic_salary IS DISTINCT FROM NEW.basic_salary)
EXECUTE FUNCTION trg_salary_audit();

-- (a) Seed: active + inactive employees, two payroll months
INSERT INTO employees(full_name, basic_salary, allowance, deduction, active) VALUES
 ('Peter Mumba',  8000, 1500, 1200, TRUE),
 ('Ruth Kasonde', 6500, 1000,  900, TRUE),
 ('Sam Bwalya',   7000,  500,  800, TRUE),
 ('Tina Lubinda', 5000,  500,  600, FALSE);     -- inactive: never processed
CALL pr_process_payroll(DATE '2026-09-01');
CALL pr_process_payroll(DATE '2026-10-01');
UPDATE employees SET active = FALSE WHERE employee_id = 3;     -- left after two months of history

-- (e) View: no active filter, so history of inactive staff is kept
CREATE OR REPLACE VIEW v_payroll_report AS
SELECT e.full_name, p.pay_month, p.gross_pay, p.net_pay
FROM payroll p JOIN employees e ON e.employee_id = p.employee_id;

-- (f) The unique index leads with employee_id, so it cannot efficiently serve a pay_month-only filter
CREATE INDEX idx_payroll_pay_month ON payroll(pay_month);

-- (g) Schedule 02:00 on the 1st of each month for the previous month
SELECT cron.schedule('monthly-payroll', '0 2 1 * *',
  $$CALL pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date)$$);

---------------------------- TESTS / EVIDENCE ----------------------------
SELECT fn_net_pay(1);                                          -- 8300
DO $$ BEGIN PERFORM fn_net_pay(99);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_process_payroll(DATE '2026-11-15');        -- not a month start
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
CALL pr_process_payroll(DATE '2026-10-01');                    -- rerun: nothing duplicated or changed
SELECT COUNT(*) FROM payroll;                                  -- 2 months x 3 = 6 rows
-- Failure is all-or-nothing: an invalid active employee aborts the whole month
UPDATE employees SET deduction = 99999 WHERE employee_id = 2;
DO $$ BEGIN CALL pr_process_payroll(DATE '2026-11-01');
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
SELECT COUNT(*) FROM payroll WHERE pay_month = DATE '2026-11-01';   -- 0 (employee 1 not saved either)
UPDATE employees SET deduction = 900 WHERE employee_id = 2;    -- restore
UPDATE employees SET basic_salary = 9000 WHERE employee_id = 1;     -- audited
UPDATE employees SET basic_salary = 9000 WHERE employee_id = 1;     -- unchanged: no audit row
SELECT * FROM salary_audit;
SELECT * FROM v_payroll_report ORDER BY pay_month, full_name;
SET enable_seqscan = off;
EXPLAIN SELECT * FROM payroll WHERE pay_month = DATE '2026-10-01';
RESET enable_seqscan;
-- Inspect the job and its run history
SELECT jobid, jobname, schedule, command, active FROM cron.job WHERE jobname = 'monthly-payroll';
SELECT runid, status, return_message, start_time, end_time
FROM cron.job_run_details
WHERE jobid = (SELECT jobid FROM cron.job WHERE jobname = 'monthly-payroll')
ORDER BY start_time DESC;
