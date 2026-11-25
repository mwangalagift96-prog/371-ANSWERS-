-- ICT371 Q5 Hostel Room Allocation (PostgreSQL + pg_cron)
CREATE EXTENSION IF NOT EXISTS pg_cron;
DROP TABLE IF EXISTS occupancy_snapshot, allocations, rooms, students CASCADE;

-- (a) Tables
CREATE TABLE students (
  student_id     SERIAL PRIMARY KEY,
  student_number VARCHAR(20) NOT NULL UNIQUE,
  full_name      VARCHAR(100) NOT NULL
);
CREATE TABLE rooms (
  room_id     SERIAL PRIMARY KEY,
  room_number VARCHAR(10) NOT NULL UNIQUE,
  capacity    INT NOT NULL CHECK (capacity > 0)
);
CREATE TABLE allocations (
  allocation_id SERIAL PRIMARY KEY,
  student_id    INT NOT NULL REFERENCES students(student_id),
  room_id       INT NOT NULL REFERENCES rooms(room_id),
  allocated_on  DATE NOT NULL,
  released_on   DATE,
  status        VARCHAR(10) NOT NULL CHECK (status IN ('ACTIVE','ENDED')),
  CONSTRAINT ck_status_release CHECK (
    (status = 'ACTIVE' AND released_on IS NULL) OR
    (status = 'ENDED'  AND released_on IS NOT NULL))
);
CREATE TABLE occupancy_snapshot (
  snapshot_date DATE NOT NULL,
  room_id       INT  NOT NULL REFERENCES rooms(room_id),
  occupied_beds INT  NOT NULL CHECK (occupied_beds >= 0),
  free_beds     INT  NOT NULL CHECK (free_beds >= 0),
  PRIMARY KEY (snapshot_date, room_id)
);
-- Concurrency safety net: one ACTIVE allocation per student
CREATE UNIQUE INDEX uq_one_active_per_student ON allocations(student_id) WHERE status = 'ACTIVE';

-- (b) Function
CREATE OR REPLACE FUNCTION fn_free_beds(p_room_id INT)
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE v_cap INT; v_active INT;
BEGIN
  SELECT capacity INTO v_cap FROM rooms WHERE room_id = p_room_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown room_id: %', p_room_id;
  END IF;
  SELECT COUNT(*) INTO v_active FROM allocations
  WHERE room_id = p_room_id AND status = 'ACTIVE';
  RETURN v_cap - v_active;
END $$;

-- (d) Trigger for direct SQL changes
CREATE OR REPLACE FUNCTION trg_check_allocation() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_cap INT; v_others INT;
BEGIN
  IF NEW.status = 'ACTIVE' THEN
    SELECT capacity INTO v_cap FROM rooms WHERE room_id = NEW.room_id FOR UPDATE; -- serialise per room
    SELECT COUNT(*) INTO v_others FROM allocations
    WHERE student_id = NEW.student_id AND status = 'ACTIVE'
      AND allocation_id <> NEW.allocation_id;               -- exclude the row being updated
    IF v_others > 0 THEN
      RAISE EXCEPTION 'Student % already has an ACTIVE allocation', NEW.student_id;
    END IF;
    SELECT COUNT(*) INTO v_others FROM allocations
    WHERE room_id = NEW.room_id AND status = 'ACTIVE'
      AND allocation_id <> NEW.allocation_id;
    IF v_others >= v_cap THEN
      RAISE EXCEPTION 'Room % is full (capacity %)', NEW.room_id, v_cap;
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_allocations_check
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW EXECUTE FUNCTION trg_check_allocation();

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_allocate_room(p_student_id INT, p_room_id INT, p_allocated_on DATE)
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM 1 FROM students WHERE student_id = p_student_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown student_id: %', p_student_id; END IF;
  PERFORM 1 FROM rooms WHERE room_id = p_room_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown room_id: %', p_room_id; END IF;
  IF p_allocated_on IS NULL THEN RAISE EXCEPTION 'Allocation date is required'; END IF;
  PERFORM 1 FROM allocations WHERE student_id = p_student_id AND status = 'ACTIVE';
  IF FOUND THEN
    RAISE EXCEPTION 'Student % already has an ACTIVE allocation', p_student_id;
  END IF;
  IF fn_free_beds(p_room_id) <= 0 THEN
    RAISE EXCEPTION 'Room % has no free beds', p_room_id;
  END IF;
  INSERT INTO allocations(student_id, room_id, allocated_on, released_on, status)
  VALUES (p_student_id, p_room_id, p_allocated_on, NULL, 'ACTIVE');
