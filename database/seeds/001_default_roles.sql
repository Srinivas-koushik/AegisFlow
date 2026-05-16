-- database/seeds/001_default_roles.sql
--
-- System role definitions and scope registry.
-- These are the built-in roles every AegisFlow deployment ships with.
-- All inserts use ON CONFLICT DO NOTHING — safe to run multiple times.
--
-- Role hierarchy:
--   readonly     — can observe only, no mutations
--   operator     — can use tools, no admin actions
--   privileged   — operator + sensitive tool access
--   admin        — full access including agent management
--   system       — internal AegisFlow services only


-- ─── Scope registry ───────────────────────────────────────────────────────────
-- Register all valid scopes before assigning them to roles.

INSERT INTO scope_definitions (scope, resource, action, description, is_sensitive)
VALUES
    -- Filesystem
    ('fs:read',         'fs',       'read',     'Read files and directory listings',              FALSE),
    ('fs:write',        'fs',       'write',    'Write, create, or modify files',                 TRUE),
    ('fs:delete',       'fs',       'delete',   'Delete files or directories',                    TRUE),
    ('fs:execute',      'fs',       'execute',  'Execute files or scripts',                       TRUE),

    -- Database
    ('db:query',        'db',       'query',    'Execute read-only SQL queries',                  FALSE),
    ('db:write',        'db',       'write',    'Execute INSERT, UPDATE, DELETE statements',      TRUE),
    ('db:schema',       'db',       'schema',   'Execute DDL (CREATE, ALTER, DROP)',              TRUE),
    ('db:admin',        'db',       'admin',    'Database administrative operations',             TRUE),

    -- API calls
    ('api:read',        'api',      'read',     'Make read-only (GET) API calls',                FALSE),
    ('api:write',       'api',      'write',    'Make mutating (POST, PUT, PATCH) API calls',    TRUE),
    ('api:delete',      'api',      'delete',   'Make DELETE API calls',                          TRUE),
    ('api:admin',       'api',      'admin',    'Access admin API endpoints',                     TRUE),

    -- Shell / terminal
    ('shell:read',      'shell',    'read',     'Read environment variables and system info',    FALSE),
    ('shell:execute',   'shell',    'execute',  'Execute shell commands',                         TRUE),
    ('shell:admin',     'shell',    'admin',    'Execute commands with elevated privileges',      TRUE),

    -- Cloud infrastructure
    ('cloud:read',      'cloud',    'read',     'Read cloud resource configurations',            FALSE),
    ('cloud:write',     'cloud',    'write',    'Create or modify cloud resources',              TRUE),
    ('cloud:delete',    'cloud',    'delete',   'Destroy cloud resources',                        TRUE),
    ('cloud:iam',       'cloud',    'iam',      'Modify IAM roles and policies',                 TRUE),

    -- MCP tools
    ('mcp:read',        'mcp',      'read',     'Call read-only MCP tools',                      FALSE),
    ('mcp:write',       'mcp',      'write',    'Call mutating MCP tools',                       TRUE),
    ('mcp:admin',       'mcp',      'admin',    'Call administrative MCP tools',                 TRUE),

    -- Knowledge and memory
    ('memory:read',     'memory',   'read',     'Read from agent memory stores',                 FALSE),
    ('memory:write',    'memory',   'write',    'Write to agent memory stores',                  FALSE),
    ('memory:delete',   'memory',   'delete',   'Delete from agent memory stores',               TRUE),

    -- Agent management (for orchestrators)
    ('agents:read',     'agents',   'read',     'Read agent identities and status',              FALSE),
    ('agents:spawn',    'agents',   'spawn',    'Spawn new sub-agents',                          TRUE),
    ('agents:suspend',  'agents',   'suspend',  'Suspend or revoke other agents',                TRUE),

    -- Observability
    ('telemetry:read',  'telemetry','read',     'Read audit logs and telemetry data',            FALSE),
    ('telemetry:write', 'telemetry','write',    'Write telemetry events',                        FALSE)

ON CONFLICT (scope) DO NOTHING;


