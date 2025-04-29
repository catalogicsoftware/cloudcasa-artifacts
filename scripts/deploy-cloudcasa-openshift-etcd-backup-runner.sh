#!/bin/bash
set -euo pipefail

# === Default Configuration ===
NAMESPACE="cloudcasa-openshift-etcd-backup"
DEPLOYMENT_NAME="cloudcasa-etcd-backup-runner"
CONFIGMAP_NAME="cloudcasa-etcd-backup-script"
LABEL_KEY="cloudcasa/openshift-etcd-backup"
LABEL_VALUE="enabled"
LABEL_SELECTOR="$LABEL_KEY=$LABEL_VALUE"
CONTAINER_NAME="cloudcasa-etcd-backup-runner"
SCRIPT_NAME="/cloudcasa-etcd-backup.sh"

# --- PVC Defaults (can be overridden by options) ---
DEFAULT_PVC_NAME="cloudcasa-etcd-backup-pvc" # Default name
DEFAULT_PVC_SC="ocs-storagecluster-cephfs" # Example default, adjust if needed
DEFAULT_PVC_SIZE_MB=5120 # 5Gi in Megabytes
DEFAULT_PVC_ACCESS_MODE="ReadWriteOnce"

# Initialize variables with defaults
pvc_name="$DEFAULT_PVC_NAME" # Use the default name initially
pvc_sc="$DEFAULT_PVC_SC"
pvc_size_mb="$DEFAULT_PVC_SIZE_MB"
pvc_access_mode="$DEFAULT_PVC_ACCESS_MODE"

# === Functions ===
usage() {
  echo "Usage: $0 [OPTIONS]"
  echo ""
  echo "Deploys resources for CloudCasa OpenShift etcd backup."
  echo ""
  echo "Options:"
  echo "  --pvc-name <name>           Specify the name for the backup PersistentVolumeClaim."
  echo "                              (Default: '$DEFAULT_PVC_NAME')"
  echo "  --pvc-sc <storage_class>    Specify the StorageClass for the backup PVC."
  echo "                              (Default: '$DEFAULT_PVC_SC')"
  echo "  --pvc-size-mb <size_mb>     Specify the size of the backup PVC in Megabytes (MiB)."
  echo "                              (Default: $DEFAULT_PVC_SIZE_MB MiB)"
  echo "  --pvc-access-mode <mode>    Specify the access mode for the backup PVC (e.g., ReadWriteOnce, ReadWriteMany)."
  echo "                              (Default: '$DEFAULT_PVC_ACCESS_MODE')"
  echo "  -h, --help                  Display this help message and exit."
  echo ""
  echo "Example:"
  echo "  $0 --pvc-name etcd-vol --pvc-sc gp2 --pvc-size-mb 10240 --pvc-access-mode ReadWriteOnce"
}

# === Option Parsing (using getopt) ===
TEMP=$(getopt -o h \
              --long help,pvc-name:,pvc-sc:,pvc-size-mb:,pvc-access-mode: \
              -n "$0" -- "$@")

if [ $? != 0 ]; then
  echo "Terminating..." >&2
  usage
  exit 1
fi

eval set -- "$TEMP"
unset TEMP

while true; do
  case "$1" in
    --pvc-name)
      pvc_name="$2"
      shift 2
      ;;
    --pvc-sc)
      pvc_sc="$2"
      shift 2
      ;;
    --pvc-size-mb)
      if ! [[ "$2" =~ ^[0-9]+$ ]]; then
         echo "Error: --pvc-size-mb requires a numeric argument." >&2
         usage
         exit 1
      fi
      pvc_size_mb="$2"
      shift 2
      ;;
    --pvc-access-mode)
      case "$2" in
          ReadWriteOnce|ReadWriteMany|ReadWriteOncePod)
              pvc_access_mode="$2"
              ;;
          *)
              echo "Error: Invalid --pvc-access-mode '$2'. Use standard modes like ReadWriteOnce, ReadWriteMany, etc." >&2
              usage
              exit 1
              ;;
      esac
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    *)
      echo "Internal error! Unexpected argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ $# -gt 0 ]]; then
    echo "Error: Unexpected arguments: $@" >&2
    usage
    exit 1
fi

# === Exit Trap ===
trap 'EXIT_CODE=$?
if [[ $EXIT_CODE -ne 0 ]]; then
  echo ""
  echo "Script exited with error (exit code: $EXIT_CODE)"
else
  echo ""
  echo "Script completed successfully"
fi
' EXIT

