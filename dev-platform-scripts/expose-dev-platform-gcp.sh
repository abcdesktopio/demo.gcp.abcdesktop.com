#!/bin/bash
# Exposes the abcdesktop dev platform on GCP by creating an ingress resource, a Google-managed SSL certificate, and a DNS A record for the specified FQDN.
# Author: Matteo Beghelli 

GCP_SA_CREDENTIALS_FILE="$1"
ABCDESKTOP_FQDN="$2"
DNS_ZONE="$3"

# Optional, set via --abcdesktop-namespace (default: abcdesktop)
ABCDESKTOP_NAMESPACE="abcdesktop"

# Optional, set via --dns-record-ttl (default: 300)
DNS_RECORD_TTL=300

# Optional, set via --project (only used for the IAP related gcloud calls below;
# if empty, the active gcloud config project is used, like the rest of this script)
PROJECT_ID=""

# Optional, set via --enable-iap to protect the ingress with Cloud IAP
ENABLE_IAP=false
IAP_SUPPORT_EMAIL=""
IAP_APPLICATION_TITLE="abcdesktop"
IAP_MEMBERS=""
# The IAP OAuth Admin API (oauth-brands/oauth-clients) was permanently shut
# down by Google on 2026-03-19, so the OAuth client can no longer be created
# automatically: create it once manually in Cloud Console (APIs & Services >
# Google Auth Platform) and pass it with --iap-client-id / --iap-client-secret.
IAP_CLIENT_ID=""
IAP_CLIENT_SECRET=""

# $1 message
# $2 status
display_message() {
    # ${2^^}: bad substitution, use "${2}"
    # use printf instead of echo for better compatibility sh zsh bash
    case "${2}" in
        "OK") COLOR="\033[0;32m";;
        "KO") COLOR="\033[0;31m";;
        "ERROR") COLOR="\033[0;31m";;
        "WARN") COLOR="\033[0;33m";;
        "INFO") COLOR="\033[1;34m";;
    esac
    printf "[$COLOR%s\033[0;0m] %s\n" "$2" "$1"
}

# $1 message
display_message_result() {
    exit_code="$?"
    if [ "$exit_code" -eq 0 ];
    then
        display_message "$1" "OK"
    else
        display_message "$1 error $exit_code" "KO"
    fi
}

# $1 command
check_command() {
    if ! command -v "$1" &> /dev/null
    then
        display_message "$1 could not be found" "KO"
    exit 1
fi
}

check_arguments() {
    if [ "$#" -lt 3 ]; then
        display_message "Missing arguments: expected at least 3 but got $#" "ERROR"
        display_message "Usage: $0 <GCP_SA_CREDENTIALS_FILE> <ABCDESKTOP_FQDN> <DNS_ZONE> [OPTION]..." "ERROR"
        exit 1
    fi
}

