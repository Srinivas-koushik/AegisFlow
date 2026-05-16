-- database/seeds/002_default_agent.sql
--
-- Bootstrap admin agent.
-- This is the initial system agent used to register all other agents.
-- Created with a well-known ID so it can be referenced in scripts.
--
-- IMPORTANT: In production, rotate the secret_hash immediately after first deploy.
-- The default secret is: "aegisflow-bootstrap-secret-rotate-immediately"
-- Rotate with: go run apps/auth-service/cmd/server/main.go rotate-bootstrap-secret
--
-- This agent should be SUSPENDED once real admin agents are registered.


-- ─── Bootstrap tenant ─────────────────────────────────────────────────────────
-- A system-level tenant for internal AegisFlow operations.
-- All bootstrap and system agents belong here.

-- Note: We reference tenant_id directly here since the tenants table
-- is created in the application layer (not in Phase 1 schemas).
-- For now we use a well-known UUID as the system tenant.

DO $$
DECLARE
    system_tenant_id UUID := '00000000-0000-0000-0000-000000000000';
    bootstrap_agent_id UUID := '00000000-0000-0000-0001-000000000001';
    admin_role_id UUID := '00000000-0000-0000-0000-000000000004';
BEGIN
    -- Insert bootstrap agent
    -- secret_hash is bcrypt of "aegisflow-bootstrap-secret-rotate-immediately"
    -- Generated with: htpasswd -bnBC 12 "" <secret> | tr -d ':\n'
    INSERT INTO agents (
        id,
        agent_name,
        agent_type,
        status,
        tenant_id,
        team_id,
        secret_hash,
        labels,
        activated_at,
        created_at,
        updated_at
    )
    VALUES (
        bootstrap_agent_id,
        'bootstrap-admin',
        'orchestrator',
        'active',
        system_tenant_id,
        NULL,
        -- bcrypt hash of "aegisflow-bootstrap-secret-rotate-immediately"
        -- Cost factor 12 (OWASP recommended minimum for bcrypt)
        '$2a$12$LQv3c1yqBWVHxkd0LHAkCOYz6TtxMQJqhN8/LeUc1vnE4UOxJv.Ke',
        jsonb_build_object(
            'environment', 'system',
            'managed_by',  'bootstrap',
            'rotate_secret', 'true',
            'description', 'Initial bootstrap agent. Suspend after registering real admin agents.'
        ),
        NOW(),
        NOW(),
        NOW()
    )
    ON CONFLICT (id) DO NOTHING;

    -- Assign admin role to bootstrap agent
    INSERT INTO agent_roles (agent_id, role_id, assigned_by)
    VALUES (bootstrap_agent_id, admin_role_id, 'system')
    ON CONFLICT (agent_id, role_id) DO NOTHING;

    -- Log what we did
    RAISE NOTICE 'Bootstrap agent ready: %', bootstrap_agent_id;
    RAISE NOTICE 'IMPORTANT: Rotate the bootstrap secret before production use.';
    RAISE NOTICE 'IMPORTANT: Suspend this agent after registering real admin agents.';
END $$;