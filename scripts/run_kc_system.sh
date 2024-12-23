#!/usr/bin/env bash

# Exit immediately if a command exits with a non-zero status,
# treat unset variables as an error, and ensure pipeline commands fail if any command fails.
set -euo pipefail

# Initialize DEBUG to 0 (non-debug)
DEBUG=0

# Output Prefixes for Readability
INF="[INFO]     "
DBG="[DEBUG]    "
ERR="[ERROR]    "
WRN="[WARNING]  "
ADD="[ADD]      "
DEL="[DELETE]   "
GEN="[GENERATE] "
DEP="[DEPLOY]   "
CRE="[CREATE]   "
WAI="[WAIT]     "

# Parse command-line arguments to detect the --debug flag
for arg in "$@"; do
  case $arg in
    --debug)
      DEBUG=1
      shift
      ;;
    *)
      ;;
  esac
done

# -----------------------------
# Logging Functions
# -----------------------------

# Display routine informational messages
log_info() {
  echo -e "${INF} $1"
}

# Display warning messages
log_warn() {
  echo -e "${WRN} $1"
}

# Display error messages
log_error() {
  echo -e "${ERR} $1" >&2
}

# Display detailed debugging information (only in debug mode)
log_debug() {
  if [ "$DEBUG" -eq 1 ]; then
    echo -e "${DBG} $1"
  fi
}

# -----------------------------
# Command Execution Functions
# -----------------------------

# Executes routine commands with suppressed output unless in debug mode
run_quiet() {
  if [ "$DEBUG" -eq 1 ]; then
    "$@"
  else
    "$@" >/dev/null 2>&1
  fi
}

# Executes sensitive commands without displaying outputs, ensuring secrets remain hidden
run_sensitive() {
  if [ "$DEBUG" -eq 1 ]; then
    "$@"
  else
    "$@" >/dev/null 2>&1
  fi
}

# Executes commands with full outputs only in debug mode
run_debug() {
  if [ "$DEBUG" -eq 1 ]; then
    "$@"
  else
    "$@" >/dev/null 2>&1
  fi
}

# -----------------------------
# Variables Configuration
# -----------------------------

# Namespaces
namespace="hbr-keycloak"
certmgr_ns="cert-manager"
sealed_secrets_ns="sealed-secrets"

# Deployment and Service Name for Sealed Secrets Controller
sealed_secrets_deployment="sealed-secrets"
sealed_secrets_service="sealed-secrets"

# Admin Passwords (Set via environment variables for security)
kc_admin_pwd="${KEYCLOAK_ADMIN_PWD:-password}"   # Default to 'password' if not set

# Helm Values Files
kc_values="keycloak-values.yaml"
pg_values="postgresql-values.yaml"
sealed_secrets_values="sealed-secrets-values.yaml"

# Readiness Parameters
readiness_timeout=300    # Total timeout in seconds
readiness_interval=10    # Interval between checks in seconds

# -----------------------------
# Utility Functions
# -----------------------------

# Function to check if a namespace exists
namespace_exists() {
    kubectl get namespace "$1" >/dev/null 2>&1
}

# Function to wait for a Secret to exist
wait_for_secret() {
    local secret_name="$1"
    local namespace="$2"
    local timeout=60
    local interval=5
    local elapsed=0

    while [ $elapsed -lt $timeout ]; do
        if kubectl get secret "$secret_name" -n "$namespace" >/dev/null 2>&1; then
            log_info "Secret '$secret_name' in namespace '$namespace' is available."
            return 0
        fi
        echo "Waiting for secret '$secret_name' in namespace '$namespace'..."
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    log_error "Secret '$secret_name' not found in namespace '$namespace' after $timeout seconds."
    return 1
}

# Function to wait for a pod with a specific selector to be ready
wait_for_pods() {
    local namespace="$1"
    local selector="$2"
    local component="$3"

    echo -n "${WAI} Waiting for $component pods to be ready..."
    if ! kubectl wait --namespace "$namespace" \
       --for=condition=ready pod \
       --selector="$selector" \
       --timeout=300s; then
        log_warn "Failed to wait for $component pods to be ready within the timeout."
        log_warn "Proceeding with the deployment of other components."
    else
        echo "${INF} OK"
    fi
}

