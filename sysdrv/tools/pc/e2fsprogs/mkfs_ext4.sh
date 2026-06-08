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
source_date_epoch_len="${#source_date_epoch}"
if ! [[ "$source_date_epoch" =~ ^[0-9]+$ ]] ||
	[ "$source_date_epoch_len" -gt 10 ] ||
	{ [ "$source_date_epoch_len" -eq 10 ] && [[ "$source_date_epoch" > "4294967295" ]]; }; then
	echo "SOURCE_DATE_EPOCH must be an unsigned 32-bit Unix timestamp: $source_date_epoch" >&2
	exit 1
fi
export SOURCE_DATE_EPOCH="$source_date_epoch"

read_ext4_le16_at() {
	local image="$1"
	local byte_offset="$2"
	local bytes=()

	read -r -a bytes < <(dd if="$image" bs=1 skip="$byte_offset" count=2 2>/dev/null | od -An -tu1 -v)
	if [ "${#bytes[@]}" -ne 2 ]; then
		echo "Failed to read ext4 field at byte offset $byte_offset from $image" >&2
		exit 1
	fi

	echo $((bytes[0] | (bytes[1] << 8)))
}

read_ext4_le32_at() {
	local image="$1"
	local byte_offset="$2"
	local bytes=()

	read -r -a bytes < <(dd if="$image" bs=1 skip="$byte_offset" count=4 2>/dev/null | od -An -tu1 -v)
	if [ "${#bytes[@]}" -ne 4 ]; then
		echo "Failed to read ext4 field at byte offset $byte_offset from $image" >&2
		exit 1
	fi

	echo $((bytes[0] | (bytes[1] << 8) | (bytes[2] << 16) | (bytes[3] << 24)))
}

write_ext4_le32_at() {
	local image="$1"
	local byte_offset="$2"
	local value="$3"
	local b0 b1 b2 b3

	b0=$((value & 255))
	b1=$(((value >> 8) & 255))
	b2=$(((value >> 16) & 255))
	b3=$(((value >> 24) & 255))
	printf "\\$(printf '%03o' "$b0")\\$(printf '%03o' "$b1")\\$(printf '%03o' "$b2")\\$(printf '%03o' "$b3")" |
		dd of="$image" bs=1 seek="$byte_offset" conv=notrunc >/dev/null 2>&1
}

is_ext4_superblock_at() {
	local image="$1"
	local sb_offset="$2"
	local expected_log_block_size="$3"
	local expected_blocks_per_group="$4"
	local expected_first_data_block="$5"
	local magic log_block_size blocks_per_group first_data_block

	magic="$(read_ext4_le16_at "$image" "$((sb_offset + 56))")"
	[ "$magic" -eq 61267 ] || return 1

	log_block_size="$(read_ext4_le32_at "$image" "$((sb_offset + 24))")"
	blocks_per_group="$(read_ext4_le32_at "$image" "$((sb_offset + 32))")"
	first_data_block="$(read_ext4_le32_at "$image" "$((sb_offset + 20))")"

	[ "$log_block_size" -eq "$expected_log_block_size" ] || return 1
	[ "$blocks_per_group" -eq "$expected_blocks_per_group" ] || return 1
	[ "$first_data_block" -eq "$expected_first_data_block" ] || return 1
}

normalize_ext4_superblock_times() {
	local image="$dst"
	local blocks_count first_data_block log_block_size block_size blocks_per_group
	local group_count group sb_offset patched

	blocks_count="$(read_ext4_le32_at "$image" $((1024 + 4)))"
	first_data_block="$(read_ext4_le32_at "$image" $((1024 + 20)))"
	log_block_size="$(read_ext4_le32_at "$image" $((1024 + 24)))"
	blocks_per_group="$(read_ext4_le32_at "$image" $((1024 + 32)))"

	if [ "$blocks_count" -le "$first_data_block" ] || [ "$blocks_per_group" -eq 0 ]; then
		echo "Invalid ext4 layout in $image" >&2
		exit 1
	fi

	block_size=$((1024 << log_block_size))
	group_count=$(((blocks_count - first_data_block + blocks_per_group - 1) / blocks_per_group))
	patched=0

	for ((group = 0; group < group_count; group++)); do
		if [ "$group" -eq 0 ]; then
			sb_offset=1024
		else
			sb_offset=$(((first_data_block + group * blocks_per_group) * block_size))
		fi

		if is_ext4_superblock_at "$image" "$sb_offset" "$log_block_size" "$blocks_per_group" "$first_data_block"; then
			write_ext4_le32_at "$image" "$((sb_offset + 44))" "$source_date_epoch"
			write_ext4_le32_at "$image" "$((sb_offset + 48))" "$source_date_epoch"
			write_ext4_le32_at "$image" "$((sb_offset + 64))" "$source_date_epoch"
			write_ext4_le32_at "$image" "$((sb_offset + 264))" "$source_date_epoch"
			patched=$((patched + 1))
		fi
	done

	if [ "$patched" -eq 0 ]; then
		echo "No ext4 superblocks found in $image" >&2
		exit 1
	fi

	echo "patched $patched ext4 superblock timestamp copies"
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
