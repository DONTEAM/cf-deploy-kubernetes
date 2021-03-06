#!/bin/bash

fatal() {
   echo "ERROR: $1"
   exit 1
}

readonly KUBECTL_ACTION=${KUBECTL_ACTION:-apply}
[[ $KUBECTL_ACTION =~ ^(apply|create|replace)$ ]] || fatal "KUBECTL_ACTION should be one of apply|create|replace "

deployment_file=${1:-deployment.yml}
: ${KUBERNETES_NAMESPACE:=default}
: ${KUBERNETES_DEPLOYMENT_TIMEOUT:=120}


if [[ -n "$KUBERNETES_SERVER" && -n "$KUBERNETES_USER" && -n "$KUBERNETES_PASSWORD" ]]; then
    unset KUBECONFIG

    echo "---> Setting up Kubernetes credentials..."
    kubectl config set-credentials deployer --username=$KUBERNETES_USER --password=$KUBERNETES_PASSWORD
    kubectl config set-cluster foo.kubernetes.com --insecure-skip-tls-verify=true --server=$KUBERNETES_SERVER
    kubectl config set-context foo.kubernetes.com/deployer --user=deployer --namespace=$KUBERNETES_NAMESPACE --cluster=foo.kubernetes.com
    kubectl config use-context foo.kubernetes.com/deployer

    KUBECONTEXT=foo.kubernetes.com/deployer
else
    if [[ -z "${KUBECONTEXT}" ]]; then
        KUBECONTEXT=$(kubectl config current-context)
         If KUBECONFIG is set we obligate to set KUBECONTEXT to valid context name
        if [[ -n "${KUBECONFIG}" ]]; then
          echo -e "--- ERROR - KUBECONTEXT Environment variable is not set, please set it to one of integrated contexts: "
          kubectl config get-contexts
          fatal "KUBECONTEXT is not set "
        else
           KUBECONTEXT=$(kubectl config current-context)
        fi
    fi
fi

#check the cluster version and decide which version of kubectl to use:
SERVER_VERSION=$(kubectl version --short=true | grep -i server | cut -c18-20 | tr -d .)

if (( "$SERVER_VERSION" <= "16" )); then mv /usr/local/bin/kubectl1.6 /usr/local/bin/kubectl; fi


[ ! -f "${deployment_file}" ] && echo "Couldn't find $deployment_file file at $(pwd)" && exit 1;


DEPLOYMENT_FILE=${deployment_file}-$(date '+%y-%m-%d_%H-%M-%S').yml
$(dirname $0)/template.sh "$deployment_file" > "$DEPLOYMENT_FILE" || fatal "Failed to apply deployment template on $deployment_file"


echo "---> Kubernetes objects to deploy in  $deployment_file :"
KUBECTL_OBJECTS=/tmp/deployment.objects
kubectl convert -f "$DEPLOYMENT_FILE" --local=true --no-headers=true -o=custom-columns="KIND:{.kind},NAME:{.metadata.name}" > >(tee $KUBECTL_OBJECTS) 2>${KUBECTL_OBJECTS}.errors
if [ $? != 0 ]; then
   cat ${KUBECTL_OBJECTS}.errors
   fatal "Failed to parse $deployment_file "
fi

DEPLOYMENT_NAME=$(awk '/^Deployment /{a=$2}END{print a}' $KUBECTL_OBJECTS)

echo "---> Submitting a deployment to Kubernetes by
   kubectl --context "${KUBECONTEXT}" --namespace "${KUBERNETES_NAMESPACE}" $KUBECTL_ACTION "
kubectl --context "${KUBECONTEXT}" --namespace "${KUBERNETES_NAMESPACE}" $KUBECTL_ACTION -f "$DEPLOYMENT_FILE" || fatal "Deployment submitting Failed"

if [ -n "$DEPLOYMENT_NAME" ]; then
    echo "---> Waiting for a successful deployment/${DEPLOYMENT_NAME} status to namespace ${KUBERNETES_NAMESPACE} ..."
    timeout -s SIGTERM -t $KUBERNETES_DEPLOYMENT_TIMEOUT kubectl --context "${KUBECONTEXT}" --namespace "${KUBERNETES_NAMESPACE}" rollout status deployment/"${DEPLOYMENT_NAME}" || fatal "Deployment Failed"
fi
