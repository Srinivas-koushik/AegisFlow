-- database/schemas/002_roles.sql
--
-- RBAC roles and their scope assignments.
-- Roles are tenant-scoped. System roles (is_system = true) are
-- created once globally and inherited by all tenants.


-- ─── Roles table ─────────────────────────────────────────────────────────────

CREATE TABLE roles (
    id              UUID        NOT NULL DEFAULT gen_random_uuid(),
    role_name       CITEXT      NOT NULL,
    description     TEXT        NOT NULL DEFAULT '',
    tenant_id       UUID,       -- NULL for system-wide roles
    is_system       BOOLEAN     NOT NULL DEFAULT FALSE,

    -- System roles cannot be deleted or modified by tenants.
    -- Only aegisflow_admin can modify them.
    is_immutable    BOOLEAN     NOT NULL DEFAULT FALSE,

    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by      TEXT        NOT NULL DEFAULT 'system',

    CONSTRAINT roles_pkey
        PRIMARY KEY (id),

    -- Role names unique per tenant. System roles (tenant_id IS NULL) also unique.
    CONSTRAINT roles_name_tenant_unique
        UNIQUE (role_name, tenant_id),

    -- Role name format: lowercase, alphanumeric, hyphens only
    CONSTRAINT chk_roles_name_format
        CHECK (role_name ~ '^[a-z0-9][a-z0-9\-]{0,62}[a-z0-9]$'),

    -- System roles must also be immutable
    CONSTRAINT chk_roles_system_immutable
        CHECK (NOT (is_system = TRUE AND is_immutable = FALSE))
);

CREATE TRIGGER roles_set_updated_at
    BEFORE UPDATE ON roles
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

-- Tenant-scoped role listing
CREATE INDEX idx_roles_tenant_id
    ON roles (tenant_id)
    WHERE tenant_id IS NOT NULL;

-- System role lookup (used during tenant bootstrap)
CREATE INDEX idx_roles_system
    ON roles (is_system, role_name)
    WHERE is_system = TRUE;

ALTER TABLE roles ENABLE ROW LEVEL SECURITY;

-- Tenants see their own roles + all system roles
CREATE POLICY roles_tenant_isolation
    ON roles
    AS PERMISSIVE
    FOR ALL
    TO aegisflow_service
    USING (
        tenant_id = current_setting('app.current_tenant_id', true)::UUID
        OR tenant_id IS NULL  -- system roles visible to all
    );

CREATE POLICY roles_admin_bypass
    ON roles AS PERMISSIVE FOR ALL TO aegisflow_admin USING (true);

COMMENT ON TABLE  roles IS
    'RBAC role definitions. Roles are collections of scopes assigned to agents.';
COMMENT ON COLUMN roles.tenant_id IS
    'NULL for system-wide roles visible to all tenants. Set for tenant-specific custom roles.';
COMMENT ON COLUMN roles.is_immutable IS
    'If true, cannot be modified or deleted. Set on built-in system roles.';


-- ─── Scope registry ───────────────────────────────────────────────────────────
-- The authoritative list of every valid scope in the system.
-- Attempting to assign an unregistered scope will fail the FK constraint.
-- This prevents typos like "fs:rite" silently succeeding.

CREATE TABLE scope_definitions (
    scope           TEXT        NOT NULL,   -- e.g. "fs:read"
    resource        TEXT        NOT NULL,   -- e.g. "fs"
    action          TEXT        NOT NULL,   -- e.g. "read"
    description     TEXT        NOT NULL,
    is_sensitive    BOOLEAN     NOT NULL DEFAULT FALSE,
    -- Sensitive scopes get extra audit logging on every use
    -- and require explicit operator approval to assign

    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT scope_definitions_pkey
        PRIMARY KEY (scope),

    -- Scope format: resource:action (lowercase, colon-separated)
    CONSTRAINT chk_scope_format
        CHECK (scope ~ '^[a-z][a-z0-9_]*:[a-z][a-z0-9_]*$'),

    -- resource and action must be consistent with the scope string
    CONSTRAINT chk_scope_resource_action_match
        CHECK (scope = resource || ':' || action)
);

