#!/bin/bash

CLOUDCASA_NAMESPACE=cloudcasa-io

# The command that talks to the cluster. Set KUBECTL to use another one, for
# example KUBECTL=oc on OpenShift. Unset, it is kubectl, or oc when only oc is
# installed.
if [ -z "$KUBECTL" ]; then
	KUBECTL=kubectl
	if ! command -v $KUBECTL > /dev/null 2>&1 && command -v oc > /dev/null 2>&1; then
		KUBECTL=oc
	fi
fi
if ! command -v ${KUBECTL%% *} > /dev/null 2>&1; then
	echo "$KUBECTL is not installed"
	exit 0
fi

# Check if the cloudcasa namespace exists.
if ! $KUBECTL get ns $CLOUDCASA_NAMESPACE > /dev/null 2>/dev/null; then
	echo "$CLOUDCASA_NAMESPACE namespace does not exist"
	exit 0
fi

function print_header() {
	echo
	echo "############ $1 ############"
}

function print_footer() {
	echo "############ $1 ############"
}

# Get all resources from the cloudcasa namespace.
function get_resources() {
	print_header "Resources in the $CLOUDCASA_NAMESPACE namespace"
	$KUBECTL get all -n $CLOUDCASA_NAMESPACE
	print_header "Velero BackupStorageLocation resources in the $CLOUDCASA_NAMESPACE namespace"
	$KUBECTL get backupstoragelocations -n $CLOUDCASA_NAMESPACE
	print_header "Velero VolumeSnapshotLocation resources in the $CLOUDCASA_NAMESPACE namespace"
	$KUBECTL get volumesnapshotlocations -n $CLOUDCASA_NAMESPACE
	print_header "Velero Backup resources in the $CLOUDCASA_NAMESPACE namespace"
	$KUBECTL get backups -n $CLOUDCASA_NAMESPACE
	print_header "Velero Restore resources in the $CLOUDCASA_NAMESPACE namespace"
	$KUBECTL get restores -n $CLOUDCASA_NAMESPACE
	print_header "Velero DeleteBackupRequests resources in the $CLOUDCASA_NAMESPACE namespace"
	$KUBECTL get deletebackuprequests -n $CLOUDCASA_NAMESPACE
	print_header "VolumeSnapshot resources"
	$KUBECTL get volumesnapshots -A -o json
	print_header "VolumeSnapshot resources - End"
	print_header "VolumeSnapshotContent resources"
	$KUBECTL get volumesnapshotcontents -o json
	print_header "VolumeSnapshotContent resources - End"
	print_header "PVC resources in the $CLOUDCASA_NAMESPACE namespace"
	$KUBECTL get pvc -n $CLOUDCASA_NAMESPACE -o json
	print_header "PVC resources in the $CLOUDCASA_NAMESPACE namespace - End"
    print_header "Configmap resources in the $CLOUDCASA_NAMESPACE namespace"
    $KUBECTL get cm -n $CLOUDCASA_NAMESPACE -o json
    print_header "Configmap resources in the $CLOUDCASA_NAMESPACE namespace - End"
	print_footer "End of resources in the $CLOUDCASA_NAMESPACE namespace and others"
}

# Describe all resources in the cloudcasa namespace.
function describe_all() {
	print_header "kubectl describe all -n $CLOUDCASA_NAMESPACE"
	$KUBECTL describe all -n $CLOUDCASA_NAMESPACE
	print_header "kubectl describe backupstoragelocations -n $CLOUDCASA_NAMESPACE"
	$KUBECTL describe backupstoragelocations -n $CLOUDCASA_NAMESPACE
	print_header "kubectl describe volumesnapshotlocations -n $CLOUDCASA_NAMESPACE"
	$KUBECTL describe volumesnapshotlocations -n $CLOUDCASA_NAMESPACE
	print_header "kubectl describe backups -n $CLOUDCASA_NAMESPACE"
	$KUBECTL describe backups -n $CLOUDCASA_NAMESPACE
	print_header "kubectl describe restores -n $CLOUDCASA_NAMESPACE"
	$KUBECTL describe restores -n $CLOUDCASA_NAMESPACE
	print_header "kubectl describe deletebackuprequests -n $CLOUDCASA_NAMESPACE"
	$KUBECTL describe deletebackuprequests -n $CLOUDCASA_NAMESPACE
	print_footer "End of output"
}

# Saves logs from kubeagent manager pod.
function get_kubeagent_manager_pod_logs() {
	print_header "Start of Kubeagent manager logs"
	$KUBECTL logs -n $CLOUDCASA_NAMESPACE "$KAGENT_MANAGER_POD"
	print_footer "End of Kubeagent manager logs"

	print_header "Start of Kubeagent manager prev logs"
	$KUBECTL logs -p -n $CLOUDCASA_NAMESPACE "$KAGENT_MANAGER_POD"
	print_footer "End of Kubeagent manager prev logs"
}