# === Script Logic ===
echo ""
echo "This script will perform the following using these settings:"
echo ""
echo "  Namespace:         $NAMESPACE"
echo "  Deployment:        $DEPLOYMENT_NAME"
echo "  ConfigMap:         $CONFIGMAP_NAME"
echo "  PVC Name:          $pvc_name"
echo "  PVC Size:          ${pvc_size_mb}Mi"
echo "  PVC StorageClass:  $pvc_sc"
echo "  PVC Access Mode:   $pvc_access_mode"
echo "  Deployment Label:  $LABEL_SELECTOR"
echo ""
echo "Detailed steps:"
echo "1. Create the namespace: $NAMESPACE"
echo "2. Create a ConfigMap named: $CONFIGMAP_NAME with the embedded etcd backup script"
echo "3. Create a PVC named: $pvc_name with specified settings" # Updated text
echo "4. Deploy a Deployment named: $DEPLOYMENT_NAME referencing PVC '$pvc_name'" # Updated text
echo "5. Assign the 'privileged' SCC to the default service account in the namespace"
echo "6. Label the Deployment and its pods with: $LABEL_SELECTOR"

echo ""
read -p "Do you want to proceed with these changes? (y/N): " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
  echo "Aborted by user."
  exit 1
fi

echo ""
echo "Please make sure:"
echo "- You have the 'oc' command installed"
echo "- You are logged into the OpenShift cluster using 'oc login'"
echo ""
read -p "Have you confirmed the above requirements? (y/N): " ready
if [[ "$ready" != "y" && "$ready" != "Y" ]]; then
  echo "Aborted due to missing prerequisites."
  exit 1
fi

echo ""
echo "Creating namespace..."
oc create ns $NAMESPACE --dry-run=client -o yaml | oc apply -f -
echo ""
echo "Creating ConfigMap with embedded script..."
oc -n $NAMESPACE create configmap $CONFIGMAP_NAME \
  --from-literal=cloudcasa-etcd-backup.sh="$(cat <<'EOF'
#!/bin/bash
set -euo pipefail
echo "[HOOK] STARTING ETCD BACKUP HOOK"

# === CONFIGURATION ===
HOST_BACKUP_DIR="/home/core/cc-etcd-backup"
PVC_BACKUP_DIR="/pvc-backup/cc-etcd-backup"

SENTINEL_FILENAME="finished"
SENTINEL_FILE_PATH="${HOST_BACKUP_DIR}/${SENTINEL_FILENAME}"
HOST_SENTINEL_FILE_PATH="/host${HOST_BACKUP_DIR}/${SENTINEL_FILENAME}"
PVC_BACKUP_SENTINEL_FILE_PATH="${PVC_BACKUP_DIR}/${SENTINEL_FILENAME}"

COPY_SENTINEL_FILENAME="copy-finished"
PVC_BACKUP_COPY_SENTINEL_FILE_PATH="${PVC_BACKUP_DIR}/${COPY_SENTINEL_FILENAME}"

trap 'EXIT_CODE=$?; if [[ $EXIT_CODE -ne 0 ]]; then
    echo "[HOOK] Cleanup on failure (exit code: $EXIT_CODE)"
    rm -f "${HOST_SENTINEL_FILE_PATH}" "${PVC_BACKUP_COPY_SENTINEL_FILE_PATH}"
fi' EXIT


# === Step 1: Prepare environment ===
echo "[HOOK] Preparing backup environment..."
# Create host backup dir inside chroot (if needed)
chroot /host /bin/mkdir -p "${HOST_BACKUP_DIR}"
# Create target PVC dir (in container context)
mkdir -p "${PVC_BACKUP_DIR}"
# Clean up any old sentinel files
rm -rf "/host${HOST_BACKUP_DIR}" "${PVC_BACKUP_DIR}"

# === Step 2: Start backup inside chroot (in background) ===
echo "[HOOK] Running cluster-backup.sh in chroot"
chroot /host /bin/bash -c "/usr/local/bin/cluster-backup.sh '${HOST_BACKUP_DIR}' && touch '${SENTINEL_FILE_PATH}'"

# === Step 3: Wait for backup to complete ===
echo "[HOOK] Waiting for etcd backup to complete..."
while [[ ! -f "${HOST_SENTINEL_FILE_PATH}" ]]; do
    echo "[HOOK] Waiting for backup sentinel: ${HOST_SENTINEL_FILE_PATH}"
    sleep 2
done
echo "[HOOK] Etcd backup complete"

# === Step 4: Copy backup files and create copy sentinel ===
echo "[HOOK] Copying backup files to PVC..."
cp -a "/host${HOST_BACKUP_DIR}/." "${PVC_BACKUP_DIR}/" && touch "${PVC_BACKUP_COPY_SENTINEL_FILE_PATH}"

# === Step 5: Wait for copy sentinel ===
echo "[HOOK] Waiting for copy to complete..."
while [[ ! -f "${PVC_BACKUP_COPY_SENTINEL_FILE_PATH}" ]]; do
    echo "[HOOK] Waiting for copy sentinel: ${PVC_BACKUP_COPY_SENTINEL_FILE_PATH}"
    sleep 2
done
echo "[HOOK] Copy to PVC complete"

