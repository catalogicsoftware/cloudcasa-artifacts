#!/usr/bin/env bash

###############################################
# Copyright 2022 Catalogic Software Inc.   ####
###############################################

# Initialize all the associative array variables with global scope
declare -A PROVISIONER
declare -A IF_CSI_DRIVER
declare -a csidrivers
declare -a storageclasses
declare -a CRDS

VALID_ARGS=$(getopt -o hc --long help,collectlogs -- "$@")
eval set -- "$VALID_ARGS"

help_()
{
echo "SYNOPSIS"
echo "	cc-validate-storage.sh  [ Options ]"
echo "DESCRIPTION"
echo "	Run the script to validate CSI storage class configuration is working fine"
echo "OPTIONS"
echo "	-h, --help"
echo "		For usage info"
echo "	-c, --collectlogs"
echo "		For more Detailed output incase of any failures"
echo "EXAMPLES"
echo "	./cc-validate-storage.sh"
echo "	./cc-validate-storage.sh  -h"
echo "	./cc-validate-storage.sh  --help"
echo "	./cc-validate-storage.sh  -c"
echo "	./cc-validate-storage.sh  --collectlogs"
exit 0
}


case "$1" in
    -h | --help)
        help_;
        ;;
    -c | --collectlogs)
        clogs=1;
        ;;
     *)
	clogs=0;
        ;;
esac



divider='=============================='
divider=$divider$divider

#volumesnapshotclasses.snapshot.storage.k8s.io:apiextensions.k8s.io/v1 volumesnapshotcontents.snapshot.storage.k8s.io:apiextensions.k8s.io/v1 volumesnapshotlocations.velero.io:apiextensions.k8s.io/v1 volumesnapshots.snapshot.storage.k8s.io:apiextensions.k8s.io/v1

header="\n%-40s %-40s\n"
format="%-40s %-40s\n"
width=60
TTC=20
#CRDS=("volumesnapshotclasses.snapshot.storage.k8s.io" "volumesnapshotcontents.snapshot.storage.k8s.io" "volumesnapshots.snapshot.storage.k8s.io")

CRDS=("volumesnapshotclasses.snapshot.storage.k8s.io:apiextensions.k8s.io/v1" "volumesnapshotcontents.snapshot.storage.k8s.io:apiextensions.k8s.io/v1" "volumesnapshotlocations.velero.io:apiextensions.k8s.io/v1" "volumesnapshots.snapshot.storage.k8s.io:apiextensions.k8s.io/v1")

echo "HOME:$HOME"
PATH_TO_YAML_FILES=$HOME/tmp/test_dir

chkAllCrdsExists()
{
	printf "%$width.${width}s\n" "$divider"	
	echo
	flag=0
	for c in ${CRDS[@]}
	do
		count=`kubectl get crd -o custom-columns='name:.metadata.name,version:.apiVersion' | grep snapshot | awk '{print $1":"$2}' | grep -w $c | wc -l`
		[[ ${count} -eq 1 ]] && { echo "CRD $c found installed" | sed s/':'/' version '/g; } || { echo "The CRD $c is not found installed in the cluster" ; flag=1 ; }
	done

	[[ ${flag} -eq 1 ]] && { echo "Please install the missing CRDS first and then retry"; exit 1; } || { echo "CRD check PASSED"; }
	echo
	printf "%$width.${width}s\n" "$divider"
}

