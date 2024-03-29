###############################################
# Copyright 2022 Catalogic Software Inc.   ####
###############################################

#!/usr/bin/env bash

SCRIPT_VERSION=0.66
echo "Version: $SCRIPT_VERSION"

# Initialize all the associative array variables with global scope
declare -A PROVISIONER
declare -A IF_CSI_DRIVER
declare -A RESULTS
declare -a csidrivers
declare -a storageclasses
declare -a CRDS

export NS='csi-setup-test'
export PD=`pwd`
retries=$TTC
div='------------------------------'
divider="$div$div$div$div"
headdiv="=============================="
headdivider="$headdiv$headdiv$headdiv$headdiv"
width=60
TTC=20
TIMEOUT=5
CRDS=("volumesnapshotclasses.snapshot.storage.k8s.io:apiextensions.k8s.io/v1" "volumesnapshotcontents.snapshot.storage.k8s.io:apiextensions.k8s.io/v1" "volumesnapshots.snapshot.storage.k8s.io:apiextensions.k8s.io/v1")
[ -z $CC_CSI_CHECK_BUSYBOX_IMAGE ] && { IMAGE='busybox'; } || { IMAGE=$CC_CSI_CHECK_BUSYBOX_IMAGE; }
KUBEPATH=


help_()
{
echo "SYNOPSIS"
echo "	cc-validate-storage.sh  [ Options ]"
echo "DESCRIPTION"
echo "	Script to verify that the CSI configuration on a given cluster is good."
echo "	The script creates Pods using busybox image from Dockerhub. If your cluster cannot access Dockerhub, please copy the image <IMAGE> to a locally accessible registry and set the environment variable"
echo "	CC_CSI_CHECK_BUSYBOX_IMAGE to the <image name> with proper tags."
echo "OPTIONS"
echo "	-h, --help"
echo "		For usage info"
echo "	-c, --cleanup"
echo "		Only clean up the test namespace. This is normally done automatically before exiting."
echo "  -C, --collectlogs"
echo "      Collects details of all resources created by the script. Typically used if there is any problem with cleanup."
echo "	-i, --image"
echo "		For specifying a custom busybox image explicitly, This option is useful when public busybox image is not accessible and you have a busybox image with other tag in your private registry."
echo "		User needs to login to the private registry and verify. The argument provided in this flag will overwrite the env variable CC_CSI_CHECK_BUSYBOX_IMAGE."
echo "	-R, --retry"
echo "		Provide this flag to run the script with custom retry count, this flag will change the retry count for resource status, by default it is set to 20"
echo "	-T, --timeout"
echo "		Provide this flag to run the script with custom retry timeout between consecutive retrials on resource status, by default it is set to 5 sec"
echo "EXAMPLES"
echo "	./cc-validate-storage.sh"
echo "	./cc-validate-storage.sh  -h"
echo "	./cc-validate-storage.sh  --help"
echo "	./cc-validate-storage.sh  -C"
echo "	./cc-validate-storage.sh  --collectlogs"
echo
echo
exit 0
}


PATH_TO_YAML_FILES=$HOME/tmp/test_dir
[[ -d $PATH_TO_YAML_FILES ]] || { mkdir -p $PATH_TO_YAML_FILES; }
echo "" > $PATH_TO_YAML_FILES/cc-validate-storage.debug.txt

initial_check()
{
	printf "$headdivider\n"
	SUPPMAJORV=1
	SUPPMINORV=20
        KUBEPATH=`which kubectl`
        [[ -z $KUBEPATH ]] && { echo 'The kubectl binary was not found. Please update you PATH variable with the location of kubectl.'; exit 1; }
        KVMAJOR=`kubectl version -o yaml 2> /dev/null | grep 'major' | tail -1 | cut -d ':' -f2 | xargs | cut -d '+' -f1`
        KVMINOR=`kubectl version -o yaml 2> /dev/null | grep 'minor' | tail -1 | cut -d ':' -f2 | xargs | cut -d '+' -f1`
	[[ $KVMAJOR -ge $SUPPMAJORV && $KVMINOR -ge $KVMINOR ]] || { echo >&2 "WARNING: Please upgrade your K8S cluster version to >= $SUPPMAJORV.$SUPPMINORV"; }
        echo "Your Cluster is running Kubernetes version: $KVMAJOR.$KVMINOR"
        echo "Env:"
        echo "CC_CSI_CHECK_BUSYBOX_IMAGE = $CC_CSI_CHECK_BUSYBOX_IMAGE"
        echo "KUBECTL PATH = $KUBEPATH"
	echo "KUBECONFIG = $KUBECONFIG"
	printf "$headdivider\n"
	echo
	echo
}
initial_check

