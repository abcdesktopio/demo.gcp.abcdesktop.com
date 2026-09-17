#!/bin/bash
# Deploys the abcdesktop dev platform on GCP by creating a GKE cluster, a VPC network, a subnetwork, and deploying abcdesktop in the specified namespace.
# Author: Matteo Beghelli 

# GKE cluster specifications arguments
GCP_SA_CREDENTIALS_FILE="$1"
PROJECT_ID="$2"
CLUSTER_NAME="$3"
CLUSTER_REGION="$4"
NUMBER_OF_NODES="$5"

# Optional, set via --vpc-network / --subnet-name (auto-created when omitted)
VPC_NETWORK=""
SUBNET_NAME=""

# Optional, set via --abcdesktop-namespace (default: abcdesktop)
ABCDESKTOP_NAMESPACE="abcdesktop"

# abcdesktop version
ABCDESKTOP_VERSION="5.0"

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
    if [ "$#" -lt 5 ]; then
        display_message "Missing arguments: expected at least 5 but got $#" "ERROR"
        display_message "Usage: $0 <GCP_SA_CREDENTIALS_FILE> <PROJECT_ID> <CLUSTER_NAME> <CLUSTER_REGION> <NUMBER_OF_NODES> [OPTION]..." "ERROR"
        exit 1
    fi
}

function help() {
        cat <<-EOF
abcdesktop dev platform setup on GCP

Usage: deploy-dev-platform-gcp.sh <GCP_SA_CREDENTIALS_FILE> <PROJECT_ID> <CLUSTER_NAME> <CLUSTER_REGION> <NUMBER_OF_NODES> [OPTION]...

Options (exclusives):
 --help                        Display this help and exit

Arguments:
 <GCP_SA_CREDENTIALS_FILE>     Define the path to the service account credentials file
 <PROJECT_ID>                  Define the GCP project id
 <CLUSTER_NAME>                Define the GKE cluster name
 <CLUSTER_REGION>              Define the GKE cluster region
 <NUMBER_OF_NODES>             Define the number of nodes in the cluster

Parameters:
 --vpc-network <name>          Define an existing VPC network name (default: auto-create a new one)
 --subnet-name <name>          Define an existing subnet name (default: auto-create a new one)
 --abcdesktop-namespace        Define the namespace for abcdesktop deployment (default: abcdesktop)
 --abcdesktop-version          Define the abcdesktop version to deploy (default: 5.0)

Examples:
    deploy-dev-platform-gcp.sh <GCP_SA_CREDENTIALS_FILE> <PROJECT_ID> <CLUSTER_NAME> <CLUSTER_REGION> <NUMBER_OF_NODES>
    Deploy an abcdesktop service on a GKE cluster, creating the VPC network and subnetwork automatically.

    deploy-dev-platform-gcp.sh <GCP_SA_CREDENTIALS_FILE> <PROJECT_ID> <CLUSTER_NAME> <CLUSTER_REGION> <NUMBER_OF_NODES> --abcdesktop-version 4.4
    Install an abcdesktop service on a GKE cluster with a specific version.

    deploy-dev-platform-gcp.sh <GCP_SA_CREDENTIALS_FILE> <PROJECT_ID> <CLUSTER_NAME> <CLUSTER_REGION> <NUMBER_OF_NODES> --vpc-network my-vpc --subnet-name my-subnet
    Deploy an abcdesktop service on a GKE cluster, using an existing VPC network and subnetwork.

    deploy-dev-platform-gcp.sh --help
    Display this help and exit.

  
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
        --vpc-network) VPC_NETWORK="$2";shift;;
        --subnet-name) SUBNET_NAME="$2";shift;;
        --abcdesktop-namespace) ABCDESKTOP_NAMESPACE="$2";shift;;
        --abcdesktop-version) ABCDESKTOP_VERSION="$2";shift;;
    esac
    shift
done

# CIDR range used for the subnetwork when it is created automatically
SUBNET_RANGE="${SUBNET_RANGE:-10.0.0.0/20}"

AUTO_VPC=false
AUTO_SUBNET=false

if [ -z "$VPC_NETWORK" ] || [ "$VPC_NETWORK" = "auto" ]; then
    AUTO_VPC=true
    VPC_NETWORK="${CLUSTER_NAME}-vpc"
