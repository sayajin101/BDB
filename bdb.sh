#!/bin/bash

#########################################
# Live KVM LVM Incremental Backups      #
# Github: https://github.com/sayajin101 #
#########################################

#--======================================--#
# Set Varibles                             #
# Only modify the below varibles as needed #
#--======================================--#
remotePort="22";
remoteUser="root";
remoteAddress="backup.server.ip";
#--========================================--#

set -x  # enable debug
set -e	# stops execution if a variable is not set
set -u	# stop execution if something goes wrong

# Check if a RPM based system
[ $(which rpm > /dev/null 2>&1; echo ${?}) -ne 0 ] && { echo -e "\nThis script is designed for a RPM based system...exiting"; exit 1; };

# Force changed blocks to disk, update the super block
sync;

# Clear all caches
echo 3 | tee /proc/sys/vm/drop_caches;


# Check for requierd applications needed to run this script
[ $(which lvcreate > /dev/null 2>&1; echo ${?}) -ne 0 ] && { echo -e "\nlvcreate is required...exiting"; exit 1; };
lvc=$(which lvcreate);
[ $(which lvremove > /dev/null 2>&1; echo ${?}) -ne 0 ] && { echo -e "\nlvremove is required...exiting"; exit 1; };
lvr=$(which lvremove);
[ $(rpm -qa | grep perl-Digest-MD5 > /dev/null 2>&1; echo ${?}) -ne 0 ] && { echo -e "\nperl-Digest-MD5 is required...exiting"; exit 1; };
[ $(which lzop > /dev/null 2>&1; echo ${?}) -ne 0 ] && { echo -e "\nlzop is required...exiting"; exit 1; };

scriptPath=$(dirname "${BASH_SOURCE[0]}");

# Check if configuration file exists
configFile="${scriptPath}/bdb.cfg";
[ ! -f ${configFile} ] && { echo -e "\nConfig file not found, creating it\nPlease add your LVMs to the config file before continuing\n" && touch ${configFile} && exit 1; };
[ ! -s ${configFile} ] && { echo -e "\n${configFile} is empty, please fill in your KVM details\n" && exit 1; };

# Check Folder Structure
[ ! -d "${scriptPath}/key" ] || [ ! -d "${scriptPath}/logs" ] && mkdir -p "${scriptPath}"/{key,logs};

# Check if ssh key exists
[ ! -f "${scriptPath}/key/lvm-backup" ] && { ssh-keygen -b 4096 -q -t rsa -N "" -C "Remote KVM LVM Backups" -f "${scriptPath}/key/lvm-backup" && chmod 600 ${scriptPath}/key/lvm-backup* && echo -e "\nSSH Key has been created in ${scriptPath}/key called lvm-backup.pub\nYou must copy the key to your remote server.\nSSH key copy command: cat ${scriptPath}/key/lvm-backup.pub | ssh -p ${remotePort} ${remoteUser}@${remoteAddress} 'cat >> .ssh/authorized_keys'\n" && exit 1; };

# Log Function
log() {
    if [ "${1}" == "error" ]; then
        echo "[`date +%Y-%m-%d_%H.%M.%S`] ${1} ${2}" >> ${scriptPath}/logs/error.log;
        echo "[`date +%Y-%m-%d_%H.%M.%S`] ${1} ${2}" >> ${scriptPath}/logs/complete.log;
    elif [ "${1}" == "success" ]; then
        echo "[`date +%Y-%m-%d_%H.%M.%S`] ${1} ${2}" >> ${scriptPath}/logs/success.log;
        echo "[`date +%Y-%m-%d_%H.%M.%S`] ${1} ${2}" >> ${scriptPath}/logs/complete.log;
    fi;
};

# Fix tail count
#backupRevisions=$((${backupRevisions} + 1));

# Get Hostname
hName=$(hostname);

