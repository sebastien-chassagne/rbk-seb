#!/bin/bash 
#
#############################################################################
#	On-Demand FileSet Restore						   
#############################################################################
# Assuming that all of this are in $PATH 									
#  uuidgen 																
#  rbkcli													
# 																			
# Also assuming that rbkcli conf file is set properly for the user who run  
# this script																
#############################################################################
# This script is provided "as-is"											
# Run on-demand in-place fileset restore for specified filepattern.								
# 					 														
# Note that rubrik_cdm_token take precedence over rubrik_cdm_username and rubrik_cdm_password.
# So, no matter which value is set for rubrik_cdm_username and rubrik_cdm_password.
# export rubrik_cdm_node_ip=someIP
# export rubrik_cdm_username="enteranythinghere"
# export rubrik_cdm_password="enteranythinghere"
# export rubrik_cdm_token='theverylongtoken'
#############################################################################


#User inputs
while getopts H:p:f:c:i:SFDh option
do
	case "${option}" in
		H) 
			myhost=${OPTARG}
			;;
		p) 
			filepattern=${OPTARG}
			;;
		f) 
			fileset=${OPTARG}
			;;
		c) 
			rbkcliconffile=${OPTARG}
			;;
		i) 	
			ignorevalue=${OPTARG}
			;;
		F)
			restorelessrecent=true
			;;
		D)
			dryrun=true
			;;
		S)
			strictsearch=true
			;;
		h) 	
			echo "Run on-demand in-place fileset restore for specified filepattern."
			echo
			echo "syntax :"
			echo "$0 -H <machinename> -p <Absolutefilepattern> -f <filesetname> -i <yes|no> -c <rubrikconfigurationfile> [-D] [-S] [-h]"
			echo " -h : display this help"
			echo " -i : specifies how errors are handled. yes means ignore errors"
			echo " -D : run the script in dry-run mode. Nothing will be restored."
			echo " -S : Perform strict search. wildcards ? and * won't be interprated as such. The filepattern must be given as fullpath."
			exit 0 
			;;
	esac
done


