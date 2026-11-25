-- ICT371 Q8 Transport Fleet Maintenance (PostgreSQL + pg_cron)
CREATE EXTENSION IF NOT EXISTS pg_cron;
DROP TABLE IF EXISTS service_alerts, trips, vehicles CASCADE;

-- (a) Tables
CREATE TABLE vehicles (
  vehicle_id            SERIAL PRIMARY KEY,
  registration          VARCHAR(15) NOT NULL UNIQUE,
  current_odometer      INT NOT NULL CHECK (current_odometer >= 0),
  last_service_odometer INT NOT NULL CHECK (last_service_odometer >= 0),
  CONSTRAINT ck_service_le_current CHECK (last_service_odometer <= current_odometer)
);
CREATE TABLE trips (
  trip_id        SERIAL PRIMARY KEY,
  vehicle_id     INT  NOT NULL REFERENCES vehicles(vehicle_id),
  trip_on        DATE NOT NULL,
  start_odometer INT  NOT NULL CHECK (start_odometer >= 0),
  end_odometer   INT  NOT NULL CHECK (end_odometer >= 0)
);
CREATE TABLE service_alerts (
  vehicle_id       INT PRIMARY KEY REFERENCES vehicles(vehicle_id),
  km_since_service INT  NOT NULL,
  flagged_on       DATE NOT NULL
);

-- (b) Function
CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id INT)
RETURNS BOOLEAN LANGUAGE plpgsql AS $$
DECLARE v_km INT;
BEGIN
  SELECT current_odometer - last_service_odometer INTO v_km
  FROM vehicles WHERE vehicle_id = p_vehicle_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
  END IF;
  RETURN v_km >= 5000;
END $$;

-- (d) Trigger: validates, then advances the odometer once per inserted trip
CREATE OR REPLACE FUNCTION trg_trip_odometer() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_current INT;
BEGIN
  SELECT current_odometer INTO v_current FROM vehicles
  WHERE vehicle_id = NEW.vehicle_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown vehicle_id: %', NEW.vehicle_id;
  END IF;
  IF NEW.start_odometer < 0 OR NEW.end_odometer <= NEW.start_odometer THEN
    RAISE EXCEPTION 'Invalid mileage: start %, end %', NEW.start_odometer, NEW.end_odometer;
  END IF;
  IF NEW.start_odometer <> v_current THEN
    RAISE EXCEPTION 'Trip must start at current odometer %, got %', v_current, NEW.start_odometer;
  END IF;
  UPDATE vehicles SET current_odometer = NEW.end_odometer WHERE vehicle_id = NEW.vehicle_id;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_trips_odometer
BEFORE INSERT ON trips
FOR EACH ROW EXECUTE FUNCTION trg_trip_odometer();

-- (c) Procedure: does not touch the odometer itself
CREATE OR REPLACE PROCEDURE pr_record_trip(p_vehicle_id INT, p_trip_on DATE, p_start INT, p_end INT)
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM 1 FROM vehicles WHERE vehicle_id = p_vehicle_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id; END IF;
  IF p_trip_on IS NULL OR p_start IS NULL OR p_end IS NULL THEN
    RAISE EXCEPTION 'Trip date and odometer readings are required';
  END IF;
  IF p_end <= p_start THEN
    RAISE EXCEPTION 'end_odometer (%) must be greater than start_odometer (%)', p_end, p_start;
  END IF;
  INSERT INTO trips(vehicle_id, trip_on, start_odometer, end_odometer)
  VALUES (p_vehicle_id, p_trip_on, p_start, p_end);
END $$;

-- (a) Seed: vehicles first, trips through the procedure (trigger already installed)
INSERT INTO vehicles(registration, current_odometer, last_service_odometer) VALUES
 ('BAK 1001', 12000, 11000),   -- 1,000 km since service
 ('BAL 2002', 20000, 14000),   -- 6,000 km: already due
 ('BAM 3003',  5000,     0);   -- exactly 5,000 km: due
CALL pr_record_trip(1, CURRENT_DATE - 10, 12000, 12300);
CALL pr_record_trip(1, CURRENT_DATE - 5,  12300, 12800);
CALL pr_record_trip(2, CURRENT_DATE - 9,  20000, 20400);
CALL pr_record_trip(2, CURRENT_DATE - 4,  20400, 21000);
CALL pr_record_trip(3, CURRENT_DATE - 8,   5000,  5200);
CALL pr_record_trip(3, CURRENT_DATE - 3,   5200,  5600);

-- (e) View
CREATE OR REPLACE VIEW v_service_due AS
SELECT registration, current_odometer - last_service_odometer AS km_since_service
FROM vehicles WHERE current_odometer - last_service_odometer >= 5000;

-- (f) Index: equality on vehicle_id, then range scan on trip_on
CREATE INDEX idx_trips_vehicle_date ON trips(vehicle_id, trip_on);

-- (g) Alert refresh: upsert due vehicles, delete the rest
CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO service_alerts(vehicle_id, km_since_service, flagged_on)
  SELECT vehicle_id, current_odometer - last_service_odometer, CURRENT_DATE
  FROM vehicles WHERE current_odometer - last_service_odometer >= 5000
  ON CONFLICT (vehicle_id) DO UPDATE SET km_since_service = EXCLUDED.km_since_service;
  DELETE FROM service_alerts a
  WHERE NOT EXISTS (SELECT 1 FROM vehicles v
                    WHERE v.vehicle_id = a.vehicle_id
                      AND v.current_odometer - v.last_service_odometer >= 5000);
END $$;

SELECT cron.schedule('refresh-service-alerts', '0 6 * * 1', $$CALL pr_refresh_service_alerts()$$);

---------------------------- TESTS / EVIDENCE ----------------------------
SELECT vehicle_id, current_odometer FROM vehicles ORDER BY 1;     -- 12800, 21000, 5600
SELECT vehicle_id, fn_service_due(vehicle_id) FROM vehicles ORDER BY 1;  -- f, t, t
DO $$ BEGIN PERFORM fn_service_due(99);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_record_trip(1, CURRENT_DATE, 13000, 13100);  -- wrong start
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_record_trip(1, CURRENT_DATE, 12800, 12800);  -- end not > start
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN INSERT INTO trips(vehicle_id,trip_on,start_odometer,end_odometer)  -- direct SQL
  VALUES (1, CURRENT_DATE, 100, 200);
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
SELECT * FROM v_service_due;
CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts;                                      -- vehicles 2 and 3
UPDATE vehicles SET last_service_odometer = current_odometer WHERE vehicle_id = 2;  -- serviced
CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts;                                      -- only vehicle 3 remains
SET enable_seqscan = off;
EXPLAIN SELECT * FROM trips
WHERE vehicle_id = 1 AND trip_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
RESET enable_seqscan;
SELECT jobid, jobname, schedule FROM cron.job;
