-- database/schemas/004_revocations.sql
--
-- Token revocation list (TRL).
-- A revoked token is blocked even if its JWT signature is valid and not expired.
--
-- Design decision: we store individual token IDs (jti claims) rather than
-- just agent IDs so that revoking one session does not invalidate all sessions
-- for that agent — unless the caller explicitly requests a full revocation.
--
-- Performance: this table is checked on EVERY token validation request.
-- It must be extremely fast. All queries are by exact token_id lookup (hash index).


CREATE TABLE token_revocations (
    -- jti (JWT ID) claim from the token being revoked.
    -- This is a UUID embedded in every JWT we issue.
    token_id        TEXT            NOT NULL,

    agent_id        UUID            NOT NULL,
    tenant_id       UUID            NOT NULL,

    -- Why was this token revoked?
    reason          TEXT            NOT NULL,

    -- Who or what triggered the revocation
    -- Format: "operator:<name>", "system", "agent:<id>", "detection_engine"
    revoked_by      TEXT            NOT NULL,

    revoked_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    -- When the token would have expired naturally.
    -- Tokens past this time are expired, not revoked — treated the same way
    -- but tracked separately for analytics.
    original_expiry TIMESTAMPTZ     NOT NULL,

    -- Whether this was a full agent revocation (all tokens) or single token.
    is_full_revocation  BOOLEAN     NOT NULL DEFAULT FALSE,

    -- If is_full_revocation = true, this links to the agent suspension record.
    suspension_id   UUID,

    CONSTRAINT token_revocations_pkey
        PRIMARY KEY (token_id),

    CONSTRAINT fk_token_revocations_agent
        FOREIGN KEY (agent_id) REFERENCES agents (id)
        ON DELETE CASCADE
        -- Note: ON DELETE CASCADE means revoking a deleted agent auto-cleans
        -- its revocation records. This is intentional.
);


-- ─── Critical: hash index for O(1) token lookup ───────────────────────────────
-- Every token validation does: SELECT EXISTS(SELECT 1 FROM token_revocations WHERE token_id = $1)
-- Hash index is faster than B-tree for exact equality lookups.
CREATE INDEX idx_token_revocations_token_id_hash
    ON token_revocations USING HASH (token_id);

-- Secondary: look up all revocations for an agent (dashboard, audit)
CREATE INDEX idx_token_revocations_agent_id
    ON token_revocations (agent_id, revoked_at DESC);

-- Cleanup: delete expired revocations (tokens past original_expiry are useless)
-- Background job runs: DELETE FROM token_revocations WHERE original_expiry < NOW() - INTERVAL '1 hour'
CREATE INDEX idx_token_revocations_original_expiry
    ON token_revocations (original_expiry ASC);

-- Tenant-level revocation audit
CREATE INDEX idx_token_revocations_tenant_id
    ON token_revocations (tenant_id, revoked_at DESC);

ALTER TABLE token_revocations ENABLE ROW LEVEL SECURITY;

CREATE POLICY token_revocations_tenant_isolation
    ON token_revocations
    AS PERMISSIVE FOR ALL TO aegisflow_service
    USING (
        tenant_id = current_setting('app.current_tenant_id', true)::UUID
    );

CREATE POLICY token_revocations_admin_bypass
    ON token_revocations AS PERMISSIVE FOR ALL TO aegisflow_admin USING (true);

COMMENT ON TABLE  token_revocations IS
    'Token revocation list. Checked on every token validation. Must stay fast — hash index on token_id.';
COMMENT ON COLUMN token_revocations.token_id IS
    'The jti (JWT ID) claim. Exact match lookup — never do a LIKE or range query on this column.';
COMMENT ON COLUMN token_revocations.is_full_revocation IS
    'True when all tokens for an agent were revoked simultaneously (e.g. agent suspended).';


-- ─── Revocation cleanup function ──────────────────────────────────────────────
-- Called by a background job (pg_cron or external scheduler).
-- Removes revocation records for tokens that have already expired naturally.
-- Once a token is past its original_expiry, the revocation record is redundant
-- because the token would fail expiry validation regardless.
-- We keep a 1-hour buffer to handle minor clock skew between services.

CREATE OR REPLACE FUNCTION cleanup_expired_revocations()
RETURNS INTEGER AS $$
DECLARE
    deleted_count INTEGER;
BEGIN
    DELETE FROM token_revocations
    WHERE original_expiry < (NOW() - INTERVAL '1 hour');

    GET DIAGNOSTICS deleted_count = ROW_COUNT;

    RETURN deleted_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION cleanup_expired_revocations() IS
    'Removes revocation records for tokens past their original expiry. Safe to call repeatedly. Returns count of deleted rows.';