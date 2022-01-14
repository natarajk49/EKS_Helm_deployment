#!/bin/bash
set +o errexit
retries_max=120

echo "cloning helm-charts"

retries=0
until git clone --depth=1 -b "${GIT_BRANCH}" git@github.ibm.com:watson-health-cognitive-services/whcs-service-clinical-data-annotator-operator.git || (( retries++ >= retries_max ))
do
  echo "Git down, trying again"
  sleep 1m
done
if [ $retries -gt $retries_max ]; then
  echo "git clone for watson-health-cognitive-services/whcs-service-clinical-data-annotator-operator.git failed"
  exit 1
fi


echo "Setup ibmcloud command-line environment"
if [ "${CLUSTER}" == "iks-reg" ]; then
  echo "${WHCS_IBM_CLOUD_TOKEN}" > whcs-dev-tools/setup-ibmcloud/secrets/cluster_vdt.txt
  bash whcs-dev-tools/setup-ibmcloud/bash/ic_cluster_${CLUSTER}_setup.sh
<< comment
elif [ "${CLUSTER}" == "az-reg" ]; then
  echo "${WHCS_IBM_CLOUD_TOKEN}" > whcs-dev-tools/setup-ibmcloud/secrets/cluster_az-reg.txt
  sudo sh -c 'echo "127.0.0.1 console-openshift-console.apps.oe6v86dg.eastus.aroapp.io" >> /etc/hosts'
  sudo sh -c 'echo "127.0.0.1 oauth-openshift.apps.oe6v86dg.eastus.aroapp.io" >> /etc/hosts'
  sudo sh -c 'echo "127.0.0.1 api.oe6v86dg.eastus.aroapp.io" >> /etc/hosts'
  sudo sh -c 'ssh -N -4 -i /home/jenkins/.ssh/id_rsa \
      -o StrictHostKeyChecking=no \
      -L 443:console-openshift-console.apps.oe6v86dg.eastus.aroapp.io:443 \
      -L 5901:127.0.0.1:5901 \
      -L 6443:api.oe6v86dg.eastus.aroapp.io:6443 \
      whcsbld@13.92.114.50 &'
  . whcs-dev-tools/setup-ibmcloud/bash/az_cluster_${CLUSTER}_setup.sh
comment
else
  echo "need to check the right cluster"
fi
if [ $? != 0 ]; then
  echo "Setup failed"
  exit 1
fi

echo "Setup namespace"
acd_namespace=ibm-wh-acd-operator-system
acd_serviceaccount=ibm-wh-acd-operator-controller-manager
helm_package_name=whcs-acd

namespaceStatus=$(kubectl get ns ${acd_namespace} -o json | jq .status.phase -r)
if [ $namespaceStatus == "Active" ]
then
    echo "namespace is present"
else
    echo "namespace is not present. so we can create and configure the cluster"
    kubectl create namespace ${acd_namespace} --dry-run=client -o yaml | kubectl apply -f -
    kubectl config set-context $(kubectl config current-context) --namespace ${acd_namespace}
    if [[ ! -z $acd_serviceaccount ]];then
      echo "creating the service account and patch "
      kubectl create serviceaccount  ${acd_serviceaccount} -n ${acd_namespace}
      kubectl patch serviceaccount ${acd_serviceaccount} -n  ${acd_namespace} -p '{"imagePullSecrets": [ {"name": "cp.icr.io"} ]}'
    else 
      echo "service account already exists"
    fi
fi



echo "Prime the api resources, seems to be a bug in retrieving on the kubernetes side in some environments"
retries=0
until kubectl api-resources || (( retries++ >= retries_max )); do
  echo "Git down, trying again"
  sleep 1m
done
if [ $retries -gt $retries_max ]; then
  echo "kubectl api-resources failed"
  exit 1
fi

#install helm 3.2.1 to use application deployment
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 get_helm.sh
./get_helm.sh

#get the helm package name
helm_pack=$(helm ls --namespace ${acd_namespace} | awk '{print $1}')
echo "printing values"
var2=$(echo $helm_pack | awk '{print $2}')

if [[ -z $var ]]; then
  echo "helm package not found"
else
  echo "*********************************** Delete package **********************"
  echo $var2
  helm delete $var2 -n ${acd_namespace}
  helm ls -n ${acd_namespace}
  echo "Helm package deleted"
fi


if [[ -f "/tmp/tls.cfg" ]];
then
  echo "This file exists on your filesystem."
