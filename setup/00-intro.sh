#!/bin/sh
set -e

# Check if running in interactive mode (has TTY)
if [ -t 0 ]; then
    INTERACTIVE=true
else
    INTERACTIVE=false
    echo "Running in non-interactive mode. Set environment variables to configure."
fi

if [ "$INTERACTIVE" = true ]; then
    gum style \
        --foreground 212 --border-foreground 212 --border double \
        --margin "1 2" --padding "2 4" \
        'Setup for the Introduction chapter'

    gum confirm '
Are you ready to start?
Select "Yes" only if you did NOT follow the story from the start (if you jumped straight into this chapter).
Feel free to say "No" and inspect the script if you prefer setting up resources manually.
' || exit 0
else
    echo "=== Setup for the Introduction chapter ==="
    echo "Proceeding with automated setup..."
fi

TOOLS_INFO="
## You will need following tools installed:
|Name            |Required             |More info                                          |
|----------------|---------------------|---------------------------------------------------|
|Linux Shell     |Yes                  |Use WSL if you are running Windows                 |
|Docker          |Yes                  |'https://docs.docker.com/engine/install'           |
|kind CLI        |Yes                  |'https://kind.sigs.k8s.io/docs/user/quick-start/#installation'|
|kubectl CLI     |Yes                  |'https://kubernetes.io/docs/tasks/tools/#kubectl'  |
|crossplane CLI  |Yes                  |'https://docs.crossplane.io/latest/cli'            |
|yq CLI          |Yes                  |'https://github.com/mikefarah/yq#install'          |
|Google Cloud account with admin permissions|If using Google Cloud|'https://cloud.google.com'|
|Google Cloud CLI|If using Google Cloud|'https://cloud.google.com/sdk/docs/install'        |
|AWS account with admin permissions|If using AWS|'https://aws.amazon.com'                  |
|AWS CLI         |If using AWS         |'https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html'|
|Azure account with admin permissions|If using Azure|'https://azure.microsoft.com'         |
|az CLI          |If using Azure       |'https://learn.microsoft.com/cli/azure/install-azure-cli'|

If you are running this script from **Nix shell**, most of the requirements are already set with the exception of **Docker** and the **hyperscaler account**.
"

if [ "$INTERACTIVE" = true ]; then
    echo "$TOOLS_INFO" | gum format
    gum confirm "
Do you have those tools installed?
" || exit 0
else
    echo "$TOOLS_INFO"
    echo "Assuming tools are installed..."
fi

rm -f .env

#########################
# Control Plane Cluster #
#########################

# Check if kind cluster already exists
if kind get clusters 2>/dev/null | grep -q "^kind$"; then
    echo "Kind cluster 'kind' already exists. Deleting it..."
    kind delete cluster --name kind
fi

kind create cluster --config kind.yaml

kubectl apply \
    --filename https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

##############
# Crossplane #
##############

helm upgrade --install crossplane crossplane \
    --repo https://charts.crossplane.io/stable \
    --namespace crossplane-system --create-namespace --wait

kubectl apply \
    --filename providers/provider-kubernetes-incluster.yaml

kubectl apply --filename providers/provider-helm-incluster.yaml

kubectl apply --filename providers/dot-kubernetes.yaml

kubectl apply --filename providers/dot-sql.yaml

kubectl apply --filename providers/dot-app.yaml

if [ "$INTERACTIVE" = true ]; then
    gum spin --spinner dot \
        --title "Waiting for Crossplane providers..." -- sleep 60
else
    echo "Waiting 60 seconds for Crossplane providers..."
    sleep 60
fi

# Wait for base providers only (kubernetes and helm)
# Cloud providers need credentials which are configured later
echo "Waiting for base providers (kubernetes and helm) to become healthy..."
echo "Note: Cloud providers will become healthy after credentials are configured"

BASE_PROVIDERS="crossplane-contrib-provider-kubernetes crossplane-provider-helm"
MAX_WAIT_TIME=600  # 10 minutes for base providers
ELAPSED=0
CHECK_INTERVAL=10