function help() {
        cat <<-EOF
abcdesktop dev platform exposure on GCP

Usage: expose-dev-platform-gcp.sh <GCP_SA_CREDENTIALS_FILE> <ABCDESKTOP_FQDN> <DNS_ZONE> [OPTION]...

Options (exclusives):
 --help                        Display this help and exit

Arguments:
 <GCP_SA_CREDENTIALS_FILE>     Define the path to the service account credentials file
 <ABCDESKTOP_FQDN>             Define the FQDN for the abcdesktop dev platform
 <DNS_ZONE>                    Define the DNS zone on which the FQDN is configured (e.g., "gcp-abcdekstop-demo")

Parameters:
 --abcdesktop-namespace        Define the namespace for abcdesktop deployment (default: abcdesktop)
 --dns-record-ttl              Define the TTL for the DNS record (default: 300)
 --project <id>                Define the GCP project id used for the Cloud IAP setup (default: active gcloud project)
 --enable-iap                  Protect the ingress with Cloud Identity-Aware Proxy (IAP)
 --iap-client-id <id>          OAuth client ID for IAP, created manually in Cloud Console (required with --enable-iap)
 --iap-client-secret <secret>  OAuth client secret for IAP, created manually in Cloud Console (required with --enable-iap)
 --iap-member <member>         Grant IAP access to this member, e.g. "user:me@example.com" or "group:team@example.com" or "domain:example.com" (comma-separated for several)

Examples:
    expose-dev-platform-gcp.sh <GCP_SA_CREDENTIALS_FILE> <ABCDESKTOP_FQDN> <DNS_ZONE>
    Expose the abcdesktop dev platform on GCP.

    expose-dev-platform-gcp.sh <GCP_SA_CREDENTIALS_FILE> <ABCDESKTOP_FQDN> <DNS_ZONE> --abcdesktop-namespace my-namespace
    Expose the abcdesktop dev platform in a specific namespace.

    expose-dev-platform-gcp.sh <GCP_SA_CREDENTIALS_FILE> <ABCDESKTOP_FQDN> <DNS_ZONE> --dns-record-ttl 600
    Expose the abcdesktop dev platform with a custom DNS record TTL.

    expose-dev-platform-gcp.sh <GCP_SA_CREDENTIALS_FILE> <ABCDESKTOP_FQDN> <DNS_ZONE> --enable-iap --iap-client-id 123-abc.apps.googleusercontent.com --iap-client-secret GOCSPX-xxx --iap-member user:me@example.com
    Expose the abcdesktop dev platform and protect it with Cloud IAP.

    expose-dev-platform-gcp.sh --help
    Display this help and exit.

Notes:
 - The script assumes that the GCP project and GKE cluster are already set up.
 - The script assumes that your DNS zone is already created in GCP and that you have the necessary permissions to create DNS records.
 - As of 2026-03-19, Google permanently shut down the IAP OAuth Admin API
   (oauth-brands/oauth-clients), so the OAuth consent screen and client can no
   longer be created via gcloud/this script. Create them once manually in
   Cloud Console (APIs & Services > Google Auth Platform) and pass the
   resulting client with --iap-client-id/--iap-client-secret.
 - The OAuth client used for --iap-client-id must have the following
   Authorized redirect URI registered in Cloud Console (Credentials > edit
   the OAuth client > Authorized redirect URIs), otherwise sign-in fails with
   "doesn't comply with Google's OAuth 2.0 policy":
     https://iap.googleapis.com/v1/oauth/clientIds/<IAP_CLIENT_ID>:handleRedirect
 - The IAP access granted with --iap-member is applied on the GKE Ingress backend service (--resource-type=backend-services), not project-wide.
 - The service account running this script needs roles/iap.admin (to manage
   IAM policy on the IAP resource) and roles/serviceusage.serviceUsageAdmin
   (to enable APIs) on the project. If the Service Usage API itself was never
   used on the project, no gcloud command can enable anything (chicken-and-egg
   SERVICE_DISABLED error): a project Owner must first enable it manually via
   https://console.developers.google.com/apis/api/serviceusage.googleapis.com/overview?project=<PROJECT_ID>

Exit status:
 0      if OK,
 1      if any problem

EOF
}

for arg in "$@"; do
    if [ "$arg" = "--help" ]; then
        help
        exit 0
    fi
done

check_arguments "$@"

while [ $# -gt 0 ]
do
    case "$1" in
        # commands
        --abcdesktop-namespace) ABCDESKTOP_NAMESPACE="$2";shift;;
        --dns-record-ttl) DNS_RECORD_TTL="$2";shift;;
        --project) PROJECT_ID="$2";shift;;
        --enable-iap) ENABLE_IAP=true;;
        --iap-client-id) IAP_CLIENT_ID="$2";shift;;
        --iap-client-secret) IAP_CLIENT_SECRET="$2";shift;;
        --iap-member) IAP_MEMBERS="$2";shift;;
    esac
    shift
done