fi

if [ -z "$SUBNET_NAME" ] || [ "$SUBNET_NAME" = "auto" ]; then
    AUTO_SUBNET=true
    SUBNET_NAME="${CLUSTER_NAME}-subnet"
fi

display_message  "abcdesktop deploy dev platform script" "INFO"
display_message  "GCP service account credentials file: $GCP_SA_CREDENTIALS_FILE" "INFO"
display_message  "Project ID: $PROJECT_ID" "INFO"
display_message  "Cluster name: $CLUSTER_NAME" "INFO"
display_message  "Cluster region: $CLUSTER_REGION" "INFO"
display_message  "VPC network: $VPC_NETWORK (auto-create: $AUTO_VPC)" "INFO"
display_message  "Subnet name: $SUBNET_NAME (auto-create: $AUTO_SUBNET)" "INFO"
display_message  "Number of nodes: $NUMBER_OF_NODES" "INFO"
display_message  "abcdesktop namespace: $ABCDESKTOP_NAMESPACE" "INFO"
display_message  "abcdesktop version: $ABCDESKTOP_VERSION" "INFO"

# Check if gcloud command is available
check_command gcloud
GCLOUD_VERSION=$(gcloud version --format=json)
display_message_result "gcloud version"

# Check if kubectl command is supported
# run command kubectl version
check_command kubectl
KUBE_VERSION=$(kubectl version --output=yaml)
display_message_result "kubectl version"

# Check if curl command is available
check_command curl
CURL_VERSION=$(curl --version | head -n 1)
display_message_result "curl version"

# Authenticate with GCP using the provided service account credentials file
gcloud auth login --cred-file="$GCP_SA_CREDENTIALS_FILE" -q
display_message_result "gcloud auth login --cred-file=$GCP_SA_CREDENTIALS_FILE"

# Create the VPC network automatically if none was provided.
if [ "$AUTO_VPC" = true ]; then
    display_message "Creating VPC network $VPC_NETWORK" "INFO"
    gcloud compute networks create "$VPC_NETWORK" \
        --project "$PROJECT_ID" \
        --subnet-mode=custom
    display_message_result "gcloud compute networks create $VPC_NETWORK"

    # The cluster nodes are private (--enable-private-nodes): they have no
    # public IP and cannot reach the public internet (e.g. ghcr.io, docker.io)
    # without a Cloud NAT gateway. Create a Cloud Router + Cloud NAT so image
    # pulls from public registries don't time out.
    ROUTER_NAME="${VPC_NETWORK}-router"
    NAT_NAME="${VPC_NETWORK}-nat"

    display_message "Creating Cloud Router $ROUTER_NAME" "INFO"
    gcloud compute routers create "$ROUTER_NAME" \
        --project "$PROJECT_ID" \
        --network "$VPC_NETWORK" \
        --region "$CLUSTER_REGION"
    display_message_result "gcloud compute routers create $ROUTER_NAME"

    display_message "Creating Cloud NAT $NAT_NAME" "INFO"
    gcloud compute routers nats create "$NAT_NAME" \
        --project "$PROJECT_ID" \
        --router "$ROUTER_NAME" \
        --region "$CLUSTER_REGION" \
        --auto-allocate-nat-external-ips \
        --nat-all-subnet-ip-ranges
    display_message_result "gcloud compute routers nats create $NAT_NAME"
fi

# The subnetwork is either an existing one, or created on the fly by the
# cluster creation command (--create-subnetwork), which also takes care of
# provisioning the secondary ranges required by --enable-ip-alias.
if [ "$AUTO_SUBNET" = true ]; then
    SUBNET_ARGS=(--create-subnetwork "name=$SUBNET_NAME,range=$SUBNET_RANGE")
else
    SUBNET_ARGS=(--subnetwork "projects/$PROJECT_ID/regions/$CLUSTER_REGION/subnetworks/$SUBNET_NAME")
fi

display_message "Starting GKE cluster creation" "INFO"

