#!/bin/bash
 
set -e
set -x
 
fail() {
	echo $1
	[ -e ${EBS_DEVICE} ] && [ "$VOLUME_ID" != "" ] && [ $REGION != "" ] && {
		ec2-detach-volume --region $REGION $VOLUME_ID
		ec2-delete-volume --region $REGION $VOLUME_ID	
	}
	exit 1	
}
 
[ "$NAME" = "" ] && NAME=mirage-`date -u +%s`
 
# these work but are quite slow;
# the user would do well to set these values as environment variables
[ "$REGION" = "" ] && REGION=eu-west-1 #TODO: autodiscover the instance's region
[ "$EBS_DEVICE" = "" ] && EBS_DEVICE="/dev/xvdh"
[ "$HOST_INSTANCE_ID" = "" ] && HOST_INSTANCE_ID=`ec2-describe-instances --region $REGION -F tag:role=host|grep ^INSTANCE|cut -f2`
[ "$ZONE" = "" ] && ZONE=`ec2-describe-instances -F instance-id=$HOST_INSTANCE_ID --region $REGION|cut -f12|grep -v "^$"`
 
EXTANT_IMAGE=`ec2-describe-images -o self --filter name="$NAME" --filter architecture=x86_64 --region $REGION --hide-tags|grep "^IMAGE"|cut -f2`
if [ "$EXTANT_IMAGE" ]; then
	echo "An image already exists with the name $NAME".  ec2-bundle-create will fail.
	echo "To delete the extant image, try this:"
	fail "ec2-deregister --region $REGION $EXTANT_IMAGE"
fi
 
if [ -e $EBS_DEVICE ]; then
	fail "There is already a device present at $EBS_DEVICE.  Please change the device ID or detach the device."
fi
 
#make an EBS volume of small size
VOLUME_ID=`ec2-create-volume --size 1 --region ${REGION} -z ${ZONE}|cut -f2`
if [ "$VOLUME_ID" = "" ]; then
	fail "Failed to create an EBS volume."
fi
 
#attach it to ourselves
ec2-attach-volume $VOLUME_ID -i $HOST_INSTANCE_ID -d $EBS_DEVICE --region $REGION
[ $? -ne 0 ] && {
	fail "Couldn't attach the EBS volume to this instance."
}
 
[ ! -e ${EBS_DEVICE} ] && sleep 2
[ ! -e ${EBS_DEVICE} ] && sleep 2
[ ! -e ${EBS_DEVICE} ] && sleep 2
 
# KERNEL is ec2-describe-images -o amazon --region ${REGION} -F "manifest-location=*pv-grub-hd0*" -F "architecture=x86_64" | tail -1 | cut -f2
KERNEL_ID=`ec2-describe-images -o amazon --region ${REGION} -F "manifest-location=*pv-grub-hd0*" -F "architecture=x86_64"| tail -1 | cut -f2`
IMG=${NAME}.img
MNT=/mnt
SUDO=sudo
 
${SUDO} mkfs.ext2 $EBS_DEVICE
 
#${SUDO} mkdir -p /mnt/mirage
#rm -f ${IMG}
#dd if=/dev/zero of=${IMG} bs=1M count=20
#${SUDO} mke2fs -F -j ${IMG}
#${SUDO} mount -o loop ${IMG} ${MNT}
${SUDO} mount -t ext2 ${EBS_DEVICE} $MNT
 
${SUDO} mkdir -p ${MNT}/boot/grub
echo default 0 > menu.lst
echo timeout 1 >> menu.lst
echo title Mirage >> menu.lst
echo " root (hd0)" >> menu.lst
echo " kernel /boot/mirage-os.gz" >> menu.lst
${SUDO} mv menu.lst ${MNT}/boot/grub/menu.lst
 
${SUDO} sh -c "cp xen/`cat xen/latest`/mir-www.xen.gz ${MNT}/boot/mirage-os.gz"
${SUDO} umount -d ${MNT}
 
SNAPSHOT_ID=`ec2-create-snapshot --region $REGION $VOLUME_ID|cut -f2`
[ "$SNAPSHOT_ID" = "" ] && fail "Couldn't make a snapshot of the EBS volume."
 
AMI_ID=`ec2-register -n $NAME --snapshot $SNAPSHOT_ID --kernel $KERNEL_ID --region $REGION --architecture x86_64|cut -f2`
 
[ "$AMI_ID" = "" ] && {
	echo "Retrying snapshot..."
	sleep 5
	AMI_ID=`ec2-register -n $NAME --snapshot $SNAPSHOT_ID --kernel $KERNEL_ID --region $REGION --architecture x86_64|cut -f2`
}
 
 
[ "$AMI_ID" = "" ] && fail "Couldn't make an AMI from the snapshot $SNAPSHOT_ID and the kernel ID $KERNEL_ID ."
 
#now make an instance running that.
#TODO: should be able to specify security group here.
INSTANCE_ID=`ec2-run-instances $AMI_ID  -t t1.micro --region ${REGION}|grep ^INSTANCE|cut -f2`
 
[ "$INSTANCE_ID" = "" ] && fail "Couldn't start an instance with AMI ID $AMI_ID ."
 
echo "Successfully made an instance; it should be online soon."
echo "To keep an eye on it:"
echo "ec2-get-console-output --region $REGION $INSTANCE_ID"
 
ec2-detach-volume --region $REGION $VOLUME_ID
ec2-delete-volume --region $REGION $VOLUME_ID
