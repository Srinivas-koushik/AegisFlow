#!/usr/bin/env bash

# scripts/generate-proto.sh
#
# Generates Go, Python, and TypeScript types from packages/proto/agent.proto
#
# Usage:
#   ./scripts/generate-proto.sh           — generate all languages
#   ./scripts/generate-proto.sh --go      — generate Go only
#   ./scripts/generate-proto.sh --python  — generate Python only
#   ./scripts/generate-proto.sh --ts      — generate TypeScript only
#   ./scripts/generate-proto.sh --check   — verify tools only, no generation
#   ./scripts/generate-proto.sh --clean   — remove all generated files
#
# Requirements (auto-checked):
#   protoc            >= 3.21.0
#   protoc-gen-go     (installed via go install)
#   protoc-gen-go-grpc (installed via go install)
#   grpc-tools        (installed via npm)
#   ts-proto          (installed via npm)
#   grpcio-tools      (installed via pip)
#   betterproto       (installed via pip)


set -euo pipefail  # exit on error, undefined vars, pipe failures

# ─── Formatting helpers ────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${RESET}  $*"; }
log_success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
log_step()    { echo -e "\n${BOLD}${CYAN}━━━ $* ${RESET}"; }
log_fatal()   { log_error "$*"; exit 1; }


# ─── Paths ────────────────────────────────────────────────────────────────────

# Resolve project root regardless of where the script is called from
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PROTO_DIR="${PROJECT_ROOT}/packages/proto"
PROTO_FILE="${PROTO_DIR}/agent.proto"

# Output directories for each language
GO_OUT="${PROJECT_ROOT}/packages/shared-types/go"
PYTHON_OUT="${PROJECT_ROOT}/packages/shared-types/python"
TS_OUT="${PROJECT_ROOT}/packages/shared-types/typescript"

# Where protoc looks for well-known types (google/protobuf/*.proto)
# We'll download these if missing
PROTO_INCLUDE="${PROTO_DIR}/include"

# Minimum required protoc version
MIN_PROTOC_VERSION="3.21.0"


# ─── Argument parsing ─────────────────────────────────────────────────────────

GEN_GO=false
GEN_PYTHON=false
GEN_TS=false
CHECK_ONLY=false
CLEAN_ONLY=false

# If no args given, generate everything
if [[ $# -eq 0 ]]; then
  GEN_GO=true
  GEN_PYTHON=true
  GEN_TS=true
else
  for arg in "$@"; do
    case "$arg" in
      --go)     GEN_GO=true ;;
      --python) GEN_PYTHON=true ;;
      --ts)     GEN_TS=true ;;
      --check)  CHECK_ONLY=true; GEN_GO=true; GEN_PYTHON=true; GEN_TS=true ;;
      --clean)  CLEAN_ONLY=true ;;
      --help|-h)
        sed -n '3,20p' "$0" | sed 's/^# //'
        exit 0
        ;;
      *)
        log_fatal "Unknown argument: $arg. Run with --help for usage."
        ;;
    esac
  done
fi


# ─── Version comparison utility ───────────────────────────────────────────────

# Returns 0 if $1 >= $2 (semver comparison)
version_gte() {
  local installed="$1"
  local required="$2"
  # Use sort -V (version sort) to compare
  [[ "$(echo -e "${required}\n${installed}" | sort -V | head -1)" == "$required" ]]
}


# ─── Tool checks ──────────────────────────────────────────────────────────────

MISSING_TOOLS=()

check_tool() {
  local tool="$1"
  local install_hint="$2"
  if ! command -v "$tool" &>/dev/null; then
    log_warn "Missing: ${tool} — ${install_hint}"
    MISSING_TOOLS+=("$tool")
    return 1
  fi
  return 0
}

