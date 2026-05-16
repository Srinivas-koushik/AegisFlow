#!/usr/bin/env bash

# scripts/bootstrap.sh
#
# AegisFlow — One-command developer environment setup.
# Idempotent: safe to run multiple times. Skips already-installed tools.
#
# Usage:
#   ./scripts/bootstrap.sh                 — full setup
#   ./scripts/bootstrap.sh --tools-only    — install tools, skip DB + git hooks
#   ./scripts/bootstrap.sh --db-only       — setup database only
#   ./scripts/bootstrap.sh --verify        — verify everything is installed correctly
#   ./scripts/bootstrap.sh --ci            — CI mode: non-interactive, strict failures
#
# Supported platforms:
#   macOS 12+   (Intel x86_64 and Apple Silicon arm64)
#   Ubuntu 20.04+, Debian 11+
#   Arch Linux
#   RHEL 8+, Fedora 36+
#
# Pinned tool versions (update these when upgrading):
#   Go:      1.22.4
#   Node:    20.14.0  (LTS)
#   Python:  3.12.4
#   protoc:  27.2
#   OPA:     0.66.0
#   Buf:     1.34.0   (modern proto toolchain, used alongside protoc)


set -euo pipefail

# ─── Constants ────────────────────────────────────────────────────────────────

readonly AEGISFLOW_VERSION="0.1.0"

# Pinned versions — change here, changes everywhere
readonly REQUIRED_GO_VERSION="1.22.4"
readonly REQUIRED_NODE_VERSION="20.14.0"
readonly REQUIRED_PYTHON_VERSION="3.12.4"
readonly REQUIRED_PROTOC_VERSION="27.2"
readonly REQUIRED_OPA_VERSION="0.66.0"
readonly REQUIRED_BUF_VERSION="1.34.0"
readonly REQUIRED_DOCKER_VERSION="24.0.0"
readonly REQUIRED_POSTGRES_VERSION="16"

# Database config for local dev (never used in production)
readonly DB_HOST="localhost"
readonly DB_PORT="5432"
readonly DB_NAME="aegisflow_dev"
readonly DB_USER="aegisflow"
readonly DB_PASSWORD="aegisflow_dev_secret"
readonly DB_TEST_NAME="aegisflow_test"

# ─── Formatting ───────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${RESET}    $*"; }
log_success() { echo -e "${GREEN}[✓]${RESET}      $*"; }
log_skip()    { echo -e "${DIM}[SKIP]${RESET}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${RESET}    $*"; }
log_error()   { echo -e "${RED}[ERROR]${RESET}   $*" >&2; }
log_step()    { echo -e "\n${BOLD}${CYAN}┌─ $* ${RESET}"; }
log_fatal()   { echo -e "${RED}${BOLD}[FATAL]${RESET}   $*" >&2; exit 1; }
log_action()  { echo -e "${MAGENTA}[INSTALL]${RESET} $*"; }

# In CI mode, errors are fatal immediately
CI_MODE=false
TOOLS_ONLY=false
DB_ONLY=false
VERIFY_ONLY=false

# Track what we installed for the summary
INSTALLED=()
SKIPPED=()
FAILED=()

# ─── Argument parsing ─────────────────────────────────────────────────────────

for arg in "$@"; do
  case "$arg" in
    --ci)          CI_MODE=true ;;
    --tools-only)  TOOLS_ONLY=true ;;
    --db-only)     DB_ONLY=true ;;
    --verify)      VERIFY_ONLY=true ;;
    --help|-h)
      sed -n '3,25p' "$0" | sed 's/^# //'
      exit 0
      ;;
    *)
      log_fatal "Unknown argument: $arg. Run with --help for usage."
      ;;
  esac
done


# ─── Platform detection ───────────────────────────────────────────────────────

detect_platform() {
  OS="$(uname -s)"
  ARCH="$(uname -m)"

  case "$OS" in
    Darwin)
      PLATFORM="macos"
      if [[ "$ARCH" == "arm64" ]]; then
        PLATFORM_VARIANT="macos-arm64"
      else
        PLATFORM_VARIANT="macos-x86_64"
      fi
      ;;
    Linux)
      PLATFORM="linux"
      # Detect Linux distribution
      if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        case "${ID:-}" in
          ubuntu|debian|linuxmint) DISTRO="debian" ;;
          arch|manjaro|endeavouros) DISTRO="arch" ;;
          rhel|centos|fedora|rocky|almalinux) DISTRO="rhel" ;;
          *) DISTRO="unknown" ;;
        esac
      else
        DISTRO="unknown"
      fi
      PLATFORM_VARIANT="linux-${ARCH}"
      ;;
    *)
      log_fatal "Unsupported OS: $OS. AegisFlow bootstrap supports macOS and Linux only."
      ;;
  esac

  log_info "Platform: ${BOLD}${OS} ${ARCH}${RESET} (${PLATFORM_VARIANT})"
}


