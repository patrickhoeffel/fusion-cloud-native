#!/usr/bin/env bash

# This script helps you keep track of the parameters needed to upgrade a Fusion cluster in Kubernetes
# vs. having to remember all the --values parameters you need to pass
PROVIDER=gke
CLUSTER_NAME=lw-sales-eu
RELEASE=jgu
NAMESPACE=jgu
CHART_VERSION=5.1.0

MY_VALUES=""
MY_VALUES="$MY_VALUES --values gke_lw-sales-eu_jgu_fusion_values.yaml"
MY_VALUES="$MY_VALUES --values gke_lw-sales-eu_jgu_fusion_resources.yaml"



# TODO: append more --values <file> args here as needed for your installation
#MY_VALUES="${MY_VALUES} --values ${PROVIDER}_${CLUSTER_NAME}_${RELEASE}_fusion_affinity.yaml"

DRY_RUN=""
DRY_RUN_REQUESTED="${1:-}"

if [ ! -z "${DRY_RUN_REQUESTED}" ]; then
  DRY_RUN="--dry-run"
fi

current_context=$(kubectl config current-context | grep "$CLUSTER_NAME")
if [ "${current_context}" == "" ]; then
  echo -e "\nERROR: Current kubeconfig not pointing to the $CLUSTER_NAME cluster!\nPlease update your current config to the correct cluster for upgrading Fusion.\n"
  exit 1
fi

if ! kubectl get namespace "${NAMESPACE}" > /dev/null 2>&1; then
  kubectl create namespace "${NAMESPACE}"
  if [ "$PROVIDER" == "gke" ]; then
    who_am_i=$(gcloud auth list --filter=status:ACTIVE --format="value(account)")
  else
    who_am_i=""
  fi
  OWNER_LABEL="${who_am_i//@/-}"
  if [ "${OWNER_LABEL}" != "" ]; then
    kubectl label namespace "${NAMESPACE}" "owner=${OWNER_LABEL}"
  fi
  echo -e "\nCreated namespace ${NAMESPACE} with owner label ${OWNER_LABEL}\n"
fi

# Make sure that the lucidworks chart repository is present and updated
lw_helm_repo=lucidworks

if ! helm repo list | grep -q "https://charts.lucidworks.com"; then
  echo -e "\nAdding the Lucidworks chart repo to helm repo list"
  helm repo add ${lw_helm_repo} https://charts.lucidworks.com
fi

helm repo update

# Make sure that the metric server is running
metrics_deployment=$(kubectl get deployment -n kube-system | grep metrics-server | cut -d ' ' -f1 -)
kubectl rollout status deployment/${metrics_deployment} --timeout=60s --namespace "kube-system"
echo ""

echo -e "Upgrading the '$RELEASE' release (Fusion chart: $CHART_VERSION) in the '$NAMESPACE' namespace in the '$CLUSTER_NAME' cluster using values:\n    ${MY_VALUES//--values}"
echo -e "\nNOTE: If this will be a long-running cluster for production purposes, you should save the following file(s) in version control:\n${MY_VALUES//--values}\n"

helm upgrade ${DRY_RUN} ${RELEASE} "${lw_helm_repo}/fusion" --install --namespace "${NAMESPACE}" --version "${CHART_VERSION}" ${MY_VALUES}

echo -e "\nWaiting up to 10 minutes to see the Fusion API Gateway deployment come online ...\n"
kubectl rollout status deployment/${RELEASE}-api-gateway --timeout=600s --namespace "${NAMESPACE}"
echo -e "\nWaiting up to 2 minutes to see the Fusion Admin deployment come online ...\n"
kubectl rollout status deployment/${RELEASE}-fusion-admin --timeout=120s --namespace "${NAMESPACE}"

current_ns=$(kubectl config view --minify --output 'jsonpath={..namespace}')
if [ "$NAMESPACE" != "$current_ns" ]; then
  kubectl config set-context --current --namespace=${NAMESPACE}
fi
echo ""
helm ls
echo ""
