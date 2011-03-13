#!/bin/bash
# Build an XCP VM disk and run it

set -e

function usage () {
    echo "Usage:"
    echo "   `basename $0` [-x <xenserver host> -u <name of this domU vm>] [-s <sr-uuid to place vdi>] <kernel name>"
}

function on_exit () {
    echo " *** Caught an error! Cleaning up."
    if [ -n "${VBD}" ]; then
        echo "Destroying VBD ${VBD}"
        ${SUDO} umount ${MNT}
        ${XE} vbd-unplug uuid=${VBD}
        ${XE} vbd-destroy uuid=${VBD}
    fi
    if [ -n "${VDI}" ]; then
        echo "Destroying VDI ${VDI}"
        ${XE} vdi-destroy uuid=${VDI}
    fi
    if [ -n "${MIRAGE_VM}" ]; then
        echo "Destroying mirage VM ${MIRAGE_VM}"
        ${XE} vm-destroy uuid=${MIRAGE_VM}
    fi
    echo "Quitting"
}

while getopts ":x:u:s:" option
do
    case $option in
        x ) DOM0_HOST=${OPTARG} ;;
        u ) MY_VM_NAME=${OPTARG} ;;
        s ) SR_UUID=${OPTARG} ;;
        : ) usage
            echo "Option -${OPTARG} requires an argument."
            exit 1;;
        '?' ) usage
            echo "Invalid option -${OPTARG}."
            exit 1 ;;
    esac
done

# Kernel name will be first unprocessed arguement remaining
ARGS=($@)
KERNEL_PATH=${ARGS[${OPTIND}-1]}

# Required args: kernel name, and (if -x then also -u)
if [ -z ${KERNEL_PATH} ]; then
    usage
    echo 'Missing kernel name.'
    exit 1
fi

KERNEL_NAME=$(basename ${KERNEL_PATH})
MNT='/mnt'
SUDO='sudo'
SIZE='10MiB' # TODO: figure this out based on compressed kernel size plus some offset.

# Set XE command depending on whether we're in dom0 or domU
if [ -z "${DOM0_HOST}" ]; then
    XE="xe"
    MY_VM=$(xenstore-read /local/domain/0/vm | cut -f 3 -d /)
    echo "Using '${XE}', this VM's uuid is ${MY_VM}"
else
    SSH="ssh root@${DOM0_HOST}"
    XE="${SSH} xe"
    # if we're not in dom0, then we need the domU vm name
    if [ -z ${MY_VM_NAME} ]; then
        usage
        echo "If we aren't running in dom0, then you need to specify your domU's VM name (not hostname)."
        exit 1
    else
        MY_VM=$(${XE} vm-list name-label=${MY_VM_NAME} --minimal)
    fi
    echo "Using '${XE}', this VM's uuid is ${MY_VM}"
fi

if [ -z "${SR_UUID}" ]; then
    SR_UUID=$(${XE} sr-list name-label=Local\\ storage --minimal)
fi
echo "Using SR ${SR_UUID}"

# Set error handler trap to clean up after an error
trap on_exit EXIT

# Create VDI
VDI=$(${XE} vdi-create name-label=${KERNEL_NAME}-vdi sharable=true \
   type=user virtual-size=${SIZE} sr-uuid=${SR_UUID})
echo "Created VDI ${VDI}"

# Create VBD (with vdi and this vm)
VBD_DEV=$(${XE} vm-param-get uuid=${MY_VM} \
    param-name=allowed-VBD-devices | cut -f 1 -d \;)
VBD=$(${XE} vbd-create vm-uuid=${MY_VM} vdi-uuid=$VDI device=${VBD_DEV} type=Disk)
echo "Created VBD ${VBD} as virtual device number ${VBD_DEV}"

# Plug VBD
${XE} vbd-plug uuid=${VBD}

# Mount vdi disk
XVD=(a b c d e f g h i j k l m n)
XVD_="xvd${XVD[${VBD_DEV}]}"
echo "Making ext3 filesystem on /dev/${XVD_}"
mke2fs -j /dev/${XVD_}
echo "Filesystem mounted at ${MNT}"
${SUDO} mount -t ext3 /dev/${XVD_} ${MNT}

# Write grub.conf to vdi disk
${SUDO} mkdir -p ${MNT}/boot/grub
echo default 0 > menu.lst
echo timeout 1 >> menu.lst
echo title Mirage >> menu.lst
echo " root (hd0)" >> menu.lst
echo " kernel /boot/${KERNEL_NAME}.gz" >> menu.lst
${SUDO} mv menu.lst ${MNT}/boot/grub/menu.lst

# Copy kernel image to vdi disk
gzip ${KERNEL_PATH}
${SUDO} cp ${KERNEL_PATH}.gz ${MNT}/boot/${KERNEL_NAME}.gz
gunzip ${KERNEL_PATH}

echo "Wrote grub.conf and copied kernel to ${MNT}/boot"

# Unmount and unplug vbd
${SUDO} umount ${MNT}
${XE} vbd-unplug uuid=${VBD}
${XE} vbd-destroy uuid=${VBD}

echo "Unmounted and destroyed VBD."

# Create mirage vm
MIRAGE_VM=$(${XE} vm-install template=Other\\ install\\ media new-name-label=${KERNEL_NAME})
${XE} vm-param-set uuid=${MIRAGE_VM} PV-bootloader=pygrub
${XE} vm-param-set uuid=${MIRAGE_VM} HVM-boot-policy=
${XE} vm-param-clear uuid=${MIRAGE_VM} param-name=HVM-boot-params

# Attach vdi to mirage vm and make bootable
VBD_DEV=$(${XE} vm-param-get uuid=${MIRAGE_VM} \
    param-name=allowed-VBD-devices | cut -f 1 -d \;)
VBD=$(${XE} vbd-create vm-uuid=${MIRAGE_VM} vdi-uuid=${VDI} device=${VBD_DEV} type=Disk)
${XE} vbd-param-set uuid=$VBD bootable=true

# Turn off error handling
trap - EXIT

echo "Created Mirage VM ${MIRAGE_VM}"