# Loop through config file
for backupList in `grep -v '^#' ${configFile} | awk '{print $2}'`; do
    iDomName=$(grep "${backupList}" ${configFile} | awk '{print $1}');
    iCompression=$(grep "${backupList}" ${configFile} | awk '{print $3}');
    
    date=$(date +%Y-%m-%d_%H.%M.%S);
    
    # Dump KVM Domain XML file
    ssh -i ${scriptPath}/key/lvm-backup -p ${remotePort} ${remoteUser}@${remoteAddress} "ls -dt /tmp/${iDomName}.* | xargs rm -f;";
    virsh dumpxml ${iDomName} | ssh -i ${scriptPath}/key/lvm-backup -p ${remotePort} ${remoteUser}@${remoteAddress} "cat > /tmp/${iDomName}.${date}.xml";
    
    # Check if Virtual Host has been defined
    [ `ssh -i ${scriptPath}/key/lvm-backup -p ${remotePort} ${remoteUser}@${remoteAddress} "virsh list --name --all | head -n -1 | grep -c '${iDomName}'"` -eq "0" ] && ssh -i ${scriptPath}/key/lvm-backup -p ${remotePort} ${remoteUser}@${remoteAddress} "virsh define /tmp/${iDomName}.${date}.xml";
    
    for lvm in `virsh dumpxml "${iDomName}" | grep 'source dev' | grep -o "'.*'" | tr -d "'" | rev | cut -d '/' -f1 | rev`; do
        iVolumeGroup=$(echo "${lvm}" | awk -F '-' '{print $1}');
        iDomName=$(echo "${lvm}" | awk -F '-' '{print $2}');
    
        # Check for stale snapshot & remove
        [ `lvs --separator ',' | awk -F ',' '$6 == '\"${iDomName}\"' && $2 == '\"${iVolumeGroup}\"' {print $1}' | tr -d ' ' | wc -l` -ne "0" ] && ${lvr} -f ${iVolumeGroup}\/${iDomName}_snap;
    
        lv_path=$(lvscan | cut -d "'" -f2 | grep "`echo ${iVolumeGroup}\/${iDomName}`");
        [ -z "${lv_path}" ] && { log error "Error: LVM path ${lv_path} does not exist, correct the path name in config file" && continue; };
    
        [ -z "${iDomName}" ] && { log error "Error: No Virtual Host Name or Compression Type Specified...Skipping" && continue; };
        [ -z "${iVolumeGroup}" ] && { log error "Unable to determine the Volume Group...Skipping" && continue; };
        [ -z "${iCompression}" ] && { log error "Error: No Virtual Host Name or Compression Type Specified...Skipping" && continue; };
    
        # Get LVM size assuming it is in GB
        size=$(lvs ${lv_path} -o LV_SIZE --noheadings --units g --nosuffix | tr -d ' ');

        # Create LVM Snapshot
        ${lvc} -s --size=${size}G -n ${iDomName}_snap ${lv_path};
    
        # Create LVM on remote server
        [ `ssh -i ${scriptPath}/key/lvm-backup -p ${remotePort} ${remoteUser}@${remoteAddress} "lvcreate -L ${size}G -n ${iDomName} ${iVolumeGroup} > /dev/null 2>&1;"; echo ${?}` -eq "0" ] && copyType="full" || copyType="incremental";

        # LVM Checksum Function
        checkSum() {
            # Get Local & Remote LVM checksums
            localMD5=$(md5sum ${lv_path}_snap | awk '{print $1}');
            remoteMD5=$(ssh -i ${scriptPath}/key/lvm-backup -p ${remotePort} ${remoteUser}@${remoteAddress} "md5sum ${lv_path} | awk '{print \$1}'");

            # Compare Snapshot local & remote LVM
            if [ -n "${copyCheck+x}" ]; then
                [ "${localMD5}" == "${remoteMD5}" ] && integrityCheck="passed" || integrityCheck="failed";
            else
                [ "${localMD5}" == "${remoteMD5}" ] && { log success "LVM Images are identical, no backup required...Skipping" && continue; } || incrementalBackup;
            fi;
        };

        fullBackup() {
            if [ "${iCompression}" == "yes" ]; then
                copyBackup() {
                    [ -z "${copyCount+x}" ] && copyCount="1";
                    [ "${copyCount}" -gt "3" ] && { log error "Error: Copy failed after 3 attempts for ${hName}.${iVolumeGroup}-${iDomName} to backup server ${remoteAddress}." && continue; };
                    /bin/dd if=${lv_path}_snap bs=64K | gzip -c -9 | ssh -i ${scriptPath}/key/lvm-backup -p ${remotePort} ${remoteUser}@${remoteAddress} "gzip -dc | dd of=${lv_path}";
                    copyCheck="yes";
                    checkSum;
                    if [ "${integrityCheck}" == "failed" ]; then
                        log error "Backup file integrity error...backup file restarting backup procedure";
                        (( copyCount++ ));
                        copyBackup;
                    else
                        ${lvr} -f ${lv_path}_snap;
                        log success "Copy for ${hName}.${iVolumeGroup}-${iDomName} to backup server ${remoteAddress} was successful.";
                    fi;
                };
                copyBackup;
            elif [ "${iCompression}" == "no" ]; then
                copyBackup() {
                    [ -z "${copyCount}" ] && copyCount="1";
                    [ "${copyCount}" -gt "3" ] && { log error "Error: Copy failed after 3 attempts for ${hName}.${iVolumeGroup}-${iDomName} to backup server ${remoteAddress}." && continue; };
                    /bin/dd if=${lv_path}_snap bs=64K | ssh -i ${scriptPath}/key/lvm-backup -p ${remotePort} ${remoteUser}@${remoteAddress} "dd of=${lv_path}";
                    copyCheck="yes";
                    checkSum;
                    if [ "${integrityCheck}" == "failed" ]; then
                        log error "Backup file integrity error...backup file restarting backup procedure";
                        (( copyCount++ ));
                        copyBackup;
                    else
                        ${lvr} -f ${lv_path}_snap;
                        log success "Copy for ${hName}.${iVolumeGroup}-${iDomName} to backup server ${remoteAddress} was successful.";
                    fi;
                };
                copyBackup;
            fi;
        };
    
        incrementalBackup() {
            ssh -i ${scriptPath}/key/lvm-backup -p ${remotePort} ${remoteUser}@${remoteAddress} "perl -'MDigest::MD5 md5' -ne 'BEGIN{\$/=\1024};print md5(\$_)' ${lv_path} | lzop -c" | lzop -dc | perl -'MDigest::MD5 md5' -ne 'BEGIN{$/=\1024};$b=md5($_);
            read STDIN,$a,16;if ($a eq $b) {print "s"} else {print "c" . $_}' ${lv_path}_snap | lzop -c | ssh -i ${scriptPath}/key/lvm-backup -p ${remotePort} ${remoteUser}@${remoteAddress} "lzop -dc | perl -ne 'BEGIN{\$/=\1} if (\$_ eq\"s\") {\$s++} else {if (\$s) {
                seek STDOUT,\$s*1024,1; \$s=0}; read ARGV,\$buf,1024; print \$buf}' 1<> ${lv_path}"
        };

        # Check if Virtual Guest is running
        if [ `ssh -i ${scriptPath}/key/lvm-backup -p ${remotePort} ${remoteUser}@${remoteAddress} "virsh list --name --title --state-running | grep -c '${iDomName}'"` -ne "0" ]; then
            # stop the virtual guest or warn & skip
            echo "Virtual Guest is running on remote server, cant start backup...skipping";
        else
            # Check if LVM images differ
            [ `echo "${copyType}"` == "incremental" ] && checkSum || fullBackup;
        fi;
	done;
done;