# ─── Version comparison ───────────────────────────────────────────────────────

# Returns 0 (true) if installed version >= required version
version_gte() {
  local installed="$1"
  local required="$2"
  [[ "$(printf '%s\n' "$required" "$installed" | sort -V | head -1)" == "$required" ]]
}

# Extract version number from a string like "go1.22.4" or "v1.22.4" or "1.22.4"
normalize_version() {
  echo "$1" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1
}


# ─── Package manager helpers ──────────────────────────────────────────────────

install_system_package() {
  local package="$1"
  log_action "Installing system package: ${package}"

  case "${PLATFORM}" in
    macos)
      if ! command -v brew &>/dev/null; then
        log_info "Installing Homebrew..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

        # Add brew to PATH for Apple Silicon
        if [[ "$ARCH" == "arm64" ]]; then
          eval "$(/opt/homebrew/bin/brew shellenv)"
        fi
      fi
      brew install "$package"
      ;;
    linux)
      case "${DISTRO}" in
        debian)
          sudo apt-get update -qq
          sudo apt-get install -y "$package"
          ;;
        arch)
          sudo pacman -Sy --noconfirm "$package"
          ;;
        rhel)
          sudo dnf install -y "$package"
          ;;
        *)
          log_warn "Unknown distro. Attempting apt-get for ${package}..."
          sudo apt-get install -y "$package" || \
            log_warn "Could not install ${package}. Please install it manually."
          ;;
      esac
      ;;
  esac
}

# Safely add a line to a shell config file if it's not already there
append_to_shell_config() {
  local line="$1"
  local config_files=("$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile")

  for config in "${config_files[@]}"; do
    if [[ -f "$config" ]] && ! grep -qF "$line" "$config"; then
      echo "$line" >> "$config"
      log_info "Added to ${config}: ${line}"
    fi
  done
}


# ─── Individual tool installers ───────────────────────────────────────────────