else 
  echo "create the file /tmp/tls.cfg"


  #Generate service certificate
  cat << EOF > /tmp/tls.cfg
  [ req ]
  default_bits       = 2048
  default_keyfile    = key.crt
  distinguished_name = req_distinguished_name
  req_extensions     = v3_req
  prompt = no

  [ req_distinguished_name ]
  commonName             = 'ibm-wh-dal3' #CN=
  organizationalUnitName = 'WH' #OU=
  organizationName       = 'IBM' #O=
  localityName           = 'Dallas' #L=
  stateOrProvinceName    = 'TX' #S=
  countryName            = 'US' #C=

  [ v3_req ]
  subjectAltName = @alt_names
  keyUsage = digitalSignature, keyEncipherment
  extendedKeyUsage = serverAuth

  [ alt_names ] 
  DNS.1 = ibm-wh-dal3
  EOF
fi


if [[ -f "/tmp/tls.key" ]];
then
  echo "This file exists on your filesystem."
else
  #Generating service secret keys
  openssl genrsa -out /tmp/tls.key 2048
fi


if [[ -f "/tmp/tls.key" &  -f "/tmp/tls.cfg" ]];
then
  echo "This file exists on your filesystem."
else
  #Generating service certificate request
  openssl req -new \
      -config /tmp/tls.cfg \
      -key /tmp/tls.key \
      -out /tmp/tls.csr
fi

if [[ -f "/tmp/tls.key" &  -f "/tmp/tls.cfg" & /tmp/tls.csr ]];
then
  echo "Files present."
else 
  #Generating pem certificate
  openssl x509 -req \
      -days 365 \
      -sha256 \
      -extensions v3_req \
      -extfile /tmp/tls.cfg \
      -in /tmp/tls.csr \
      -out /tmp/tls.crt \
      -signkey /tmp/tls.key
fi
   
if [[ ! -f "/tmp/tls.key" || ! -f "/tmp/tls.cfg" || ! -f "/tmp/tls.csr" ]];
then
  echo "Need to Certificate Files present."
else 
  kubectl create secret generic ibm-wh-acd-acd-certs-keystore     --namespace ${acd_namespace}    --from-file=/tmp/tls.crt     --from-file=/tmp/tls.key
  kubectl create secret generic ibm-wh-acd-aci-certs-keystore     --namespace ${acd_namespace}    --from-file=/tmp/tls.crt     --from-file=/tmp/tls.key      
  kubectl create secret generic ibm-wh-acd-av-certs-keystore     --namespace ${acd_namespace}     --from-file=/tmp/tls.crt     --from-file=/tmp/tls.key              
  kubectl create secret generic ibm-wh-acd-cd-certs-keystore     --namespace ${acd_namespace}     --from-file=/tmp/tls.crt     --from-file=/tmp/tls.key              
  kubectl create secret generic ibm-wh-acd-cds-certs-keystore     --namespace ${acd_namespace}     --from-file=/tmp/tls.crt     --from-file=/tmp/tls.key              
  kubectl create secret generic ibm-wh-acd-cv-certs-keystore     --namespace ${acd_namespace}     --from-file=/tmp/tls.crt     --from-file=/tmp/tls.key              
  kubectl create secret generic ibm-wh-acd-hyp-certs-keystore     --namespace ${acd_namespace}     --from-file=/tmp/tls.crt     --from-file=/tmp/tls.key              
  kubectl create secret generic ibm-wh-acd-mod-certs-keystore     --namespace ${acd_namespace}    --from-file=/tmp/tls.crt     --from-file=/tmp/tls.key              
  kubectl create secret generic ibm-wh-acd-neg-certs-keystore     --namespace ${acd_namespace}     --from-file=/tmp/tls.crt     --from-file=/tmp/tls.key              
  kubectl create secret generic ibm-wh-acd-ont-certs-keystore     --namespace ${acd_namespace}     --from-file=/tmp/tls.crt     --from-file=/tmp/tls.key              
  kubectl create secret generic ibm-wh-acd-spl-certs-keystore     --namespace ${acd_namespace}     --from-file=/tmp/tls.crt     --from-file=/tmp/tls.key              
  kubectl create configmap ibm-wh-acd-certs-truststore-pem     --namespace ${acd_namespace}  --from-file=/tmp/tls.crt
fi


pwd

helm install ${helm_package_name} whcs-service-clinical-data-annotator-operator/helm-charts/ibm-wh-acd-chart --set replicas=1 --set license.accept=true --set configurationStorage.file.persistent=false --namespace ${acd_namespace}
kubectl get all -n ${acd_namespace}

echo "tested kubectl objects"

kubectl patch serviceaccount ibm-wh-acd-operand -n ${acd_namespace} -p '{"imagePullSecrets": [{"name": "cp.icr.io"} ]}'

