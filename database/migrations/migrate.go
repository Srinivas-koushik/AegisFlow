// database/migrations/migrate.go
//
// AegisFlow database migration runner.
//
// Applies SQL migrations in order, tracks applied migrations in a
// schema_migrations table, and supports rollback for the last applied migration.
//
// Usage:
//   go run database/migrations/migrate.go up         — apply all pending
//   go run database/migrations/migrate.go down       — roll back last migration
//   go run database/migrations/migrate.go status     — show applied/pending
//   go run database/migrations/migrate.go version    — show current version
//   go run database/migrations/migrate.go validate   — validate migration files
//
// Environment variables:
//   DATABASE_URL — required, postgres connection string
//   MIGRATIONS_DIR — optional, defaults to database/schemas/
//   SEEDS_DIR — optional, defaults to database/seeds/

package main

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"
)

// ─── Constants ────────────────────────────────────────────────────────────────

const (
	migrationTableDDL = `
		CREATE TABLE IF NOT EXISTS schema_migrations (
			version         TEXT            NOT NULL,
			filename        TEXT            NOT NULL,
			checksum        TEXT            NOT NULL,
			applied_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
			execution_ms    BIGINT          NOT NULL,
			applied_by      TEXT            NOT NULL DEFAULT current_user,

			CONSTRAINT schema_migrations_pkey PRIMARY KEY (version)
		);

		-- Prevent modifications to the migration history.
		-- Only the migration runner (aegisflow_admin) can insert here.
		COMMENT ON TABLE schema_migrations IS
			'Migration history. Never edit manually. Checksum detects tampering.';
	`

	// Lock ID for advisory lock — prevents two migration runners from
	// running simultaneously (e.g. two pods starting at the same time).
	// This is a stable arbitrary number unique to AegisFlow.
	advisoryLockID = 7391847201983746
)

// ─── Types ────────────────────────────────────────────────────────────────────

// Migration represents a single SQL migration file.
type Migration struct {
	Version  string // e.g. "001"
	Filename string // e.g. "001_agents.sql"
	Path     string // full path to the file
	SQL      string // file contents
	Checksum string // SHA-256 of the SQL content
}

// MigrationRecord is a row from the schema_migrations table.
type MigrationRecord struct {
	Version     string
	Filename    string
	Checksum    string
	AppliedAt   time.Time
	ExecutionMs int64
	AppliedBy   string
}

// Runner handles the migration lifecycle.
type Runner struct {
	db            *sql.DB
	migrationsDir string
	seedsDir      string
	logger        *log.Logger
}

// ─── Entry point ──────────────────────────────────────────────────────────────

func main() {
	if len(os.Args) < 2 {
		printUsage()
		os.Exit(1)
	}

	command := os.Args[1]

	logger := log.New(os.Stdout, "[migrate] ", log.LstdFlags)

	// Validate required env vars
	databaseURL := os.Getenv("DATABASE_URL")
	if databaseURL == "" {
		logger.Fatal("DATABASE_URL environment variable is required")
	}

	migrationsDir := envOrDefault("MIGRATIONS_DIR", "database/schemas")
	seedsDir := envOrDefault("SEEDS_DIR", "database/seeds")

	// Open database connection
	db, err := sql.Open("postgres", databaseURL)
	if err != nil {
		logger.Fatalf("Failed to open database connection: %v", err)
	}
	defer db.Close()

	// Configure connection pool
	db.SetMaxOpenConns(3) // migrations don't need many connections
	db.SetMaxIdleConns(1)
	db.SetConnMaxLifetime(5 * time.Minute)

	// Verify connectivity
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if err := db.PingContext(ctx); err != nil {
		logger.Fatalf("Cannot connect to database: %v\nURL: %s", err, maskPassword(databaseURL))
	}

	runner := &Runner{
		db:            db,
		migrationsDir: migrationsDir,
		seedsDir:      seedsDir,
		logger:        logger,
	}

	// Ensure migrations table exists before any operation
	if err := runner.ensureMigrationsTable(context.Background()); err != nil {
		logger.Fatalf("Failed to initialize migrations table: %v", err)
	}

	// Execute command
	switch command {
	case "up":
		if err := runner.Up(context.Background()); err != nil {
			logger.Fatalf("Migration up failed: %v", err)
		}
	case "down":
		if err := runner.Down(context.Background()); err != nil {
			logger.Fatalf("Migration down failed: %v", err)
		}
	case "status":
		if err := runner.Status(context.Background()); err != nil {
			logger.Fatalf("Status check failed: %v", err)
		}
	case "version":
		if err := runner.Version(context.Background()); err != nil {
			logger.Fatalf("Version check failed: %v", err)
		}
	case "validate":
		if err := runner.Validate(context.Background()); err != nil {
			logger.Fatalf("Validation failed: %v", err)
		}
	case "seed":
		if err := runner.Seed(context.Background()); err != nil {
			logger.Fatalf("Seed failed: %v", err)
		}
	default:
		logger.Fatalf("Unknown command: %s", command)
	}
}