display_message  "abcdesktop expose dev platform script" "INFO"
display_message  "GCP service account credentials file: $GCP_SA_CREDENTIALS_FILE" "INFO"
display_message  "abcdesktop FQDN: $ABCDESKTOP_FQDN" "INFO"
display_message  "abcdesktop namespace: $ABCDESKTOP_NAMESPACE" "INFO"
display_message  "DNS zone: $DNS_ZONE" "INFO"

# Check if gcloud command is available
check_command gcloud
GCLOUD_VERSION=$(gcloud version --format=json)
display_message_result "gcloud version"

# Check if kubectl command is supported
# run command kubectl version
check_command kubectl
KUBE_VERSION=$(kubectl version --output=yaml)
display_message_result "kubectl version"

# Authenticate with GCP using the provided service account credentials file
gcloud auth login --cred-file="$GCP_SA_CREDENTIALS_FILE" -q
display_message_result "gcloud auth login --cred-file=$GCP_SA_CREDENTIALS_FILE"

# --- Step 1: create an HTTP-only ingress for the FQDN (HTTPS is added once the cert is ready) ---
cat > abcdesktop_dev_platform_host.yaml <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ingress-abcdesktop
  annotations:
    spec.ingressClassName: "gce"
spec:
  rules:
    - host: "$ABCDESKTOP_FQDN"
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: http-router
                port:
                  number: 80
EOF

display_message_result "cat > abcdesktop_dev_platform_host.yaml <<EOF"
display_message "abcdesktop_dev_platform_host.yaml file created with the following content:" "INFO"
cat abcdesktop_dev_platform_host.yaml

display_message "Applying the ingress resource to the Kubernetes cluster..." "INFO"
kubectl apply -f abcdesktop_dev_platform_host.yaml -n "$ABCDESKTOP_NAMESPACE"
display_message_result "kubectl apply -f abcdesktop_dev_platform_host.yaml -n $ABCDESKTOP_NAMESPACE"