prompt_user()
{
	printf "$headdivider\n"
	echo "The Script will perform the following actions in your cluster:"
	echo "  - Check the available csidrivers installed."
	echo "  - Find the storage classes and their provisioners."
	echo "  - Find storage classes whose provisioners can be mapped to CSI drivers and volume snapshot classes."
	echo "  - For each such storage class: "
	echo "    - 1. Create a PVC and POD in csi-setup-test namespace."
	echo "    - 2. Create a snapshot with all available volumesnapshotclasses for the storage class."
    echo
    echo "After the test, the script will delete all the resources it created for the test. "
	echo
    echo "The script uses the busybox image from Dockerhub to create pods. If the cluster cannot access"
    echo "Dockerhub, copy the busybox image to a locally accessible registry and set the env variable"
    echo "CC_CSI_CHECK_BUSYBOX_IMAGE to the local image."
	echo

	printf "Press y/yes to Continue and n/no to exit: "

    # Without explicitly reading from terminal, we cannot pipe the script to "bash" as follows:
    #   $ curl https://raw.githubusercontent.com/catalogicsoftware/cloudcasa-artifacts/master/scripts/cc-validate-storage.sh | bash -
    # Without "</dev/tty", "read" will read from STDIN and will not give chance to user to answer
    # the prompt.
	read CHOICE < /dev/tty

	case $CHOICE in
		'Y' | 'YES' | 'y' | 'yes')
			echo "Continuing ...";	
			;;
		'N' | 'NO' | 'n' | 'no')
			echo "Exiting ...";
			printf "$headdivider\n"
			exit 0;
			;;
		*)
			echo "Not a valid input. You can choose any of 'Y','y','YES','yes','N','n','NO','no'. Exiting."
			printf "$headdivider\n"
			exit 1;
			;;
	esac
	printf "$headdivider\n"
}

chkAllCrdsExists()
{
	printf "$headdivider\n"	
	echo
	flag=0
	for c in ${CRDS[@]}
	do
		count=`kubectl get crd -o custom-columns='name:.metadata.name,version:.apiVersion' | grep snapshot | awk '{print $1":"$2}' | grep -w $c | wc -l`
		[[ ${count} -eq 1 ]] && { echo "CRD $c found installed" | sed s/':'/' version '/g; } || { echo "The CRD $c is not found installed in the cluster." ; flag=1 ; }
	done

	[[ ${flag} -eq 1 ]] && { echo "Please install the missing CRDs first and then rerun the script."; exit 1; } || { echo "CRD check PASSED"; }
	echo
	printf "$headdivider\n"
}