// ─── Core migration logic ─────────────────────────────────────────────────────

// Up applies all pending migrations in version order.
func (r *Runner) Up(ctx context.Context) error {
	// Acquire advisory lock to prevent concurrent migration runs
	if err := r.acquireAdvisoryLock(ctx); err != nil {
		return fmt.Errorf("could not acquire migration lock: %w", err)
	}
	defer r.releaseAdvisoryLock(ctx)

	pending, err := r.pendingMigrations(ctx)
	if err != nil {
		return err
	}

	if len(pending) == 0 {
		r.logger.Println("No pending migrations. Database is up to date.")
		return nil
	}

	r.logger.Printf("Applying %d pending migration(s)...", len(pending))

	for _, m := range pending {
		if err := r.applyMigration(ctx, m); err != nil {
			return fmt.Errorf("failed to apply migration %s: %w", m.Filename, err)
		}
	}

	r.logger.Printf("Successfully applied %d migration(s).", len(pending))
	return nil
}

// Down rolls back the most recently applied migration.
// We intentionally only roll back one at a time — bulk rollbacks
// are dangerous and should be done deliberately, one step at a time.
func (r *Runner) Down(ctx context.Context) error {
	if err := r.acquireAdvisoryLock(ctx); err != nil {
		return fmt.Errorf("could not acquire migration lock: %w", err)
	}
	defer r.releaseAdvisoryLock(ctx)

	// Find the last applied migration
	var record MigrationRecord
	err := r.db.QueryRowContext(ctx, `
		SELECT version, filename, checksum, applied_at, execution_ms, applied_by
		FROM schema_migrations
		ORDER BY version DESC
		LIMIT 1
	`).Scan(
		&record.Version, &record.Filename, &record.Checksum,
		&record.AppliedAt, &record.ExecutionMs, &record.AppliedBy,
	)
	if errors.Is(err, sql.ErrNoRows) {
		r.logger.Println("No migrations to roll back.")
		return nil
	}
	if err != nil {
		return fmt.Errorf("could not query last migration: %w", err)
	}

	// Look for a corresponding rollback file: e.g. 001_agents.down.sql
	downFile := strings.TrimSuffix(record.Filename, ".sql") + ".down.sql"
	downPath := filepath.Join(r.migrationsDir, downFile)

	if _, err := os.Stat(downPath); os.IsNotExist(err) {
		return fmt.Errorf(
			"no rollback file found for %s\nExpected: %s\n"+
				"Create this file with the SQL to reverse the migration.",
			record.Filename, downPath,
		)
	}

	downSQL, err := os.ReadFile(downPath)
	if err != nil {
		return fmt.Errorf("could not read rollback file %s: %w", downPath, err)
	}

	r.logger.Printf("Rolling back migration %s...", record.Filename)

	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("could not begin transaction: %w", err)
	}
	defer func() {
		if err != nil {
			_ = tx.Rollback()
		}
	}()

	if _, err = tx.ExecContext(ctx, string(downSQL)); err != nil {
		return fmt.Errorf("rollback SQL failed: %w", err)
	}

	if _, err = tx.ExecContext(ctx,
		"DELETE FROM schema_migrations WHERE version = $1",
		record.Version,
	); err != nil {
		return fmt.Errorf("could not remove migration record: %w", err)
	}

	if err = tx.Commit(); err != nil {
		return fmt.Errorf("could not commit rollback: %w", err)
	}

	r.logger.Printf("Successfully rolled back %s.", record.Filename)
	return nil
}