# -----------------------------
# Core Functions
# -----------------------------

# Function to install Sealed Secrets Controller via Helm
install_sealed_secrets_via_helm() {
    log_info "Installing Sealed Secrets Controller via Helm"
    run_quiet helm install sealed-secrets oci://registry-1.docker.io/bitnamicharts/sealed-secrets \
      -f "${sealed_secrets_values}" \
      --namespace "$sealed_secrets_ns" \
      --create-namespace \
      --wait \
      --timeout "${readiness_timeout}s"

    log_info "Sealed Secrets Controller installed via Helm."
}

# Function to install Sealed Secrets Controller via YAML (Alternative Method)
install_sealed_secrets_via_yaml() {
    log_info "Installing Sealed Secrets Controller via YAML"
    run_quiet kubectl apply -f "$sealed_secrets_controller_yaml"

    log_info "Waiting for Sealed Secrets Controller to be ready..."

    local elapsed=0
    while [ $elapsed -lt $readiness_timeout ]; do
        # Fetch the number of ready replicas
        ready_replicas=$(kubectl get deployment "$sealed_secrets_deployment" -n "$sealed_secrets_ns" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
        desired_replicas=$(kubectl get deployment "$sealed_secrets_deployment" -n "$sealed_secrets_ns" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 1)

        if [ "$ready_replicas" -ge "$desired_replicas" ]; then
            log_info "Sealed Secrets Controller is ready."
            return 0
        fi

        echo "Sealed Secrets Controller not ready yet. ($ready_replicas/$desired_replicas)"
        sleep "$readiness_interval"
        elapsed=$((elapsed + readiness_interval))
    done

    log_error "Sealed Secrets Controller deployment '$sealed_secrets_deployment' in namespace '$sealed_secrets_ns' did not become ready within $readiness_timeout seconds."
    log_info "Current deployment status:"
    run_quiet kubectl get deployment "$sealed_secrets_deployment" -n "$sealed_secrets_ns" || true
    log_info "Current pod statuses:"
    run_quiet kubectl get pods -n "$sealed_secrets_ns" -l app.kubernetes.io/name=sealed-secrets || true
    exit 1
}

# Function to install Sealed Secrets Controller (Choose Method)
install_sealed_secrets() {
    # Choose installation method: Helm or YAML
    # Uncomment the preferred method and comment out the other

    # Method 1: Install via Helm (Recommended)
    install_sealed_secrets_via_helm

    # Method 2: Install via YAML
    # install_sealed_secrets_via_yaml
}

# Function to create a Sealed Secret
create_sealed_secret() {
    local secret_name="$1"
    local secret_namespace="$2"
    local secret_file="$3"

    log_info "Creating Sealed Secret for '$secret_name'"

    # Ensure the Sealed Secrets Controller is ready
    if ! namespace_exists "$sealed_secrets_ns" || ! kubectl get deployment "$sealed_secrets_deployment" -n "$sealed_secrets_ns" >/dev/null 2>&1; then
        log_info "Sealed Secrets Controller is not deployed yet. Installing..."
        install_sealed_secrets
    fi

    # Display Secret YAML in debug mode only
    if [ "$DEBUG" -eq 1 ]; then
        log_debug "=== $secret_file ==="
        cat "$secret_file"
        log_debug "=== End of $secret_file ==="
    fi

    # Generate Sealed Secret using a pipeline
    # In debug mode, display the outputs
    # In non-debug mode, suppress stderr but allow the pipeline to function correctly
    if [ "$DEBUG" -eq 1 ]; then
        kubectl create -f "$secret_file" --dry-run=client -o json | \
        kubeseal --controller-name "$sealed_secrets_service" --controller-namespace "$sealed_secrets_ns" --format=yaml > "${secret_file}.sealed.yaml"
    else
        kubectl create -f "$secret_file" --dry-run=client -o json 2>/dev/null | \
        kubeseal --controller-name "$sealed_secrets_service" --controller-namespace "$sealed_secrets_ns" --format=yaml > "${secret_file}.sealed.yaml" 2>/dev/null
    fi

    log_info "Applying Sealed Secret '$secret_name'"
    run_quiet kubectl apply -f "${secret_file}.sealed.yaml"

    # Wait for the underlying Secret to be created
    wait_for_secret "$secret_name" "$secret_namespace"

    # Verify Secret Data in debug mode only
    if [ "$DEBUG" -eq 1 ]; then
        log_debug "Verifying Secret '$secret_name' in namespace '$secret_namespace'"
        kubectl get secret "$secret_name" -n "$secret_namespace" -o yaml
    fi

    # Clean up temporary sealed secret file
    rm -f "${secret_file}.sealed.yaml"
}

# -----------------------------
# Main Deployment Steps
# -----------------------------

log_info "Starting Keycloak and PostgreSQL-HA deployment..."

# Cleanup existing namespaces if they exist
if namespace_exists "$namespace"; then
    log_info "Namespace '$namespace' exists. Deleting..."
    run_quiet kubectl delete namespace "$namespace"
fi

if namespace_exists "$certmgr_ns"; then
    log_info "Namespace '$certmgr_ns' exists. Deleting..."
    run_quiet kubectl delete namespace "$certmgr_ns"
fi

# Create necessary namespaces
log_info "Creating namespace '$namespace'"
run_quiet kubectl create namespace "$namespace"

log_info "Creating namespace '$sealed_secrets_ns'"
run_quiet kubectl create namespace "$sealed_secrets_ns"

# Install Sealed Secrets Controller if not present
if ! namespace_exists "$sealed_secrets_ns" || ! kubectl get deployment "$sealed_secrets_deployment" -n "$sealed_secrets_ns" >/dev/null 2>&1; then
    install_sealed_secrets
else
    log_info "Sealed Secrets Controller already installed."
    log_info "Ensuring Sealed Secrets Controller is ready..."

    local elapsed=0
    while [ $elapsed -lt $readiness_timeout ]; do
        ready_replicas=$(kubectl get deployment "$sealed_secrets_deployment" -n "$sealed_secrets_ns" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
        desired_replicas=$(kubectl get deployment "$sealed_secrets_deployment" -n "$sealed_secrets_ns" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 1)

        if [ "$ready_replicas" -ge "$desired_replicas" ]; then
            log_info "Sealed Secrets Controller is ready."
            break
        fi

        echo "Sealed Secrets Controller not ready yet. ($ready_replicas/$desired_replicas)"
        sleep "$readiness_interval"
        elapsed=$((elapsed + readiness_interval))
    done

    if [ "$ready_replicas" -lt "$desired_replicas" ]; then
        log_error "Sealed Secrets Controller deployment '$sealed_secrets_deployment' in namespace '$sealed_secrets_ns' did not become ready within $readiness_timeout seconds."
        log_info "Current deployment status:"
        run_quiet kubectl get deployment "$sealed_secrets_deployment" -n "$sealed_secrets_ns" || true
        log_info "Current pod statuses:"
        run_quiet kubectl get pods -n "$sealed_secrets_ns" -l app.kubernetes.io/name=sealed-secrets || true
        exit 1
    fi
fi

# Add Bitnami Helm repo and update it
log_info "Adding Bitnami Helm repo and updating it"
run_quiet helm repo add bitnami https://charts.bitnami.com/bitnami
run_quiet helm repo update

# Generate Keycloak admin password
log_info "Generating Keycloak admin password"
KEYCLOAK_ADMIN_PASSWORD=$(echo -n "$kc_admin_pwd")

# Display Keycloak Admin Password in debug mode only
if [ "$DEBUG" -eq 1 ]; then
    log_debug "KEYCLOAK_ADMIN_PASSWORD: '$KEYCLOAK_ADMIN_PASSWORD'"
fi

# Create Keycloak admin Secret YAML
cat <<EOF > keycloak-admin-secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: keycloak-admin-password
  namespace: $namespace
type: Opaque
data:
  password: $(echo -n "$KEYCLOAK_ADMIN_PASSWORD" | base64)
EOF

# Create Sealed Secret for Keycloak admin password
create_sealed_secret "keycloak-admin-password" "$namespace" "keycloak-admin-secret.yaml"

# Generate PostgreSQL and PgPool passwords
log_info "Generating passwords and secrets for PostgreSQL, RepMgr, and PgPool admin"
POSTGRES_ADMIN_PASSWORD=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 16)
POSTGRES_USER_PASSWORD=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 16)
REPMGR_PASSWORD=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 16)
PGPOOL_ADMIN_PASSWORD=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 16)

