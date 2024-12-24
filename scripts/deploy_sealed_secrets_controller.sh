#!/usr/bin/env bash

# -----------------------------------------------------------------------------
# Script Name: deploy_sealed_secrets_controller.sh
# Description: Deploys the Sealed Secrets controller on Kubernetes using Helm.
#              Utilizes the 'sealed-secrets' namespace and Bitnami's Helm chart.
# Usage: ./deploy_sealed_secrets_controller.sh
# -----------------------------------------------------------------------------

# Exit immediately if a command exits with a non-zero status,
# treat unset variables as an error, and ensure pipeline commands fail if any command fails.
set -euo pipefail

# -----------------------------
# Function Definitions
# -----------------------------

# Function to display usage instructions
usage() {
  echo "Usage: $0"
  echo ""
  echo "This script deploys the Sealed Secrets controller on Kubernetes using Helm."
  echo "It uses the 'sealed-secrets' namespace and the Bitnami Sealed Secrets Helm chart."
  echo ""
  echo "Ensure that Helm is installed and configured to communicate with your Kubernetes cluster."
  echo "The Sealed Secrets controller must be installed before generating or using SealedSecrets."
  echo ""
  exit 1
}

# Function to check if Helm is installed
check_helm_installed() {
  if ! command -v helm &>/dev/null; then
    echo "Error: Helm is not installed. Please install Helm before running this script."
    echo "Visit https://helm.sh/docs/intro/install/ for installation instructions."
    exit 1
  fi

  # Check Helm version (ensure Helm 3+)
  helm_version=$(helm version --short | awk -F '+' '{print $1}')
  helm_major_version=$(echo "$helm_version" | awk -F '.' '{print $1}' | tr -d 'v')

  if [[ "$helm_major_version" -lt 3 ]]; then
    echo "Error: Helm version 3 or higher is required. Detected version: $helm_version"
    exit 1
  fi
}

# Function to add Bitnami repository if not already added
add_bitnami_repo() {
  if helm repo list | grep -q 'bitnami'; then
    echo "Helm repository 'bitnami' already exists. Skipping addition."
  else
    echo "Adding Bitnami Helm repository..."
    helm repo add bitnami https://charts.bitnami.com/bitnami
  fi
}

# Function to update Helm repositories
update_helm_repos() {
  echo "Updating Helm repositories..."
  helm repo update
}

# Function to create namespace if it doesn't exist
create_namespace() {
  local namespace="$1"
  if kubectl get namespace "$namespace" &>/dev/null; then
    echo "Namespace '$namespace' already exists. Skipping creation."
  else
    echo "Creating namespace '$namespace'..."
    kubectl create namespace "$namespace"
  fi
}

# Function to deploy or upgrade Sealed Secrets controller
deploy_sealed_secrets() {
  local release_name="sealed-secrets"
  local chart_name="oci://registry-1.docker.io/bitnamicharts/sealed-secrets"
  local namespace="sealed-secrets"

  echo "Deploying Sealed Secrets controller..."

  # Check if the release already exists
  if helm ls --namespace "$namespace" | grep -q "^$release_name\s"; then
    echo "Helm release '$release_name' already exists. Upgrading..."
    helm upgrade "$release_name" "$chart_name" --namespace "$namespace" --reuse-values
  else
    echo "Installing Helm release '$release_name'..."
    helm install "$release_name" "$chart_name" --namespace "$namespace" --create-namespace
  fi

  echo "Waiting for Sealed Secrets controller to be ready..."
  kubectl rollout status deployment/"$release_name"-controller --namespace "$namespace"
}

# -----------------------------
# Main Execution Flow
# -----------------------------

# Check if help is requested
if [[ "$#" -gt 0 && ("$1" == "-h" || "$1" == "--help") ]]; then
  usage
fi

# Check Helm installation and version
check_helm_installed

# Add Bitnami repository
add_bitnami_repo

# Update Helm repositories
update_helm_repos

# Define the Sealed Secrets namespace
sealed_secrets_namespace="sealed-secrets"

# Create the namespace if not exists
create_namespace "$sealed_secrets_namespace"

# Deploy or upgrade Sealed Secrets controller
deploy_sealed_secrets

echo "Sealed Secrets controller deployment completed successfully."
exit 0
