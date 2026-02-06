#!/usr/bin/env bash
set -euo pipefail

NS="${1:-}"
if [[ -z "$NS" ]]; then
  echo "Usage: $0 <namespace>"
  exit 1
fi

echo ">> Target namespace: $NS"

# Ensure namespace exists
if ! kubectl get ns "$NS" >/dev/null 2>&1; then
  echo ">> Creating namespace $NS"
  kubectl create namespace "$NS"
else
  echo ">> Namespace $NS already exists"
fi

echo ">> Creating ServiceAccount"
cat <<EOL | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${NS}-user
  namespace: ${NS}
EOL

echo ">> Creating FULL-ACCESS Role (${NS}-scoped, all verbs/resources)"
cat <<EOL | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${NS}-full-access
  namespace: ${NS}
rules:
- apiGroups:
  - ""          # core
  - "*"         # any other API group
  resources:
  - "*"         # all namespaced resources
  verbs:
  - "*"         # all verbs
EOL

echo ">> Binding Role to the ServiceAccount"
cat <<EOL | kubectl apply -f -
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
EOL

echo ">> Creating a ServiceAccount token Secret (controller will populate fields)"
cat <<EOL | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: ${NS}-user-token
  namespace: ${NS}
  annotations:
    kubernetes.io/service-account.name: "${NS}-user"
type: kubernetes.io/service-account-token
EOL

echo ">> Waiting for token to be populated in the Secret..."
for i in {1..30}; do
  TOKEN_B64="$(kubectl get secret ${NS}-user-token -n "$NS" -o jsonpath='{.data.token}' 2>/dev/null || true)"
  if [[ -n "${TOKEN_B64}" ]]; then
    break
  fi
  sleep 2
done

if [[ -z "${TOKEN_B64:-}" ]]; then
  echo "ERROR: Token not populated in Secret '${NS}-user-token' in namespace '$NS'."
  exit 2
fi

echo ">> Extracting token, CA and cluster details"
# Decode token
if command -v base64 >/dev/null 2>&1; then
  TOKEN="$(printf "%s" "$TOKEN_B64" | base64 -d 2>/dev/null || printf "%s" "$TOKEN_B64" | base64 -D)"
else
  echo "ERROR: base64 command not found."
  exit 3
fi
CA_CERT_B64="$(kubectl get secret ${NS}-user-token -n "$NS" -o jsonpath='{.data.ca\.crt}')"
CLUSTER_ENDPOINT="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
CLUSTER_NAME="$(kubectl config view --minify -o jsonpath='{.contexts[0].context.cluster}')"

OUT="kubeconfig-${NS}.conf"
echo ">> Writing kubeconfig to ${OUT}"

cat > "${OUT}" <<EOF
apiVersion: v1
kind: Config
preferences: {}
clusters:
- name: ${CLUSTER_NAME}
  cluster:
    server: ${CLUSTER_ENDPOINT}
    certificate-authority-data: ${CA_CERT_B64}
contexts:
- name: ${NS}-user-context
  context:
    cluster: ${CLUSTER_NAME}
    namespace: ${NS}
    user: ${NS}-user
current-context: ${NS}-user-context
users:
- name: ${NS}-user
  user:
    token: ${TOKEN}
EOF

echo ">> Done."
echo "Kubeconfig: ${OUT}"

echo
echo "Sanity checks:"
echo "  KUBECONFIG=${OUT} kubectl auth can-i '*' '*' -n ${NS}      # expect 'yes'"
echo "  KUBECONFIG=${OUT} kubectl auth can-i list pods -n default  # expect 'no'"