-- ─── System roles ─────────────────────────────────────────────────────────────

INSERT INTO roles (id, role_name, description, tenant_id, is_system, is_immutable, created_by)
VALUES
    -- readonly: observe-only, no tool use, no mutations
    ('00000000-0000-0000-0000-000000000001',
     'readonly',
     'Read-only access. Can observe system state but cannot invoke any mutating tools.',
     NULL, TRUE, TRUE, 'system'),

    -- operator: standard agent role for most production use cases
    ('00000000-0000-0000-0000-000000000002',
     'operator',
     'Standard operator role. Can use most tools except privileged infrastructure operations.',
     NULL, TRUE, TRUE, 'system'),

    -- privileged: for agents that need sensitive tool access
    ('00000000-0000-0000-0000-000000000003',
     'privileged',
     'Privileged operator. Includes sensitive scopes like shell:execute and cloud:write.',
     NULL, TRUE, TRUE, 'system'),

    -- admin: full access including agent management
    ('00000000-0000-0000-0000-000000000004',
     'admin',
     'Full administrative access. Can manage agents, roles, and all tools.',
     NULL, TRUE, TRUE, 'system'),

    -- system: internal service-to-service communication
    ('00000000-0000-0000-0000-000000000005',
     'system',
     'Internal AegisFlow service identity. Not for external agents.',
     NULL, TRUE, TRUE, 'system')

ON CONFLICT (role_name, tenant_id) DO NOTHING;


-- ─── Role-scope assignments ───────────────────────────────────────────────────

-- readonly role scopes
INSERT INTO role_scopes (role_id, scope, granted_by)
SELECT '00000000-0000-0000-0000-000000000001', scope, 'system'
FROM scope_definitions
WHERE scope IN (
    'fs:read', 'db:query', 'api:read',
    'shell:read', 'cloud:read', 'mcp:read',
    'memory:read', 'agents:read', 'telemetry:read'
)
ON CONFLICT (role_id, scope) DO NOTHING;


-- operator role scopes (readonly + common write operations)
INSERT INTO role_scopes (role_id, scope, granted_by)
SELECT '00000000-0000-0000-0000-000000000002', scope, 'system'
FROM scope_definitions
WHERE scope IN (
    'fs:read', 'fs:write',
    'db:query', 'db:write',
    'api:read', 'api:write',
    'shell:read',
    'cloud:read',
    'mcp:read', 'mcp:write',
    'memory:read', 'memory:write',
    'agents:read',
    'telemetry:read', 'telemetry:write'
)
ON CONFLICT (role_id, scope) DO NOTHING;


-- privileged role scopes (operator + sensitive operations)
INSERT INTO role_scopes (role_id, scope, granted_by)
SELECT '00000000-0000-0000-0000-000000000003', scope, 'system'
FROM scope_definitions
WHERE scope IN (
    'fs:read', 'fs:write', 'fs:delete', 'fs:execute',
    'db:query', 'db:write', 'db:schema',
    'api:read', 'api:write', 'api:delete',
    'shell:read', 'shell:execute',
    'cloud:read', 'cloud:write',
    'mcp:read', 'mcp:write', 'mcp:admin',
    'memory:read', 'memory:write', 'memory:delete',
    'agents:read', 'agents:spawn',
    'telemetry:read', 'telemetry:write'
)
ON CONFLICT (role_id, scope) DO NOTHING;


-- admin role — all scopes
INSERT INTO role_scopes (role_id, scope, granted_by)
SELECT '00000000-0000-0000-0000-000000000004', scope, 'system'
FROM scope_definitions
ON CONFLICT (role_id, scope) DO NOTHING;


-- system role — scopes needed for internal service communication
INSERT INTO role_scopes (role_id, scope, granted_by)
SELECT '00000000-0000-0000-0000-000000000005', scope, 'system'
FROM scope_definitions
WHERE scope IN (
    'agents:read', 'agents:suspend',
    'telemetry:read', 'telemetry:write'
)
ON CONFLICT (role_id, scope) DO NOTHING;