while [ $ELAPSED -lt $MAX_WAIT_TIME ]; do
    echo "Checking base providers (elapsed: ${ELAPSED}s / ${MAX_WAIT_TIME}s)..."

    ALL_BASE_HEALTHY=true

    for provider_name in $BASE_PROVIDERS; do
        # Check if provider exists and is healthy
        if kubectl get provider $provider_name &>/dev/null; then
            HEALTHY=$(kubectl get provider $provider_name -o jsonpath='{.status.conditions[?(@.type=="Healthy")].status}' 2>/dev/null || echo "Unknown")
            INSTALLED=$(kubectl get provider $provider_name -o jsonpath='{.status.conditions[?(@.type=="Installed")].status}' 2>/dev/null || echo "Unknown")

            if [ "$HEALTHY" = "True" ] && [ "$INSTALLED" = "True" ]; then
                echo "  ✓ $provider_name is healthy"
            else
                echo "  ⏳ $provider_name - Healthy: $HEALTHY, Installed: $INSTALLED"
                ALL_BASE_HEALTHY=false
            fi
        else
            echo "  ⏳ $provider_name - Not found yet"
            ALL_BASE_HEALTHY=false
        fi
    done

    if [ "$ALL_BASE_HEALTHY" = true ]; then
        echo "All base providers are healthy!"
        break
    fi

    if [ $ELAPSED -ge $MAX_WAIT_TIME ]; then
        echo "ERROR: Base providers did not become healthy within $MAX_WAIT_TIME seconds"
        echo "Current provider status:"
        kubectl get providers
        exit 1
    fi

    sleep $CHECK_INTERVAL
    ELAPSED=$((ELAPSED + CHECK_INTERVAL))
done

if [ "$INTERACTIVE" = true ]; then
    echo "## Which Hyperscaler do you want to use?" | gum format
    HYPERSCALER=$(gum choose "google" "aws" "azure")
else
    if [ -z "$HYPERSCALER" ]; then
        echo "ERROR: HYPERSCALER environment variable must be set (google, aws, or azure)"
        exit 1
    fi
    echo "Using hyperscaler: $HYPERSCALER"
fi

echo "export HYPERSCALER=$HYPERSCALER" >> .env

if [[ "$HYPERSCALER" == "google" ]]; then

    if [ "$INTERACTIVE" = true ]; then
        gcloud auth login
    else
        echo "Skipping gcloud auth login in non-interactive mode. Ensure you're already authenticated."
    fi

    if [ -z "$PROJECT_ID" ]; then
        PROJECT_ID=dot-$(date +%Y%m%d%H%M%S)
    fi

    echo "export PROJECT_ID=$PROJECT_ID" >> .env

    gcloud projects create ${PROJECT_ID}

    if [ "$INTERACTIVE" = true ]; then
        echo "## Open https://console.cloud.google.com/billing/linkedaccount?project=$PROJECT_ID and link a billing account" \
            | gum format
        gum input --placeholder "Press the enter key to continue."

        echo "## Open https://console.cloud.google.com/marketplace/product/google/container.googleapis.com?project=$PROJECT_ID and *ENABLE* the API" \
            | gum format
        gum input --placeholder "Press the enter key to continue."

        echo "## Open https://console.cloud.google.com/apis/library/sqladmin.googleapis.com?project=$PROJECT_ID and *ENABLE* the API" \
            | gum format
        gum input --placeholder "Press the enter key to continue."
    else
        echo "In non-interactive mode. Ensure billing is linked and APIs are enabled:"
        echo "  1. Billing: https://console.cloud.google.com/billing/linkedaccount?project=$PROJECT_ID"
        echo "  2. Container API: https://console.cloud.google.com/marketplace/product/google/container.googleapis.com?project=$PROJECT_ID"
        echo "  3. SQL Admin API: https://console.cloud.google.com/apis/library/sqladmin.googleapis.com?project=$PROJECT_ID"
        sleep 5
    fi

    export SA_NAME=devops-toolkit

    export SA="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

    gcloud iam service-accounts create $SA_NAME \
        --project $PROJECT_ID

    export ROLE=roles/admin

    gcloud projects add-iam-policy-binding \
        --role $ROLE $PROJECT_ID --member serviceAccount:$SA

    gcloud iam service-accounts keys create gcp-creds.json \
        --project $PROJECT_ID --iam-account $SA

    kubectl --namespace crossplane-system \
        create secret generic gcp-creds \
        --from-file creds=./gcp-creds.json

    echo "
