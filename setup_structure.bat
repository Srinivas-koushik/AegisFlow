@echo off

mkdir docs\architecture
mkdir docs\api
mkdir docs\deployment
mkdir docs\security

mkdir apps\runtime-gateway\src
mkdir apps\runtime-gateway\tests
mkdir apps\runtime-gateway\migrations

mkdir apps\auth-service\cmd\server
mkdir apps\auth-service\internal
mkdir apps\auth-service\tests

mkdir apps\telemetry-service\cmd
mkdir apps\telemetry-service\internal
mkdir apps\telemetry-service\tests

mkdir apps\detection-engine\app
mkdir apps\detection-engine\tests
mkdir apps\detection-engine\datasets

mkdir apps\sandbox-executor\src
mkdir apps\sandbox-executor\tests

mkdir apps\mcp-security-gateway\src
mkdir apps\mcp-security-gateway\tests

mkdir apps\frontend-dashboard\public
mkdir apps\frontend-dashboard\src
mkdir apps\frontend-dashboard\tests

mkdir apps\cli\src
mkdir apps\cli\tests

mkdir packages\proto
mkdir packages\shared-config
mkdir packages\shared-security
mkdir packages\shared-logging
mkdir packages\shared-types
mkdir packages\sdk

mkdir infrastructure\docker
mkdir infrastructure\kubernetes
mkdir infrastructure\helm
mkdir infrastructure\terraform
mkdir infrastructure\monitoring
mkdir infrastructure\opa

mkdir database\migrations
mkdir database\schemas
mkdir database\seeds

mkdir scripts

mkdir tests\unit
mkdir tests\integration
mkdir tests\e2e
mkdir tests\security

mkdir .github\workflows

mkdir deployment\local
mkdir deployment\staging
mkdir deployment\production

type nul > README.md
type nul > docker-compose.yml
type nul > .gitignore
type nul > Makefile
type nul > .env.example

echo AegisFlow structure created successfully.
pause