// Status prints applied and pending migrations with details.
func (r *Runner) Status(ctx context.Context) error {
	applied, err := r.appliedMigrations(ctx)
	if err != nil {
		return err
	}

	all, err := r.loadMigrationFiles()
	if err != nil {
		return err
	}

	appliedMap := make(map[string]MigrationRecord)
	for _, rec := range applied {
		appliedMap[rec.Version] = rec
	}

	fmt.Println("\n Migration Status")
	fmt.Println(strings.Repeat("─", 80))
	fmt.Printf("%-6s %-40s %-12s %s\n", "Ver", "File", "Status", "Applied At")
	fmt.Println(strings.Repeat("─", 80))

	for _, m := range all {
		if rec, ok := appliedMap[m.Version]; ok {
			// Verify checksum hasn't changed since it was applied
			status := "✓ applied"
			if rec.Checksum != m.Checksum {
				status = "✗ MODIFIED"
			}
			fmt.Printf("%-6s %-40s %-12s %s\n",
				m.Version, m.Filename, status,
				rec.AppliedAt.Format("2006-01-02 15:04:05"),
			)
		} else {
			fmt.Printf("%-6s %-40s %-12s %s\n",
				m.Version, m.Filename, "· pending", "—",
			)
		}
	}

	fmt.Println(strings.Repeat("─", 80))
	pending, _ := r.pendingMigrations(ctx)
	fmt.Printf("\n%d applied, %d pending\n\n", len(applied), len(pending))
	return nil
}

// Version prints only the current schema version.
func (r *Runner) Version(ctx context.Context) error {
	var version, filename string
	var appliedAt time.Time

	err := r.db.QueryRowContext(ctx, `
		SELECT version, filename, applied_at
		FROM schema_migrations
		ORDER BY version DESC
		LIMIT 1
	`).Scan(&version, &filename, &appliedAt)

	if errors.Is(err, sql.ErrNoRows) {
		fmt.Println("No migrations applied. Schema version: none")
		return nil
	}
	if err != nil {
		return fmt.Errorf("could not query current version: %w", err)
	}

	fmt.Printf("Current version: %s (%s) — applied %s\n",
		version, filename, appliedAt.Format(time.RFC3339))
	return nil
}

// Validate checks that no applied migrations have been modified
// and that all migration files are properly numbered and formatted.
func (r *Runner) Validate(ctx context.Context) error {
	r.logger.Println("Validating migration files...")

	all, err := r.loadMigrationFiles()
	if err != nil {
		return err
	}

	applied, err := r.appliedMigrations(ctx)
	if err != nil {
		return err
	}

	appliedMap := make(map[string]MigrationRecord)
	for _, rec := range applied {
		appliedMap[rec.Version] = rec
	}

	hasErrors := false

	for _, m := range all {
		// Check applied migrations haven't been modified
		if rec, ok := appliedMap[m.Version]; ok {
			if rec.Checksum != m.Checksum {
				r.logger.Printf(
					"CHECKSUM MISMATCH: %s was modified after being applied!\n"+
						"  Applied checksum:  %s\n"+
						"  Current checksum:  %s\n"+
						"  This migration cannot be re-applied. Create a new migration instead.",
					m.Filename, rec.Checksum, m.Checksum,
				)
				hasErrors = true
			}
		}

		// Check file is not empty
		if strings.TrimSpace(m.SQL) == "" {
			r.logger.Printf("EMPTY FILE: %s contains no SQL", m.Filename)
			hasErrors = true
		}

		// Check naming convention: NNN_description.sql
		if !migrationFilenameValid(m.Filename) {
			r.logger.Printf(
				"INVALID FILENAME: %s — expected format: NNN_description.sql (e.g. 001_agents.sql)",
				m.Filename,
			)
			hasErrors = true
		}
	}

	// Check for version gaps
	versions := make([]string, 0, len(all))
	for _, m := range all {
		versions = append(versions, m.Version)
	}
	if gaps := findVersionGaps(versions); len(gaps) > 0 {
		r.logger.Printf("VERSION GAPS detected: %v", gaps)
		hasErrors = true
	}

	if hasErrors {
		return fmt.Errorf("validation failed — see errors above")
	}

	r.logger.Printf("Validation passed. %d migration file(s) are valid.", len(all))
	return nil
}