# Create a GKE cluster in the specified project/region. Notable non-default flags:
#  - --enable-private-nodes + --enable-ip-alias: nodes have no public IP, only
#    reachable via the VPC/Cloud NAT created above.
#  - --enable-dataplane-v2*: Cilium-based networking with flow observability.
#  - --enable-shielded-nodes + secure-boot/integrity-monitoring: hardened nodes.
#  - --enable-autoupgrade/--enable-autorepair + "regular" release channel.
gcloud beta container \
    --project "$PROJECT_ID" clusters create "$CLUSTER_NAME" \
    --region "$CLUSTER_REGION" \
    --no-enable-basic-auth \
    --cluster-version \
"1.35.6-gke.1710000" \
    --release-channel \
"regular" \
    --machine-type \
"n4-standard-4" \
    --image-type \
"COS_CONTAINERD" \
    --disk-type \
"hyperdisk-balanced" \
    --disk-size \
"100" \
    --metadata \
disable-legacy-endpoints=true \
    --service-account \
"default" \
    --scopes \
"https://www.googleapis.com/auth/devstorage.read_only","https://www.googleapis.com/auth/logging.write","https://www.googleapis.com/auth/monitoring","https://www.googleapis.com/auth/service.management.readonly","https://www.googleapis.com/auth/servicecontrol","https://www.googleapis.com/auth/trace.append" \
    --max-pods-per-node \
"110" \
    --num-nodes \
"$NUMBER_OF_NODES" \
    --logging=SYSTEM,WORKLOAD \
    --monitoring=SYSTEM,STORAGE,HPA,POD,DAEMONSET,DEPLOYMENT,STATEFULSET,CADVISOR,KUBELET,DCGM,JOBSET \
    --enable-private-nodes \
    --enable-ip-alias \
    --network \
"projects/$PROJECT_ID/global/networks/$VPC_NETWORK" \
    "${SUBNET_ARGS[@]}" \
    --enable-intra-node-visibility \
    --default-max-pods-per-node \
"110" \
    --enable-ip-access \
    --enable-authorized-networks-on-private-endpoint \
    --security-posture=standard \
    --workload-vulnerability-scanning=disabled \
    --enable-dataplane-v2 \
    --enable-dataplane-v2-metrics \
    --enable-dataplane-v2-flow-observability \
    --no-enable-google-cloud-access \
    --addons \
HorizontalPodAutoscaling,HttpLoadBalancing,NodeLocalDNS,GcePersistentDiskCsiDriver \
    --enable-autoupgrade \
    --enable-autorepair \
    --max-surge-upgrade \
1 \
    --max-unavailable-upgrade \
0 \
    --binauthz-evaluation-mode=DISABLED \
    --enable-managed-prometheus \
    --enable-shielded-nodes \
    --shielded-integrity-monitoring \
    --shielded-secure-boot \
    --node-locations \
"$CLUSTER_REGION-b","$CLUSTER_REGION-a","$CLUSTER_REGION-c"

# --- Point kubectl at the newly created cluster ---
# Get the credentials for the GKE cluster to configure kubectl to use it.
gcloud container clusters get-credentials "$CLUSTER_NAME" --region "$CLUSTER_REGION" --project "$PROJECT_ID"
display_message_result "gcloud container clusters get-credentials $CLUSTER_NAME --region $CLUSTER_REGION --project $PROJECT_ID"

# Check the cluster information and the nodes in the cluster using kubectl.
kubectl cluster-info
display_message_result "kubectl cluster-info"
kubectl get nodes
display_message_result "kubectl get nodes"

# --- Install abcdesktop itself ---
# Fetch and run the official abcdesktop installer script for the requested version.
wget https://raw.githubusercontent.com/abcdesktopio/conf/main/kubernetes/install-"$ABCDESKTOP_VERSION".sh
display_message_result "wget https://raw.githubusercontent.com/abcdesktopio/conf/main/kubernetes/install-$ABCDESKTOP_VERSION.sh"
chmod 755 install-"$ABCDESKTOP_VERSION".sh
./install-"$ABCDESKTOP_VERSION".sh --namespace $ABCDESKTOP_NAMESPACE
display_message_result "./install-$ABCDESKTOP_VERSION.sh --namespace $ABCDESKTOP_NAMESPACE"

# Check the pods in the abcdesktop namespace to verify that the deployment was successful.
kubectl get pods -n $ABCDESKTOP_NAMESPACE
display_message_result "kubectl get pods -n $ABCDESKTOP_NAMESPACE"