getCsiDrivers()
{
	# Get the list of csidrivers those exist in the cluster
	csidrivers=(`kubectl get csidrivers | grep -v 'NAME' |awk '{print $1}'`)
	csidriverslen=${#csidrivers[@]}
	[ $csidriverslen -gt 0 ] || { echo "No CSI drivers found in the cluster. Exiting."; exit 1; }
	printf "%-30s %-90s\n" "  " "Found the following csi-drivers:"
	csip=`echo ${csidrivers[@]} | sed s/' '/', '/g`
	echo $csip
	printf "$headdivider\n"
}


setCsiDrivers()
{
	# For each csidriver set IF_CSI_DRIVER as 1
	for i in ${csidrivers[@]}
	do
		IF_CSI_DRIVER[$i]=1
	done
}


getStorageClasses()
{
	# Check the pvs which are present in the cluster and list the uniq values of their storageclass
	storageclasses=(`kubectl get storageclass | grep -v 'NAME' | awk '{print $1}' | sort -u | uniq`)
	storageclasseslen=${#storageclasses[@]}
	storageclassp=`echo ${storageclasses[@]} | sed s/' '/', '/g`
	[ $storageclasseslen -gt 0 ] || { echo "No storage classes are found in the cluster. Exiting."; exit 1; }
	printf "%-30s %-90s\n" "  " "Found the following storage classes: "
	echo $storageclassp
	printf "$headdivider\n"
}

getVolumesnapshotClasses()
{
	volumesnapshotclasses=(`kubectl get volumesnapshotclass | grep -v 'NAME' | awk '{print $1}' | sort -u | uniq`)
	volumesnapshotclasslen=${#volumesnapshotclasses[@]}
	volumesnapshotclassp=`echo ${volumesnapshotclasses[@]} |  sed s/' '/', '/g`
	[ $volumesnapshotclasslen -gt 0 ] || { echo "No Volumesnapshotclass resources are found in the cluster. Exiting."; exit 1; }
        printf "%-30s %-90s\n"  "  " "Found the following Volumesnapshotclasses: "
	echo $volumesnapshotclassp
	printf "$headdivider\n"
}

setProvisionerForSC()
{
	# For each storage class find the respective provisioner and unset the IF_CSI_DRIVER as 0 if no Value defind for any provisioner

	echo
        div='------------------------------'
        divider="+$div$div+$div$div+"
        headdiv="=============================="
        headdivider="+$headdiv$headdiv+$headdiv$headdiv+"
        format="%-60s %-60s %-1s\n"
        printf "$headdivider\n"
	printf "%-30s %-90s %-1s\n" "|  " "Listing of storage classes with their provisioners" "|"
	printf "$headdivider\n"
	printf "$format" "|  STORAGE CLASS" "|  PROVISIONER" "|"
	printf "$headdivider\n"

	for i in ${storageclasses[@]}
	do
		echo "Describing the SC $i" >> $PATH_TO_YAML_FILES/cc-validate-storage.debug.txt ; kubectl describe storageclass $i >> $PATH_TO_YAML_FILES/cc-validate-storage.debug.txt
		PROVISIONER[$i]=`kubectl describe storageclass $i | grep 'Provisioner' | cut -f2 -d ':' | xargs`
		[[ ${IF_CSI_DRIVER[${PROVISIONER[$i]}]} -eq 1 ]] || IF_CSI_DRIVER[${PROVISIONER[$i]}]=0
 		printf "$format" "|  $i" "|  ${PROVISIONER[$i]}" "|"
		printf "$divider\n" 
	done
}

chknamespacestate()
{
	echo "Describing the namespace resource" >> $PATH_TO_YAML_FILES/cc-validate-storage.debug.txt ; kubectl describe namespace $1 >> $PATH_TO_YAML_FILES/cc-validate-storage.debug.txt
	nsstate=`kubectl describe namespace $1 | grep 'Status:' | cut -f2 -d ':' | xargs`
	[[ $nsstate == 'Active' ]] && { echo >&2 "$1 Namespace is Active"; return 0; } || { echo >&2 "The Namespace had some failures"; return 1; }
}

chkAndDelCsiSetupTestNamespace()
{

	state=`kubectl get namespaces | grep csi-setup-test | wc -l`
	[[ $state -gt 0 ]] && { echo "Found namespace csi-setup-test. Deleting ..."; decommission $1 1; }
	[[ -d ~/tmp/test_dir ]] && { rm -rf ~/tmp/test_dir/*.yaml > /dev/null 2>&1 ; }
}


chkPvcPodStatus()
{
	echo 'yaml content for pod and pvc' >> $PATH_TO_YAML_FILES/cc-validate-storage.debug.txt ;
	kubectl get pvc $1 -n $3 -o yaml | grep -v 'f:phase:' | grep 'phase'  >> $PATH_TO_YAML_FILES/cc-validate-storage.debug.txt;
	kubectl get pod $2 -n $3 -o yaml | grep -v 'f:phase:' | grep 'phase'  >> $PATH_TO_YAML_FILES/cc-validate-storage.debug.txt;
        PVCSTATUS=`kubectl get pvc $1 -n $3 -o yaml | grep -v 'f:phase:' | grep 'phase' | cut -f2 -d ":" | xargs`
	PODSTATUS=`kubectl get pod $2 -n $3 -o yaml | grep -v 'f:phase:' | grep 'phase' | cut -f2 -d ":" | xargs`
	PVCPODSTATUS=$PVCSTATUS$PODSTATUS
        retryleft=$4
        case $PVCPODSTATUS in
                'BoundRunning')
			printf "\n"
                        return 0;
                        ;;
                *)
                        [[ $retryleft -gt 0 ]] && { (( retryleft=retryleft-1 )); printf >&2 ".  "; sleep $TIMEOUT; chkPvcPodStatus $1 $2 $3 $retryleft; } || { return 1; }
                        ;;
        esac

}


chkVsStatus()
{
	echo 'yaml content of volumesnapshot' >> $PATH_TO_YAML_FILES/cc-validate-storage.debug.txt ;
	kubectl get volumesnapshot $1 -n $2 -o yaml | grep -v 'f:readyToUse:' | grep 'readyToUse' >> $PATH_TO_YAML_FILES/cc-validate-storage.debug.txt;
        VSTATUS=`kubectl get volumesnapshot $1 -n $2 -o yaml | grep -v 'f:readyToUse:' | grep 'readyToUse' | cut -f2 -d ':' | xargs`
	retryleft=$3
	case $VSTATUS in
                'true')
			printf "\n";
                        return 0;
                        ;;
                'false')
			[[ $retryleft -gt 0 ]] && { (( retryleft=retryleft-1 )); printf >&2 ".  "; sleep $TIMEOUT; chkVsStatus $1 $2 $retryleft; } || { return 1; }
                        ;;
                *)
                        return 1;
                        ;;
        esac
}

delpvc()
{
	NS=$1
       	pvcs=(`kubectl get pvc -n $NS | grep -vi 'NAME' | awk '{print $1}'`) 
	for p in ${pvcs[@]}
	do
		kubectl delete pvc ${p} -n ${NS}  > /dev/null 2>&1 
	done
}

delvs()
{

        NS=$1
        vss=(`kubectl get volumesnapshot -n $NS | grep -vi 'NAME' | awk '{print $1}'`)     
        for v in ${vss[@]}
        do
                kubectl delete volumesnapshot ${v} -n ${NS}  > /dev/null 2>&1 
        done
}

deldepl_()
{
	NS=$1
	kubectl delete -f ${PATH_TO_YAML_FILES}/busybox-deployment.yaml -n $NS --force --grace-period=0 > /dev/null 2>&1 & 
       	sleep $TIMEOUT
	TERMINATINGPODS=(`kubectl get pods -n $NS | grep -v 'NAME' | awk '{print $1}'`)
	for p in ${TERMINATINGPODS[@]}
	do
		kubectl delete pod $p -n $NS --force --grace-period=0 > /dev/null 2>&1 
	done
}

verifydeplcleanup()
{
	    NS=$1
        retryleft=$2
        TERMINATINGPODS=(`kubectl get pods -n $NS 2> /dev/null | grep -v 'NAME' | awk '{print $1}'`)
	    [[ ${#TERMINATINGPODS[@]} -gt 0 ]] && { [[ $retryleft -gt 0 ]] && { (( retryleft=retryleft-1 )) ; printf ". "; sleep $TIMEOUT; verifydeplcleanup $NS $retryleft; } || { echo "Deployment Cleanup is stuck. Please verify the resources and clean those manually. Exiting ..."; exit 1; } } || { echo; echo "Deployment cleanup is done."; }
}

deldepl()
{
        NS=$1
        kubectl delete -f ${PATH_TO_YAML_FILES}/busybox-deployment.yaml -n $NS > /dev/null 2>&1 &
        sleep $TIMEOUT
        TERMINATINGPODS=(`kubectl get pods -n $NS 2> /dev/null | grep -v 'NAME' | awk '{print $1}'`)
	    [[ ${#TERMINATINGPODS[@]} -gt 0 ]] && { printf "Checking deployment cleanup (will try $TTC times with ${TIMEOUT}s interval) "; verifydeplcleanup $NS $TTC; }
}

delsnapcon()
{
	NS=$1
	for vsccs in `kubectl get volumesnapshotcontent | grep $NS | awk '{print $1}'`
	do          
		kubectl patch volumesnapshotcontent $vsccs --type json --patch='[{ "op": "replace", "path": "/spec/deletionPolicy", value: Delete }]' > /dev/null 2>&1           
		kubectl delete volumesnapshotcontent $vsccs > /dev/null 2>&1 & 
		# kubectl patch volumesnapshotcontent $vsccs --type json --patch='[{ "op": "remove", "path": "/metadata/finalizers" }]' > /dev/null 2>&1 
	done
}

delpv()
{
	NS=$1
	for pvss in `kubectl get pv 2> /dev/null | grep $NS | awk '{print $1}'`
	do
		kubectl patch pv $pvss --type json --patch='[[{ "op": "replace", "path": "/spec/persistentVolumeReclaimPolicy", value: Delete }]]' > /dev/null 2>&1
		kubectl delete pv $pvss > /dev/null 2>&1 &
		# kubectl patch pv $pvss --type json --patch='[{ "op": "remove", "path": "/metadata/finalizers" }]' > /dev/null 2>&1
	done
}

patchpv()
{
	PVNAME_=$1
	kubectl patch pv $PVNAME_ -p '{"spec":{"persistentVolumeReclaimPolicy":"Delete"}}' > /dev/null 2>&1
}

patchvsc()
{
	VSCNAME_=$1
	kubectl patch volumesnapshotcontent $VSCNAME_ --type json --patch='[{ "op": "replace", "path": "/spec/deletionPolicy", value: Delete }]' > /dev/null 2>&1
}

decommission()
{
	NS=$1
	NSS=$2
	PODS=`kubectl get pods -n $NS 2> /dev/null | grep -v 'NAME' | wc -l`
	VSS=`kubectl get volumesnapshot -n $NS 2> /dev/null | grep -v 'NAME' | wc -l`
	PVCS=`kubectl get pvc -n $NS 2> /dev/null | grep -v 'NAME' | wc -l`
	PVS=`kubectl get pv 2> /dev/null | grep $NS | awk '{print $1}' | wc -l`
	VSCS=`kubectl get volumesnapshotcontent 2> /dev/null | grep $NS | awk '{print $1}' | wc -l`

        echo "Deleting namespace $NS, pods=$PODS, volumesnapshots=$VSS, volumesnapshotcontents=$VSCS, pvcs=$PVCS"

	[[ $PODS -gt 0 ]] && { deldepl $NS; }
	[[ $PVCS -gt 0 ]] && { delpvc $NS; }
        [[ $VSS -gt 0 ]] && { delvs $NS; }
	[[ $VSCS -gt 0 ]] && { delsnapcon $NS; }
	[[ $PVS -gt 0 ]] && { delpv $NS;}
	[[ $NSS -gt 0 ]] && { kubectl delete -f ${PATH_TO_YAML_FILES}/namespace.yaml --force  > /dev/null 2>&1 ; }
}

verifycleanup()
{
	retryleft=$2
	PODS=`kubectl get pods -n $1 -l cloudcasa.io/csi-verify-script=true 2> /dev/null | grep -v 'NAME' | wc -l`
	VSS=`kubectl get volumesnapshot -n $1 -l cloudcasa.io/csi-verify-script=true 2> /dev/null | grep -v 'NAME' | wc -l`
	PVCS=`kubectl get pvc -n $1 -l cloudcasa.io/csi-verify-script=true 2> /dev/null | grep -v 'NAME' | wc -l`
	[[ $PODS -gt 0 || $VSS -gt 0 || $PVCS -gt 0 ]] && { [[ $retryleft -gt 0 ]] && { (( retryleft=retryleft-1 )) ; echo "Waiting for cleanup with retries left=$retryleft"; sleep $TIMEOUT; verifycleanup $1 $retryleft; } || { echo "Cleanup is stuck. Exiting."; exit 1; } } || { echo "Cleanup is done."; }
}

gennsyaml()
{
cat << EOF > ${PATH_TO_YAML_FILES}/namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: csi-setup-test
EOF
}

genpvcyaml()
{
cat << EOF > ${PATH_TO_YAML_FILES}/busybox-pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  generateName: ${PVCPREF}-
  labels:
    app: wordpress
    cloudcasa.io/csi-verify-script: "true"
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 5Mi
  storageClassName: ${SCNAME}
EOF
}

gendeplyaml()
{
cat << EOF > ${PATH_TO_YAML_FILES}/busybox-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: busybox
  labels:
    app: busybox
    cloudcasa.io/csi-verify-script: "true"
spec:
  selector:
    matchLabels:
      app: busybox
      tier: busybox
      cloudcasa.io/csi-verify-script: "true"
  strategy:
    type: Recreate
  template:
    metadata:
      labels:
        app: busybox
        tier: busybox
        cloudcasa.io/csi-verify-script: "true"
    spec:
      containers:
      - image: ${IMAGE}
        name: busybox
        command:
          - sleep
          - "3600"
        volumeMounts:
        - name: busybox-persistent-storage
          mountPath: /var/
      volumes:
      - name: busybox-persistent-storage
        persistentVolumeClaim:
          claimName: ${PVCNAME}
EOF
}

genvsyaml()
{
cat << EOF > ${PATH_TO_YAML_FILES}/csi-snapshot-busybox.yaml
apiVersion: ${VSCAPI}
kind: VolumeSnapshot
metadata:
  generateName: ${VSPREF}-
  labels:
    cloudcasa.io/csi-verify-script: "true"
spec:
  volumeSnapshotClassName: ${VSCNAME}
  source:
    persistentVolumeClaimName: ${PVCNAME}
EOF
}

resultsummary()
{
	div='--------------------'
	divider="+$div$div$div$div+$div+"
	headdiv="===================="
	headdivider="+$headdiv$headdiv$headdiv$headdiv+$headdiv+"
	format="%-80s %-20s %-1s\n"
	
	printf "$headdivider\n"
	printf "%-40s %-60s %-1s\n" "|  " "RESULT SUMMARY" "|"
	printf "$headdivider\n"
	for ri in ${!RESIND[@]}
	do
		printf "$format" "|  ${RESIND[$ri]}" "|  ${RESULTS[${RESIND[$ri]}]}" "|"
		[[ ${RESIND[$ri]} =~ "TESTED SC" ]] && { printf "$headdivider\n"; } || { printf "$divider\n"; } 
	done		
}

getinfo()
{
	PODS=(`kubectl get pods -n $NS -l cloudcasa.io/csi-verify-script=true 2> /dev/null | grep -v 'NAME' | awk '{print $1}' | tr '\n' ' '`)
	VSS=(`kubectl get volumesnapshot -n $NS -l cloudcasa.io/csi-verify-script=true 2> /dev/null | grep -v 'NAME' | awk '{print $1}' | tr '\n' ' '`)
	VSCS=(`kubectl get volumesnapshotcontent | grep '$NS' | awk '{print $1}' | tr '\n' ' '`)
	PVCS=(`kubectl get pvc -n $NS -l cloudcasa.io/csi-verify-script=true 2> /dev/null | grep -v 'NAME' | awk '{print $1}' | tr '\n' ' '`)
	
	[[ ${#PODS[@]} -eq 0 && ${#VSS[@]} -eq 0 && ${#VSCS[@]} -eq 0 && ${#PVCS[@]} -eq 0 ]] && { echo "==========================================================="; echo "No resources in the namespace $NS, Exiting ..."; echo "==========================================================="; exit 0; }

	[[ ${#PODS[@]} -gt 0 ]] && { printf "PODs: ${#PODS[@]} "; }
	[[ ${#VSS[@]} -gt 0 ]] && { printf "Volumesnapshot: ${#VSS[@]} "; }
        [[ ${#VSCS[@]} -gt 0 ]] && { printf "Volumesnapshotcontents: ${#VSCS[@]} "; }
	[[ ${#PVCS[@]} -gt 0 ]] && { printf "Persistantvolumes: ${#PVCS[@]}";}
	
	echo; 

	[[ ${#PODS[@]} -gt 0 ]] && { echo "==========================================================================================="; echo "======================= Describing PODs in namespace $NS =======================" ; echo "==========================================================================================="; for pd in ${PODS[@]}; do kubectl describe pod $pd -n $NS; echo "===========================================================================================";	done; 	echo ;	echo; }
	[[ ${#PVCS[@]} -gt 0 ]] && { echo "==========================================================================================="; echo "======================= Describing PVCs in namespace $NS ======================="; echo "==========================================================================================="; for p in ${PVCS[@]}; do kubectl describe pvc $p -n $NS; echo "==========================================================================================="; done;  echo ; echo ; }
    [[ ${#VSS[@]} -gt 0 ]] && { echo "======================================================================================================"; echo "======================= Describing volumesnapshots in namespace $NS ======================="; echo "======================================================================================================"; for v in ${VSS[@]}; do kubectl describe volumesnapshots $v -n $NS; echo "======================================================================================================"; done; echo; echo;}
    [[ ${#VSCS[@]} -gt 0 ]] && { echo "============================================================================================================"; echo "======================= Describing volumesnapshotcontent in namespace $NS ======================="; echo "============================================================================================================"; for vs in ${VSCS[@]}; do kubectl describe volumesnapshotcontent $vs -n $NS; echo "============================================================================================================"; done; echo; echo; } 
	
}

handleIfLonghorn()
{
	DRIVER=$1
	LH=`kubectl describe csidriver $DRIVER | grep 'Manager:' | cut -f2 -d ':' | xargs`
	if [[ $LH =~ "longhorn" ]] 
	then
		MINSUPMAJV=1
		MINSUPMINV=3
		VERS=`kubectl describe csidriver $DRIVER | grep 'driver.longhorn.io/version' | grep -v 'f:driver.longhorn.io/version' | cut -d ':' -f2 | cut -d 'v' -f2 | xargs`; 
		MAJORV=`echo $VERS| tr '.' ' ' | awk '{ print $1}'`
		MINOR=`echo $VERS| tr '.' ' ' | awk '{ print $2}'`
		[[ $MAJORV -ge $MINSUPMAJV && $MINOR -ge $MINSUPMINV ]] && { echo "longhorn version: $VERS"; } || { echo "WARNING: You are running an unsupported version of Longhorn: $VERS. Supported versions are >= $MINSUPMAJV.$MINSUPMINV"; }
	fi
}

VALID_ARGS=$(getopt -o hCci:T:R: --long help,collectlogs,cleanup,image:,timeout:,retry: -- "$@")
eval set -- "$VALID_ARGS"
ST=$?
if [[ $ST -ne 0 ]]; then
    help_; 
    exit 1;
fi

while [ : ]; do
	case "$1" in
		-h | --help)
			help_;
			exit 0;
        	;;
		-c | --cleanup)
			echo "Processing cleanup";
			decommission $NS 1
			verifycleanup $NS $TTC
			exit 0;
        	;;
		-C | --collectlogs)
			getinfo;
			exit 0;
		;;
		-i | --image)
			IMAGE=$2;
			shift 2;
		;;
		-T | --timeout)
			TIMEOUT=$2;
			shift 2;
		;;
		-R | --retry)
			TTC=$2;
			shift 2;
		;;
		--)
			shift;
			break;
        	;;
	esac
done

prompt_user
chkAllCrdsExists
getCsiDrivers
setCsiDrivers
getStorageClasses
getVolumesnapshotClasses
setProvisionerForSC
chkAndDelCsiSetupTestNamespace $NS





RESULTS=()

echo

div='------------------------------'
divider="$div$div$div$div"
headdiv="=============================="
headdivider="$headdiv$headdiv$headdiv$headdiv"
format="%-60s %-60s %-1s\n"

CSISC=0

#echo "" > $PATH_TO_YAML_FILES/pv.txt

for i in ${storageclasses[@]}
do
        if [[ ${IF_CSI_DRIVER[${PROVISIONER[$i]}]} -eq 1 ]]; then
                echo
		CSISC=1
		VSCLASS=(`kubectl get volumesnapshotclass | grep -v 'NAME' | grep "${PROVISIONER[$i]}" | awk '{print $1}'`)
		vsclen=${#VSCLASS[@]}
		
		if [ $vsclen -gt 0 ]
		then
			printf "$headdivider\n"
			printf "%-30s %-90s\n" "  " "Snapshot testing for storageclass $i PVCs started."
			printf "$headdivider\n"
			handleIfLonghorn ${PROVISIONER[$i]}
			RESULTS["TESTED SC $i"]="YES"
			RESIND+=("TESTED SC $i")
                	export SCNAME=$i
                	export PVCPREF="pvc-${i}"
		
                	SCBINDMODE=`kubectl describe sc $i | grep 'VolumeBindingMode' |  cut -f2 -d ':' | xargs`

                	[[ -d $PATH_TO_YAML_FILES ]] || { mkdir -p $PATH_TO_YAML_FILES; }

                	gennsyaml;
                	genpvcyaml;

                	cd $PATH_TO_YAML_FILES;
                	kubectl apply -f namespace.yaml; chknamespacestate $NS > /dev/null 2>&1;

			echo "SC volume Binding mode is $SCBINDMODE. Provisioning the test PVC and POD now. Will validate the status of both first."
                	kubectl create -f busybox-pvc.yaml -n $NS > /dev/null 2>&1;

			export PVCNAME=`kubectl get pvc -n $NS -o yaml | grep 'name:' | cut -f2 -d ':' | xargs`
                	
			gendeplyaml;

                	kubectl apply -f $PATH_TO_YAML_FILES/busybox-deployment.yaml -n $NS > /dev/null 2>&1;
                	PODNAME=`kubectl get pods -n $NS | grep -v 'NAME' | awk '{print $1}' | xargs`;
			printf "Checking PVC and POD status (will try $TTC times with ${TIMEOUT}s interval) "
			chkPvcPodStatus $PVCNAME $PODNAME $NS $TTC;
                	PVCPODCHK=$?
			echo
	
                	if [ $PVCPODCHK -eq 0 ] 
			then
				export PVNAME=`kubectl get pvc $PVCNAME -n $NS -o yaml | grep 'volumeName:' | cut -f2 -d ':' | xargs`
				patchpv $PVNAME;	
				echo "PVC creation test PASSED"
				echo "POD creation test PASSED"
				RESULTS["PVC creation for SC $i"]="PASSED"
				RESIND+=("PVC creation for SC $i")
				RESULTS["POD creation for SC $i"]="PASSED"
				RESIND+=("POD creation for SC $i")
                       		VSCLASS=(`kubectl get volumesnapshotclass | grep -v 'NAME' | grep "${PROVISIONER[$i]}" | awk '{print $1}'`)
               			for j in ${VSCLASS[@]}
                		do
					echo "------------ Testing volumesnapshot creation for VSC $j ------------"
					echo "Describing volumesnapshotclass $j" >> $PATH_TO_YAML_FILES/cc-validate-storage.debug.txt 
				        kubectl describe volumesnapshotclass $j >> $PATH_TO_YAML_FILES/cc-validate-storage.debug.txt 	
                        		export VSCAPI=`kubectl describe volumesnapshotclass $j | grep 'API Version' | head -1 | cut -f2 -d ':' | xargs`
                        		export VSCNAME=$j
                        		export VSPREF="snap-${j}"
                        		genvsyaml;
                        		kubectl create -f $PATH_TO_YAML_FILES/csi-snapshot-busybox.yaml -n $NS > /dev/null 2>&1 ;
                        		VSNAME=`kubectl get volumesnapshot -n $NS -o yaml | grep 'name:' | cut -f2 -d ':' | xargs`
					printf "Checking Volumesnapshot $VSNAME status (will try $TTC times with ${TIMEOUT}s interval) "
                        		chkVsStatus $VSNAME $NS $TTC
					VSCHK=$?
					[[ $VSCHK -eq 0 ]] && { VSCONAME=`kubectl get volumesnapshot $VSNAME -n $NS -o yaml | grep 'boundVolumeSnapshotContentName:' | cut -f2 -d ':' | xargs` ; patchvsc $VSCONAME; RESULTS["volumesnapshot creation for VSC $j"]="PASSED"; RESIND+=("volumesnapshot creation for VSC $j"); echo "------------ Testing of volumesnapshot creation for VSC $j PASSED ------------"; echo; } || { RESULTS["volumesnapshot creation for VSC $j"]="FAILED"; RESIND+=("volumesnapshot creation for VSC $j"); echo " \"readyToUse\" flag of VSC $j wasn't found to be \"true\" even after max retries";echo "------------ Testing of volumesnapshot creation for VSC $j FAILED ------------"; echo; }
					[[ $VSCHK -ne 0 ]] && { echo "Here are volumesnapshot Events:"; echo "Describing the volumesnapshot for $j" >> $PATH_TO_YAML_FILES/cc-validate-storage.debug.txt ;kubectl describe volumesnapshot $VSNAME -n $NS >> $PATH_TO_YAML_FILES/cc-validate-storage.debug.txt ;  kubectl describe volumesnapshot $VSNAME -n $NS | grep -A 10 'Events:' | grep -v 'Events:'; }
                        		kubectl delete volumesnapshot $VSNAME -n $NS  > /dev/null 2>&1 & 
					# kubectl patch volumesnapshot $VSNAME --type json --patch='[{ "op": "remove", "path": "/metadata/finalizers"}]' -n $NS > /dev/null 2>&1 
					sleep $TIMEOUT
                		done
				deldepl $NS
                       		kubectl delete pvc $PVCNAME -n $NS  > /dev/null 2>&1 &
				sleep $TIMEOUT
                       		# kubectl patch pvc $PVCNAME --type json --patch='[{ "op": "remove", "path": "/metadata/finalizers"}]' -n $NS  > /dev/null 2>&1
			else	
		        	PVCSTAT=`kubectl get pvc $PVCNAME -n $NS -o yaml | grep -v 'f:phase:' | grep 'phase:' | cut -f2 -d ":" | xargs`
		        	PODSTAT=`kubectl get pod $PODNAME -n $NS -o yaml | grep -v 'f:phase:' | grep 'phase:' | cut -f2 -d ":" | xargs`

				[[ $PODSTAT == 'Running' ]] && { RESULTS["POD creation for SC $i"]="PASSED"; RESIND+=("POD creation for SC $i"); echo "POD Check was PASSED"; } || { RESULTS["POD creation for SC $i"]="FAILED"; RESIND+=("POD creation for SC $i"); echo "POD Check FAILED as POD status wasn't found to be \"Running\" even after max retries"; }
				[[ $PODSTAT != 'Running' ]] && { echo "Here are POD Events:"; echo "Describing the pod $PODNAME" >>  $PATH_TO_YAML_FILES/cc-validate-storage.debug.txt ;  kubectl describe pod $PODNAME -n $NS >> $PATH_TO_YAML_FILES/cc-validate-storage.debug.txt; kubectl describe pod $PODNAME -n $NS | grep -A 10 'Events:' | grep -v 'Events:'; }

		        	[[ $PVCSTAT == 'Bound' ]] && { RESULTS["PVC creation for SC $i"]="PASSED"; RESIND+=("PVC creation for SC $i"); echo "PVC Check was PASSED"; export PVNAME=`kubectl get pvc $PVCNAME -n $NS -o yaml | grep 'volumeName:' | cut -f2 -d ':' | xargs`; patchpv $PVNAME; } || { RESULTS["PVC creation for SC $i"]="FAILED"; RESIND+=("PVC creation for SC $i"); echo "PVC Check FAILED as PVC status wasn't found to be \"Bound\" even after max retries"; }	
				[[ $PVCSTAT != 'Bound' ]] && { echo "Here are PVC Events:"; echo "Describing the PVC $PVCNAME" >> $PATH_TO_YAML_FILES/cc-validate-storage.debug.txt; kubectl describe pvc $PVCNAME -n $NS >> $PATH_TO_YAML_FILES/cc-validate-storage.debug.txt; kubectl describe pvc $PVCNAME -n $NS | grep -A 10 'Events:' | grep -v 'Events:'; }
				
				RESULTS["volumesnapshot creation test for SC $i"]="SKIPPED"
				RESIND+=("volumesnapshot creation test for SC $i")	
				echo "No Volumesnapshot creation test will be performed for any Volumesnapshotclass of SC $i as one of PVC POD checks failed. Skipping to next Storageclass."
				echo
				deldepl $NS 
				kubectl delete pvc $PVCNAME -n $NS > /dev/null 2>&1 &
				sleep $TIMEOUT;
				#kubectl patch pvc $PVCNAME --type json --patch='[{ "op": "remove", "path": "/metadata/finalizers"}]' -n $NS  > /dev/null 2>&1
               		fi

			verifycleanup $NS $TTC	
		else
			echo "No Volumesnapshotclass found for Storageclass $i. Skipping to the next Storageclass"
			RESULTS["volumesnapshot creation test for SC $i"]="SKIPPED"
			RESIND+=("volumesnapshot creation test for SC $i")
		fi

            printf "$headdivider\n"
       	    printf "%-30s %-90s\n" "  " "Snapshot testing for storageclass $i PVCs COMPLETED."
            printf "$headdivider\n"
	
	    echo
        fi
done

[[ $CSISC -eq 0 ]] && { echo "Could not find storage classes whose provisioners have corresponding CSI drivers. Exiting."; exit 0; }

decommission $NS 1

echo
echo

resultsummary 
echo "Please Check the file \"$PATH_TO_YAML_FILES/cc-validate-storage.debug.txt\", For more info."