install_go() {
  log_step "Go ${REQUIRED_GO_VERSION}"

  if command -v go &>/dev/null; then
    local current
    current=$(normalize_version "$(go version)")
    if version_gte "$current" "$REQUIRED_GO_VERSION"; then
      log_skip "Go ${current} already installed (>= ${REQUIRED_GO_VERSION})"
      SKIPPED+=("go")
      return 0
    fi
    log_warn "Go ${current} found but need >= ${REQUIRED_GO_VERSION}, upgrading..."
  fi

  log_action "Installing Go ${REQUIRED_GO_VERSION}"

  local go_archive go_url
  if [[ "$PLATFORM" == "macos" ]]; then
    if [[ "$ARCH" == "arm64" ]]; then
      go_archive="go${REQUIRED_GO_VERSION}.darwin-arm64.tar.gz"
    else
      go_archive="go${REQUIRED_GO_VERSION}.darwin-amd64.tar.gz"
    fi
  else
    if [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
      go_archive="go${REQUIRED_GO_VERSION}.linux-arm64.tar.gz"
    else
      go_archive="go${REQUIRED_GO_VERSION}.linux-amd64.tar.gz"
    fi
  fi

  go_url="https://go.dev/dl/${go_archive}"

  local tmp_dir
  tmp_dir=$(mktemp -d)
  trap 'rm -rf "$tmp_dir"' RETURN

  log_info "Downloading ${go_url}..."
  curl -fsSL "$go_url" -o "${tmp_dir}/${go_archive}"

  # Verify checksum (fetch from Go download page)
  log_info "Verifying checksum..."
  local expected_sha
  expected_sha=$(curl -fsSL "https://go.dev/dl/?mode=json" | \
    python3 -c "
import sys, json
data = json.load(sys.stdin)
for release in data:
    if release['version'] == 'go${REQUIRED_GO_VERSION}':
        for f in release['files']:
            if f['filename'] == '${go_archive}':
                print(f['sha256'])
                sys.exit(0)
" 2>/dev/null || echo "")

  if [[ -n "$expected_sha" ]]; then
    local actual_sha
    actual_sha=$(sha256sum "${tmp_dir}/${go_archive}" 2>/dev/null || \
                 shasum -a 256 "${tmp_dir}/${go_archive}" | awk '{print $1}')
    if [[ "$actual_sha" != "$expected_sha" ]]; then
      log_fatal "Go archive checksum mismatch. Expected: ${expected_sha}, Got: ${actual_sha}"
    fi
    log_success "Checksum verified"
  else
    log_warn "Could not fetch expected checksum — skipping verification"
  fi

  sudo rm -rf /usr/local/go
  sudo tar -C /usr/local -xzf "${tmp_dir}/${go_archive}"

  # Add to PATH
  export PATH="/usr/local/go/bin:$PATH"
  append_to_shell_config 'export PATH="/usr/local/go/bin:$PATH"'

  log_success "Go ${REQUIRED_GO_VERSION} installed"
  INSTALLED+=("go@${REQUIRED_GO_VERSION}")
}

install_go_tools() {
  log_step "Go protoc plugins + dev tools"

  # Ensure GOPATH/bin is on PATH
  local gopath
  gopath=$(go env GOPATH)
  export PATH="${gopath}/bin:$PATH"
  append_to_shell_config "export PATH=\"${gopath}/bin:\$PATH\""

  declare -A go_tools=(
    ["protoc-gen-go"]="google.golang.org/protobuf/cmd/protoc-gen-go@v1.34.2"
    ["protoc-gen-go-grpc"]="google.golang.org/grpc/cmd/protoc-gen-go-grpc@v1.4.0"
    ["migrate"]="github.com/golang-migrate/migrate/v4/cmd/migrate@v4.17.1"
    ["golangci-lint"]="github.com/golangci/golangci-lint/cmd/golangci-lint@v1.59.1"
    ["air"]="github.com/air-verse/air@v1.52.3"    # live reload for dev
    ["mockgen"]="go.uber.org/mock/mockgen@v0.4.0"  # mock generation
  )

  for tool in "${!go_tools[@]}"; do
    if command -v "$tool" &>/dev/null; then
      log_skip "${tool} already installed"
      SKIPPED+=("$tool")
    else
      log_action "Installing ${tool}..."
      go install "${go_tools[$tool]}"
      log_success "${tool} installed"
      INSTALLED+=("$tool")
    fi
  done
}

install_node() {
  log_step "Node.js ${REQUIRED_NODE_VERSION}"

  # Prefer nvm for Node management — allows per-project version switching
  if command -v node &>/dev/null; then
    local current
    current=$(normalize_version "$(node --version)")
    if version_gte "$current" "$REQUIRED_NODE_VERSION"; then
      log_skip "Node ${current} already installed (>= ${REQUIRED_NODE_VERSION})"
      SKIPPED+=("node")
      return 0
    fi
    log_warn "Node ${current} found but need >= ${REQUIRED_NODE_VERSION}"
  fi

  # Install nvm if not present
  if ! command -v nvm &>/dev/null && [[ ! -f "$HOME/.nvm/nvm.sh" ]]; then
    log_action "Installing nvm (Node Version Manager)..."
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
  fi

  # Source nvm
  export NVM_DIR="$HOME/.nvm"
  # shellcheck source=/dev/null
  [[ -s "$NVM_DIR/nvm.sh" ]] && source "$NVM_DIR/nvm.sh"

  log_action "Installing Node.js ${REQUIRED_NODE_VERSION} via nvm..."
  nvm install "$REQUIRED_NODE_VERSION"
  nvm alias default "$REQUIRED_NODE_VERSION"
  nvm use "$REQUIRED_NODE_VERSION"

  log_success "Node.js $(node --version) installed"
  INSTALLED+=("node@${REQUIRED_NODE_VERSION}")
}

install_node_tools() {
  log_step "Node.js global tools"

  declare -A node_tools=(
    ["ts-proto"]="ts-proto@2.0.1"
    ["grpc-tools"]="grpc-tools@1.12.4"
    ["typescript"]="typescript@5.5.3"
    ["tsx"]="tsx@4.16.2"           # TypeScript executor for scripts
    ["pnpm"]="pnpm@9.5.0"          # faster npm
  )

  for tool in "${!node_tools[@]}"; do
    if npm list -g "$tool" &>/dev/null 2>&1; then
      log_skip "${tool} already installed globally"
      SKIPPED+=("$tool")
    else
      log_action "Installing ${tool}..."
      npm install -g "${node_tools[$tool]}"
      log_success "${tool} installed"
      INSTALLED+=("$tool")
    fi
  done
}

install_python() {
  log_step "Python ${REQUIRED_PYTHON_VERSION}"

  if command -v python3 &>/dev/null; then
    local current
    current=$(normalize_version "$(python3 --version 2>&1)")
    if version_gte "$current" "3.11.0"; then  # allow 3.11+ not just exact
      log_skip "Python ${current} already installed (>= 3.11.0)"
      SKIPPED+=("python3")

      # Still ensure pip packages are installed
      install_python_packages
      return 0
    fi
  fi

  case "$PLATFORM" in
    macos)
      install_system_package "python@3.12"
      ;;
    linux)
      case "${DISTRO}" in
        debian)
          sudo apt-get update -qq
          sudo apt-get install -y \
            python3.12 python3.12-venv python3.12-dev \
            python3-pip python3-wheel
          ;;
        arch)
          sudo pacman -Sy --noconfirm python python-pip
          ;;
        rhel)
          sudo dnf install -y python3.12 python3.12-pip python3.12-devel
          ;;
      esac
      ;;
  esac

  log_success "Python $(python3 --version) installed"
  INSTALLED+=("python@${REQUIRED_PYTHON_VERSION}")

  install_python_packages
}