getCsiDrivers()
{
	# Get the list of csidrivers those exist in the cluster
	csidrivers=(`kubectl get csidrivers | grep -v 'NAME' |awk '{print $1}'`)
	csidriverslen=${#csidrivers[@]}
	[ $csidriverslen -gt 0 ] || { echo "No CSI drivers Found in the cluster, Exiting..."; exit 1; }
	echo "Found these csi-drivers:"
	csip=`echo ${csidrivers[@]} | sed s/' '/', '/g`
	echo $csip
	printf "%$width.${width}s\n" "$divider"
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
	[ $storageclasseslen -gt 0 ] || { echo "No StorageClasses found in the cluster, Exiting ...."; exit 1; }
	echo "Found following storage classes: "
	echo $storageclassp
	printf "%$width.${width}s\n" "$divider"
}

getVolumesnapshotClasses()
{
	volumesnapshotclasses=(`kubectl get volumesnapshotclass | grep -v 'NAME' | awk '{print $1}' | sort -u | uniq`)
	volumesnapshotclasslen=${#volumesnapshotclasses[@]}
	volumesnapshotclassp=`echo ${volumesnapshotclasses[@]} |  sed s/' '/', '/g`
	[ $volumesnapshotclasslen -gt 0 ] || { echo "No Volumesnapshotclass found in the cluster, Exiting ...."; exit 1; }
        echo "Found following Volumesnapshotclasses: "
	echo $volumesnapshotclassp
	printf "%$width.${width}s\n" "$divider"
}

setProvisionerForSC()
{
	# For each storage class find the respective provisioner and unset the IF_CSI_DRIVER as 0 if no Value defind for any provisioner
	echo
	printf "%55s\n" "Mapping of Storage class with it's Provisioner"
	printf "%${width}.${width}s" "--------------------------------------------------------------------"
        printf "$header" "Storage Class" "Provisioner"
	printf "%${width}.${width}s \n" "--------------------------------------------------------------------"	
	for i in ${storageclasses[@]}
	do
        	kubectl describe storageclass $i > /dev/null 2>&1 ; 
		if [[ $? -eq 0 ]]; then
			PROVISIONER[$i]=`kubectl describe storageclass $i | grep 'Provisioner' | cut -f2 -d ':' | xargs`
		else 
			echo "The Storageclass $i is not found, However the PV with storageclass $i do exist, Storageclass might be deleted accidently, Please create it"
		fi
		[[ ${IF_CSI_DRIVER[${PROVISIONER[$i]}]} -eq 1 ]] || IF_CSI_DRIVER[${PROVISIONER[$i]}]=0
	printf "$format" "$i" "${PROVISIONER[$i]}"
	done
	printf "%${width}.${width}s \n" "--------------------------------------------------------------------"
}

chknamespacestate()
{
	nsstate=`kubectl describe namespace $1 | grep 'Status:' | cut -f2 -d ':' | xargs`
	[[ $nsstate == 'Active' ]] && { echo >&2 "$1 Namespace is Active"; return 0; } || { echo >&2 "The Namespace had some failures"; return 1; }
}

chkAndDelCsiSetupTestNamespace()
{

	state=`kubectl get namespaces | grep csi-setup-test | wc -l`
	[[ $state -gt 0 ]] && { echo "Found namespace csi-setup-test :( Deleting ..."; decommission $1 1; }
	[[ -d ~/tmp/test_dir ]] && { rm -rf ~/tmp/test_dir/ > /dev/null 2>&1 ; }
}


chkPvcPodStatus()
{
        PVCSTATUS=`kubectl get pvc $1 -n $3 -o yaml | grep 'phase' | cut -f2 -d ":" | xargs`
	PODSTATUS=`kubectl get pod $2 -n $3 -o yaml | grep 'phase' | cut -f2 -d ":" | xargs`
	PVCPODSTATUS=$PVCSTATUS$PODSTATUS
        retryleft=$4
        case $PVCPODSTATUS in
                'BoundRunning')
			printf "\n"
                        return 0;
                        ;;
                *)
                        [[ $retryleft -gt 0 ]] && { (( retryleft=retryleft-1 )); printf >&2 ".  "; sleep 5; chkPvcPodStatus $1 $2 $3 $retryleft; } || { return 1; }
                        ;;
        esac

}


chkVsStatus()
{
        VSTATUS=`kubectl get volumesnapshot $1 -n $2 -o yaml | grep 'readyToUse' | cut -f2 -d ':' | xargs`
	retryleft=$3
	case $VSTATUS in
                'true')
			printf "\n";
                        return 0;
                        ;;
                'false')
			[[ $retryleft -gt 0 ]] && { (( retryleft=retryleft-1 )); printf >&2 ".  "; sleep 5; chkVsStatus $1 $2 $retryleft; } || { return 1; }
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
		kubectl delete pvc ${p} -n ${NS} --force  > /dev/null 2>&1 
	done
}

delvs()
{

        NS=$1
        vss=(`kubectl get volumesnapshot -n $NS | grep -vi 'NAME' | awk '{print $1}'`)     
        for v in ${vss[@]}
        do
                kubectl delete volumesnapshot ${v} -n ${NS} --force  > /dev/null 2>&1 
        done
}

deldepl()
{
	NS=$1
	kubectl delete -f ${PATH_TO_YAML_FILES}/busybox-deployment.yaml -n $NS --force --grace-period=0 > /dev/null 2>&1 & 
       	sleep 5
	TERMINATINGPODS=(`kubectl get pods -n $NS | grep -v 'NAME' | grep 'Terminating' | awk '{print $1}'`)
	for p in ${TERMINATINGPODS[@]}
	do
		kubectl delete pod $p -n $NS --force --grace-period=0 > /dev/null 2>&1 
	done
}

