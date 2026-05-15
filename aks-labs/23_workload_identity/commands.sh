# https://learn.microsoft.com/en-us/azure/aks/learn/tutorial-kubernetes-workload-identity

az extension add --name aks-preview
az extension update --name aks-preview

az extension update --name aks-preview
az feature register --namespace "Microsoft.ContainerService" --name "EnableWorkloadIdentityPreview"
az feature list -o table --query "[?contains(name, 'Microsoft.ContainerService/EnableWorkloadIdentityPreview')].{Name:name,State:properties.state}"
az provider register --namespace Microsoft.ContainerService
az feature register --namespace "Microsoft.ContainerService" --name "EnableOIDCIssuerPreview"
az feature list -o table --query "[?contains(name, 'Microsoft.ContainerService/EnableOIDCIssuerPreview')].{Name:name,State:properties.state}"
az provider register --namespace Microsoft.ContainerService

# environment variables for the Azure Key Vault resource
export AKS_NAME="aks-cluster"
export KEYVAULT_NAME="azwi-kv-demo-015"
export KEYVAULT_SECRET_NAME="my-secret"
export RESOURCE_GROUP="aks-wi-oidc"
export LOCATION="canadacentral"

# environment variables for the Kubernetes Service account & federated identity credential
export SERVICE_ACCOUNT_NAMESPACE="default"
export SERVICE_ACCOUNT_NAME="workload-identity-sa"

# environment variables for the Federated Identity
export SUBSCRIPTION="$(az account list --query "[?isDefault].id" -o tsv)"
echo $SUBSCRIPTION
# user assigned identity name
export UAID="fic-test-ua"
# federated identity name
export FICID="fic-test-fic-name"

# create resource group and AKS clsuter with OIDC and Workload Identity enabled
az group create --name ${RESOURCE_GROUP} --location ${LOCATION}

az aks create -g ${RESOURCE_GROUP} -n ${AKS_NAME} \
              --node-count 1 \
              --enable-oidc-issuer \
              --enable-workload-identity \
              --generate-ssh-keys

# get the OIDC Issuer URL
export AKS_OIDC_ISSUER="$(az aks show -n ${AKS_NAME} -g ${RESOURCE_GROUP} --query "oidcIssuerProfile.issuerUrl" -otsv)"
echo "${AKS_OIDC_ISSUER}"

# create keyvault and secret
az keyvault create --resource-group ${RESOURCE_GROUP} --location ${LOCATION} --name ${KEYVAULT_NAME}

# get your current user's object ID
export CURRENT_USER_OID="$(az ad signed-in-user show --query id -o tsv)"
echo $CURRENT_USER_OID

export KV_SCOPE="$(az keyvault show --name azwi-kv-demo-015 --resource-group aks-wi-oidc --query id -o tsv)"
  echo "${KV_SCOPE}"

# assign Key Vault Secrets Officer role on the vault
az role assignment create \
  --role "Key Vault Secrets Officer" \
  --assignee-object-id "${CURRENT_USER_OID}" \
  --assignee-principal-type User \
  --scope "/subscriptions/${SUBSCRIPTION}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.KeyVault/vaults/${KEYVAULT_NAME}"

az keyvault secret set --vault-name ${KEYVAULT_NAME} --name ${KEYVAULT_SECRET_NAME} --value 'Hello! Nelson here!'

# create user assigned managed identity
az identity create --name ${UAID} --resource-group ${RESOURCE_GROUP} \
                   --location ${LOCATION} \
                   --subscription ${SUBSCRIPTION}

export USER_ASSIGNED_CLIENT_ID="$(az identity show --resource-group ${RESOURCE_GROUP} --name ${UAID} --query 'clientId' -otsv)"
echo $USER_ASSIGNED_CLIENT_ID

# give managed identity access to key vault secrets (RBAC-enabled vault requires role assignment, not set-policy)
export UAID_PRINCIPAL_ID="$(az identity show --resource-group "${RESOURCE_GROUP}" --name "${UAID}" --query 'principalId' -otsv)"
az role assignment create \
  --role "Key Vault Secrets User" \
  --assignee-object-id "${UAID_PRINCIPAL_ID}" \
  --assignee-principal-type ServicePrincipal \
  --scope "${KV_SCOPE}"

echo $UAID_PRINCIPAL_ID

# connect to the AKS cluster
az aks get-credentials -n ${AKS_NAME} -g ${RESOURCE_GROUP} --overwrite-existing

# create a Kubernetes service account and annotate it with the client ID of the Managed Identity
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  annotations:
    azure.workload.identity/client-id: ${USER_ASSIGNED_CLIENT_ID}
  labels:
    azure.workload.identity/use: "true"
  name: ${SERVICE_ACCOUNT_NAME}
  namespace: ${SERVICE_ACCOUNT_NAMESPACE}
EOF

# Use the az identity federated-credential create command to create the federated identity credential between the managed identity, the service account issuer, and the subject.
az identity federated-credential create --name ${FICID} --resource-group ${RESOURCE_GROUP} \
            --identity-name ${UAID} \
            --issuer ${AKS_OIDC_ISSUER} \
            --subject system:serviceaccount:${SERVICE_ACCOUNT_NAMESPACE}:${SERVICE_ACCOUNT_NAME}
# wait few minutes for the federation to propagate

# Run the following to deploy a pod that references the service account created in the previous step.
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: quick-start
  namespace: ${SERVICE_ACCOUNT_NAMESPACE}
  labels:
    azure.workload.identity/use: "true"
spec:
  serviceAccountName: ${SERVICE_ACCOUNT_NAME}
  containers:
    - image: ghcr.io/azure/azure-workload-identity/msal-go
      name: oidc
      env:
      - name: KEYVAULT_URL
        value: "https://${KEYVAULT_NAME}.vault.azure.net/"
      - name: SECRET_NAME
        value: ${KEYVAULT_SECRET_NAME}
  nodeSelector:
    kubernetes.io/os: linux
EOF


kubectl describe pod quick-start
kubectl logs quick-start

# cleanup resources
kubectl delete pod quick-start
kubectl delete sa "${SERVICE_ACCOUNT_NAME}" --namespace "${SERVICE_ACCOUNT_NAMESPACE}"
az group delete --name "${RESOURCE_GROUP}"
