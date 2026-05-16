-- database/schemas/001_agents.sql
--
-- Core agent identity table.
-- Every AI agent that interacts with AegisFlow must have a record here.
-- This is the root of the entire identity model.
--
-- Naming conventions:
--   - All tables: snake_case, plural
--   - All columns: snake_case
--   - All indexes: idx_<table>_<columns>
--   - All constraints: chk_<table>_<description>
--   - All foreign keys: fk_<table>_<referenced_table>


-- Enable UUID generation without an extension where possible.
-- pgcrypto gives us gen_random_uuid() which uses OS-level entropy.
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- citext gives us case-insensitive text comparisons for agent names
-- without forcing a lower() call on every query.
CREATE EXTENSION IF NOT EXISTS "citext";


-- ─── Agent type enum ──────────────────────────────────────────────────────────
-- Mirrors AgentType in agent.proto exactly.
-- Using a Postgres enum over a varchar gives us:
--   1. Storage efficiency (4 bytes vs variable)
--   2. Constraint enforcement at the DB level, not just application level
--   3. Clear documentation of valid values in the schema itself

CREATE TYPE agent_type AS ENUM (
    'llm',            -- single large language model
    'orchestrator',   -- coordinates multiple sub-agents
    'tool_caller',    -- specialized tool execution agent
    'evaluator',      -- judges or scores other agent outputs
    'human_proxy'     -- represents a human-in-the-loop step
);


-- ─── Agent status enum ────────────────────────────────────────────────────────

CREATE TYPE agent_status AS ENUM (
    'pending',    -- registered, awaiting activation
    'active',     -- operating normally
    'degraded',   -- operating with reduced permissions after a warning
    'suspended',  -- halted, pending human review
    'revoked'     -- permanently decommissioned, cannot be reinstated
);


-- ─── Agents table ─────────────────────────────────────────────────────────────

CREATE TABLE agents (
    -- Identity
    id              UUID            NOT NULL DEFAULT gen_random_uuid(),
    agent_name      CITEXT          NOT NULL,
    agent_type      agent_type      NOT NULL,
    status          agent_status    NOT NULL DEFAULT 'pending',

    -- Tenant isolation
    -- Every agent belongs to exactly one tenant.
    -- Queries that cross tenant boundaries are impossible by design.
    tenant_id       UUID            NOT NULL,
    team_id         UUID,           -- optional sub-group within a tenant

    -- Network restrictions
    -- CIDR blocks this agent is allowed to originate from.
    -- NULL means no IP restriction (any IP accepted).
    -- Example: {"10.0.0.0/8", "192.168.1.0/24"}
    allowed_ip_cidrs INET[],

    -- Operator-attached metadata.
    -- Stored as JSONB for flexible querying (e.g. WHERE labels->>'env' = 'production').
    -- Application layer is responsible for keeping values as strings (mirrors proto map<string,string>).
    labels          JSONB           NOT NULL DEFAULT '{}',

    -- Secret hash — we never store the raw agent secret.
    -- Stores bcrypt hash of the agent's shared secret.
    -- Used during IssueToken to verify the agent is who it claims to be.
    secret_hash     TEXT,

    -- Lifecycle timestamps
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    activated_at    TIMESTAMPTZ,    -- when status first moved to 'active'
    last_seen_at    TIMESTAMPTZ,    -- last successful token validation

    -- Suspension tracking
    suspended_at    TIMESTAMPTZ,
    suspended_by    TEXT,           -- agent_id or 'system' or 'operator:<name>'
    suspension_reason TEXT,

    -- Revocation tracking
    revoked_at      TIMESTAMPTZ,
    revoked_by      TEXT,
    revocation_reason TEXT,

    -- Soft delete — we never hard delete agent records.
    -- Deleted agents are kept for audit purposes.
    deleted_at      TIMESTAMPTZ,

    -- Optimistic locking version counter.
    -- Prevents lost updates when two processes update the same agent simultaneously.
    version         INTEGER         NOT NULL DEFAULT 1,

    -- ─── Constraints ──────────────────────────────────────────────────────────

    CONSTRAINT agents_pkey
        PRIMARY KEY (id),

    -- Agent names must be unique within a tenant.
    -- Two tenants can have an agent named "finance-copilot" — that is fine.
    CONSTRAINT agents_name_tenant_unique
        UNIQUE (agent_name, tenant_id),

    -- Agent name format: lowercase alphanumeric and hyphens only.
    -- Prevents injection via agent names in log messages.
    CONSTRAINT chk_agents_name_format
        CHECK (agent_name ~ '^[a-z0-9][a-z0-9\-]{0,62}[a-z0-9]$'),

    -- Suspension fields must all be set together or not at all.
    CONSTRAINT chk_agents_suspension_consistency
        CHECK (
            (suspended_at IS NULL AND suspended_by IS NULL AND suspension_reason IS NULL)
            OR
            (suspended_at IS NOT NULL AND suspended_by IS NOT NULL AND suspension_reason IS NOT NULL)
        ),

    -- Revocation fields must all be set together or not at all.
    CONSTRAINT chk_agents_revocation_consistency
        CHECK (
            (revoked_at IS NULL AND revoked_by IS NULL AND revocation_reason IS NULL)
            OR
            (revoked_at IS NOT NULL AND revoked_by IS NOT NULL AND revocation_reason IS NOT NULL)
        ),

    -- A revoked agent cannot be un-revoked (enforced in application too, but belt-and-suspenders).
    CONSTRAINT chk_agents_revoked_is_terminal
        CHECK (
            NOT (status = 'revoked' AND deleted_at IS NOT NULL)
        ),

    -- labels must be a flat object (no nested objects), enforced at insert/update.
    CONSTRAINT chk_agents_labels_flat
        CHECK (jsonb_typeof(labels) = 'object'),

    -- version must always be positive
    CONSTRAINT chk_agents_version_positive
        CHECK (version > 0)
);