END $$;

-- (a) Seed: full (R101, R104), partly occupied (R102), empty (R103)
INSERT INTO students(student_number, full_name) VALUES
 ('H001','Alice Mwale'),('H002','Brian Chola'),('H003','Cynthia Daka'),
 ('H004','David Sichone'),('H005','Eve Kalaba'),('H006','Felix Musonda');
INSERT INTO rooms(room_number, capacity) VALUES ('R101',2),('R102',3),('R103',2),('R104',1);
CALL pr_allocate_room(1, 1, CURRENT_DATE - 60);
CALL pr_allocate_room(2, 1, CURRENT_DATE - 50);   -- R101 now full
CALL pr_allocate_room(3, 2, CURRENT_DATE - 40);   -- R102 partly occupied
CALL pr_allocate_room(4, 4, CURRENT_DATE - 30);   -- R104 full
CALL pr_allocate_room(5, 2, CURRENT_DATE - 90);
UPDATE allocations SET status = 'ENDED', released_on = CURRENT_DATE - 10
WHERE student_id = 5 AND status = 'ACTIVE';       -- history only, frees the bed

-- (e) View (LEFT JOIN keeps rooms without allocations)
CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT r.room_id, r.room_number, r.capacity,
       COUNT(a.allocation_id)              AS occupied_beds,
       r.capacity - COUNT(a.allocation_id) AS free_beds
FROM rooms r
LEFT JOIN allocations a ON a.room_id = r.room_id AND a.status = 'ACTIVE'
GROUP BY r.room_id, r.room_number, r.capacity;

-- (f) Partial index: only ACTIVE rows, searched by room
CREATE INDEX idx_alloc_active_room ON allocations(room_id) WHERE status = 'ACTIVE';

-- (g) Refresh procedure
CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO occupancy_snapshot(snapshot_date, room_id, occupied_beds, free_beds)
  SELECT CURRENT_DATE, room_id, occupied_beds, free_beds FROM v_room_occupancy
  ON CONFLICT (snapshot_date, room_id) DO UPDATE
    SET occupied_beds = EXCLUDED.occupied_beds, free_beds = EXCLUDED.free_beds;
END $$;

SELECT cron.schedule('refresh-occupancy', '55 23 * * *', $$CALL pr_refresh_occupancy()$$);

---------------------------- TESTS / EVIDENCE ----------------------------
SELECT room_id, fn_free_beds(room_id) FROM rooms ORDER BY 1;   -- 0, 2, 2, 0
DO $$ BEGIN PERFORM fn_free_beds(99);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_allocate_room(6, 1, CURRENT_DATE);          -- full room
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_allocate_room(1, 3, CURRENT_DATE);          -- already ACTIVE
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
-- Direct SQL is also blocked by the trigger:
DO $$ BEGIN INSERT INTO allocations(student_id,room_id,allocated_on,status) VALUES (6,1,CURRENT_DATE,'ACTIVE');
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
SELECT * FROM v_room_occupancy ORDER BY room_number;
CALL pr_refresh_occupancy();
CALL pr_refresh_occupancy();                                    -- rerun replaces values
SELECT * FROM occupancy_snapshot ORDER BY room_id;
SET enable_seqscan = off;
EXPLAIN SELECT * FROM allocations WHERE room_id = 2 AND status = 'ACTIVE';
RESET enable_seqscan;
SELECT jobid, jobname, schedule FROM cron.job;
