#!/bin/bash

err_handler() {
	ret=$?
	[ "$ret" -eq 0 ] && return

	msg_error "Running ${FUNCNAME[1]} failed!"
	msg_error "exit code $ret from line ${BASH_LINENO[0]}:"
	msg_info "    $BASH_COMMAND"
	exit $ret
}

trap 'err_handler' ERR
# source files
src=$1
# generate image
dst=$2

if [ -z "$3" -o -z "$dst" -o ! -d "$src" ]; then
	echo "command format: $(basename $0) <source> <dest image> <partition size>"
	exit 0
fi
source_date_epoch="${SOURCE_DATE_EPOCH:-0}"
if ! [[ "$source_date_epoch" =~ ^[0-9]+$ ]] || [ "$source_date_epoch" -gt 4294967295 ]; then
	echo "SOURCE_DATE_EPOCH must be an unsigned 32-bit Unix timestamp: $source_date_epoch" >&2
	exit 1
fi

write_ext4_le32() {
	local image="$1"
	local offset="$2"
	local value="$3"
	local b0 b1 b2 b3

	b0=$((value & 255))
	b1=$(((value >> 8) & 255))
	b2=$(((value >> 16) & 255))
	b3=$(((value >> 24) & 255))
	printf "\\$(printf '%03o' "$b0")\\$(printf '%03o' "$b1")\\$(printf '%03o' "$b2")\\$(printf '%03o' "$b3")" |
		dd of="$image" bs=1 seek="$((1024 + offset))" conv=notrunc >/dev/null 2>&1
}

normalize_ext4_superblock_times() {
	write_ext4_le32 "$dst" 44 "$source_date_epoch"
	write_ext4_le32 "$dst" 48 "$source_date_epoch"
	write_ext4_le32 "$dst" 64 "$source_date_epoch"
	write_ext4_le32 "$dst" 264 "$source_date_epoch"
}

mkfs_ext4_uuid_opt=()
case "$(basename "$dst")" in
	rootfs*.img | system*.img)
		mkfs_ext4_uuid_opt=(-U "${AIDEN_EXT4_UUID:-00000000-0000-4000-8000-000000000000}")
		;;
esac


# the size of generate image, get info from parameter.txt
# eg. 0x00040000@0x00016000(rootfs)
# calculate size fo rootfs partition: 0x00040000 * 512 = 128*0x100000 (Bytes)
dst_size="$(( $3 / 1024 / 1024 ))M"

cwd=$(dirname $(readlink -f $0))
export PATH=$cwd:$PATH

rm -f $dst

bin_dir=./
if [ -f $cwd/bin/mkfs.ext4 ];then
	bin_dir=bin
fi
mkfs_ext4_opts=(
	-d "$src"
	-r 1
	-N 0
	-m 5
	-L ""
	"${mkfs_ext4_uuid_opt[@]}"
	-E lazy_itable_init=0,lazy_journal_init=0,root_owner=0:0
	-O ^64bit,^huge_file,^metadata_csum,^metadata_csum_seed
)


mkdir -p $(dirname $dst)

echo mkfs.ext4 "${mkfs_ext4_opts[@]}" "$dst" "$dst_size"
mkfs.ext4 "${mkfs_ext4_opts[@]}" "$dst" "$dst_size"
if [ $? != 0 ]; then
	echo "*** Maybe you need to increase the filesystem size "
	exit 1
fi
echo "resize2fs -M $dst"
resize2fs -M $dst
echo "e2fsck -fy  $dst"
e2fsck -fy  $dst
echo "tune2fs -m 5  $dst"
tune2fs -m 5  $dst
echo "resize2fs -M $dst"
resize2fs -M $dst
echo "normalize ext4 superblock timestamps to SOURCE_DATE_EPOCH=$source_date_epoch"
normalize_ext4_superblock_times