install_python_packages() {
  log_step "Python packages"

  local packages=(
    "grpcio==1.64.1"
    "grpcio-tools==1.64.1"
    "betterproto[compiler]==2.0.0b6"
    "protobuf==5.27.2"
    "pydantic==2.8.2"           # runtime config validation
    "structlog==24.2.0"         # structured logging
    "opentelemetry-sdk==1.25.0" # observability
    "opentelemetry-exporter-otlp==1.25.0"
    "pytest==8.2.2"
    "pytest-asyncio==0.23.7"
    "black==24.4.2"             # formatter
    "ruff==0.5.1"               # linter
    "mypy==1.10.1"              # type checking
  )

  local needs_install=false
  for pkg in "${packages[@]}"; do
    local pkg_name
    pkg_name=$(echo "$pkg" | cut -d'=' -f1)
    if ! python3 -c "import ${pkg_name//-/_}" &>/dev/null 2>&1; then
      needs_install=true
      break
    fi
  done

  if [[ "$needs_install" == false ]]; then
    log_skip "All Python packages already installed"
    SKIPPED+=("python-packages")
    return 0
  fi

  log_action "Installing Python packages..."
  python3 -m pip install --upgrade pip --quiet
  python3 -m pip install "${packages[@]}" --quiet --break-system-packages 2>/dev/null || \
    python3 -m pip install "${packages[@]}" --quiet

  log_success "Python packages installed"
  INSTALLED+=("python-packages")
}

install_protoc() {
  log_step "protoc ${REQUIRED_PROTOC_VERSION}"

  if command -v protoc &>/dev/null; then
    local current
    current=$(normalize_version "$(protoc --version 2>&1)")
    if version_gte "$current" "$REQUIRED_PROTOC_VERSION"; then
      log_skip "protoc ${current} already installed"
      SKIPPED+=("protoc")
      return 0
    fi
    log_warn "protoc ${current} found but need >= ${REQUIRED_PROTOC_VERSION}"
  fi

  log_action "Installing protoc ${REQUIRED_PROTOC_VERSION}..."

  local protoc_zip protoc_url
  case "$PLATFORM" in
    macos)
      if [[ "$ARCH" == "arm64" ]]; then
        protoc_zip="protoc-${REQUIRED_PROTOC_VERSION}-osx-aarch_64.zip"
      else
        protoc_zip="protoc-${REQUIRED_PROTOC_VERSION}-osx-x86_64.zip"
      fi
      ;;
    linux)
      if [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
        protoc_zip="protoc-${REQUIRED_PROTOC_VERSION}-linux-aarch_64.zip"
      else
        protoc_zip="protoc-${REQUIRED_PROTOC_VERSION}-linux-x86_64.zip"
      fi
      ;;
  esac

  protoc_url="https://github.com/protocolbuffers/protobuf/releases/download/v${REQUIRED_PROTOC_VERSION}/${protoc_zip}"

  local tmp_dir
  tmp_dir=$(mktemp -d)
  trap 'rm -rf "$tmp_dir"' RETURN

  curl -fsSL "$protoc_url" -o "${tmp_dir}/${protoc_zip}"
  unzip -q "${tmp_dir}/${protoc_zip}" -d "${tmp_dir}/protoc"

  sudo cp "${tmp_dir}/protoc/bin/protoc" /usr/local/bin/
  sudo cp -r "${tmp_dir}/protoc/include/"* /usr/local/include/ 2>/dev/null || true
  sudo chmod +x /usr/local/bin/protoc

  log_success "protoc $(protoc --version) installed"
  INSTALLED+=("protoc@${REQUIRED_PROTOC_VERSION}")
}

install_buf() {
  log_step "Buf ${REQUIRED_BUF_VERSION} (modern proto toolchain)"

  if command -v buf &>/dev/null; then
    local current
    current=$(normalize_version "$(buf --version 2>&1)")
    if version_gte "$current" "$REQUIRED_BUF_VERSION"; then
      log_skip "buf ${current} already installed"
      SKIPPED+=("buf")
      return 0
    fi
  fi

  log_action "Installing buf ${REQUIRED_BUF_VERSION}..."

  local buf_binary buf_url
  case "$PLATFORM" in
    macos)
      [[ "$ARCH" == "arm64" ]] && \
        buf_binary="buf-Darwin-arm64" || \
        buf_binary="buf-Darwin-x86_64"
      ;;
    linux)
      [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]] && \
        buf_binary="buf-Linux-aarch64" || \
        buf_binary="buf-Linux-x86_64"
      ;;
  esac

  buf_url="https://github.com/bufbuild/buf/releases/download/v${REQUIRED_BUF_VERSION}/${buf_binary}"

  curl -fsSL "$buf_url" -o /tmp/buf
  chmod +x /tmp/buf
  sudo mv /tmp/buf /usr/local/bin/buf

  log_success "buf $(buf --version) installed"
  INSTALLED+=("buf@${REQUIRED_BUF_VERSION}")
}

