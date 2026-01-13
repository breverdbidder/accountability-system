-- ACTIVE_TASKS TABLE SCHEMA
-- Zero ambiguity task tracking system

CREATE TABLE IF NOT EXISTS active_tasks (
    task_id SERIAL PRIMARY KEY,
    description TEXT NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    status TEXT CHECK (status IN ('INITIATED', 'BLOCKED', 'COMPLETED')) DEFAULT 'INITIATED',
    who_owns TEXT CHECK (who_owns IN ('ARIEL', 'CLAUDE', 'BOTH')) NOT NULL,
    completion_artifacts JSONB,
    complexity INT CHECK (complexity BETWEEN 1 AND 10),
    estimated_minutes INT,
    blocked_reason TEXT,
    completed_at TIMESTAMPTZ,
    artifact_verified BOOLEAN DEFAULT FALSE,
    CONSTRAINT completion_check CHECK (
        (status = 'COMPLETED' AND completion_artifacts IS NOT NULL AND artifact_verified = TRUE)
        OR status != 'COMPLETED'
    )
);

-- NO NEW TASKS RULE: Max 3 open at once
CREATE OR REPLACE FUNCTION enforce_max_open_tasks()
RETURNS TRIGGER AS $$
BEGIN
    IF (SELECT COUNT(*) FROM active_tasks WHERE status IN ('INITIATED', 'BLOCKED')) >= 3 THEN
        RAISE EXCEPTION '⛔ BLOCKED: 3 open tasks exist. Clear one first.';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER check_max_tasks
BEFORE INSERT ON active_tasks
FOR EACH ROW
EXECUTE FUNCTION enforce_max_open_tasks();

-- TASK ABANDONMENT TRACKING
CREATE TABLE IF NOT EXISTS task_timeline (
    event_id SERIAL PRIMARY KEY,
    task_id INT REFERENCES active_tasks(task_id),
    event_type TEXT CHECK (event_type IN ('CREATED', 'SOLUTION_PROVIDED', 'USER_SWITCHED_CONTEXT', 'BLOCKED', 'COMPLETED', 'INTERVENTION')),
    event_timestamp TIMESTAMPTZ DEFAULT NOW(),
    minutes_elapsed INT,
    context_note TEXT
);

-- AUTO-INSERT ABANDONMENT EVENTS
CREATE OR REPLACE FUNCTION log_task_event(
    p_task_id INT,
    p_event_type TEXT,
    p_context_note TEXT DEFAULT NULL
) RETURNS VOID AS $$
DECLARE
    v_minutes_elapsed INT;
    v_created_at TIMESTAMPTZ;
BEGIN
    SELECT created_at INTO v_created_at FROM active_tasks WHERE task_id = p_task_id;
    v_minutes_elapsed := EXTRACT(EPOCH FROM (NOW() - v_created_at))/60;
    
    INSERT INTO task_timeline (task_id, event_type, event_timestamp, minutes_elapsed, context_note)
    VALUES (p_task_id, p_event_type, NOW(), v_minutes_elapsed, p_context_note);
END;
$$ LANGUAGE plpgsql;

-- VIEW: CURRENT OPEN TASKS
CREATE OR REPLACE VIEW current_open_tasks AS
SELECT 
    task_id,
    description,
    status,
    who_owns,
    EXTRACT(EPOCH FROM (NOW() - created_at))/60 AS minutes_open,
    CASE
        WHEN EXTRACT(EPOCH FROM (NOW() - created_at))/60 > 60 THEN '⚠️ CRITICAL'
        WHEN EXTRACT(EPOCH FROM (NOW() - created_at))/60 > 30 THEN '🔄 WARNING'
        WHEN EXTRACT(EPOCH FROM (NOW() - created_at))/60 > 15 THEN '📌 ATTENTION'
        ELSE '✅ NORMAL'
    END AS alert_level,
    completion_artifacts,
    artifact_verified
FROM active_tasks
WHERE status IN ('INITIATED', 'BLOCKED')
ORDER BY created_at ASC;