# === Step 6: Validate backup files ===
SNAPSHOT_FILE=$(find "${PVC_BACKUP_DIR}" -maxdepth 1 -type f -name "snapshot_*.db" | sort | tail -n1)
TAR_FILE=$(find "${PVC_BACKUP_DIR}" -maxdepth 1 -type f -name "static_kuberesources_*.tar.gz" | sort | tail -n1)

for file in "$SNAPSHOT_FILE" "$TAR_FILE"; do
    if [[ -z "$file" || ! -s "$file" ]]; then
        echo "[HOOK] ERROR: Copied file $file is missing or empty!" >&2
        exit 1
    fi
    echo "[HOOK] Verified: $(basename "$file") is $(stat -c%s "$file") bytes"
done

# === Step 7: Cleanup backup dir from host and sentinels ===
echo "[HOOK] Cleaning up backup directory from host..."
rm -rf "${HOST_BACKUP_DIR}"

echo "[HOOK] Cleaning up sentinel files..."
rm -f "${PVC_BACKUP_COPY_SENTINEL_FILE_PATH}" "${PVC_BACKUP_SENTINEL_FILE_PATH}"

echo "[HOOK] ETCD BACKUP HOOK COMPLETE"
EOF
)" --dry-run=client -o yaml | oc apply -f -

echo ""
echo "Creating PVC for backup storage with specified settings..."

oc -n $NAMESPACE apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $pvc_name # Use the variable for PVC name
spec:
  accessModes:
    - $pvc_access_mode
  resources:
    requests:
      storage: ${pvc_size_mb}Mi
  storageClassName: $pvc_sc
EOF

echo ""
read -p "Do you authorize assigning the 'privileged' SCC to the default service account in namespace '${NAMESPACE}'? (y/N): " scc_confirm
if [[ "$scc_confirm" == "y" || "$scc_confirm" == "Y" ]]; then
  echo "Assigning SCC..."
  oc adm policy add-scc-to-user privileged -z default -n ${NAMESPACE}
  echo "SCC assignment complete."
else
  echo "Skipping SCC assignment."
fi

echo ""
echo "Creating Deployment..."
oc -n $NAMESPACE apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${DEPLOYMENT_NAME} # Can use variables here too if needed
  labels:
    ${LABEL_KEY}: "${LABEL_VALUE}"
spec:
  replicas: 1
  selector:
    matchLabels:
      app: cloudcasa-etcd-backup-runner
  template:
    metadata:
      labels:
        app: cloudcasa-etcd-backup-runner
        ${LABEL_KEY}: "${LABEL_VALUE}"
    spec:
      nodeSelector:
        'node-role.kubernetes.io/control-plane': ""
      hostPID: true
      hostIPC: true
      hostNetwork: true
      tolerations:
      - key: "node-role.kubernetes.io/master"
        operator: "Exists"
        effect: "NoSchedule"
      containers:
      - name: ${CONTAINER_NAME} # Variable used
        image: registry.access.redhat.com/ubi8/ubi
        command: ["/bin/sh", "-c"]
        args:
          - "sh ${SCRIPT_NAME}; sleep 3600" # Variable used
        securityContext:
          privileged: true
          allowPrivilegeEscalation: true
          runAsUser: 0
          seccompProfile:
            type: RuntimeDefault
        volumeMounts:
        - name: host-root
          mountPath: /host
          mountPropagation: HostToContainer
        - name: pvc-backup # This name is internal to the Pod spec
          mountPath: /pvc-backup
        - name: trigger-script # This name is internal to the Pod spec
          mountPath: ${SCRIPT_NAME} # Variable used
          subPath: cloudcasa-etcd-backup.sh # This must match the key in the ConfigMap
      volumes:
      - name: host-root
        hostPath:
          path: /
      - name: pvc-backup # This volume name must match the volumeMount name above
        persistentVolumeClaim:
          claimName: ${pvc_name} # *** Use the variable for the PVC name ***
      - name: trigger-script # This volume name must match the volumeMount name above
        configMap:
          name: ${CONFIGMAP_NAME} # Variable used
          # Ensure defaultMode is set if needed, e.g., for execute permissions
          # defaultMode: 0755
EOF

echo ""
echo "Deployment '$DEPLOYMENT_NAME' has been created in namespace '$NAMESPACE'. Waiting for Deployment to become Ready..."
oc -n $NAMESPACE rollout status deployment/$DEPLOYMENT_NAME --timeout=600s
echo ""
echo "---"
echo ""
echo "Next steps:"
echo ""
echo "1. In CloudCasa, define a backup that includes the namespace: $NAMESPACE"
echo "2. Add a pre-backup hook with the following details:"
echo ""
echo "   - Namespace: $NAMESPACE"
echo "   - Container: $CONTAINER_NAME"
echo "   - Pod selector: app=cloudcasa-etcd-backup-runner"
echo "   - Hook command: /bin/sh -c ". $SCRIPT_NAME""
echo ""
echo "===================================================="
echo "CloudCasa OpenShift etcd backup agent is now set up."
echo "===================================================="
echo ""