install_opa() {
  log_step "OPA (Open Policy Agent) ${REQUIRED_OPA_VERSION}"

  if command -v opa &>/dev/null; then
    local current
    current=$(normalize_version "$(opa version 2>&1 | head -1)")
    if version_gte "$current" "$REQUIRED_OPA_VERSION"; then
      log_skip "OPA ${current} already installed"
      SKIPPED+=("opa")
      return 0
    fi
  fi

  log_action "Installing OPA ${REQUIRED_OPA_VERSION}..."

  local opa_binary opa_url
  case "$PLATFORM" in
    macos)
      [[ "$ARCH" == "arm64" ]] && \
        opa_binary="opa_darwin_arm64_static" || \
        opa_binary="opa_darwin_amd64_static"
      ;;
    linux)
      [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]] && \
        opa_binary="opa_linux_arm64_static" || \
        opa_binary="opa_linux_amd64_static"
      ;;
  esac

  opa_url="https://github.com/open-policy-agent/opa/releases/download/v${REQUIRED_OPA_VERSION}/${opa_binary}"

  curl -fsSL "$opa_url" -o /tmp/opa
  chmod +x /tmp/opa
  sudo mv /tmp/opa /usr/local/bin/opa

  log_success "OPA $(opa version | head -1) installed"
  INSTALLED+=("opa@${REQUIRED_OPA_VERSION}")
}

install_docker() {
  log_step "Docker ${REQUIRED_DOCKER_VERSION}+"

  if command -v docker &>/dev/null; then
    local current
    current=$(normalize_version "$(docker --version 2>&1)")
    if version_gte "$current" "$REQUIRED_DOCKER_VERSION"; then
      log_skip "Docker ${current} already installed"
      SKIPPED+=("docker")
      return 0
    fi
  fi

  case "$PLATFORM" in
    macos)
      log_warn "Docker Desktop must be installed manually on macOS."
      log_warn "Download from: https://www.docker.com/products/docker-desktop"
      log_warn "Skipping Docker installation — install manually and re-run."
      SKIPPED+=("docker (manual required)")
      return 0
      ;;
    linux)
      log_action "Installing Docker Engine..."
      case "${DISTRO}" in
        debian)
          # Official Docker install script (most reliable on Debian/Ubuntu)
          curl -fsSL https://get.docker.com | sudo bash
          sudo usermod -aG docker "$USER"
          log_warn "Added ${USER} to docker group. Log out and back in to use Docker without sudo."
          ;;
        arch)
          sudo pacman -Sy --noconfirm docker docker-compose
          sudo systemctl enable --now docker
          sudo usermod -aG docker "$USER"
          ;;
        rhel)
          sudo dnf install -y docker-ce docker-ce-cli containerd.io
          sudo systemctl enable --now docker
          sudo usermod -aG docker "$USER"
          ;;
      esac
      ;;
  esac

  log_success "Docker installed"
  INSTALLED+=("docker")
}

install_postgres_client() {
  log_step "PostgreSQL client tools"

  if command -v psql &>/dev/null; then
    log_skip "psql already installed ($(psql --version | head -1))"
    SKIPPED+=("psql")
    return 0
  fi

  case "$PLATFORM" in
    macos)
      install_system_package "libpq"
      # libpq installs psql, pg_dump etc
      brew link --force libpq
      ;;
    linux)
      case "${DISTRO}" in
        debian)
          sudo apt-get install -y "postgresql-client-${REQUIRED_POSTGRES_VERSION}" || \
            sudo apt-get install -y postgresql-client
          ;;
        arch)
          sudo pacman -Sy --noconfirm postgresql-libs
          ;;
        rhel)
          sudo dnf install -y postgresql
          ;;
      esac
      ;;
  esac

  log_success "PostgreSQL client installed"
  INSTALLED+=("psql")
}


# ─── Database setup ───────────────────────────────────────────────────────────