// Seed runs all seed files in order.
// Seeds are idempotent — they use INSERT ... ON CONFLICT DO NOTHING.
func (r *Runner) Seed(ctx context.Context) error {
	r.logger.Println("Running seeds...")

	entries, err := os.ReadDir(r.seedsDir)
	if err != nil {
		if os.IsNotExist(err) {
			r.logger.Println("No seeds directory found. Skipping.")
			return nil
		}
		return fmt.Errorf("could not read seeds directory: %w", err)
	}

	var seedFiles []string
	for _, entry := range entries {
		if !entry.IsDir() && strings.HasSuffix(entry.Name(), ".sql") {
			seedFiles = append(seedFiles, filepath.Join(r.seedsDir, entry.Name()))
		}
	}
	sort.Strings(seedFiles)

	for _, path := range seedFiles {
		content, err := os.ReadFile(path)
		if err != nil {
			return fmt.Errorf("could not read seed file %s: %w", path, err)
		}

		r.logger.Printf("Running seed: %s", filepath.Base(path))

		if _, err := r.db.ExecContext(ctx, string(content)); err != nil {
			return fmt.Errorf("seed %s failed: %w", filepath.Base(path), err)
		}
	}

	r.logger.Printf("Seeding complete. %d seed file(s) applied.", len(seedFiles))
	return nil
}

// ─── Internal helpers ─────────────────────────────────────────────────────────

func (r *Runner) ensureMigrationsTable(ctx context.Context) error {
	_, err := r.db.ExecContext(ctx, migrationTableDDL)
	return err
}

func (r *Runner) acquireAdvisoryLock(ctx context.Context) error {
	var acquired bool
	err := r.db.QueryRowContext(ctx,
		"SELECT pg_try_advisory_lock($1)", advisoryLockID,
	).Scan(&acquired)
	if err != nil {
		return err
	}
	if !acquired {
		return fmt.Errorf(
			"another migration process is running (advisory lock %d is held). "+
				"If this is wrong, run: SELECT pg_advisory_unlock(%d);",
			advisoryLockID, advisoryLockID,
		)
	}
	return nil
}

func (r *Runner) releaseAdvisoryLock(ctx context.Context) {
	_, _ = r.db.ExecContext(ctx, "SELECT pg_advisory_unlock($1)", advisoryLockID)
}

func (r *Runner) applyMigration(ctx context.Context, m Migration) error {
	r.logger.Printf("Applying %s...", m.Filename)
	start := time.Now()

	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("could not begin transaction: %w", err)
	}
	defer func() {
		if err != nil {
			_ = tx.Rollback()
			r.logger.Printf("Rolled back %s due to error", m.Filename)
		}
	}()

	// Execute the migration SQL
	if _, err = tx.ExecContext(ctx, m.SQL); err != nil {
		return fmt.Errorf("SQL execution failed: %w", err)
	}

	executionMs := time.Since(start).Milliseconds()

	// Record the migration
	if _, err = tx.ExecContext(ctx, `
		INSERT INTO schema_migrations (version, filename, checksum, applied_at, execution_ms)
		VALUES ($1, $2, $3, NOW(), $4)
	`, m.Version, m.Filename, m.Checksum, executionMs); err != nil {
		return fmt.Errorf("could not record migration: %w", err)
	}

	if err = tx.Commit(); err != nil {
		return fmt.Errorf("could not commit migration: %w", err)
	}

	r.logger.Printf("Applied %s in %dms", m.Filename, executionMs)
	return nil
}

