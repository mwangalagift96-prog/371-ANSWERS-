-- ICT371 Q3 Library Returns and Overdue Fines (PostgreSQL + pg_cron)
CREATE EXTENSION IF NOT EXISTS pg_cron;
DROP TABLE IF EXISTS overdue_summary, loan_audit, loans, books CASCADE;

-- (a) Tables
CREATE TABLE books (
  book_id SERIAL PRIMARY KEY,
  title   VARCHAR(150) NOT NULL
);
CREATE TABLE loans (
  loan_id       SERIAL PRIMARY KEY,
  book_id       INT NOT NULL REFERENCES books(book_id),
  borrower_name VARCHAR(100) NOT NULL,
  borrowed_on   DATE NOT NULL,
  due_on        DATE NOT NULL,
  returned_on   DATE,
  fine_amount   NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (fine_amount >= 0),
  CONSTRAINT ck_due_after_borrow CHECK (due_on >= borrowed_on)
);
CREATE TABLE loan_audit (
  audit_id         SERIAL PRIMARY KEY,
  loan_id          INT NOT NULL REFERENCES loans(loan_id),
  old_returned_on  DATE,
  new_returned_on  DATE,
  changed_at       TIMESTAMP NOT NULL DEFAULT now()
);
CREATE TABLE overdue_summary (
  snapshot_date DATE PRIMARY KEY,
  overdue_count INT NOT NULL,
  total_fine    NUMERIC(12,2) NOT NULL
);

-- (b) Function: K2 per day late, stops accruing at return
CREATE OR REPLACE FUNCTION fn_loan_fine(p_loan_id INT, p_as_of DATE)
RETURNS NUMERIC LANGUAGE plpgsql AS $$
DECLARE v_due DATE; v_ret DATE; v_end DATE;
BEGIN
  SELECT due_on, returned_on INTO v_due, v_ret FROM loans WHERE loan_id = p_loan_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown loan_id: %', p_loan_id;
  END IF;
  IF p_as_of IS NULL THEN
    RAISE EXCEPTION 'p_as_of is required';
  END IF;
  v_end := LEAST(p_as_of, COALESCE(v_ret, p_as_of));
  RETURN 2 * GREATEST(v_end - v_due, 0);
END $$;

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_return_loan(p_loan_id INT, p_returned_on DATE)
LANGUAGE plpgsql AS $$
DECLARE v_borrowed DATE; v_ret DATE; v_due DATE;
BEGIN
  SELECT borrowed_on, returned_on, due_on INTO v_borrowed, v_ret, v_due
  FROM loans WHERE loan_id = p_loan_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown loan_id: %', p_loan_id;
  END IF;
  IF v_ret IS NOT NULL THEN
    RAISE EXCEPTION 'Loan % was already returned on %', p_loan_id, v_ret;
  END IF;
  IF p_returned_on IS NULL OR p_returned_on < v_borrowed THEN
    RAISE EXCEPTION 'Return date % is before borrowed date %', p_returned_on, v_borrowed;
  END IF;
  UPDATE loans
  SET returned_on = p_returned_on,
      fine_amount = 2 * GREATEST(p_returned_on - v_due, 0)   -- same rule as fn_loan_fine
  WHERE loan_id = p_loan_id;
END $$;

-- (d) Trigger
CREATE OR REPLACE FUNCTION trg_loan_audit() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO loan_audit(loan_id, old_returned_on, new_returned_on)
  VALUES (OLD.loan_id, OLD.returned_on, NEW.returned_on);
  RETURN NEW;
END $$;
CREATE TRIGGER trg_loans_return_audit
AFTER UPDATE ON loans
FOR EACH ROW
WHEN (OLD.returned_on IS DISTINCT FROM NEW.returned_on)
EXECUTE FUNCTION trg_loan_audit();

-- (a) Seed: 3 books, 6 loans (dates relative to today so results stay meaningful)
INSERT INTO books(title) VALUES
 ('Database System Concepts'), ('Introduction to Algorithms'), ('Operating System Concepts');
INSERT INTO loans(book_id, borrower_name, borrowed_on, due_on) VALUES
 (1, 'Alice Zulu',    CURRENT_DATE - 30, CURRENT_DATE - 16),  -- 1 open, overdue
 (1, 'Bob Tembo',     CURRENT_DATE - 5,  CURRENT_DATE + 9),   -- 2 open, on time
 (2, 'Chola Mumba',   CURRENT_DATE - 20, CURRENT_DATE - 6),   -- 3 returned on due date
 (2, 'Dalitso Njobvu',CURRENT_DATE - 25, CURRENT_DATE - 11),  -- 4 returned late
 (3, 'Esther Lungu',  CURRENT_DATE - 14, CURRENT_DATE - 1),   -- 5 open, overdue
 (3, 'Femi Sakala',   CURRENT_DATE - 3,  CURRENT_DATE + 11);  -- 6 open, on time
CALL pr_return_loan(3, CURRENT_DATE - 6);   -- due date: fine 0
CALL pr_return_loan(4, CURRENT_DATE - 8);   -- 3 days late: fine K6

-- (e) View
CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT l.loan_id, b.title, l.borrower_name, l.due_on,
       fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_today
FROM loans l JOIN books b ON b.book_id = l.book_id
WHERE l.returned_on IS NULL AND l.due_on < CURRENT_DATE;

-- (f) Partial index: only unreturned loans are indexed, keyed by book
CREATE INDEX idx_loans_open_by_book ON loans(book_id) WHERE returned_on IS NULL;

-- (g) Refresh procedure
-- Counts loans still unreturned as of p_as_of (never returned, or returned after that date)
CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO overdue_summary(snapshot_date, overdue_count, total_fine)
  SELECT p_as_of, COUNT(*), COALESCE(SUM(2 * GREATEST(p_as_of - due_on, 0)),0)
  FROM loans
  WHERE borrowed_on <= p_as_of AND (returned_on IS NULL OR returned_on > p_as_of)
  ON CONFLICT (snapshot_date) DO UPDATE
    SET overdue_count = EXCLUDED.overdue_count, total_fine = EXCLUDED.total_fine;
END $$;
-- To count only loans already past due, add "AND due_on < p_as_of" to the WHERE clause.

SELECT cron.schedule('refresh-overdue', '10 0 * * *', $$CALL pr_refresh_overdue(CURRENT_DATE)$$);

---------------------------- TESTS / EVIDENCE ----------------------------
SELECT fn_loan_fine(1, CURRENT_DATE);   -- 32
SELECT fn_loan_fine(3, CURRENT_DATE);   -- 0 (returned on due date)
SELECT fn_loan_fine(4, CURRENT_DATE);   -- 6 (stops at return date)
DO $$ BEGIN PERFORM fn_loan_fine(99, CURRENT_DATE);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_return_loan(3, CURRENT_DATE);            -- already returned
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_return_loan(2, CURRENT_DATE - 30);       -- before borrowed_on
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
UPDATE loans SET borrower_name = 'Alice B. Zulu' WHERE loan_id = 1;  -- no audit row
SELECT * FROM loan_audit ORDER BY audit_id;
SELECT * FROM v_overdue_loans;
CALL pr_refresh_overdue(CURRENT_DATE);
CALL pr_refresh_overdue(CURRENT_DATE);     -- rerun replaces
SELECT * FROM overdue_summary;
SET enable_seqscan = off;
EXPLAIN SELECT * FROM loans WHERE book_id = 1 AND returned_on IS NULL;
RESET enable_seqscan;
SELECT jobid, jobname, schedule FROM cron.job;