delsnapcon()
{
	for i in `kubectl get volumesnapshotcontent | grep csi-setup-test | awk '{print $1}'`
	do          
		kubectl patch volumesnapshotcontent $i --type json --patch='[{ "op": "replace", "path": "/spec/deletionPolicy", value: Delete }]' > /dev/null 2>&1           
		kubectl delete volumesnapshotcontent $i > /dev/null 2>&1 & 
		kubectl patch volumesnapshotcontent $i --type json --patch='[{ "op": "remove", "path": "/metadata/finalizers" }]' > /dev/null 2>&1 
	done
}

decommission()
{
	NS=$1
	NSS=$2
	PODS=`kubectl get pods -n $NS 2> /dev/null | grep -v 'NAME' | wc -l`
	VSS=`kubectl get volumesnapshot -n $NS 2> /dev/null | grep -v 'NAME' | wc -l`
	PVCS=`kubectl get pvc -n $NS 2> /dev/null | grep -v 'NAME' | wc -l`
	VSCS=`kubectl get volumesnapshotcontent | grep $NS | awk '{print $1}' | wc -l`

	echo "Deleting namespace $NS, pods=$PODS, volumesnapshots=$VSS, volumesnapshotcontents=$VSCS, pvcs=$PVCS"
	[[ $PODS -gt 0 ]] && { deldepl $1; }
	[[ $VSS -gt 0 ]] && { delvs $1; } 
	[[ $PVCS -gt 0 ]] && { delpvc $1; }
	[[ $VSCS -gt 0 ]] && { delsnapcon ; }
	[[ $NSS -gt 0 ]] && { kubectl delete -f ${PATH_TO_YAML_FILES}/namespace.yaml --force  > /dev/null 2>&1 ; }
}

verifycleanup()
{
	retryleft=$2
	PODS=`kubectl get pods -n $1 -l cloudcasa.io/csi-verify-script=true 2> /dev/null | grep -v 'NAME' | wc -l`
	VSS=`kubectl get volumesnapshot -n $1 -l cloudcasa.io/csi-verify-script=true 2> /dev/null | grep -v 'NAME' | wc -l`
	PVCS=`kubectl get pvc -n $1 -l cloudcasa.io/csi-verify-script=true 2> /dev/null | grep -v 'NAME' | wc -l`
	[[ $PODS -gt 0 || $VSS -gt 0 || $PVCS -gt 0 ]] && { [[ $retryleft -gt 0 ]] && { (( retryleft=retryleft-1 )) ; echo "waiting for cleanup with retriesleft=$retryleft"; sleep 5; verifycleanup $1 $retryleft; } || { echo "Cleanup is stuck... Exiting"; exit 1; } } || { echo "cleanup is done"; }
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
  strategy:
    type: Recreate
  template:
    metadata:
      labels:
        app: busybox
        tier: busybox
    spec:
      containers:
      - image: busybox
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

export NS='csi-setup-test'
export PD=`pwd`
retries=$TTC

chkAllCrdsExists
getCsiDrivers
setCsiDrivers
getStorageClasses
getVolumesnapshotClasses
setProvisionerForSC
chkAndDelCsiSetupTestNamespace $NS


VALID_ARGS=$(getopt -o hc --long help,collectlogs -- "$@")
eval set -- "$VALID_ARGS"

help_()
{
echo "help"
exit 0
}


case "$1" in
    -h | --help)
	help_;
        ;;
    -c | --collectlogs)
        echo "Processing 'collectlogs' option"
	c=1
        ;;
     *)
        ;;
esac



echo

