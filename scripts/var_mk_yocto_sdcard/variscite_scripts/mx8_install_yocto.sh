#!/bin/bash -e

. /usr/bin/echos.sh

IMGS_PATH=/opt/images/Yocto
UBOOT_IMAGE=imx-boot-sd.bin
ROOTFS_IMAGE=rootfs.tar.gz
BOOTLOADER_RESERVED_SIZE=8
BOOTLOADER_OFFSET=33
DISPLAY=lvds
PART=p
ROOTFSPART=1
BOOTDIR=/boot

check_board()
{
	if grep -q "i.MX8MM" /sys/devices/soc0/soc_id; then
		BOARD=imx8mm-var-dart
		DTB_PREFIX=fsl-imx8mm-var-dart
		BLOCK=mmcblk2
	elif grep -q "i.MX8QXP" /sys/devices/soc0/soc_id; then
		BOARD=imx8qxp-var-som
		DTB_PREFIX=fsl-imx8qxp-var-som
		BLOCK=mmcblk0
		BOOTLOADER_OFFSET=32
	elif grep -q "i.MX8QM" /sys/devices/soc0/soc_id; then
		BOARD=imx8qm-var-som
		DTB_PREFIX=fsl-imx8qm-var-som
		BLOCK=mmcblk0
		BOOTLOADER_OFFSET=32
	elif grep -q "i.MX8M" /sys/devices/soc0/soc_id; then
		BOARD=imx8m-var-dart
		DTB_PREFIX=fsl-imx8mq-var-dart
		BLOCK=mmcblk0

		if [[ $DISPLAY != "lvds" && $DISPLAY != "hdmi" && \
		      $DISPLAY != "dual-display" ]]; then
			red_bold_echo "ERROR: invalid display, should be lvds, hdmi or dual-display"
			exit 1
		fi
	else
		red_bold_echo "ERROR: Unsupported board"
		exit 1
	fi


	if [[ ! -b /dev/${BLOCK} ]] ; then
		red_bold_echo "ERROR: Can't find eMMC device (/dev/${BLOCK})."
		red_bold_echo "Please verify you are using the correct options for your SOM."
		exit 1
	fi
}

check_images()
{
	if [[ ! -f $IMGS_PATH/$UBOOT_IMAGE ]] ; then
		red_bold_echo "ERROR: \"$IMGS_PATH/$UBOOT_IMAGE\" does not exist"
		exit 1
	fi

	if [[ ! -f $IMGS_PATH/$ROOTFS_IMAGE ]] ; then
		red_bold_echo "ERROR: \"$IMGS_PATH/$ROOTFS_IMAGE\" does not exist"
		exit 1
	fi
}

delete_emmc()
{
	echo
	blue_underlined_bold_echo "Deleting current partitions"

	umount /dev/${BLOCK}${PART}* 2>/dev/null || true

	for ((i=1; i<=16; i++)); do
		if [[ -e /dev/${BLOCK}${PART}${i} ]]; then
			dd if=/dev/zero of=/dev/${BLOCK}${PART}${i} bs=1M count=1 2>/dev/null || true
		fi
	done
	sync

	dd if=/dev/zero of=/dev/${BLOCK} bs=1M count=${BOOTLOADER_RESERVED_SIZE}

	sync; sleep 1
}

create_emmc_parts()
{
	echo
	blue_underlined_bold_echo "Creating new partitions"

	SECT_SIZE_BYTES=`cat /sys/block/${BLOCK}/queue/hw_sector_size`
	PART1_FIRST_SECT=$(($BOOTLOADER_RESERVED_SIZE * 1024 * 1024 / $SECT_SIZE_BYTES))

	(echo n; echo p; echo $ROOTFSPART; echo $PART1_FIRST_SECT; echo; \
	 echo p; echo w) | fdisk -u /dev/${BLOCK} > /dev/null

	sync; sleep 1
	fdisk -u -l /dev/${BLOCK}
}

create_emmc_swupdate_parts()
{
	echo
	blue_underlined_bold_echo "Creating new partitions"

	TOTAL_SECTORS=`cat /sys/block/${BLOCK}/size`
	SECT_SIZE_BYTES=`cat /sys/block/${BLOCK}/queue/hw_sector_size`

	BOOTLOADER_RESERVED_SIZE_BYTES=$((BOOTLOADER_RESERVED_SIZE * 1024 * 1024))
	ROOTFS1_PART_START=$((BOOTLOADER_RESERVED_SIZE_BYTES / SECT_SIZE_BYTES))

	DATA_SIZE_BYTES=$((DATA_SIZE * 1024 * 1024))
	DATA_PART_SIZE=$((DATA_SIZE_BYTES / SECT_SIZE_BYTES))

	ROOTFS1_PART_SIZE=$((( TOTAL_SECTORS - ROOTFS1_PART_START - DATA_PART_SIZE ) / 2))
	ROOTFS2_PART_SIZE=$ROOTFS1_PART_SIZE

	ROOTFS2_PART_START=$((ROOTFS1_PART_START + ROOTFS1_PART_SIZE))
	DATA_PART_START=$((ROOTFS2_PART_START + ROOTFS2_PART_SIZE))

	ROOTFS1_PART_END=$((ROOTFS2_PART_START - 1))
	ROOTFS2_PART_END=$((DATA_PART_START - 1))

	if [[ $ROOTFS1_PART_START == 0 ]] ; then
		ROOTFS1_PART_START=""
	fi

	(echo n; echo p; echo $ROOTFSPART;  echo $ROOTFS1_PART_START; echo $ROOTFS1_PART_END; \
	 echo n; echo p; echo $ROOTFS2PART; echo $ROOTFS2_PART_START; echo $ROOTFS2_PART_END; \
	 echo n; echo p; echo $DATAPART;    echo $DATA_PART_START; echo; \
	 echo p; echo w) | fdisk -u /dev/${BLOCK} > /dev/null

	sync; sleep 1
	fdisk -u -l /dev/${BLOCK}
}


