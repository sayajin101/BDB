# BDB
KVM LVM (Block Device) Incremental Backup

* This script is designed to do Live LVM Snapshot backups of KVM virtual servers
* Once it has created the LVM snapshot it will dd the LVM image & gzip it at the same time to a specified location.
* Once the gzip process is complete it will remove the LVM snapshot.
* This script requires the "bdb.cfg" file to exist which must contain the Virsh domain name and either yes or no
 for compression
 * This script will do a once off full backup, and then do imcremental backups after that which are merged with
 the full backup.
 * Please note on the remote side the LVM must not be active/mounted
