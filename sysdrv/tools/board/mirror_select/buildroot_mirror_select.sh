#!/bin/bash
BACKUP_MIRROR_SITE="http://sources.buildroot.net"

#PRIMARY_MIRROR_SITES=("http://sources.buildroot.net" "https://mirrors.lzu.edu.cn/buildroot")
PRIMARY_MIRROR_SITES=("http://sources.buildroot.net" "https://mirrors.nju.edu.cn/buildroot/")

# Uncomment and use other mirror sites if needed
# KERNEL_MIRROR_SITES=(
#     "https://cdn.kernel.org/pub"
#     "https://mirror.bjtu.edu.cn/kernel/"
# )
#
# GNU_MIRROR_SITES=(
#     "http://ftpmirror.gnu.org"
#     "http://mirrors.nju.edu.cn/gnu/"
# )
#
# LUAROCKS_MIRROR_SITES=(
#     "http://rocks.moonscript.org"
#     "https://luarocks.cn"
# )
#
# CPAN_MIRROR_SITES=(
#     "https://cpan.metacpan.org"
#     "http://mirrors.nju.edu.cn/CPAN/"
# )

function get_fastest_mirror() {
	local MIRROR_SITES=("${!1}")
	local fallback_site="${MIRROR_SITES[0]}"
	local fastest_site="$fallback_site"
	local min_time=""

	if ! command -v curl >/dev/null 2>&1; then
		echo "$fallback_site"
		return 0
	fi

	for site in "${MIRROR_SITES[@]}"; do
		if time=$(timeout 1.5 curl -s -w "%{time_connect}\n" -o /dev/null "$site" 2>/dev/null); then
			if [ -z "$min_time" ] || awk "BEGIN {exit !($time < $min_time)}"; then
				min_time="$time"
				fastest_site="$site"
			fi
		fi
	done

	if [ -z "$fastest_site" ]; then
		fastest_site="$fallback_site"
	fi

	echo "$fastest_site"
}

PRIMARY_FAST_MIRROR=$(get_fastest_mirror PRIMARY_MIRROR_SITES[@])
if [ -z "$PRIMARY_FAST_MIRROR" ]; then
	PRIMARY_FAST_MIRROR="${PRIMARY_MIRROR_SITES[0]}"
fi
echo "Fast mirror is $PRIMARY_FAST_MIRROR"

PRIMARY_MIRROR_STRING='BR2_PRIMARY_SITE='
BACKUP_MIRROR_STRING='BR2_BACKUP_SITE='

CONFIG_PATH="$1"
CONFIG_TMP="${CONFIG_PATH}.tmp.$$"
while IFS= read -r line || [ -n "$line" ]; do
	case "$line" in
		"$PRIMARY_MIRROR_STRING"*)
			printf 'BR2_PRIMARY_SITE="%s"\n' "$PRIMARY_FAST_MIRROR"
			;;
		"$BACKUP_MIRROR_STRING"*)
			printf 'BR2_BACKUP_SITE="%s"\n' "$BACKUP_MIRROR_SITE"
			;;
		*)
			printf '%s\n' "$line"
			;;
	esac
done < "$CONFIG_PATH" > "$CONFIG_TMP"
mv "$CONFIG_TMP" "$CONFIG_PATH"
