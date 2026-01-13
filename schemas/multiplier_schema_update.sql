-- MULTIPLIER FRAMEWORK: Active Tasks Schema Update
-- Add The 5 Permissions fields to existing active_tasks table
-- Date: January 13, 2026

-- Add new columns for Multiplier decision framework
ALTER TABLE active_tasks 
ADD COLUMN IF NOT EXISTS permission_stage TEXT CHECK (
    permission_stage IN (
        'ELIMINATE_REVIEW',
        'AUTOMATE_REVIEW',
        'DELEGATE_REVIEW',
        'PROCRASTINATE_REVIEW',
        'CONCENTRATE_ACTIVE',
        'ELIMINATED',
        'AUTOMATED',
        'DELEGATED',
        'DEFERRED'
    )
),
ADD COLUMN IF NOT EXISTS significance_score INT,  -- Importance × Time
ADD COLUMN IF NOT EXISTS roti_calculation JSONB,  -- {time_invested, time_saved, ratio}
ADD COLUMN IF NOT EXISTS mvot_comparison JSONB,   -- {ariel_rate, delegate_rate, savings}
ADD COLUMN IF NOT EXISTS defer_until DATE,        -- For PROCRASTINATE
ADD COLUMN IF NOT EXISTS defer_reason TEXT,
ADD COLUMN IF NOT EXISTS eliminated_reason TEXT,
ADD COLUMN IF NOT EXISTS automation_plan TEXT,
ADD COLUMN IF NOT EXISTS delegate_to TEXT;

-- Update constraint for status to include new states
ALTER TABLE active_tasks DROP CONSTRAINT IF EXISTS active_tasks_status_check;
ALTER TABLE active_tasks ADD CONSTRAINT active_tasks_status_check 
CHECK (status IN ('INITIATED', 'BLOCKED', 'COMPLETED', 'ELIMINATED', 'DEFERRED', 'AUTOMATED', 'DELEGATED'));

-- Create view for current workload (only actionable tasks)
CREATE OR REPLACE VIEW current_workload AS
SELECT 
    task_id,
    description,
    status,
    permission_stage,
    who_owns,
    significance_score,
    EXTRACT(EPOCH FROM (NOW() - created_at))/60 AS minutes_open,
    CASE
        WHEN permission_stage = 'CONCENTRATE_ACTIVE' THEN '🎯 CRITICAL'
        WHEN EXTRACT(EPOCH FROM (NOW() - created_at))/60 > 60 THEN '⚠️ OVERDUE'
        WHEN EXTRACT(EPOCH FROM (NOW() - created_at))/60 > 30 THEN '🔄 WARNING'
        WHEN EXTRACT(EPOCH FROM (NOW() - created_at))/60 > 15 THEN '📌 ATTENTION'
        ELSE '✅ NORMAL'
    END AS alert_level
FROM active_tasks
WHERE status IN ('INITIATED', 'BLOCKED')
  AND permission_stage NOT IN ('ELIMINATED', 'DEFERRED')
ORDER BY 
    CASE permission_stage
        WHEN 'CONCENTRATE_ACTIVE' THEN 1
        ELSE 2
    END,
    significance_score DESC NULLS LAST,
    created_at ASC;

-- Create view for deferred tasks (intentionally postponed)
CREATE OR REPLACE VIEW deferred_tasks AS
SELECT 
    task_id,
    description,
    defer_until,
    defer_reason,
    significance_score,
    CASE
        WHEN defer_until < CURRENT_DATE THEN '⏰ DUE NOW'
        WHEN defer_until <= CURRENT_DATE + INTERVAL '7 days' THEN '📅 DUE SOON'
        ELSE '⏳ FUTURE'
    END AS status,
    defer_until - CURRENT_DATE AS days_until
FROM active_tasks
WHERE status = 'DEFERRED'
  AND defer_until IS NOT NULL
ORDER BY defer_until ASC;

-- Create view for multiplier metrics
CREATE OR REPLACE VIEW multiplier_metrics AS
SELECT 
    COUNT(*) FILTER (WHERE permission_stage = 'ELIMINATED') AS eliminated_count,
    COUNT(*) FILTER (WHERE permission_stage LIKE 'AUTOMATE%') AS automated_count,
    COUNT(*) FILTER (WHERE permission_stage LIKE 'DELEGATE%') AS delegated_count,
    COUNT(*) FILTER (WHERE permission_stage LIKE 'PROCRASTINATE%') AS deferred_count,
    COUNT(*) FILTER (WHERE permission_stage = 'CONCENTRATE_ACTIVE') AS concentrate_count,
    COUNT(*) FILTER (WHERE status = 'COMPLETED') AS completed_count,
    ROUND(AVG(significance_score)) AS avg_significance,
    ROUND(AVG(EXTRACT(EPOCH FROM (completed_at - created_at))/60)) AS avg_completion_minutes
