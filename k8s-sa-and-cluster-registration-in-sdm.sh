#!/usr/bin/env bash

# This script creates a service account in the Kubernetes cluster
# and registers the cluster in StrongDM as a k8s-service resource,
# ready for discovery.

# Before running this script,
# 1) Read the script and understand what it does.
# 2) Use kubectl to set the context to the cluster that you want to install in StrongDM.
# 3) Log in to StrongDM.
# 4) Set environment variables for NAMESPACE, SERVICE_ACCOUNT, and CLUSTER_RESOURCE_NAME if you want to use different values from these defaults.

NAMESPACE=${NAMESPACE:-"default"}
SERVICE_ACCOUNT=${SERVICE_ACCOUNT:-"cluster-service-account"}

set -e
CURRENT_CONTEXT=$(kubectl config current-context)
CURRENT_CLUSTER=$(kubectl config view -o jsonpath="{.contexts[?(@.name == \"${CURRENT_CONTEXT}\"})].context.cluster}")

DEFAULT_CLUSTER_RESOURCE_NAME=${CURRENT_CLUSTER//[^a-zA-Z0-9]/-}
CLUSTER_RESOURCE_NAME=${CLUSTER_RESOURCE_NAME:-"$DEFAULT_CLUSTER_RESOURCE_NAME"}

CURRENT_CLUSTER_ADDRESS=$(kubectl config view -o jsonpath="{.clusters[?(@.name == \"${CURRENT_CLUSTER}\"})].cluster.server}")

CURRENT_CLUSTER_HOSTNAME=$(echo "$CURRENT_CLUSTER_ADDRESS" | awk -F[/:] '{print $4}')
CURRENT_CLUSTER_PORT=$(echo "$CURRENT_CLUSTER_ADDRESS" | awk -F[/:] '{
  if (NF >= 5 && $5 != "") {
    print $5
  } else if ($1 == "https") {
    print 443
  } else if ($1 == "http") {
    print 80
  } else {
    print "error_port_unknown"
  }
}')



# Check if the cluster resource name is already in use.
if [[ -n $(sdm admin clusters list --filter "name:${CLUSTER_RESOURCE_NAME}" | tail +2) ]]; then
  echo "The cluster resource name ${CLUSTER_RESOURCE_NAME} is already in use in StrongDM."
  read -p "Delete the existing cluster resource and make a new one (y/n)? " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]
  then
      echo "Not deleting the existing resource. Exiting."
      exit 1
  fi
  sdm admin clusters delete "${CLUSTER_RESOURCE_NAME}" || true
fi

# Define multiline prompt to be used for confirmation.
PROMPT=$(cat <<END_OF_PROMPT

This script operates on the following cluster:
  - Context: ${CURRENT_CONTEXT}
  - Cluster: ${CURRENT_CLUSTER}
  - Cluster Address: ${CURRENT_CLUSTER_ADDRESS}
  - Cluster Hostname: ${CURRENT_CLUSTER_HOSTNAME}
  - Cluster Port: ${CURRENT_CLUSTER_PORT}

The following will be established in the cluster:
  - Namespace: ${NAMESPACE}
  - Service Account: ${SERVICE_ACCOUNT}
  - Cluster Role: ${SERVICE_ACCOUNT}-role with minimal permissions required for StrongDM discovery
  - Cluster Role Binding: ${SERVICE_ACCOUNT}-cluster-role-binding
  - Secret: ${SERVICE_ACCOUNT}-secret containing the long-lived API token for the service account.

 In StrongDM, the cluster will be registered as a new k8s-service resource named "${CLUSTER_RESOURCE_NAME}".

Proceed (y/n)?
END_OF_PROMPT
)

read -p "$PROMPT " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]
then
    echo "Exiting without making any changes."
    exit 1
fi

# Begin making changes.

# Establish the namespace.
kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${NAMESPACE}
EOF

# Establish service account.
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${SERVICE_ACCOUNT}
  namespace: ${NAMESPACE}
EOF

# Establish cluster role with the minimum set of permissions required to support discovery in StrongDM.
kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
   name: ${SERVICE_ACCOUNT}-role
rules:
  - apiGroups: [""]
    resources: ["namespaces", "serviceaccounts"]
    verbs: ["list", "get", "watch"]
  - apiGroups: ["rbac.authorization.k8s.io"]
    resources: ["roles", "rolebindings", "clusterroles", "clusterrolebindings"]
    verbs: ["list", "get", "watch"]
EOF

# Establish cluster role binding
kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${SERVICE_ACCOUNT}-cluster-role-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: ${SERVICE_ACCOUNT}-role
subjects:
- kind: ServiceAccount
  name: ${SERVICE_ACCOUNT}
  namespace: ${NAMESPACE}
EOF

# Establish long-lived api token for the service account
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${SERVICE_ACCOUNT}-secret
  namespace: ${NAMESPACE}
  annotations:
    kubernetes.io/service-account.name: ${SERVICE_ACCOUNT}
type: kubernetes.io/service-account-token
EOF

SERVICE_ACCOUNT_TOKEN=$(kubectl get secret --namespace "${NAMESPACE}" "${SERVICE_ACCOUNT}-secret" -o "jsonpath={.data['token']}" | base64 -d)

# Verify that the token works as expected for a StrongDM healthcheck.
TOKEN_TEST_STATUS=$(curl -k -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer $SERVICE_ACCOUNT_TOKEN" \
  -H "Content-Type: application/json" \
  -X GET \
  "${CURRENT_CLUSTER_ADDRESS}/api/v1/namespaces")
if [ "$TOKEN_TEST_STATUS" -eq 200 ]; then
  echo "The token works for listing namespaces!"
else
  echo "The token does not work. HTTP response code: $TOKEN_TEST_STATUS"
  curl -k  \
    -H "Authorization: Bearer $SERVICE_ACCOUNT_TOKEN" \
    -H "Content-Type: application/json" \
    -X GET \
    "${CURRENT_CLUSTER_ADDRESS}/api/v1/namespaces"
  exit 1
fi

sdm admin clusters add k8s-service \
  --api-token "${SERVICE_ACCOUNT_TOKEN}" \
  --hostname "${CURRENT_CLUSTER_HOSTNAME}" \
  --port "${CURRENT_CLUSTER_PORT}" \
  --healthcheck-namespace "${NAMESPACE}" \
  "${CLUSTER_RESOURCE_NAME}"

echo "New cluster resource created in StrongDM."
sdm admin clusters list --filter "name:${CLUSTER_RESOURCE_NAME}"