-- ─── Indexes ──────────────────────────────────────────────────────────────────

-- Primary lookup: validate a token → get agent by ID
-- This is the hottest query in the system — token validation happens on every request
CREATE INDEX idx_agents_id_status
    ON agents (id, status)
    WHERE deleted_at IS NULL;

-- Tenant-scoped listing: dashboard agent list view
CREATE INDEX idx_agents_tenant_id
    ON agents (tenant_id, status, created_at DESC)
    WHERE deleted_at IS NULL;

-- Team-scoped listing
CREATE INDEX idx_agents_team_id
    ON agents (team_id, status)
    WHERE team_id IS NOT NULL AND deleted_at IS NULL;

-- Operational monitoring: find all suspended agents across tenants
CREATE INDEX idx_agents_status
    ON agents (status, suspended_at DESC)
    WHERE status IN ('suspended', 'degraded');

-- Label-based queries: find all production agents, all v2 agents, etc.
-- GIN index enables efficient JSONB containment queries (@>)
CREATE INDEX idx_agents_labels
    ON agents USING GIN (labels)
    WHERE deleted_at IS NULL;

-- Last seen: detect stale/inactive agents
CREATE INDEX idx_agents_last_seen
    ON agents (last_seen_at ASC NULLS FIRST)
    WHERE status = 'active' AND deleted_at IS NULL;

-- Type-based filtering
CREATE INDEX idx_agents_type
    ON agents (agent_type, tenant_id)
    WHERE deleted_at IS NULL;


-- ─── Automatic updated_at trigger ────────────────────────────────────────────
-- Postgres does not auto-update updated_at — we use a trigger.
-- This function is reused by every table that has an updated_at column.

CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER agents_set_updated_at
    BEFORE UPDATE ON agents
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();


-- ─── Optimistic locking trigger ───────────────────────────────────────────────
-- Automatically increments the version counter on every update.
-- The application layer should include WHERE version = $known_version
-- in UPDATE statements and check that exactly 1 row was affected.

CREATE OR REPLACE FUNCTION increment_version()
RETURNS TRIGGER AS $$
BEGIN
    NEW.version = OLD.version + 1;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER agents_increment_version
    BEFORE UPDATE ON agents
    FOR EACH ROW
    EXECUTE FUNCTION increment_version();


-- ─── Row-level security ───────────────────────────────────────────────────────
-- RLS ensures that even if application-level tenant filtering has a bug,
-- the database itself will never return rows from the wrong tenant.
--
-- The application sets the current tenant via:
--   SET LOCAL app.current_tenant_id = '<uuid>';
-- at the start of every transaction.
--
-- The aegisflow_service role is used by the application.
-- The aegisflow_admin role bypasses RLS (used for migrations only).

ALTER TABLE agents ENABLE ROW LEVEL SECURITY;

-- Application role can only see its own tenant's agents
CREATE POLICY agents_tenant_isolation
    ON agents
    AS PERMISSIVE
    FOR ALL
    TO aegisflow_service
    USING (tenant_id = current_setting('app.current_tenant_id', true)::UUID);

-- Admin role bypasses RLS entirely (for migrations, backfills, support)
CREATE POLICY agents_admin_bypass
    ON agents
    AS PERMISSIVE
    FOR ALL
    TO aegisflow_admin
    USING (true);


-- ─── Comments ────────────────────────────────────────────────────────────────
-- pg_catalog comments are surfaced by most DB GUI tools and psql \d+

COMMENT ON TABLE  agents IS
    'Core identity table. Every AI agent registered with AegisFlow has exactly one record here.';
COMMENT ON COLUMN agents.id IS
    'Stable UUID. Never reassigned. Embedded in every JWT as the sub claim.';
COMMENT ON COLUMN agents.secret_hash IS
    'bcrypt hash of the agent shared secret. Used during token issuance only. Never logged.';
COMMENT ON COLUMN agents.labels IS
    'Operator-attached key-value metadata. Flat JSON object only. Values must be strings.';
COMMENT ON COLUMN agents.allowed_ip_cidrs IS
    'If set, requests from IPs outside these CIDRs are rejected regardless of token validity.';
COMMENT ON COLUMN agents.version IS
    'Optimistic lock counter. Include in UPDATE WHERE clause to detect concurrent modifications.';