setup_database() {
  log_step "Local PostgreSQL setup"

  # Check if PostgreSQL is running via Docker (preferred for local dev)
  if docker ps &>/dev/null 2>&1; then
    local container_name="aegisflow-postgres"

    if docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
      if docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
        log_skip "PostgreSQL container '${container_name}' already running"
      else
        log_info "Starting existing PostgreSQL container..."
        docker start "$container_name"
        log_success "PostgreSQL container started"
      fi
    else
      log_action "Creating PostgreSQL ${REQUIRED_POSTGRES_VERSION} container..."
      docker run -d \
        --name "$container_name" \
        --restart unless-stopped \
        -e POSTGRES_USER="$DB_USER" \
        -e POSTGRES_PASSWORD="$DB_PASSWORD" \
        -e POSTGRES_DB="$DB_NAME" \
        -p "${DB_PORT}:5432" \
        -v aegisflow-postgres-data:/var/lib/postgresql/data \
        "postgres:${REQUIRED_POSTGRES_VERSION}-alpine"

      log_info "Waiting for PostgreSQL to be ready..."
      local retries=30
      until docker exec "$container_name" pg_isready -U "$DB_USER" &>/dev/null 2>&1; do
        retries=$((retries - 1))
        if [[ $retries -eq 0 ]]; then
          log_fatal "PostgreSQL failed to start within 30 seconds"
        fi
        sleep 1
      done

      log_success "PostgreSQL container running on port ${DB_PORT}"
    fi

    # Create test database if it doesn't exist
    docker exec "$container_name" psql -U "$DB_USER" -tc \
      "SELECT 1 FROM pg_database WHERE datname='${DB_TEST_NAME}'" | \
      grep -q 1 || \
      docker exec "$container_name" psql -U "$DB_USER" \
        -c "CREATE DATABASE ${DB_TEST_NAME};"

    log_success "Databases ready: ${DB_NAME}, ${DB_TEST_NAME}"
    INSTALLED+=("postgres-docker")

  else
    log_warn "Docker not available. Attempting to connect to local PostgreSQL..."

    if command -v psql &>/dev/null; then
      if PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" \
          -U "$DB_USER" -d "$DB_NAME" -c '\q' &>/dev/null 2>&1; then
        log_skip "PostgreSQL already accessible at ${DB_HOST}:${DB_PORT}"
      else
        log_warn "Cannot connect to PostgreSQL. Please ensure it is running:"
        log_warn "  Host: ${DB_HOST}:${DB_PORT}"
        log_warn "  User: ${DB_USER}"
        log_warn "  DB:   ${DB_NAME}"
      fi
    else
      log_warn "Neither Docker nor psql available. Database setup skipped."
      log_warn "Install Docker and re-run, or set up PostgreSQL manually."
    fi
  fi
}


# ─── Environment file setup ───────────────────────────────────────────────────

setup_env_files() {
  log_step "Environment configuration"

  local env_template="${PROJECT_ROOT}/.env.example"
  local env_local="${PROJECT_ROOT}/.env.local"

  # Create .env.example if it doesn't exist yet (first-time setup)
  if [[ ! -f "$env_template" ]]; then
    log_action "Creating .env.example template..."
    cat > "$env_template" << EOF
# AegisFlow local development environment
# Copy this file to .env.local and fill in your values.
# NEVER commit .env.local to version control.

# ─── Database ─────────────────────────────────────────────────────────────────
DATABASE_URL=postgresql://${DB_USER}:${DB_PASSWORD}@${DB_HOST}:${DB_PORT}/${DB_NAME}
DATABASE_TEST_URL=postgresql://${DB_USER}:${DB_PASSWORD}@${DB_HOST}:${DB_PORT}/${DB_TEST_NAME}
DATABASE_MAX_CONNECTIONS=25
DATABASE_MAX_IDLE_CONNECTIONS=5

# ─── Auth Service ─────────────────────────────────────────────────────────────
AUTH_SERVICE_PORT=8081
AUTH_SERVICE_GRPC_PORT=9091
AUTH_SERVICE_LOG_LEVEL=debug

# JWT configuration
# Generate with: openssl rand -base64 64
JWT_SIGNING_KEY=REPLACE_WITH_STRONG_SECRET_MIN_64_CHARS
JWT_DEFAULT_TTL=3600         # seconds (1 hour)
JWT_MAX_TTL=86400            # seconds (24 hours)
JWT_ISSUER=aegisflow.local

# ─── Credential backend ───────────────────────────────────────────────────────
CREDENTIAL_BACKEND=memory    # memory | vault | aws_sm | gcp_sm | azure_kv
VAULT_ADDR=http://localhost:8200
VAULT_TOKEN=dev-root-token   # dev mode only

# ─── Telemetry ────────────────────────────────────────────────────────────────
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317
OTEL_SERVICE_NAME=aegisflow-auth
OTEL_TRACE_RATIO=1.0         # 1.0 = 100% sampling (reduce in production)

# ─── Runtime gateway ──────────────────────────────────────────────────────────
RUNTIME_GATEWAY_PORT=8082
RUNTIME_GATEWAY_GRPC_PORT=9092
OPA_BUNDLE_PATH=./infrastructure/opa/bundles

# ─── MCP Security Gateway ─────────────────────────────────────────────────────
MCP_GATEWAY_PORT=8083
MCP_INJECTION_THRESHOLD=0.75  # confidence threshold for blocking
MCP_ENABLE_SCHEMA_VALIDATION=true

# ─── Detection Engine ─────────────────────────────────────────────────────────
DETECTION_ENGINE_PORT=8084
DETECTION_MODEL_PATH=./apps/detection-engine/models
ANOMALY_THRESHOLD=0.85

# ─── Frontend dashboard ───────────────────────────────────────────────────────
NEXT_PUBLIC_API_URL=http://localhost:8082
NEXT_PUBLIC_WS_URL=ws://localhost:8082

# ─── Feature flags ────────────────────────────────────────────────────────────
FEATURE_AUTO_SUSPEND=false   # auto-suspend agents on CRITICAL threat
FEATURE_AUDIT_CHAIN=false    # cryptographic audit log chaining
EOF
    log_success "Created .env.example"
  fi

  # Create .env.local from template if it doesn't exist
  if [[ ! -f "$env_local" ]]; then
    cp "$env_template" "$env_local"

    # Auto-generate a JWT signing key
    local jwt_key
    jwt_key=$(openssl rand -base64 64 | tr -d '\n')
    sed -i.bak "s|REPLACE_WITH_STRONG_SECRET_MIN_64_CHARS|${jwt_key}|" "$env_local"
    rm -f "${env_local}.bak"

    log_success "Created .env.local with auto-generated JWT signing key"
    log_warn ".env.local is gitignored — never commit it"
  else
    log_skip ".env.local already exists"
  fi

  # Ensure .env.local is in .gitignore
  local gitignore="${PROJECT_ROOT}/.gitignore"
  if [[ -f "$gitignore" ]] && ! grep -q "\.env\.local" "$gitignore"; then
    echo ".env.local" >> "$gitignore"
    log_info "Added .env.local to .gitignore"
  fi
}