display_message "Waiting for the ingress resource to be created..." "INFO"
display_message "This may take a few minutes..." "INFO"
# Wait for the ingress resource to be created and get the external IP address
while true; do
    INGRESS_IP=$(kubectl get ingress ingress-abcdesktop -n "$ABCDESKTOP_NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
    if [ -n "$INGRESS_IP" ]; then
        break
    fi
    sleep 5
done
display_message "External IP address of the ingress resource: $INGRESS_IP" "INFO"

# --- Step 2: point the FQDN to the ingress IP via a DNS A record ---
display_message "Creating a DNS A record for $ABCDESKTOP_FQDN pointing to $INGRESS_IP..." "INFO"
# Create a DNS A record for the FQDN pointing to the ingress IP address
gcloud dns record-sets create "$ABCDESKTOP_FQDN." --type=A --ttl="$DNS_RECORD_TTL" --zone="$DNS_ZONE" --rrdatas="$INGRESS_IP"
display_message_result "gcloud dns record-sets create $ABCDESKTOP_FQDN. --type=A --ttl=$DNS_RECORD_TTL --zone=$DNS_ZONE --rrdatas=$INGRESS_IP"

# --- Step 3: request a Google-managed SSL certificate and switch the ingress to HTTPS ---
display_message "Configuring Google-managed SSL certificate for $ABCDESKTOP_FQDN..." "INFO"
cat > abcdesktop_dev_platform_ssl.yaml <<EOF
apiVersion: networking.gke.io/v1
kind: ManagedCertificate
metadata:
  name: abcdesktop-cert
spec:
  domains:
    - "$ABCDESKTOP_FQDN"
EOF

display_message_result "cat > abcdesktop_dev_platform_ssl.yaml <<EOF"
display_message "abcdesktop_dev_platform_ssl.yaml file created with the following content:" "INFO"
cat abcdesktop_dev_platform_ssl.yaml

display_message "Applying the ManagedCertificate resource to the Kubernetes cluster..." "INFO"
kubectl apply -f abcdesktop_dev_platform_ssl.yaml -n "$ABCDESKTOP_NAMESPACE"
display_message_result "kubectl apply -f abcdesktop_dev_platform_ssl.yaml -n $ABCDESKTOP_NAMESPACE"

display_message "Updating the ingress resource to use the ManagedCertificate..." "INFO"
cat > abcdesktop_dev_platform_ingress_update.yaml <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ingress-abcdesktop
  annotations:
    spec.ingressClassName: "gce"
    networking.gke.io/managed-certificates: "abcdesktop-cert"
spec:
  rules:
    - host: "$ABCDESKTOP_FQDN"
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: http-router
                port:
                  number: 80           
EOF

display_message_result "cat > abcdesktop_dev_platform_ingress_update.yaml <<EOF"
display_message "abcdesktop_dev_platform_ingress_update.yaml file created with the following content:" "INFO"
cat abcdesktop_dev_platform_ingress_update.yaml

display_message "Applying the updated ingress resource to the Kubernetes cluster..." "INFO"
kubectl apply -f abcdesktop_dev_platform_ingress_update.yaml -n "$ABCDESKTOP_NAMESPACE"
display_message_result "kubectl apply -f abcdesktop_dev_platform_ingress_update.yaml -n $ABCDESKTOP_NAMESPACE"

display_message "Waiting for the SSL certificate to be provisioned..." "INFO"
display_message "This may take more than 15 minutes. Time to get a coffee ;)" "INFO"

while true; do
    CERT_STATUS=$(kubectl get managedcertificate abcdesktop-cert -n $ABCDESKTOP_NAMESPACE -o jsonpath='{.status.certificateStatus}')
    if [ "$CERT_STATUS" == "Active" ]; then
        break
    fi
    sleep 30
done

display_message "SSL certificate for $ABCDESKTOP_FQDN is now active." "INFO"

# --- Step 4: optionally protect the app with Cloud IAP, then apply a longer ---
# --- ingress connection timeout (needed for abcdesktop's long-lived sessions) ---
display_message "Increasing ingress connection timeout to 1800 seconds..." "INFO"

# IAP_SPEC is injected into the BackendConfig YAML further down, once populated.
IAP_SPEC=""
if [ "$ENABLE_IAP" = true ]; then
    PROJECT_FLAG=()
    [ -n "$PROJECT_ID" ] && PROJECT_FLAG=(--project="$PROJECT_ID")

    display_message "Enabling the Cloud IAP API..." "INFO"
    if ! gcloud services enable iap.googleapis.com "${PROJECT_FLAG[@]}"; then
        display_message "gcloud services enable iap.googleapis.com failed (check that the service account has roles/serviceusage.serviceUsageAdmin on the project), continuing best-effort" "WARN"
    fi

    if [ -z "$IAP_CLIENT_ID" ] || [ -z "$IAP_CLIENT_SECRET" ]; then
        display_message "Missing --iap-client-id/--iap-client-secret. The IAP OAuth Admin API was permanently shut down on 2026-03-19: create the OAuth consent screen and client manually in Cloud Console (APIs & Services > Google Auth Platform) and pass them with --iap-client-id/--iap-client-secret" "KO"
        exit 1
    fi
    display_message "Using the provided IAP OAuth client $IAP_CLIENT_ID" "INFO"

    IAP_SECRET_NAME="iap-oauth-secret"
    display_message "Storing the IAP OAuth client credentials in secret $IAP_SECRET_NAME..." "INFO"
    kubectl create secret generic "$IAP_SECRET_NAME" \
        --from-literal=client_id="$IAP_CLIENT_ID" \
        --from-literal=client_secret="$IAP_CLIENT_SECRET" \
        -n "$ABCDESKTOP_NAMESPACE" \
        --dry-run=client -o yaml | kubectl apply -f -
    display_message_result "kubectl apply secret/$IAP_SECRET_NAME -n $ABCDESKTOP_NAMESPACE"

    IAP_SPEC=$(cat <<-IAPEOF
  iap:
    enabled: true
    oauthclientCredentials:
      secretName: $IAP_SECRET_NAME
IAPEOF
)

    if [ -n "$IAP_MEMBERS" ]; then
        display_message "Looking up the backend service created by the GKE Ingress for http-router..." "INFO"
        IAP_BACKEND_SERVICE=$(gcloud compute backend-services list "${PROJECT_FLAG[@]}" \
            --global --format="value(name)" --filter="name~http-router" 2>/dev/null | head -n 1)
        if [ -z "$IAP_BACKEND_SERVICE" ]; then
            display_message "Could not find the http-router backend service yet, skipping IAP IAM bindings. Re-run this script once the ingress/backend service is fully provisioned." "WARN"
        else
            display_message "Granting Cloud IAP access on backend service $IAP_BACKEND_SERVICE (roles/iap.httpsResourceAccessor)..." "INFO"
            IFS=',' read -ra MEMBER_LIST <<< "$IAP_MEMBERS"
            for MEMBER in "${MEMBER_LIST[@]}"; do
                gcloud iap web add-iam-policy-binding \
                    --member="$MEMBER" \
                    --role="roles/iap.httpsResourceAccessor" \
                    --resource-type=backend-services \
                    --service="$IAP_BACKEND_SERVICE" \
                    "${PROJECT_FLAG[@]}"
                display_message_result "gcloud iap web add-iam-policy-binding --member=$MEMBER --service=$IAP_BACKEND_SERVICE"
            done
        fi
    else
        display_message "No --iap-member provided: nobody will be authorized to access the IAP-protected app yet" "WARN"
    fi
fi

# --- Step 5: BackendConfig (timeout + IAP if enabled) applied to the http-router service ---
cat > abcdesktop_dev_platform_ingress_increased_timeout.yaml <<EOF
apiVersion: cloud.google.com/v1
kind: BackendConfig
metadata:
  name: long-timeout-backend
spec:
  timeoutSec: 1800
$IAP_SPEC
EOF

display_message_result "cat > abcdesktop_dev_platform_ingress_increased_timeout.yaml <<EOF"
display_message "abcdesktop_dev_platform_ingress_increased_timeout.yaml file created with the following content:" "INFO"
cat abcdesktop_dev_platform_ingress_increased_timeout.yaml

display_message "Applying the BackendConfig resource to the Kubernetes cluster..." "INFO"
kubectl apply -f abcdesktop_dev_platform_ingress_increased_timeout.yaml -n "$ABCDESKTOP_NAMESPACE"
display_message_result "kubectl apply -f abcdesktop_dev_platform_ingress_increased_timeout.yaml -n $ABCDESKTOP_NAMESPACE"

display_message "Updating the http-router service to use the BackendConfig..." "INFO"
cat > abcdesktop_dev_platform_service_update.yaml <<EOF
kind: Service
apiVersion: v1
metadata:
  name: http-router
  labels:
    abcdesktop/role: router-od
  annotations:
    cloud.google.com/backend-config: '{"ports":{"80":"long-timeout-backend"}}'
spec:
  selector:
    run: router-od
  ports:
  - protocol: TCP
    port: 443
    targetPort: 443
    name: https
  - protocol: TCP
    port: 80
    targetPort: 80
    name: http
EOF

display_message_result "cat > abcdesktop_dev_platform_service_update.yaml <<EOF"
display_message "abcdesktop_dev_platform_service_update.yaml file created with the following content:" "INFO"
cat abcdesktop_dev_platform_service_update.yaml

display_message "Applying the updated http-router service to the Kubernetes cluster..." "INFO"
kubectl apply -f abcdesktop_dev_platform_service_update.yaml -n "$ABCDESKTOP_NAMESPACE"
display_message_result "kubectl apply -f abcdesktop_dev_platform_service_update.yaml -n $ABCDESKTOP_NAMESPACE"

display_message "Your abcdesktop dev platform is now accessible at https://$ABCDESKTOP_FQDN" "INFO"
display_message "Please note that it may take a few minutes for the DNS changes to propagate." "INFO"