# Display Generated Passwords in debug mode only
if [ "$DEBUG" -eq 1 ]; then
    log_debug "POSTGRES_ADMIN_PASSWORD: '$POSTGRES_ADMIN_PASSWORD'"
    log_debug "POSTGRES_USER_PASSWORD: '$POSTGRES_USER_PASSWORD'"
    log_debug "REPMGR_PASSWORD: '$REPMGR_PASSWORD'"
    log_debug "PGPOOL_ADMIN_PASSWORD: '$PGPOOL_ADMIN_PASSWORD'"
fi

# Create PostgreSQL Secret YAML
cat <<EOF > postgresql-secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: postgresql-secret
  namespace: $namespace
type: Opaque
data:
  password: $(echo -n "$POSTGRES_USER_PASSWORD" | base64)
  postgres-password: $(echo -n "$POSTGRES_ADMIN_PASSWORD" | base64)
  repmgr-password: $(echo -n "$REPMGR_PASSWORD" | base64)
EOF

# Create Sealed Secret for PostgreSQL
create_sealed_secret "postgresql-secret" "$namespace" "postgresql-secret.yaml"

# Create PgPool Secret YAML
cat <<EOF > pgpool-secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: pgpool-secret
  namespace: $namespace
type: Opaque
data:
  admin-password: $(echo -n "$PGPOOL_ADMIN_PASSWORD" | base64)