format_emmc_parts()
{
	echo
	blue_underlined_bold_echo "Formatting partitions"

	if [[ $swupdate == 0 ]] ; then
		mkfs.ext4 /dev/${BLOCK}${PART}${ROOTFSPART} -L rootfs
	elif [[ $swupdate == 1 ]] ; then
		mkfs.ext4 /dev/${BLOCK}${PART}${ROOTFSPART}  -L rootfs1
		mkfs.ext4 /dev/${BLOCK}${PART}${ROOTFS2PART} -L rootfs2
		mkfs.ext4 /dev/${BLOCK}${PART}${DATAPART}    -L data
	fi
	sync; sleep 1
}

install_bootloader_to_emmc()
{
	echo
	blue_underlined_bold_echo "Installing booloader"

	dd if=${IMGS_PATH}/${UBOOT_IMAGE} of=/dev/${BLOCK} bs=1K seek=${BOOTLOADER_OFFSET}
	sync
}

install_rootfs_to_emmc()
{
	echo
	blue_underlined_bold_echo "Installing rootfs"

	MOUNTDIR=/run/media/${BLOCK}${PART}${ROOTFSPART}
	mkdir -p ${MOUNTDIR}
	mount /dev/${BLOCK}${PART}${ROOTFSPART} ${MOUNTDIR}

	printf "Extracting files"
	tar --warning=no-timestamp -xpf ${IMGS_PATH}/${ROOTFS_IMAGE} -C ${MOUNTDIR} --checkpoint=.1200

	if [[ ${BOARD} = "imx8m-var-dart" ]]; then
		# Create DTB symlinks
		(cd ${MOUNTDIR}/${BOOTDIR}; ln -fs ${DTB_PREFIX}-emmc-wifi-${DISPLAY}.dtb ${DTB_PREFIX}.dtb)
		(cd ${MOUNTDIR}/${BOOTDIR}; ln -fs ${DTB_PREFIX}-emmc-wifi-${DISPLAY}-cb12.dtb ${DTB_PREFIX}-cb12.dtb)

		# Install blacklist.conf
		cp ${MOUNTDIR}/etc/wifi/blacklist.conf ${MOUNTDIR}/etc/modprobe.d
	fi

	if [[ ${BOARD} = "imx8qxp-var-som" ]]; then
		# Create DTB symlink
		(cd ${MOUNTDIR}/${BOOTDIR}; ln -fs ${DTB_PREFIX}-wifi.dtb ${DTB_PREFIX}.dtb)

		# Install blacklist.conf
		cp ${MOUNTDIR}/etc/wifi/blacklist.conf ${MOUNTDIR}/etc/modprobe.d
	fi

	# Adjust u-boot-fw-utils for eMMC on the installed rootfs
	sed -i "s/\/dev\/mmcblk./\/dev\/${BLOCK}/" ${MOUNTDIR}/etc/fw_env.config

	echo
	sync

	umount ${MOUNTDIR}
}

stop_udev()
{
	if [ -f /lib/systemd/system/systemd-udevd.service ]; then
		systemctl -q mask --runtime systemd-udevd
		systemctl -q stop systemd-udevd
	fi
}

start_udev()
{
	if [ -f /lib/systemd/system/systemd-udevd.service ]; then
		systemctl -q unmask --runtime systemd-udevd
		systemctl -q start systemd-udevd
	fi
}

usage()
{
	echo
	echo "This script installs Yocto on the SOM's internal storage device"
	echo
	echo " Usage: $(basename $0) <option>"
	echo
	echo " options:"
	echo " -h                           show help message"
	echo " -d <lvds|hdmi|dual-display>  set display type, default is lvds"
	echo " -u                           create two rootfs partitions (for swUpdate double-copy)."
	echo
}

finish()
{
	echo
	blue_bold_echo "Yocto installed successfully"
	exit 0
}

#################################################
#           Execution starts here               #
#################################################

if [[ $EUID != 0 ]] ; then
	red_bold_echo "This script must be run with super-user privileges"
	exit 1
fi

blue_underlined_bold_echo "*** Variscite MX8M Yocto eMMC Recovery ***"
echo

swupdate=0

while getopts d:hu OPTION;
do
	case $OPTION in
	d)
		DISPLAY=$OPTARG
		;;
	h)
		usage
		exit 0
		;;
	u)
		swupdate=1
		;;
	*)
		usage
		exit 1
		;;
	esac
done

printf "Board: "
blue_bold_echo $BOARD

printf "Installing to internal storage device: "
blue_bold_echo eMMC

if [[ $swupdate == 1 ]] ; then
	blue_bold_echo "Creating two rootfs partitions"

	ROOTFS2PART=2
	DATAPART=3
	DATA_SIZE=200
fi

check_board
check_images
stop_udev
delete_emmc
if [[ $swupdate == 0 ]] ; then
	create_emmc_parts
elif [[ $swupdate == 1 ]] ; then
	create_emmc_swupdate_parts
fi
format_emmc_parts
install_bootloader_to_emmc
install_rootfs_to_emmc
start_udev
finish