apiVersion: gcp.upbound.io/v1beta1
kind: ProviderConfig
metadata:
  name: default
spec:
  projectID: $PROJECT_ID
  credentials:
    source: Secret
    secretRef:
      namespace: crossplane-system
      name: gcp-creds
      key: creds" | kubectl apply --filename -

elif [[ "$HYPERSCALER" == "aws" ]]; then

    if [ "$INTERACTIVE" = true ]; then
        AWS_ACCESS_KEY_ID=$(gum input --placeholder "AWS Access Key ID" --value "$AWS_ACCESS_KEY_ID")
        echo "export AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID" >> .env

        AWS_SECRET_ACCESS_KEY=$(gum input --placeholder "AWS Secret Access Key" --value "$AWS_SECRET_ACCESS_KEY" --password)
        echo "export AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY" >> .env

        AWS_ACCOUNT_ID=$(gum input --placeholder "AWS Account ID" --value "$AWS_ACCOUNT_ID")
        echo "export AWS_ACCOUNT_ID=$AWS_ACCOUNT_ID" >> .env
    else
        if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ] || [ -z "$AWS_ACCOUNT_ID" ]; then
            echo "ERROR: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, and AWS_ACCOUNT_ID environment variables must be set"
            exit 1
        fi
        echo "export AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID" >> .env
        echo "export AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY" >> .env
        echo "export AWS_ACCOUNT_ID=$AWS_ACCOUNT_ID" >> .env
        echo "Using AWS credentials from environment variables"
    fi

    echo "[default]
aws_access_key_id = $AWS_ACCESS_KEY_ID
aws_secret_access_key = $AWS_SECRET_ACCESS_KEY
" >aws-creds.conf

    kubectl --namespace crossplane-system \
        create secret generic aws-creds \
        --from-file creds=./aws-creds.conf

    kubectl apply --filename providers/aws-config.yaml

else

    if [ "$INTERACTIVE" = true ]; then
        AZURE_TENANT_ID=$(gum input --placeholder "Azure Tenant ID" --value "$AZURE_TENANT_ID")
        az login --tenant $AZURE_TENANT_ID
    else
        if [ -z "$AZURE_TENANT_ID" ]; then
            echo "ERROR: AZURE_TENANT_ID environment variable must be set"
            exit 1
        fi
        echo "Skipping az login in non-interactive mode. Ensure you're already authenticated."
    fi

    export SUBSCRIPTION_ID=$(az account show --query id -o tsv)

    az ad sp create-for-rbac --sdk-auth --role Owner --scopes /subscriptions/$SUBSCRIPTION_ID | tee azure-creds.json

    kubectl --namespace crossplane-system create secret generic azure-creds --from-file creds=./azure-creds.json

    kubectl apply --filename providers/azure-config.yaml

    DB_NAME=silly-demo-db-$(date +%Y%m%d%H%M%S)

    echo "---
apiVersion: devopstoolkitseries.com/v1alpha1
kind: ClusterClaim
metadata:
  name: cluster-01
spec:
  id: cluster01
  compositionSelector:
    matchLabels:
      provider: azure
      cluster: aks
  parameters:
    nodeSize: small
    minNodeCount: 3
---
apiVersion: v1
kind: Secret
metadata:
  name: $DB_NAME-password
data:
  password: SVdpbGxOZXZlclRlbGxAMQ==
---
apiVersion: devopstoolkitseries.com/v1alpha1
kind: SQLClaim
metadata:
  name: silly-demo-db