# ─── Git hooks ────────────────────────────────────────────────────────────────

setup_git_hooks() {
  log_step "Git hooks"

  local hooks_dir="${PROJECT_ROOT}/.git/hooks"

  if [[ ! -d "${PROJECT_ROOT}/.git" ]]; then
    log_warn "Not a git repository. Skipping git hooks setup."
    return 0
  fi

  mkdir -p "$hooks_dir"

  # Pre-commit: lint + format check + proto validation
  cat > "${hooks_dir}/pre-commit" << 'HOOK'
#!/usr/bin/env bash
# AegisFlow pre-commit hook
# Runs linting, formatting, and proto validation before every commit.

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RESET='\033[0m'
FAILED=()

run_check() {
  local name="$1"; shift
  if "$@" &>/dev/null 2>&1; then
    echo -e "${GREEN}[✓]${RESET} ${name}"
  else
    echo -e "${RED}[✗]${RESET} ${name}"
    FAILED+=("$name")
  fi
}

echo "Running AegisFlow pre-commit checks..."

# Check for secrets accidentally staged
if git diff --cached --name-only | xargs grep -l "PRIVATE KEY\|-----BEGIN\|jwt_secret\|password=" 2>/dev/null | grep -v ".env.example"; then
  echo -e "${RED}[✗]${RESET} Possible secrets detected in staged files. Commit blocked."
  exit 1
fi

# Go checks (only if Go files changed)
if git diff --cached --name-only | grep -q "\.go$"; then
  run_check "go fmt"      bash -c "gofmt -l $(git diff --cached --name-only | grep '\.go$') | [ ! -s /dev/stdin ]"
  run_check "go vet"      go vet ./...
  run_check "golangci-lint" golangci-lint run --fast ./... 2>/dev/null || true
fi

# Python checks (only if Python files changed)
if git diff --cached --name-only | grep -q "\.py$"; then
  run_check "ruff (python)" ruff check .
  run_check "black check"   black --check .
fi

# TypeScript checks (only if TS files changed)
if git diff --cached --name-only | grep -q "\.ts$\|\.tsx$"; then
  run_check "tsc" npx tsc --noEmit 2>/dev/null || true
fi

# Proto validation (only if proto files changed)
if git diff --cached --name-only | grep -q "\.proto$"; then
  run_check "buf lint" buf lint
fi

if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo ""
  echo -e "${RED}Pre-commit failed:${RESET}"
  for check in "${FAILED[@]}"; do
    echo "  - ${check}"
  done
  echo ""
  echo "Fix the above and try again. Use --no-verify to bypass (not recommended)."
  exit 1
fi

echo -e "${GREEN}All pre-commit checks passed.${RESET}"
HOOK

  # Commit-msg: enforce conventional commits format
  cat > "${hooks_dir}/commit-msg" << 'HOOK'
#!/usr/bin/env bash
# Enforces Conventional Commits format: https://www.conventionalcommits.org
# Valid: feat(auth): add JWT rotation
#        fix(sandbox): handle timeout edge case
#        docs: update bootstrap instructions

commit_msg=$(cat "$1")
pattern='^(feat|fix|docs|style|refactor|perf|test|chore|ci|build|revert)(\([a-z0-9-]+\))?: .{1,100}$'

if ! echo "$commit_msg" | grep -qE "$pattern"; then
  echo ""
  echo "Invalid commit message format."
  echo "Expected: <type>(<scope>): <description>"
  echo "Example:  feat(auth): add agent token rotation"
  echo ""
  echo "Valid types: feat fix docs style refactor perf test chore ci build revert"
  echo ""
  exit 1
fi
HOOK

  chmod +x "${hooks_dir}/pre-commit"
  chmod +x "${hooks_dir}/commit-msg"

  log_success "Git hooks installed (pre-commit, commit-msg)"
  INSTALLED+=("git-hooks")
}