check_protoc_version() {
  if ! command -v protoc &>/dev/null; then
    MISSING_TOOLS+=("protoc")
    log_warn "Missing: protoc — https://github.com/protocolbuffers/protobuf/releases"
    return 1
  fi

  local version
  version=$(protoc --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)

  if ! version_gte "$version" "$MIN_PROTOC_VERSION"; then
    log_fatal "protoc version $version is below minimum required $MIN_PROTOC_VERSION"
  fi

  log_success "protoc $version"
  return 0
}

check_all_tools() {
  log_step "Checking required tools"

  check_protoc_version

  # Go plugins
  if [[ "$GEN_GO" == true ]]; then
    check_tool "protoc-gen-go" \
      "go install google.golang.org/protobuf/cmd/protoc-gen-go@latest" || true
    check_tool "protoc-gen-go-grpc" \
      "go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@latest" || true
  fi

  # Python plugins
  if [[ "$GEN_PYTHON" == true ]]; then
    check_tool "python3" "https://python.org" || true

    # Check grpcio-tools is importable as a Python module
    if ! python3 -c "import grpc_tools.protoc" &>/dev/null; then
      log_warn "Missing Python module: grpcio-tools — pip install grpcio-tools betterproto[compiler]"
      MISSING_TOOLS+=("grpcio-tools")
    else
      log_success "grpcio-tools (python)"
    fi
  fi

  # TypeScript plugins
  if [[ "$GEN_TS" == true ]]; then
    check_tool "node" "https://nodejs.org" || true
    # ts-proto is used as a local npx tool, check it's in node_modules or globally
    if ! npx --no ts-proto --version &>/dev/null 2>&1; then
      log_warn "Missing: ts-proto — npm install -g ts-proto  OR  add to package.json devDependencies"
      MISSING_TOOLS+=("ts-proto")
    else
      log_success "ts-proto"
    fi
    check_tool "grpc_tools_node_protoc_plugin" \
      "npm install -g grpc-tools" || true
  fi

  # Report
  if [[ ${#MISSING_TOOLS[@]} -gt 0 ]]; then
    echo ""
    log_error "The following tools are missing:"
    for t in "${MISSING_TOOLS[@]}"; do
      echo "  - $t"
    done
    echo ""
    echo "Run ${CYAN}./scripts/bootstrap.sh${RESET} to install all dependencies automatically."
    exit 1
  fi

  log_success "All required tools present"
}


# ─── Proto include / well-known types ─────────────────────────────────────────

# protoc needs access to google/protobuf/*.proto for our imports.
# We download them if they're not already cached locally.
ensure_proto_includes() {
  if [[ -d "${PROTO_INCLUDE}/google/protobuf" ]]; then
    return 0
  fi

  log_step "Downloading well-known proto includes"
  mkdir -p "${PROTO_INCLUDE}"

  local protoc_version
  protoc_version=$(protoc --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
  local include_url="https://raw.githubusercontent.com/protocolbuffers/protobuf/v${protoc_version}/src"

  local well_known_types=(
    "google/protobuf/timestamp.proto"
    "google/protobuf/duration.proto"
    "google/protobuf/struct.proto"
    "google/protobuf/any.proto"
    "google/protobuf/empty.proto"
    "google/protobuf/wrappers.proto"
  )

  for proto_file in "${well_known_types[@]}"; do
    local dest="${PROTO_INCLUDE}/${proto_file}"
    mkdir -p "$(dirname "$dest")"
    if [[ ! -f "$dest" ]]; then
      log_info "Fetching ${proto_file}..."
      curl -fsSL "${include_url}/${proto_file}" -o "$dest" || \
        log_fatal "Failed to download ${proto_file}. Check your internet connection."
    fi
  done

  log_success "Well-known types ready"
}


# ─── Clean ────────────────────────────────────────────────────────────────────

clean_generated() {
  log_step "Cleaning generated files"

  # Go: remove generated .pb.go files but not handwritten code
  if [[ -d "$GO_OUT" ]]; then
    find "$GO_OUT" -name "*.pb.go" -delete && \
      log_success "Cleaned Go generated files" || \
      log_warn "No Go generated files found"
  fi

  # Python: remove generated _pb2.py and _pb2_grpc.py files
  if [[ -d "$PYTHON_OUT" ]]; then
    find "$PYTHON_OUT" -name "*_pb2*.py" -delete && \
      log_success "Cleaned Python generated files" || \
      log_warn "No Python generated files found"
  fi

  # TypeScript: remove generated .ts files in the gen/ subfolder
  if [[ -d "${TS_OUT}/gen" ]]; then
    rm -rf "${TS_OUT}/gen" && \
      log_success "Cleaned TypeScript generated files" || \
      log_warn "No TypeScript generated files found"
  fi

  if [[ "$CLEAN_ONLY" == true ]]; then
    echo ""
    log_success "Clean complete."
    exit 0
  fi
}


# ─── Generate Go ──────────────────────────────────────────────────────────────

generate_go() {
  log_step "Generating Go types"

  mkdir -p "$GO_OUT"

  protoc \
    --proto_path="${PROTO_DIR}" \
    --proto_path="${PROTO_INCLUDE}" \
    --go_out="${GO_OUT}" \
    --go_opt=paths=source_relative \
    --go-grpc_out="${GO_OUT}" \
    --go-grpc_opt=paths=source_relative \
    "${PROTO_FILE}"

  # Verify output exists and has content
  local generated_files
  generated_files=$(find "$GO_OUT" -name "*.pb.go" 2>/dev/null | wc -l | tr -d ' ')

  if [[ "$generated_files" -eq 0 ]]; then
    log_fatal "Go generation produced no output files. Check protoc errors above."
  fi

  log_success "Generated ${generated_files} Go file(s) → ${GO_OUT}"

  # List what was generated
  find "$GO_OUT" -name "*.pb.go" | while read -r f; do
    local size
    size=$(wc -l < "$f")
    log_info "  ${f##"$PROJECT_ROOT/"} (${size} lines)"
  done
}


# ─── Generate Python ──────────────────────────────────────────────────────────

generate_python() {
  log_step "Generating Python types"

  mkdir -p "$PYTHON_OUT"

  # Use grpcio-tools (Python's protoc wrapper) — this avoids protoc version
  # mismatch issues between the system protoc and Python's expected version.
  python3 -m grpc_tools.protoc \
    --proto_path="${PROTO_DIR}" \
    --proto_path="${PROTO_INCLUDE}" \
    --python_out="${PYTHON_OUT}" \
    --grpc_python_out="${PYTHON_OUT}" \
    --pyi_out="${PYTHON_OUT}" \
    "${PROTO_FILE}"

  # Fix relative imports in generated files (grpcio-tools generates absolute
  # imports that break when used as a package)
  find "$PYTHON_OUT" -name "*_pb2_grpc.py" | while read -r f; do
    # Replace "import agent_pb2" with "from . import agent_pb2"
    sed -i.bak 's/^import \([a-z_]*_pb2\)/from . import \1/' "$f"
    rm -f "${f}.bak"
  done

  # Create __init__.py if it doesn't exist, so the directory is a package
  if [[ ! -f "${PYTHON_OUT}/__init__.py" ]]; then
    cat > "${PYTHON_OUT}/__init__.py" << 'EOF'
# Auto-generated package init. Do not edit manually.
# Re-exports all generated proto types for convenient importing.
from .agent_pb2 import (
    AgentIdentity,
    AgentCredential,
    Role,
    ScopeDefinition,
    TokenRevocation,
    TokenSummary,
    AuditEvent,
    ThreatSignal,
    PolicyDecision,
    SandboxSpec,
    SandboxResult,
)
from .agent_pb2 import (
    AgentType,
    AgentStatus,
    Decision,
    EventType,
    ThreatSeverity,
    ThreatType,
    CredentialBackend,
)

__all__ = [
    "AgentIdentity", "AgentCredential", "Role", "ScopeDefinition",
    "TokenRevocation", "TokenSummary", "AuditEvent", "ThreatSignal",
    "PolicyDecision", "SandboxSpec", "SandboxResult",
    "AgentType", "AgentStatus", "Decision", "EventType",
    "ThreatSeverity", "ThreatType", "CredentialBackend",
]
EOF
    log_info "Created ${PYTHON_OUT}/__init__.py"
  fi

  local generated_files
  generated_files=$(find "$PYTHON_OUT" -name "*_pb2*.py" 2>/dev/null | wc -l | tr -d ' ')

  if [[ "$generated_files" -eq 0 ]]; then
    log_fatal "Python generation produced no output files."
  fi

  log_success "Generated ${generated_files} Python file(s) → ${PYTHON_OUT}"

  find "$PYTHON_OUT" -name "*_pb2*.py" -o -name "*_pb2*.pyi" | while read -r f; do
    local size
    size=$(wc -l < "$f")
    log_info "  ${f##"$PROJECT_ROOT/"} (${size} lines)"
  done
}


# ─── Generate TypeScript ───────────────────────────────────────────────────────

generate_typescript() {
  log_step "Generating TypeScript types"

  local ts_gen_dir="${TS_OUT}/gen"
  mkdir -p "$ts_gen_dir"

  # ts-proto generates idiomatic TypeScript (interfaces, enums, async clients)
  # rather than the older JS-style grpc-web output.
  # Options:
  #   outputServices=grpc-js  → generates Node.js gRPC service stubs
  #   esModuleInterop=true    → compatible with TypeScript's strict mode
  #   stringEnums=true        → enums as string unions instead of numbers
  #   onlyTypes=false         → also generate service client code
  protoc \
    --proto_path="${PROTO_DIR}" \
    --proto_path="${PROTO_INCLUDE}" \
    --plugin="protoc-gen-ts_proto=$(which ts-proto-protoc-plugin 2>/dev/null || npx --no ts-proto --print-plugin-path 2>/dev/null || echo "ts-proto")" \
    --ts_proto_out="${ts_gen_dir}" \
    --ts_proto_opt=outputServices=grpc-js \
    --ts_proto_opt=esModuleInterop=true \
    --ts_proto_opt=stringEnums=true \
    --ts_proto_opt=onlyTypes=false \
    --ts_proto_opt=useDate=true \
    --ts_proto_opt=env=node \
    "${PROTO_FILE}"

  # Create a barrel export so consumers can do:
  # import { AgentIdentity, Decision } from '@aegisflow/shared-types'
  cat > "${TS_OUT}/index.ts" << 'EOF'
/**
 * AegisFlow shared types — auto-generated from packages/proto/agent.proto
 * Do not edit this file manually. Run scripts/generate-proto.sh to regenerate.
 */
export * from './gen/agent';
EOF

  local generated_files
  generated_files=$(find "$ts_gen_dir" -name "*.ts" 2>/dev/null | wc -l | tr -d ' ')

  if [[ "$generated_files" -eq 0 ]]; then
    log_fatal "TypeScript generation produced no output files."
  fi

  log_success "Generated ${generated_files} TypeScript file(s) → ${ts_gen_dir}"

  find "$ts_gen_dir" -name "*.ts" | while read -r f; do
    local size
    size=$(wc -l < "$f")
    log_info "  ${f##"$PROJECT_ROOT/"} (${size} lines)"
  done
}


# ─── Post-generation validation ───────────────────────────────────────────────

# Spot-check that key type names appear in the generated output.
# This catches silent codegen failures where the tool runs but produces
# incorrect or empty output.
validate_output() {
  log_step "Validating generated output"

  local failed=false

  if [[ "$GEN_GO" == true ]]; then
    local go_file="${GO_OUT}/agent.pb.go"
    if [[ ! -f "$go_file" ]]; then
      log_error "Expected Go file not found: $go_file"
      failed=true
    else
      for symbol in "AgentIdentity" "AuditEvent" "ThreatSignal" "PolicyDecision"; do
        if ! grep -q "$symbol" "$go_file"; then
          log_error "Go output missing expected type: $symbol"
          failed=true
        fi
      done
      log_success "Go output validated"
    fi
  fi

  if [[ "$GEN_PYTHON" == true ]]; then
    local py_file="${PYTHON_OUT}/agent_pb2.py"
    if [[ ! -f "$py_file" ]]; then
      log_error "Expected Python file not found: $py_file"
      failed=true
    else
      # Proto-generated Python uses descriptor pools, not direct class names
      # so we check for the descriptor name instead
      for symbol in "AgentIdentity" "AuditEvent" "ThreatSignal"; do
        if ! grep -q "$symbol" "$py_file"; then
          log_error "Python output missing expected descriptor: $symbol"
          failed=true
        fi
      done
      log_success "Python output validated"
    fi
  fi

  if [[ "$GEN_TS" == true ]]; then
    local ts_file="${TS_OUT}/gen/agent.ts"
    if [[ ! -f "$ts_file" ]]; then
      log_error "Expected TypeScript file not found: $ts_file"
      failed=true
    else
      for symbol in "AgentIdentity" "AuditEvent" "ThreatSignal" "Decision"; do
        if ! grep -q "$symbol" "$ts_file"; then
          log_error "TypeScript output missing expected type: $symbol"
          failed=true
        fi
      done
      log_success "TypeScript output validated"
    fi
  fi

  if [[ "$failed" == true ]]; then
    log_fatal "Validation failed. Generated output is incomplete or missing."
  fi
}


# ─── Summary ──────────────────────────────────────────────────────────────────

print_summary() {
  echo ""
  echo -e "${BOLD}${GREEN}━━━ Generation complete ━━━${RESET}"
  echo ""

  [[ "$GEN_GO" == true ]]     && echo -e "  Go          → ${CYAN}${GO_OUT}${RESET}"
  [[ "$GEN_PYTHON" == true ]] && echo -e "  Python      → ${CYAN}${PYTHON_OUT}${RESET}"
  [[ "$GEN_TS" == true ]]     && echo -e "  TypeScript  → ${CYAN}${TS_OUT}${RESET}"

  echo ""
  echo -e "  Import in Go:         ${YELLOW}import aegisflowv1 \"github.com/aegisflow/packages/proto/gen/go\"${RESET}"
  echo -e "  Import in Python:     ${YELLOW}from packages.shared_types.python import AgentIdentity${RESET}"
  echo -e "  Import in TypeScript: ${YELLOW}import { AgentIdentity } from '@aegisflow/shared-types'${RESET}"
  echo ""
}


# ─── Main execution ───────────────────────────────────────────────────────────

main() {
  echo ""
  echo -e "${BOLD}AegisFlow — Proto Code Generation${RESET}"
  echo -e "Proto source: ${CYAN}${PROTO_FILE}${RESET}"
  echo ""

  # Verify proto file exists
  if [[ ! -f "$PROTO_FILE" ]]; then
    log_fatal "Proto file not found: ${PROTO_FILE}"
  fi

  # Step 1: check tools
  check_all_tools

  # If --check only, stop here
  if [[ "$CHECK_ONLY" == true ]]; then
    echo ""
    log_success "Tool check passed. All required tools are installed."
    exit 0
  fi

  # Step 2: ensure proto includes (well-known types)
  ensure_proto_includes

  # Step 3: clean old generated files
  clean_generated

  # Step 4: generate
  [[ "$GEN_GO" == true ]]     && generate_go
  [[ "$GEN_PYTHON" == true ]] && generate_python
  [[ "$GEN_TS" == true ]]     && generate_typescript

  # Step 5: validate
  validate_output

  # Step 6: summary
  print_summary
}

main "$@"