spec:
  id: $DB_NAME
  compositionSelector:
    matchLabels:
      provider: azure
      db: postgresql
  parameters:
    version: \"11\"
    size: small
---
apiVersion: devopstoolkitseries.com/v1alpha1
kind: AppClaim
metadata:
  name: silly-demo
spec:
  id: silly-demo
  compositionSelector:
    matchLabels:
      type: backend-db
      location: remote
  parameters:
    namespace: production
    image: c8n.io/vfarcic/silly-demo:1.4.52
    port: 8080
    host: silly-demo.acme.com
    dbSecret:
      name: silly-demo-db
      namespace: a-team
    kubernetesProviderConfigName: cluster01" \
    | tee examples/azure-intro.yaml

fi

kubectl create namespace a-team

###########################################################################
# Wait for all providers to become healthy (now that credentials are set) #
###########################################################################

echo "Waiting for all cloud providers to become healthy now that credentials are configured..."
MAX_WAIT_TIME=900  # 15 minutes for all providers
ELAPSED=0
CHECK_INTERVAL=15

while [ $ELAPSED -lt $MAX_WAIT_TIME ]; do
    echo "Checking all providers (elapsed: ${ELAPSED}s / ${MAX_WAIT_TIME}s)..."

    ALL_HEALTHY=true
    PROVIDER_COUNT=0
    UNHEALTHY_COUNT=0

    # Get list of all providers
    PROVIDERS=$(kubectl get providers -o name 2>/dev/null || echo "")

    if [ -z "$PROVIDERS" ]; then
        echo "No providers found"
        ALL_HEALTHY=false
    else
        for provider in $PROVIDERS; do
            PROVIDER_COUNT=$((PROVIDER_COUNT + 1))
            PROVIDER_NAME=$(echo $provider | cut -d'/' -f2)

            HEALTHY=$(kubectl get $provider -o jsonpath='{.status.conditions[?(@.type=="Healthy")].status}' 2>/dev/null || echo "Unknown")
            INSTALLED=$(kubectl get $provider -o jsonpath='{.status.conditions[?(@.type=="Installed")].status}' 2>/dev/null || echo "Unknown")

            if [ "$HEALTHY" = "True" ] && [ "$INSTALLED" = "True" ]; then
                echo "  ✓ $PROVIDER_NAME"
            else
                echo "  ⏳ $PROVIDER_NAME - Healthy: $HEALTHY, Installed: $INSTALLED"
                UNHEALTHY_COUNT=$((UNHEALTHY_COUNT + 1))
                ALL_HEALTHY=false
            fi
        done
    fi

    echo "Summary: $((PROVIDER_COUNT - UNHEALTHY_COUNT))/$PROVIDER_COUNT providers healthy"

    if [ "$ALL_HEALTHY" = true ] && [ $PROVIDER_COUNT -gt 0 ]; then
        echo "All $PROVIDER_COUNT providers are healthy!"
        break
    fi

    if [ $ELAPSED -ge $MAX_WAIT_TIME ]; then
        echo "WARNING: Not all providers became healthy within $MAX_WAIT_TIME seconds"
        echo "Continuing anyway. You may need to debug unhealthy providers manually."
        kubectl get providers
        break
    fi

    sleep $CHECK_INTERVAL
    ELAPSED=$((ELAPSED + CHECK_INTERVAL))
done

###########
# Argo CD #
###########

REPO_URL=$(git config --get remote.origin.url)
# workaround to avoid setting up SSH key in ArgoCD
REPO_URL=$(echo $REPO_URL | sed 's/git@github.com:/https:\/\/github.com\//') # replace git@github.com: to https://github.com/

yq --inplace ".spec.source.repoURL = \"$REPO_URL\"" argocd/apps.yaml

helm upgrade --install argocd argo-cd \
    --repo https://argoproj.github.io/argo-helm \
    --namespace argocd --create-namespace \
    --values argocd/helm-values.yaml --wait

kubectl apply --filename argocd/apps.yaml