for i in ${storageclasses[@]}
do
        if [[ ${IF_CSI_DRIVER[${PROVISIONER[$i]}]} -eq 1 ]]; then
                echo
                VSCLASS=(`kubectl get volumesnapshotclass | grep -v 'NAME' | grep "${PROVISIONER[$i]}" | awk '{print $1}'`)
		vsclen=${#VSCLASS[@]}

		if [ $vsclen -gt 0 ]
		then
			echo "============================================================================================================="
			echo "                   Snapshot testing for storageclass $i PVCs started"
			echo "============================================================================================================="
                	export SCNAME=$i
                	export PVCPREF="pvc-${i}"
		
                	SCBINDMODE=`kubectl describe sc $i | grep 'VolumeBindingMode' |  cut -f2 -d ':' | xargs`

                	[[ -d $PATH_TO_YAML_FILES ]] || { mkdir -p $PATH_TO_YAML_FILES; }

                	gennsyaml;
                	genpvcyaml;

                	cd $PATH_TO_YAML_FILES;
                	kubectl apply -f namespace.yaml; chknamespacestate $NS > /dev/null 2>&1;

			echo "SC volume Binding mode is $SCBINDMODE, Provisioning the test PVC and POD now, Will validate the status of both first"
                	kubectl create -f busybox-pvc.yaml -n $NS > /dev/null 2>&1;

                	export PVCNAME=`kubectl get pvc -n $NS | grep -v 'NAME' | awk '{print $1}' | xargs`
                	gendeplyaml;

                	kubectl apply -f $PATH_TO_YAML_FILES/busybox-deployment.yaml -n $NS > /dev/null 2>&1;
                	PODNAME=`kubectl get pods -n $NS | grep -v 'NAME' | awk '{print $1}' | xargs`;
			printf "Retrying on PVC and POD status check with 5s retrial timeout  "
			chkPvcPodStatus $PVCNAME $PODNAME $NS $TTC;
                	PVCPODCHK=$?
			echo
	
                	if [ $PVCPODCHK -eq 0 ] 
			then	
				echo "POD and PVC creation test PASSED"
                       		VSCLASS=(`kubectl get volumesnapshotclass | grep -v 'NAME' | grep "${PROVISIONER[$i]}" | awk '{print $1}'`)
               			for j in ${VSCLASS[@]}
                		do
					echo "------------ Testing volumesnapshot creation for VSC $j ------------"
					
                        		export VSCAPI=`kubectl describe volumesnapshotclass $j | grep 'API Version' | head -1 | cut -f2 -d ':' | xargs`
                        		export VSCNAME=$j
                        		export VSPREF="snap-${j}"
                        		genvsyaml;
                        		kubectl create -f $PATH_TO_YAML_FILES/csi-snapshot-busybox.yaml -n $NS > /dev/null 2>&1 ;
                        		VSNAME=`kubectl get volumesnapshot -n $NS | grep -v 'NAME' | awk '{print $1}' | xargs`
					printf "Retrying on Volumesnapshot $VSNAME status check with 5s retrial timeout  "
                        		chkVsStatus $VSNAME $NS $TTC
					VSCHK=$?
                        		[[ $VSCHK -eq 0 ]] && { echo "------------ Testing of volumesnapshot creation for VSC $j PASSED ------------"; echo; } || { echo "------------ Testing of volumesnapshot creation for VSC $j FAILED ------------"; echo; }
					[[ $VSCHK -ne 0 && $clogs -eq 1 ]] && { kubectl describe volumesnapshot $VSNAME -n $NS | grep -A 10 'Events:'; }
                        		kubectl delete volumesnapshot $VSNAME -n $NS --grace-period=0 --force  > /dev/null 2>&1 & 
					kubectl patch volumesnapshot $VSNAME --type json --patch='[{ "op": "remove", "path": "/metadata/finalizers"}]' -n $NS > /dev/null 2>&1 
					sleep 5
                		done
				deldepl $NS > /dev/null 2>&1
                       		kubectl delete pvc $PVCNAME -n $NS --grace-period=0 --force  > /dev/null 2>&1 &
                       		kubectl patch pvc $PVCNAME --type json --patch='[{ "op": "remove", "path": "/metadata/finalizers"}]' -n $NS  > /dev/null 2>&1
			else	
		        	PVCSTAT=`kubectl get pvc $PVCNAME -n $NS -o yaml | grep 'phase' | cut -f2 -d ":" | xargs`
		        	PODSTAT=`kubectl get pod $PODNAME -n $NS -o yaml | grep 'phase' | cut -f2 -d ":" | xargs`

				[[ $PODSTAT == 'Running' ]] && { echo "POD Check was PASSED"; } || { echo "POD Check was FALIED"; }
				[[ $PODSTAT != 'Running' && $clogs -eq 1 ]] && { kubectl describe pod $PODNAME -n $NS | grep -A 10 'Events:'; }
		        	[[ $PVCSTAT == 'Bound' ]] && { echo "PVC Check was PASSED"; } || { echo "PVC Check was FAILED"; }	
				[[ $PVCSTAT != 'Bound' && $clogs -eq 1 ]] && { kubectl describe pvc $PVCNAME -n $NS | grep -A 10 'Events:'; }
				echo
				deldepl $NS > /dev/null 2>&1
				kubectl delete pvc $PVCNAME -n $NS --grace-period=0 --force  > /dev/null 2>&1 &
				kubectl patch pvc $PVCNAME --type json --patch='[{ "op": "remove", "path": "/metadata/finalizers"}]' -n $NS  > /dev/null 2>&1
               		fi

			verifycleanup $NS $TTC	
		else
			echo "No Volumesnapshotclass found for Storageclass $i, jumping to the next Storageclass"
		fi
            echo "============================================================================================================="
            echo "                   Snapshot testing for storageclass $i PVCs completed"
            echo "============================================================================================================="
	    echo
        fi
done

decommission $NS 1

