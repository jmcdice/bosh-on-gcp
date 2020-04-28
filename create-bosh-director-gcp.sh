#!/usr/bin/env bash
# 
# Clone Director templates
# Give me open-source bosh director on GCP

# Edit these to match your zone's default subnet's
SUBNET_CIDR='10.128.0.0/20'
SUBNET_GW='10.128.0.1'
BOSH_IP='10.128.0.10'
GCP_ZONE='us-central1-c'

# Shouldn't have to modify anything below here..
SERVICE_ACCOUNT='bosh-director-sa'
GCP_PROJECT=$(gcloud config get-value project)
MYIP=$(curl -s ifconfig.co)

function get_external_ip() {

  gcloud compute addresses create bosh-director --region $(gcloud config get-value compute/region)
}

function create_director_service_account() {

  if [ ! -f creds/bosh-director-sa.json ]; then
    
    echo -n "Creating (IAM) service account (${SERVICE_ACCOUNT}): "
    gcloud iam service-accounts create ${SERVICE_ACCOUNT} --display-name=${SERVICE_ACCOUNT}

    echo -n "Creating service account key: "
    gcloud iam service-accounts keys create creds/${SERVICE_ACCOUNT}.json \
      --iam-account="${SERVICE_ACCOUNT}@${GCP_PROJECT}.iam.gserviceaccount.com"

    echo -n "Adding ${SERVICE_ACCOUNT} to ${GCP_PROJECT}: "
    gcloud projects add-iam-policy-binding ${GCP_PROJECT} \
      --member=serviceAccount:"${SERVICE_ACCOUNT}@${GCP_PROJECT}.iam.gserviceaccount.com" \
      --role=roles/editor
  fi
}

function create_fw_access() {

  EXT_IP=$(gcloud -q compute addresses list|grep bosh-director|awk '{print $2}')

  gcloud compute firewall-rules list | grep -q bosh-dir-access
  if [ $? -eq 0 ]; then
    echo "FW rule already exists."
  else 
    echo "Allowing access to ${EXT_IP} from ${MYIP}/32 to tcp 6868,25555."
    gcloud compute firewall-rules create bosh-dir-access \
        --direction=INGRESS \
        --priority=1000 \
        --network=default \
        --action=ALLOW \
        --rules=tcp:6868,tcp:25555 \
        --source-ranges=${MYIP}/32
  fi
}

function clone_deployment_config() {

  if [ ! -d bosh-deployment ]; then
    git clone https://github.com/cloudfoundry/bosh-deployment.git
  fi
}

function bosh_director() {

  local ACTION=$1

  EXT_IP=$(gcloud -q compute addresses list|grep bosh-director|awk '{print $2}')

  bosh ${ACTION}-env bosh-deployment/bosh.yml \
    --state=state.json \
    --vars-store=creds.yml \
    -o bosh-deployment/gcp/cpi.yml \
    -o bosh-deployment/external-ip-not-recommended.yml \
    -v director_name=bosh-1 \
    -v internal_cidr=${SUBNET_CIDR} \
    -v internal_gw=${SUBNET_GW} \
    -v internal_ip=${BOSH_IP} \
    -v external_ip=${EXT_IP} \
    --var-file gcp_credentials_json=creds/bosh-director-sa.json \
    -v project_id=${GCP_PROJECT} \
    -v zone=${GCP_ZONE} \
    -v tags=[internal] \
    -v network=default \
    -v subnetwork=default
}

function bosh_director_target() {

  EXT_IP=$(gcloud -q compute addresses list|grep bosh-director|awk '{print $2}')
  bosh -e ${EXT_IP}  alias-env bosh-gcp --ca-cert <(bosh int creds.yml --path /director_ssl/ca)
  bosh -e bosh-gcp login --client=admin --client-secret=$(bosh int creds.yml --path /admin_password)
  echo "bosh -e bosh-gcp deployments"
}

function delete_everything() {

  bosh -e bosh-gcp log-out
  bosh_director delete
  gcloud compute firewall-rules delete bosh-dir-access
  gcloud compute addresses delete bosh-director
  gcloud iam service-accounts delete "${SERVICE_ACCOUNT}@${GCP_PROJECT}.iam.gserviceaccount.com" --quiet
  gcloud projects remove-iam-policy-binding ${GCP_PROJECT} --role roles/editor \
    --member "serviceAccount:${SERVICE_ACCOUNT}@${GCP_PROJECT}.iam.gserviceaccount.com" --quiet

  rm -f creds/bosh-director-sa.json
  rmdir creds/
  rm -f creds.yml state.json
}

# delete_everything; exit

get_external_ip
create_fw_access
clone_deployment_config
create_director_service_account
bosh_director create
bosh_director_target

