#!/usr/bin/env bash

set +x

echo -e "===========================================\n"
echo -e "Deploying Keycloak and PostgreSQL-HA to k8s\n"
echo -e "===========================================\n"

namespace="hbr-keycloak"
certmgr_ns="cert-manager"
kc_admin_pwd="password" # change it!

# values.yaml
kc_values="keycloak-values.yaml"
pg_values="postgresql-values.yaml"

# output
ADD="[ADD]		"
DEL="[DELETE]	"
GEN="[GENERATE]	"
DEP="[DEPLOY]	"
CRE="[CREATE]	"
WAI="[WAIT]		"

if kubectl get namespaces | grep -q "$namespace"; then
    echo -e "$DEL namespace $namespace\n"
    kubectl delete ns "$namespace"  >/dev/null 2>&1
fi

if kubectl get namespaces | grep -q "$certmgr_ns"; then
    echo -e "$DEL namespace $certmgr_ns\n"
    kubectl delete ns "$certmgr_ns" >/dev/null 2>&1
fi

echo -e "$CRE namespace $namespace\n"

kubectl create namespace "$namespace" >/dev/null 2>&1

echo -e "$ADD bitnami Helm repo and update it\n"

helm repo add bitnami https://charts.bitnami.com/bitnami  >/dev/null 2>&1
helm repo update  >/dev/null 2>&1

echo -e "$GEN Keycloak admin password and secret\n"

KEYCLOAK_ADMIN_PASSWORD=$(echo -n "$kc_admin_pwd")

kubectl create secret generic keycloak-admin-password \
  --from-literal=password=$KEYCLOAK_ADMIN_PASSWORD \
  -n hbr-keycloak  >/dev/null 2>&1

echo -e "$GEN passwords and secrets for PostgreSQL, RepMgr, and PgPool admin\n"

POSTGRES_ADMIN_PASSWORD=$(openssl rand -hex 16 | base64 | tr -d '\n')
POSTGRES_USER_PASSWORD=$(openssl rand -hex 16 | base64 | tr -d '\n')
REPMGR_PASSWORD=$(openssl rand -hex 16 | base64 | tr -d '\n')
PGPOOL_ADMIN_PASSWORD=$(openssl rand -hex 16 | base64 | tr -d '\n')

kubectl create secret generic postgresql-secret \
  --from-literal=password=$POSTGRES_USER_PASSWORD \
  --from-literal=postgres-password=$POSTGRES_ADMIN_PASSWORD \
  --from-literal=repmgr-password=$REPMGR_PASSWORD \
  -n hbr-keycloak  >/dev/null 2>&1

kubectl create secret generic pgpool-secret \
  --from-literal=admin-password=$PGPOOL_ADMIN_PASSWORD \
  -n hbr-keycloak  >/dev/null 2>&1

echo -e "$DEP PostgreSQL with Helm and $pg_values\n"

helm install postgresql-ha bitnami/postgresql-ha \
  --namespace hbr-keycloak \
  -f "$pg_values"  >/dev/null 2>&1

echo -n "$WAI PostgreSQL..."

kubectl wait --namespace "$namespace" \
   --for=condition=ready pod \
  --selector=app.kubernetes.io/component=pgpool \
  --timeout=90s  >/dev/null 2>&1

printf "OK\n"

echo -e "\n$DEP Keycloak with Helm and $kc_values\n"

helm install keycloak bitnami/keycloak \
  --namespace hbr-keycloak \
  -f "$kc_values"  >/dev/null 2>&1

echo -e "$CRE namespace $certmgr_ns\n"

kubectl create namespace "$certmgr_ns"  >/dev/null 2>&1

echo -e "$ADD jetstack Helm repo and update it\n"

helm repo add jetstack https://charts.jetstack.io  >/dev/null 2>&1
helm repo update  >/dev/null 2>&1

echo -e "$DEP CRDs for cert-manager\n"

certmgr_crds="https://github.com/cert-manager/cert-manager/releases/download/v1.11.1/cert-manager.crds.yaml"

kubectl apply -f "$certmgr_crds" >/dev/null 2>&1

echo -e "$DEP cert-manager\n"

helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --version v1.11.1 >/dev/null 2>&1

echo -e "$DEP ClusterIssuer into namespace $namespace\n"

kubectl apply -f cluster-issuer-selfsigned.yaml \
  -n "$namespace" >/dev/null 2>&1

echo -e "$DEP self-signed certificate into namespace $namespace\n"

kubectl apply -f selfsigned-certificate.yaml \
  -n "$namespace" >/dev/null 2>&1

echo -e "$DEP NGINX-Ingress\n"

kubectl apply -f keycloak-ingress-with-cert-manager.yaml \
  -n hbr-keycloak >/dev/null 2>&1

echo -n "$WAI Keycloak..."

kubectl wait --namespace "$namespace" \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=keycloak \
  --timeout=90s >/dev/null 2>&1

printf "OK\n"

echo -e "\nKeycloak and PostgreSQL-HA are ready!\n"

set -x