func (r *Runner) loadMigrationFiles() ([]Migration, error) {
	var migrations []Migration

	err := filepath.WalkDir(r.migrationsDir, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() || !strings.HasSuffix(d.Name(), ".sql") {
			return nil
		}
		// Skip rollback files (*.down.sql) — only load up migrations
		if strings.HasSuffix(d.Name(), ".down.sql") {
			return nil
		}

		content, err := os.ReadFile(path)
		if err != nil {
			return fmt.Errorf("could not read %s: %w", path, err)
		}

		version := extractVersion(d.Name())
		checksum := sha256Hex(content)

		migrations = append(migrations, Migration{
			Version:  version,
			Filename: d.Name(),
			Path:     path,
			SQL:      string(content),
			Checksum: checksum,
		})
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("could not load migration files from %s: %w", r.migrationsDir, err)
	}

	sort.Slice(migrations, func(i, j int) bool {
		return migrations[i].Version < migrations[j].Version
	})

	return migrations, nil
}

func (r *Runner) appliedMigrations(ctx context.Context) ([]MigrationRecord, error) {
	rows, err := r.db.QueryContext(ctx, `
		SELECT version, filename, checksum, applied_at, execution_ms, applied_by
		FROM schema_migrations
		ORDER BY version ASC
	`)
	if err != nil {
		return nil, fmt.Errorf("could not query applied migrations: %w", err)
	}
	defer rows.Close()

	var records []MigrationRecord
	for rows.Next() {
		var rec MigrationRecord
		if err := rows.Scan(
			&rec.Version, &rec.Filename, &rec.Checksum,
			&rec.AppliedAt, &rec.ExecutionMs, &rec.AppliedBy,
		); err != nil {
			return nil, err
		}
		records = append(records, rec)
	}
	return records, rows.Err()
}

func (r *Runner) pendingMigrations(ctx context.Context) ([]Migration, error) {
	all, err := r.loadMigrationFiles()
	if err != nil {
		return nil, err
	}

	applied, err := r.appliedMigrations(ctx)
	if err != nil {
		return nil, err
	}

	appliedVersions := make(map[string]bool)
	for _, rec := range applied {
		appliedVersions[rec.Version] = true
	}

	var pending []Migration
	for _, m := range all {
		if !appliedVersions[m.Version] {
			pending = append(pending, m)
		}
	}

	return pending, nil
}

// ─── Utility functions ────────────────────────────────────────────────────────

func extractVersion(filename string) string {
	parts := strings.SplitN(filename, "_", 2)
	if len(parts) == 0 {
		return ""
	}
	return parts[0]
}

func sha256Hex(data []byte) string {
	h := sha256.Sum256(data)
	return hex.EncodeToString(h[:])
}

func migrationFilenameValid(filename string) bool {
	parts := strings.SplitN(filename, "_", 2)
	if len(parts) < 2 {
		return false
	}
	// Version must be all digits
	for _, c := range parts[0] {
		if c < '0' || c > '9' {
			return false
		}
	}
	return strings.HasSuffix(filename, ".sql")
}

func findVersionGaps(versions []string) []string {
	if len(versions) == 0 {
		return nil
	}
	sort.Strings(versions)
	var gaps []string
	for i := 1; i < len(versions); i++ {
		prev := versions[i-1]
		curr := versions[i]
		var prevN, currN int
		fmt.Sscanf(prev, "%d", &prevN)
		fmt.Sscanf(curr, "%d", &currN)
		if currN != prevN+1 {
			gaps = append(gaps, fmt.Sprintf("%s → %s", prev, curr))
		}
	}
	return gaps
}

func maskPassword(url string) string {
	// Mask password in postgres://user:password@host/db
	if idx := strings.Index(url, "@"); idx != -1 {
		credEnd := strings.LastIndex(url[:idx], ":")
		if credEnd != -1 {
			return url[:credEnd+1] + "****" + url[idx:]
		}
	}
	return url
}

func envOrDefault(key, defaultVal string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return defaultVal
}

func printUsage() {
	fmt.Fprintf(os.Stderr, `
AegisFlow database migration runner

Usage:
  go run database/migrations/migrate.go <command>

Commands:
  up        Apply all pending migrations
  down      Roll back the last applied migration
  status    Show applied and pending migrations
  version   Show current schema version
  validate  Verify migration files are intact
  seed      Run seed files

Environment:
  DATABASE_URL     required — postgres connection string
  MIGRATIONS_DIR   optional — defaults to database/schemas
  SEEDS_DIR        optional — defaults to database/seeds

`)
}

// Ensure io and fs are used (imported above)
var _ = io.EOF
var _ = fs.ErrNotExist
