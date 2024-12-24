#!/usr/bin/env bash

# -----------------------------------------------------------------------------
# Script Name: deploy_all_sealed_secrets.sh
# Description: Automates the creation and application of SealedSecrets for
#              Keycloak Admin Password, PostgreSQL Secret, and PgPool Secret
#              in Kubernetes.
# Usage: ./deploy_all_sealed_secrets.sh [--keycloak-password <PASSWORD>] [--namespace <NAMESPACE>]
#        If --keycloak-password is not provided or is used without a value,
#        the default password "password" will be used.
#        If --namespace is not provided or is used without a value,
#        the default namespace "hbr-keycloak" will be used.
# -----------------------------------------------------------------------------

# Exit immediately if a command exits with a non-zero status,
# treat unset variables as an error, and ensure pipeline commands fail if any command fails.
set -euo pipefail

# -----------------------------
# Function Definitions
# -----------------------------

# Function to display usage instructions
usage() {
  echo "Usage: $0 [--keycloak-password <PASSWORD>] [--namespace <NAMESPACE>]"
  echo ""
  echo "Options:"
  echo "  --keycloak-password [PASSWORD]   Provide Keycloak admin password as an argument."
  echo "                                   If PASSWORD is not provided, defaults to 'password'."
  echo "  --namespace [NAMESPACE]           Specify the Kubernetes namespace."
  echo "                                   If NAMESPACE is not provided, defaults to 'hbr-keycloak'."
  echo "  -h, --help                       Display this help message."
  exit 1
}

# Function to check for required commands
check_dependencies() {
  local dependencies=(kubectl kubeseal openssl base64)
  for cmd in "${dependencies[@]}"; do
    if ! command -v "$cmd" &>/dev/null; then
      echo "Error: '$cmd' command not found. Please install it before running this script."
      exit 1
    fi
  done
}

# Function to generate a random password
generate_password() {
  # Generates a 16-character alphanumeric password
  openssl rand -base64 12 | tr -dc 'a-zA-Z0-9' | head -c 16
}

# Function to create and seal a secret
# Arguments:
#   $1 - Secret Name
#   $2 - Namespace
#   $3 - Output Directory
#   $4... - Literal Key=Value pairs (e.g., --from-literal=key=value)
create_sealed_secret() {
  local secret_name="$1"
  local namespace="$2"
  local output_dir="$3"
  shift 3
  local literals=("$@")
  local output_file="$output_dir/${secret_name}.json"

  echo "Creating and sealing secret: $secret_name"

  # Create the Kubernetes Secret and seal it
  kubectl create secret generic "$secret_name" "${literals[@]}" \
    --namespace "$namespace" --dry-run=client -o json | \
  kubeseal --controller-name="sealed-secrets" --controller-namespace="sealed-secrets" -o json > "$output_file"

  echo "SealedSecret saved to: $output_file"
}

# -----------------------------
# Variable Initialization
# -----------------------------

# Default Values
default_namespace="hbr-keycloak"
namespace="$default_namespace"
sealed_secrets_dir="sealed-secrets"

# Default Keycloak password
default_keycloak_password="password"

# Initialize keycloak_password with default
keycloak_password="$default_keycloak_password"

# Initialize flags
create_namespace=false

# Ensure the sealed-secrets directory exists
mkdir -p "$sealed_secrets_dir"

# -----------------------------
# Parse Command-Line Arguments
# -----------------------------

while [[ "$#" -gt 0 ]]; do
  case $1 in
    --keycloak-password)
      # Check if the next argument exists and is not another flag
      if [[ -n "${2:-}" && ! "$2" =~ ^-- ]]; then
        keycloak_password="$2"
        shift 2
      else
        # No password provided; use default
        keycloak_password="$default_keycloak_password"
        shift 1
      fi
      ;;
    --namespace)
      # Check if the next argument exists and is not another flag
      if [[ -n "${2:-}" && ! "$2" =~ ^-- ]]; then
        namespace="$2"
        shift 2
      else
        # No namespace provided; use default
        namespace="$default_namespace"
        shift 1
      fi
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Unknown parameter passed: $1"
      usage
      ;;
  esac
done

# -----------------------------
# Main Execution Flow
# -----------------------------

# Check for required dependencies
check_dependencies

echo "Starting SealedSecrets generation and application..."

# Create SealedSecret for Keycloak Admin Password
create_sealed_secret \
  "keycloak-admin-password" \
  "$namespace" \
  "$sealed_secrets_dir" \
  "--from-literal=password=$keycloak_password"

# Create SealedSecret for PostgreSQL Secret
create_sealed_secret \
  "postgresql-secret" \
  "$namespace" \
  "$sealed_secrets_dir" \
  "--from-literal=password=$(generate_password)" \
  "--from-literal=postgres-password=$(generate_password)" \
  "--from-literal=repmgr-password=$(generate_password)"

# Create SealedSecret for PgPool Secret
create_sealed_secret \
  "pgpool-secret" \
  "$namespace" \
  "$sealed_secrets_dir" \
  "--from-literal=admin-password=$(generate_password)"

# Apply the SealedSecrets to the specified namespace
echo "Applying SealedSecrets to the namespace '$namespace'..."
kubectl apply -f "$sealed_secrets_dir/" -n "$namespace"

echo "All SealedSecrets have been successfully created and applied to the '$namespace' namespace."
echo "You can now reference these sealed secrets in your Helm chart's 'values.yaml'."

exit 0