COMMENT ON TABLE  scope_definitions IS
    'Registry of all valid scopes. A scope not in this table cannot be assigned to any role or agent.';
COMMENT ON COLUMN scope_definitions.is_sensitive IS
    'Sensitive scopes trigger extra audit logging and require operator approval to assign.';


-- ─── Role-scope assignments ───────────────────────────────────────────────────
-- Many-to-many between roles and scopes.
-- A role can have many scopes; a scope can belong to many roles.

CREATE TABLE role_scopes (
    role_id         UUID        NOT NULL,
    scope           TEXT        NOT NULL,
    granted_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    granted_by      TEXT        NOT NULL DEFAULT 'system',

    CONSTRAINT role_scopes_pkey
        PRIMARY KEY (role_id, scope),

    CONSTRAINT fk_role_scopes_role
        FOREIGN KEY (role_id) REFERENCES roles (id)
        ON DELETE CASCADE,

    CONSTRAINT fk_role_scopes_scope
        FOREIGN KEY (scope) REFERENCES scope_definitions (scope)
        ON DELETE RESTRICT  -- cannot delete a scope that is assigned to a role
);

CREATE INDEX idx_role_scopes_role_id
    ON role_scopes (role_id);

CREATE INDEX idx_role_scopes_scope
    ON role_scopes (scope);

COMMENT ON TABLE role_scopes IS
    'Many-to-many join between roles and scopes. Deleting a role cascades here.';


-- ─── Agent-role assignments ───────────────────────────────────────────────────
-- Many-to-many between agents and roles.
-- An agent's effective scopes = union of all scopes from all assigned roles.

CREATE TABLE agent_roles (
    agent_id        UUID        NOT NULL,
    role_id         UUID        NOT NULL,
    assigned_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    assigned_by     TEXT        NOT NULL,
    expires_at      TIMESTAMPTZ,    -- optional: role assignment can be time-limited

    CONSTRAINT agent_roles_pkey
        PRIMARY KEY (agent_id, role_id),

    CONSTRAINT fk_agent_roles_agent
        FOREIGN KEY (agent_id) REFERENCES agents (id)
        ON DELETE CASCADE,

    CONSTRAINT fk_agent_roles_role
        FOREIGN KEY (role_id) REFERENCES roles (id)
        ON DELETE RESTRICT,

    -- expires_at must be in the future at assignment time
    -- (checked at application layer; this prevents obvious mistakes)
    CONSTRAINT chk_agent_roles_expiry_future
        CHECK (expires_at IS NULL OR expires_at > assigned_at)
);

CREATE INDEX idx_agent_roles_agent_id
    ON agent_roles (agent_id);

-- Find all agents with a specific role (admin queries)
CREATE INDEX idx_agent_roles_role_id
    ON agent_roles (role_id, assigned_at DESC);

-- Find expiring role assignments (background cleanup job)
CREATE INDEX idx_agent_roles_expires_at
    ON agent_roles (expires_at ASC)
    WHERE expires_at IS NOT NULL;

ALTER TABLE agent_roles ENABLE ROW LEVEL SECURITY;

CREATE POLICY agent_roles_tenant_isolation
    ON agent_roles
    AS PERMISSIVE FOR ALL TO aegisflow_service
    USING (
        agent_id IN (
            SELECT id FROM agents
            WHERE tenant_id = current_setting('app.current_tenant_id', true)::UUID
        )
    );

CREATE POLICY agent_roles_admin_bypass
    ON agent_roles AS PERMISSIVE FOR ALL TO aegisflow_admin USING (true);

COMMENT ON TABLE  agent_roles IS
    'Many-to-many between agents and roles. An agent effective scopes = union of all role scopes.';
COMMENT ON COLUMN agent_roles.expires_at IS
    'If set, this role assignment is automatically invalid after this timestamp. Auth service enforces this.';