EOF

# Create Sealed Secret for PgPool
create_sealed_secret "pgpool-secret" "$namespace" "pgpool-secret.yaml"

# Deploy PostgreSQL with Helm using Sealed Secrets
log_info "Deploying PostgreSQL-HA with Helm and '$pg_values'"
run_quiet helm install postgresql-ha oci://registry-1.docker.io/bitnamicharts/postgresql-ha \
  --namespace "$namespace" \
  -f "$pg_values"

# Wait for PostgreSQL-HA pods to be ready
wait_for_pods "$namespace" "app.kubernetes.io/component=pgpool" "PostgreSQL-HA"

# Deploy Keycloak with Helm using Sealed Secrets
log_info "Deploying Keycloak with Helm and '$kc_values'"
run_quiet helm install keycloak oci://registry-1.docker.io/bitnamicharts/keycloak \
  --namespace "$namespace" \
  -f "$kc_values"

# Install Cert-Manager
log_info "Creating namespace '$certmgr_ns'"
run_quiet kubectl create namespace "$certmgr_ns"

log_info "Adding Jetstack Helm repo and updating it"
run_quiet helm repo add jetstack https://charts.jetstack.io
run_quiet helm repo update

log_info "Installing Cert-Manager CRDs"
certmgr_crds="https://github.com/cert-manager/cert-manager/releases/download/v1.11.1/cert-manager.crds.yaml"
run_quiet kubectl apply -f "$certmgr_crds"

log_info "Deploying Cert-Manager with Helm"
run_quiet helm install cert-manager jetstack/cert-manager \
  --namespace "$certmgr_ns" \
  --version v1.11.1

log_info "Applying ClusterIssuer"
run_quiet kubectl apply -f cluster-issuer-selfsigned.yaml \
  -n "$namespace"

log_info "Applying Self-Signed Certificate"
run_quiet kubectl apply -f selfsigned-certificate.yaml \
  -n "$namespace"

log_info "Deploying NGINX Ingress Controller with Cert-Manager Integration"
run_quiet kubectl apply -f keycloak-ingress-with-cert-manager.yaml \
  -n "$namespace"

# Wait for Keycloak pods to be ready
wait_for_pods "$namespace" "app.kubernetes.io/component=keycloak" "Keycloak"

log_info "Keycloak and PostgreSQL-HA are ready!"
