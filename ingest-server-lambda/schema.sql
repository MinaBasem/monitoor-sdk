-- Run this once against your Neon database before deploying the Lambda function.
-- Creates the concurrency-tracking table used to coordinate Neon compute suspension:
-- the last Lambda invocation to finish brings active → 0 and suspends the endpoint.

CREATE TABLE IF NOT EXISTS lambda_concurrency (
    active INTEGER NOT NULL DEFAULT 0,
    CONSTRAINT active_non_negative CHECK (active >= 0)
);

-- Ensure exactly one row exists.
INSERT INTO lambda_concurrency (active)
SELECT 0
WHERE NOT EXISTS (SELECT 1 FROM lambda_concurrency);
