#!/bin/bash

CLOUDCASA_NAMESPACE=cloudcasa-io

# Check if the cloudcasa namespace exists.
if ! kubectl get ns $CLOUDCASA_NAMESPACE > /dev/null 2>/dev/null; then
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
	kubectl get all -n $CLOUDCASA_NAMESPACE
	print_header "Velero BackupStorageLocation resources in the $CLOUDCASA_NAMESPACE namespace"
	kubectl get backupstoragelocations -n $CLOUDCASA_NAMESPACE
	print_header "Velero VolumeSnapshotLocation resources in the $CLOUDCASA_NAMESPACE namespace"
	kubectl get volumesnapshotlocations -n $CLOUDCASA_NAMESPACE
	print_header "Velero Backup resources in the $CLOUDCASA_NAMESPACE namespace"
	kubectl get backups -n $CLOUDCASA_NAMESPACE
	print_header "Velero Restore resources in the $CLOUDCASA_NAMESPACE namespace"
	kubectl get restores -n $CLOUDCASA_NAMESPACE
	print_header "Velero DeleteBackupRequests resources in the $CLOUDCASA_NAMESPACE namespace"
	kubectl get deletebackuprequests -n $CLOUDCASA_NAMESPACE
	print_footer "End of resources in the $CLOUDCASA_NAMESPACE namespace"
}

# Describe all resources in the cloudcasa namespace.
function describe_all() {
	print_header "kubectl describe all -n $CLOUDCASA_NAMESPACE"
	kubectl describe all -n $CLOUDCASA_NAMESPACE
	print_header "kubectl describe backupstoragelocations -n $CLOUDCASA_NAMESPACE"
	kubectl describe backupstoragelocations -n $CLOUDCASA_NAMESPACE
	print_header "kubectl describe volumesnapshotlocations -n $CLOUDCASA_NAMESPACE"
	kubectl describe volumesnapshotlocations -n $CLOUDCASA_NAMESPACE
	print_header "kubectl describe backups -n $CLOUDCASA_NAMESPACE"
	kubectl describe backups -n $CLOUDCASA_NAMESPACE
	print_header "kubectl describe restores -n $CLOUDCASA_NAMESPACE"
	kubectl describe restores -n $CLOUDCASA_NAMESPACE
	print_header "kubectl describe deletebackuprequests -n $CLOUDCASA_NAMESPACE"
	kubectl describe deletebackuprequests -n $CLOUDCASA_NAMESPACE
	print_footer "End of output"
}

# Saves logs from kubeagent manager pod.
function get_kubeagent_manager_pod_logs() {
	print_header "Start of Kubeagent manager logs"
	kubectl logs -n $CLOUDCASA_NAMESPACE "$KAGENT_MANAGER_POD"
	print_footer "End of Kubeagent manager logs"
}

# Saves logs from kubeagent pod (kubeagent and Velero containers).
function get_kubeagent_pod_logs() {
	print_header "Start of Kubeagent logs"
	kubectl logs -n $CLOUDCASA_NAMESPACE "$KAGENT_POD" kubeagent
	print_footer "End of Kubeagent logs"

	print_header "Start of Velero logs"
	kubectl logs -n $CLOUDCASA_NAMESPACE "$KAGENT_POD" kubeagent-backup-helper
	print_footer "End of Velero logs"
}

get_resources

# Get kubeagent manager logs only if the pod is in a running state.
KAGENT_MANAGER_POD=$(kubectl get pods -n $CLOUDCASA_NAMESPACE 2>/dev/null | awk '/^cloudcasa-kubeagent-manager-/ {print $1}')
if [ ! "$KAGENT_MANAGER_POD" == "" ]; then
	get_kubeagent_manager_pod_logs
fi

# Get kubeagent logs only if the pod is in a running state.
KAGENT_POD=$(kubectl get pods -n $CLOUDCASA_NAMESPACE 2>/dev/null | awk '/^kubeagent-/ {print $1}')
if [ ! "$KAGENT_POD" == "" ]; then
	get_kubeagent_pod_logs
fi

function get_kubemover_logs() {
	PODS=$(kubectl get pods -n $CLOUDCASA_NAMESPACE | awk 'NR > 1 {print $1}')
	MOVER_PODS=$(kubectl get pods -n $CLOUDCASA_NAMESPACE 2>/dev/null | awk '/^kubemover/ {print $1}')
	for pod in $MOVER_PODS
	do
		print_header "Start of $pod logs"
		kubectl logs -n $CLOUDCASA_NAMESPACE "$pod"
		print_footer "End of $pod logs"
	done
}

get_kubemover_logs
describe_all
