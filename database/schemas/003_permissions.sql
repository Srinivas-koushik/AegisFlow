-- database/schemas/003_permissions.sql
--
-- Fine-grained per-agent permission overrides.
-- These sit on top of role-based scopes and handle two cases:
--
--   1. GRANT: give this specific agent one scope without a full role
--   2. DENY:  explicitly block this scope even if a role would grant it
--
-- Evaluation order (auth service enforces this):
--   explicit DENY > explicit GRANT > role-based scopes
--
-- This mirrors the principle of least surprise:
-- a security team can always override a role grant with an explicit deny.


CREATE TYPE permission_effect AS ENUM (
    'grant',    -- explicitly allow this scope
    'deny'      -- explicitly deny this scope, overriding any role grant
);


-- ─── Agent direct permissions ─────────────────────────────────────────────────

CREATE TABLE agent_permissions (
    id              UUID                NOT NULL DEFAULT gen_random_uuid(),
    agent_id        UUID                NOT NULL,
    scope           TEXT                NOT NULL,
    effect          permission_effect   NOT NULL,

    -- Why this permission was granted/denied — required for audit trail.
    reason          TEXT                NOT NULL,

    -- Who made this change
    granted_by      TEXT                NOT NULL,

    -- Time-bounded permissions
    granted_at      TIMESTAMPTZ         NOT NULL DEFAULT NOW(),
    expires_at      TIMESTAMPTZ,

    -- Condition: optional JSON rule evaluated at runtime.
    -- Allows contextual permissions like:
    --   {"time_window": {"start": "09:00", "end": "17:00", "tz": "UTC"}}
    --   {"source_ip": "10.0.0.0/8"}
    -- NULL means unconditional.
    condition       JSONB,

    CONSTRAINT agent_permissions_pkey
        PRIMARY KEY (id),

    -- An agent cannot have both GRANT and DENY for the same scope simultaneously.
    -- The application should remove the old one before creating the new one.
    CONSTRAINT agent_permissions_unique_scope_effect
        UNIQUE (agent_id, scope, effect),

    CONSTRAINT fk_agent_permissions_agent
        FOREIGN KEY (agent_id) REFERENCES agents (id)
        ON DELETE CASCADE,

    CONSTRAINT fk_agent_permissions_scope
        FOREIGN KEY (scope) REFERENCES scope_definitions (scope)
        ON DELETE RESTRICT,

    CONSTRAINT chk_agent_permissions_expiry
        CHECK (expires_at IS NULL OR expires_at > granted_at),

    CONSTRAINT chk_agent_permissions_condition_object
        CHECK (condition IS NULL OR jsonb_typeof(condition) = 'object')
);

-- Fast lookup during token validation: get all permission overrides for an agent
CREATE INDEX idx_agent_permissions_agent_id
    ON agent_permissions (agent_id, effect, scope)
    WHERE expires_at IS NULL OR expires_at > NOW();

-- Expiry cleanup
CREATE INDEX idx_agent_permissions_expires_at
    ON agent_permissions (expires_at ASC)
    WHERE expires_at IS NOT NULL;

-- Find all agents with a specific deny (security audit query)
CREATE INDEX idx_agent_permissions_scope_deny
    ON agent_permissions (scope, effect)
    WHERE effect = 'deny';

ALTER TABLE agent_permissions ENABLE ROW LEVEL SECURITY;

CREATE POLICY agent_permissions_tenant_isolation
    ON agent_permissions
    AS PERMISSIVE FOR ALL TO aegisflow_service
    USING (
        agent_id IN (
            SELECT id FROM agents
            WHERE tenant_id = current_setting('app.current_tenant_id', true)::UUID
        )
    );

CREATE POLICY agent_permissions_admin_bypass
    ON agent_permissions AS PERMISSIVE FOR ALL TO aegisflow_admin USING (true);

COMMENT ON TABLE  agent_permissions IS
    'Fine-grained per-agent scope overrides. Explicit DENY always wins over role-granted scopes.';
COMMENT ON COLUMN agent_permissions.condition IS
    'Optional JSON condition evaluated at runtime. NULL means unconditional. See docs/security/conditions.md.';
COMMENT ON COLUMN agent_permissions.effect IS
    'grant = allow regardless of roles. deny = block regardless of roles. deny always wins.';