#!/usr/bin/env bash
set -euo pipefail

NS="${1:-}"
[[ -z "$NS" ]] && { echo "Usage: $0 <namespace>"; exit 1; }

echo ">> Target namespace: $NS"

# Helper function to apply Kubernetes manifests
apply_manifest() {
  local title="$1"
  local manifest="$2"
  echo ">> $title"
  kubectl apply -f - <<< "$manifest"
}

# Create namespace
kubectl get ns "$NS" >/dev/null 2>&1 || {
  echo ">> Creating namespace $NS"
  kubectl create namespace "$NS"
}
echo ">> Namespace $NS already exists"

# ServiceAccount
apply_manifest "Creating ServiceAccount" "
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${NS}-user
  namespace: ${NS}
"

# Role
apply_manifest "Creating FULL-ACCESS Role (${NS}-scoped, all verbs/resources)" "
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${NS}-full-access
  namespace: ${NS}
rules:
- apiGroups: ['', '*']
  resources: ['*']
  verbs: ['*']
"

# RoleBinding
apply_manifest "Binding Role to the ServiceAccount" "
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${NS}-full-access-binding
  namespace: ${NS}
subjects:
- kind: ServiceAccount
  name: ${NS}-user
  namespace: ${NS}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: ${NS}-full-access
"

# Secret
apply_manifest "Creating a ServiceAccount token Secret" "
apiVersion: v1
kind: Secret
metadata:
  name: ${NS}-user-token
  namespace: ${NS}
  annotations:
    kubernetes.io/service-account.name: '${NS}-user'
type: kubernetes.io/service-account-token
"

# Wait for token
echo ">> Waiting for token to be populated in the Secret..."
for i in {1..30}; do
  TOKEN_B64="$(kubectl get secret ${NS}-user-token -n "$NS" -o jsonpath='{.data.token}' 2>/dev/null || true)"
  [[ -n "${TOKEN_B64}" ]] && break
  sleep 2
done

[[ -z "${TOKEN_B64:-}" ]] && { echo "ERROR: Token not populated"; exit 2; }

# Extract credentials
echo ">> Extracting token, CA and cluster details"
TOKEN="$(printf "%s" "$TOKEN_B64" | base64 -d 2>/dev/null || printf "%s" "$TOKEN_B64" | base64 -D)"
CA_CERT_B64="$(kubectl get secret ${NS}-user-token -n "$NS" -o jsonpath='{.data.ca\.crt}' | tr -d '\n\r ')"
CLUSTER_ENDPOINT="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
CLUSTER_NAME="$(kubectl config view --minify -o jsonpath='{.contexts[0].context.cluster}')"

# Generate kubeconfig
OUT="kubeconfig-${NS}.conf"
echo ">> Writing kubeconfig to ${OUT}"

printf 'apiVersion: v1\nkind: Config\npreferences: {}\nclusters:\n- name: %s\n  cluster:\n    server: %s\n    certificate-authority-data: %s\ncontexts:\n- name: %s-user-context\n  context:\n    cluster: %s\n    namespace: %s\n    user: %s-user\ncurrent-context: %s-user-context\nusers:\n- name: %s-user\n  user:\n    token: %s\n' \
  "${CLUSTER_NAME}" "${CLUSTER_ENDPOINT}" "${CA_CERT_B64}" \
  "${NS}" "${CLUSTER_NAME}" "${NS}" "${NS}" "${NS}" "${TOKEN}" > "${OUT}"

echo ">> Done."
echo "Kubeconfig: ${OUT}"
echo
echo "Sanity checks:"
echo "  KUBECONFIG=${OUT} kubectl auth can-i '*' '*' -n ${NS}      # expect 'yes'"
echo "  KUBECONFIG=${OUT} kubectl auth can-i list pods -n default  # expect 'no'"