# ─── Verification ─────────────────────────────────────────────────────────────

verify_installation() {
  log_step "Verifying installation"

  local all_ok=true

  verify_tool() {
    local name="$1"
    local cmd="$2"
    local min_version="${3:-}"

    if ! command -v "$name" &>/dev/null; then
      echo -e "  ${RED}✗${RESET} ${name} — not found"
      all_ok=false
      return
    fi

    if [[ -n "$min_version" ]]; then
      local current
      current=$(eval "$cmd" 2>&1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
      if version_gte "$current" "$min_version"; then
        echo -e "  ${GREEN}✓${RESET} ${name} ${current}"
      else
        echo -e "  ${YELLOW}⚠${RESET} ${name} ${current} (need >= ${min_version})"
        all_ok=false
      fi
    else
      echo -e "  ${GREEN}✓${RESET} ${name}"
    fi
  }

  echo ""
  verify_tool "go"             "go version"        "$REQUIRED_GO_VERSION"
  verify_tool "node"           "node --version"    "$REQUIRED_NODE_VERSION"
  verify_tool "python3"        "python3 --version" "3.11.0"
  verify_tool "protoc"         "protoc --version"  "$REQUIRED_PROTOC_VERSION"
  verify_tool "buf"            "buf --version"     "$REQUIRED_BUF_VERSION"
  verify_tool "opa"            "opa version"       "$REQUIRED_OPA_VERSION"
  verify_tool "docker"         "docker --version"  "$REQUIRED_DOCKER_VERSION"
  verify_tool "psql"           "psql --version"    ""
  verify_tool "protoc-gen-go"  "protoc-gen-go --version" ""
  verify_tool "protoc-gen-go-grpc" "protoc-gen-go-grpc --version" ""
  verify_tool "golangci-lint"  "golangci-lint --version" ""
  verify_tool "air"            "air -v"            ""
  echo ""

  if [[ "$all_ok" == false ]]; then
    log_warn "Some tools are missing or below minimum version."
    log_warn "Run ${CYAN}./scripts/bootstrap.sh${RESET} to install missing tools."
    return 1
  fi

  log_success "All tools verified"
}


# ─── Summary ──────────────────────────────────────────────────────────────────

print_summary() {
  echo ""
  echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "${BOLD}  AegisFlow bootstrap complete${RESET}"
  echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo ""

  if [[ ${#INSTALLED[@]} -gt 0 ]]; then
    echo -e "${GREEN}Installed:${RESET}"
    for item in "${INSTALLED[@]}"; do
      echo "  + $item"
    done
    echo ""
  fi

  if [[ ${#SKIPPED[@]} -gt 0 ]]; then
    echo -e "${DIM}Already present (skipped):${RESET}"
    for item in "${SKIPPED[@]}"; do
      echo "  · $item"
    done
    echo ""
  fi

  echo -e "${BOLD}Next steps:${RESET}"
  echo -e "  1. Reload your shell:  ${CYAN}source ~/.bashrc${RESET}  (or restart terminal)"
  echo -e "  2. Generate proto types: ${CYAN}./scripts/generate-proto.sh${RESET}"
  echo -e "  3. Seed the database:  ${CYAN}./scripts/seed-db.sh${RESET}"
  echo -e "  4. Start auth service: ${CYAN}cd apps/auth-service && air${RESET}"
  echo ""
  echo -e "  Docs: ${CYAN}docs/deployment/local.md${RESET}"
  echo ""
}


# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  echo ""
  echo -e "${BOLD}AegisFlow v${AEGISFLOW_VERSION} — Developer Bootstrap${RESET}"
  echo -e "${DIM}Platform: ${OS} ${ARCH}${RESET}"
  echo ""

  detect_platform

  # Verify only mode
  if [[ "$VERIFY_ONLY" == true ]]; then
    verify_installation
    exit $?
  fi

  # DB only mode
  if [[ "$DB_ONLY" == true ]]; then
    setup_database
    exit 0
  fi

  # Full setup or tools only
  install_go
  install_go_tools
  install_node
  install_node_tools
  install_python
  install_protoc
  install_buf
  install_opa
  install_docker
  install_postgres_client

  if [[ "$TOOLS_ONLY" == false ]]; then
    setup_database
    setup_env_files
    setup_git_hooks
  fi

  verify_installation
  print_summary
}

main "$@"