if [[ $filepattern != /* ]]
then
	echo "-p given argument is not an absolute path"
	echo "Exiting..."
	exit 1
fi

#Start check if binaries exists
type jq > /dev/null 2>&1
if [ $? -ne 0 ]
then
	echo "jq is not installed"
	echo "Exiting..."
	exit 1
fi

type rbkcli > /dev/null 2>&1
if [ $? -ne 0 ]
then
	echo "rbkcli is not installed"
	echo "Exiting..."
	exit 1
fi

type uuidgen > /dev/null 2>&1
if [ $? -ne 0 ]
then
	echo "uuidgen is not installed"
	echo "Exiting..."
	exit 1
fi
#Start check if binaries exists

#Check if all required args have been provided
if [ -z $myhost ] || [ -z $fileset ] || [ -z $rbkcliconffile ] || [ -z $ignorevalue ]
then
	echo "Not enough parameters -H -p -f -i and -c are needed"
	echo "syntax :"
	echo "$0 -H <machinename> -p <Absolutefilepattern> -f <filesetname> [-e <yes|no>] -c <rubrikconfigurationfile>"
	exit 1
fi

#echo "ignore : $ignorevalue"
case $ignorevalue in
	yes)
		ignore=true
		;;
	no)
		ignore=false
		;;
	*)
		echo "correct value for -i : yes or no"
		exit 1
		;;
esac


#Temp Directory 
TmpDir=${HOME}/rbk-temp

#uniq identifier
uuidgen_num=$(uuidgen)

#Initialize Job Status
State=NONE

#create $TmpDir if this folder does not exist
if [ ! -d "${TmpDir}" ] 
then
	mkdir -p $TmpDir
fi

#Check interval in seconds
checkintervalinsec=20


#Source rbkcli env
if [ ! -f  "$rbkcliconffile" ]
then 
  echo "\"$rbkcliconffile\" not found !"
  exit 2
else
  source ${rbkcliconffile}
fi


#get hostid
echo "Verifying hostname..."
hostid=$(rbkcli host -f hostname=${myhost},operatingSystemType!=Windows | jq -r ".[].id")
if [ -z "$hostid" ]
then
	echo "The specified host $myhost does not exist !"
	echo "Please review upper/lower case and check if the host exist"
	echo "Exiting..."
	exit 2
fi

#Find the fileset id for given fileset
filesetid=$(rbkcli fileset -f name=${fileset} -q host_name=$myhost -s name,hostName=${myhost},id | jq -r ".[].id")

#Check if filesetname exist
if [ -z $filesetid ]
then
	echo "The specified fileset is not assigned to host $myhost or  does not exist !"
	echo "Exiting..."
	exit 2
fi

#Locate the latest snapshot
rbkcli fileset $filesetid | jq -r '.snapshots[] |"\(.id) \(.date)"' >$TmpDir/snaplist.${uuidgen_num}
if [ ! -z $restorelessrecent ]
then
	#latestSnapshotId=$(rbkcli fileset $filesetid | jq -r '.snapshots|.[].id' | tail -2 | head -1)
	latestSnapshotId=$(cat $TmpDir/snaplist.${uuidgen_num} | awk '{print $1}' | tail -2 | head -1)
	snapshotdate=$(cat $TmpDir/snaplist.${uuidgen_num} | awk '{print $2}' | tail -2 | head -1)
else
	#latestSnapshotId=$(rbkcli fileset $filesetid | jq -r '.snapshots|.[].id' | tail -1)
	latestSnapshotId=$(cat $TmpDir/snaplist.${uuidgen_num} | awk '{print $1}' | tail -1)
	snapshotdate=$(cat $TmpDir/snaplist.${uuidgen_num} | awk '{print $2}' | tail -1)
fi
snapshotdatelocal=$(date -d "$snapshotdate")
echo "Using snapshot created on $snapshotdatelocal"


#remove / if set as the latest character if strict search mode is enabled
if [ "$strictsearch" = "true" ]
then
	filepattern=$(echo $filepattern | sed 's/\/$//g')
fi

echo "Searching..."
cpt=1
rbkcli search -q managed_id=${filesetid},query_string=${filepattern} > $TmpDir/searchresult.json.$uuidgen_num.$cpt
TotalFound=$(cat $TmpDir/searchresult.json.$uuidgen_num.$cpt | jq -r ".total")
#nextCursor=$(grep \"nextCursor\" $TmpDir/searchresult.json.$uuidgen_num.$cpt | cut -d\" -f4)
nextCursor=$(cat $TmpDir/searchresult.json.$uuidgen_num.$cpt |jq -r .nextCursor)

#Check if search query return something
if [ $TotalFound -eq 0 ]
then
	echo "No items that match the search pattern \"${filepattern}\" found in $fileset"
	echo "Exiting..."
	exit 2
fi

#loop until all files has been found
while [ "$nextCursor" != "null" ]
do
	(( cpt = $cpt + 1 ))
	rbkcli search -q managed_id=${filesetid},query_string=${filepattern},cursor=$nextCursor > $TmpDir/searchresult.json.$uuidgen_num.$cpt
	#nextCursor=$(grep \"nextCursor\" $TmpDir/searchresult.json.$uuidgen_num.$cpt | cut -d\" -f4)
	nextCursor=$(cat $TmpDir/searchresult.json.$uuidgen_num.$cpt |jq -r .nextCursor)
done

#convert to csv for easy triage
maxcpt=$cpt
cpt=1
while [ $cpt -le $maxcpt ]
do
	#keep onlyfullpath, filename and filesize for matched file in the latest snapshot
	myexecjq=$(echo "jq -r '.data[]| \"\(.path) \(.filename) \(.fileVersions[] |select(.snapshotId == \"$latestSnapshotId\")| .size)\"'")
	#myexecjq=$(echo "jq -r '.data[]| \"\(.path) \(.filename) \(.fileVersions[] |select(.snapshotId == \"$latestSnapshotId\")| .size) \(select .fileVersions[].fileMode != \"directory\")\"'")

	
	echo "cat $TmpDir/searchresult.json.$uuidgen_num.$cpt | $myexecjq" > $TmpDir/Exec.$uuidgen_num.$cpt
	
	if [ "$strictsearch" = "true" ]
	then
		bash $TmpDir/Exec.$uuidgen_num.$cpt | egrep -E "^${filepattern} " > $TmpDir/searchresult.json.$uuidgen_num.$cpt.csv
	else
		bash $TmpDir/Exec.$uuidgen_num.$cpt > $TmpDir/searchresult.json.$uuidgen_num.$cpt.csv
	fi

	#exit if csv files are empty
	filesize=$(stat -c%s $TmpDir/searchresult.json.$uuidgen_num.$cpt.csv)
	
	#Exit if csv file are empty. Empty file mean that latest snapshot hasn't been indexed.
	if [ $filesize -eq 0 ]
	then
		echo "latest_snapshot is not indexed yet or file pattern is not included in the latest snapshot"
		echo "If indexing issue then you may re-run the command with -F to restore from the previous snapshot"
		echo "exiting..."
		rm -f $TmpDir/*${uuidgen_num}*
		exit 1
	fi
	(( cpt = $cpt + 1 ))
done


echo "Generating restore request command..."
cpt=1
sizeB=0
numfile=0
numfiletotal=0


while [ $cpt -le $maxcpt ]
do
	while read path filename size 
	do
		#Format payload with required variables
		#search endpoint report absolute path AND filename as path. so need to remove the last field (/ separator is used).
		restorePath=${path%/*}
		if [ -z $restorePath ]
		then
			restorePath=/
		fi
		
		payload=$(echo "{\"path\": \"${path}\",\"restorePath\": \"${restorePath}\"}")
		payload_list=$(echo "${payload_list},$payload")
		
		#Restoresize estimation
		size=$(echo $size | cut -d\  -f2)
		((sizeB = $sizeB + $size ))
	done < $TmpDir/searchresult.json.$uuidgen_num.$cpt.csv
	numfile=$(wc -l $TmpDir/searchresult.json.$uuidgen_num.$cpt.csv |  awk '{print $1}')
	((numfiletotal = $numfiletotal + $numfile ))
	(( cpt = $cpt + 1 ))
done


#format the payload list
thepayload=$(echo $payload_list|sed "s/^,//g")

rbkclipayload=$(echo "{\"restoreConfig\": [ $thepayload  ], \"ignoreErrors\": $ignore}")
echo "rbkcli fileset snapshot $latestSnapshotId restore_files -v internal -m post -p '$rbkclipayload'" > $TmpDir/Exec.${uuidgen_num}

chmod +x $TmpDir/Exec.${uuidgen_num}


echo "items to restore : $numfiletotal"
echo "size to restore : $sizeB B"

#check dry-run flag
if [ ! -z $dryrun ]
then
	echo "Script ran in dry-run mode."
	echo "Exiting..."
	rm -f $TmpDir/*${uuidgen_num}*
	exit 0
fi

echo "Running restore..."
bash $TmpDir/Exec.${uuidgen_num} > $TmpDir/jobstate.$uuidgen_num

jobid=$(cat $TmpDir/jobstate.$uuidgen_num | jq -r ".id")

if [ "$jobid" == "null" ]
then
	echo "something went wrong..."
	cat $TmpDir/jobstate.$uuidgen_num | jq -r ".message"
	exit 1
fi

#Check for completion
while true
do

	rbkcli fileset request $jobid 2>&1 > $TmpDir/SnapstatusFile.${uuidgen_num}
	State=$(cat $TmpDir/SnapstatusFile.${uuidgen_num} | grep status | awk -F\" '{print $4}')
	Progress=$(cat $TmpDir/SnapstatusFile.${uuidgen_num}| grep progress | awk -F\: '{print $NF}'| sed 's/,//g'|sed 's/\ //g')
	
	# if State=SUCCEEDED then force then Progress to 100
	if [ "$State" = "SUCCEEDED" ]
	then
		Progress=100.0
	elif [ "$State" = "FAILED" ]
	then
		Progress=0.0
	fi
 
 	echo -e " $(date) -\t $State -\t ${Progress}%"

	if [ "$State" = "SUCCEEDED" ]
	then
		echo "Restore of fileset $filesetname on $myhost completed successfully !"

		#remove temp files
		rm -f $TmpDir/*${uuidgen_num}*
		exit 0
		
	elif [ "$State" = "FAILED" ]
	then
		echo "Restore of fileset $filesetname on $myhost failed :("

		# display failure reason
		rbkcli fileset request $jobid -s error

		#remove temp files
		rm -f $TmpDir/*${uuidgen_num}*
		exit 1
	fi
	
	echo "Sleeping for $checkintervalinsec seconds..."
	sleep $checkintervalinsec
done