FROM active_tasks
WHERE created_at >= CURRENT_DATE - INTERVAL '7 days';

-- Function to calculate significance score
CREATE OR REPLACE FUNCTION calculate_significance(
    importance INT,  -- 1-10 scale
    time_hours_per_occurrence NUMERIC,
    occurrences_per_year INT
) RETURNS INT AS $$
BEGIN
    RETURN importance * (time_hours_per_occurrence * occurrences_per_year);
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Function to calculate R.O.T.I. (Return on Time Invested)
CREATE OR REPLACE FUNCTION calculate_roti(
    time_to_automate_hours NUMERIC,
    time_saved_per_occurrence_hours NUMERIC,
    occurrences_per_year INT,
    years INT DEFAULT 5
) RETURNS JSONB AS $$
DECLARE
    total_time_saved NUMERIC;
    roti_ratio NUMERIC;
BEGIN
    total_time_saved := time_saved_per_occurrence_hours * occurrences_per_year * years;
    roti_ratio := total_time_saved / NULLIF(time_to_automate_hours, 0);
    
    RETURN jsonb_build_object(
        'time_invested', time_to_automate_hours,
        'time_saved_per_year', time_saved_per_occurrence_hours * occurrences_per_year,
        'time_saved_total', total_time_saved,
        'years', years,
        'roti_ratio', ROUND(roti_ratio, 2),
        'recommendation', CASE
            WHEN roti_ratio >= 5 THEN 'AUTOMATE NOW'
            WHEN roti_ratio >= 2 THEN 'AUTOMATE'
            ELSE 'MANUAL OK'
        END
    );
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Function to enforce max open tasks (update existing function)
CREATE OR REPLACE FUNCTION enforce_max_open_tasks()
RETURNS TRIGGER AS $$
BEGIN
    -- Only enforce for tasks that are actionable (not eliminated/deferred)
    IF NEW.status IN ('INITIATED', 'BLOCKED') 
       AND (NEW.permission_stage IS NULL OR NEW.permission_stage NOT IN ('ELIMINATED', 'DEFERRED')) THEN
        
        IF (SELECT COUNT(*) FROM active_tasks 
            WHERE status IN ('INITIATED', 'BLOCKED')
              AND (permission_stage IS NULL OR permission_stage NOT IN ('ELIMINATED', 'DEFERRED'))) >= 3 THEN
            RAISE EXCEPTION '⛔ BLOCKED: 3 open tasks exist. Apply Focus Funnel: ELIMINATE/AUTOMATE/DELEGATE/PROCRASTINATE one first.';
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Example usage queries

-- View current workload
-- SELECT * FROM current_workload;

-- View tasks due for review from defer pile
-- SELECT * FROM deferred_tasks WHERE status = '⏰ DUE NOW';

-- View multiplier metrics for last 7 days
-- SELECT * FROM multiplier_metrics;

-- Calculate significance for a task
-- SELECT calculate_significance(
--     importance := 8,
--     time_hours_per_occurrence := 0.5,
--     occurrences_per_year := 365
-- );  -- Returns 1460

-- Calculate R.O.T.I. for automation project
-- SELECT calculate_roti(
--     time_to_automate_hours := 40,
--     time_saved_per_occurrence_hours := 0.5,
--     occurrences_per_year := 365,
--     years := 5
-- );

COMMENT ON TABLE active_tasks IS 'Task tracking with Multiplier Framework (5 Permissions)';
COMMENT ON COLUMN active_tasks.permission_stage IS 'Which of the 5 permissions: ELIMINATE/AUTOMATE/DELEGATE/PROCRASTINATE/CONCENTRATE';
COMMENT ON COLUMN active_tasks.significance_score IS 'Importance × Time (used to prioritize)';
COMMENT ON COLUMN active_tasks.roti_calculation IS 'Return on Time Invested calculation for automation decisions';
COMMENT ON COLUMN active_tasks.mvot_comparison IS 'Money Value of Time comparison for delegation decisions';
COMMENT ON COLUMN active_tasks.defer_until IS 'Date when deferred task should be reviewed again';