# Saves logs from kubeagent pod (kubeagent and Velero containers).
function get_kubeagent_pod_logs() {
	print_header "Start of Kubeagent prev logs"
	$KUBECTL logs -p -n $CLOUDCASA_NAMESPACE "$KAGENT_POD" kubeagent
	print_footer "End of Kubeagent prev logs"

	print_header "Start of Kubeagent logs"
	$KUBECTL logs -n $CLOUDCASA_NAMESPACE "$KAGENT_POD" kubeagent
	print_footer "End of Kubeagent logs"

	if ! $KUBECTL get pod -n $CLOUDCASA_NAMESPACE "$KAGENT_POD" -o jsonpath='{.spec.containers[*].name}' | grep -qw kubeagent-backup-helper; then
		get_helper_pod_logs
		return
	fi

	print_header "Start of Velero prev logs"
	$KUBECTL logs -p -n $CLOUDCASA_NAMESPACE "$KAGENT_POD" kubeagent-backup-helper
	print_footer "End of Velero prev logs"

	print_header "Start of Velero logs"
	$KUBECTL logs -n $CLOUDCASA_NAMESPACE "$KAGENT_POD" kubeagent-backup-helper
	print_footer "End of Velero logs"
}

# Newer agents run Velero in a helper pod per job, not in the kubeagent pod.
# Their logs go under the same Velero headers, so log parsers still work.
function get_helper_pod_logs() {
	HELPER_PODS=$($KUBECTL get pods -n $CLOUDCASA_NAMESPACE -l app.kubernetes.io/component=cloudcasa-job-helper -o name 2>/dev/null)

	print_header "Start of Velero prev logs"
	for pod in $HELPER_PODS
	do
		echo "------------ $pod ------------"
		$KUBECTL logs -p -n $CLOUDCASA_NAMESPACE "$pod" cc-helper
	done
	print_footer "End of Velero prev logs"

	print_header "Start of Velero logs"
	echo "A helper pod is deleted when its job ends. For a finished job, see <op>.cc-helper-<job ID>.cc-helper.log.gz in the logs of that job."
	for pod in $HELPER_PODS
	do
		echo "------------ $pod ------------"
		$KUBECTL logs -n $CLOUDCASA_NAMESPACE "$pod" cc-helper
	done
	print_footer "End of Velero logs"
}

# Objects that newer agents create to mount an NFS/SMB file store directly.
# Only secret names are listed, never their data.
function get_filestore_resources() {
	print_header "File store PVs"
	$KUBECTL get pv -l filestore-manager.cloudcasa.io/cache-key -o yaml
	print_header "Restore mover pods, PVCs and PVs in all namespaces"
	$KUBECTL get pods,pvc -A -l cloudcasa-io-data-mover -o wide
	$KUBECTL get pv -l cloudcasa-io-data-mover -o wide
	print_header "Secrets in the $CLOUDCASA_NAMESPACE namespace"
	$KUBECTL get secrets -n $CLOUDCASA_NAMESPACE
	print_header "NetworkPolicies in the $CLOUDCASA_NAMESPACE namespace"
	$KUBECTL get networkpolicies -n $CLOUDCASA_NAMESPACE
	print_footer "End of file store resources"
}

get_resources

# Get kubeagent manager logs only if the pod is in a running state.
KAGENT_MANAGER_POD=$($KUBECTL get pods -n $CLOUDCASA_NAMESPACE 2>/dev/null | awk '/^cloudcasa-kubeagent-manager-/ {print $1}')
if [ ! "$KAGENT_MANAGER_POD" == "" ]; then
	get_kubeagent_manager_pod_logs
fi

# Get kubeagent logs only if the pod is in a running state.
KAGENT_POD=$($KUBECTL get pods -n $CLOUDCASA_NAMESPACE 2>/dev/null | awk '/^kubeagent-/ {print $1}')
if [ ! "$KAGENT_POD" == "" ]; then
	get_kubeagent_pod_logs
fi

function get_kubemover_logs() {
	PODS=$($KUBECTL get pods -n $CLOUDCASA_NAMESPACE | awk 'NR > 1 {print $1}')
	MOVER_PODS=$($KUBECTL get pods -n $CLOUDCASA_NAMESPACE 2>/dev/null | awk '/^kubemover/ {print $1}')
	for pod in $MOVER_PODS
	do
		print_header "Start of $pod logs"
		$KUBECTL logs -n $CLOUDCASA_NAMESPACE "$pod"
		print_footer "End of $pod logs"
	done
}

get_kubemover_logs
get_filestore_resources
describe_all
