#!/usr/bin/env sh

set -e

DEFAULT_CHANNEL_VALUE="stable"
if [ -z "$CHANNEL" ]; then
	CHANNEL=$DEFAULT_CHANNEL_VALUE
fi

DEFAULT_DOWNLOAD_URL="https://download.docker.com"
if [ -z "$DOWNLOAD_URL" ]; then
	DOWNLOAD_URL=$DEFAULT_DOWNLOAD_URL
fi

DEFAULT_REPO_FILE="docker-ce.repo"
if [ -z "$REPO_FILE" ]; then
	REPO_FILE="$DEFAULT_REPO_FILE"
fi

mirror=''
DRY_RUN=${DRY_RUN:-}
while [ $# -gt 0 ]; do
	case "$1" in
		--channel)
			CHANNEL="$2"
			shift
			;;
		--dry-run)
			DRY_RUN=1
			;;
		--mirror)
			mirror="$2"
			shift
			;;
		--version)
			VERSION="${2#v}"
			shift
			;;
		--*)
			echo "Illegal option $1"
			;;
	esac
	shift $(( $# > 0 ? 1 : 0 ))
done

case "$mirror" in
	Aliyun)
		DOWNLOAD_URL="https://mirrors.aliyun.com/docker-ce"
		;;
	AzureChinaCloud)
		DOWNLOAD_URL="https://mirror.azure.cn/docker-ce"
		;;
	"")
		;;
	*)
		>&2 echo "unknown mirror '$mirror': use either 'Aliyun', or 'AzureChinaCloud'."
		exit 1
		;;
esac

case "$CHANNEL" in
	stable|test)
		;;
	edge|nightly)
		>&2 echo "DEPRECATED: the $CHANNEL channel has been deprecated and no longer supported by this script."
		exit 1
		;;
	*)
		>&2 echo "unknown CHANNEL '$CHANNEL': use either stable or test."
		exit 1
		;;
esac

command_exists() {
	command -v "$@" > /dev/null 2>&1
}

version_gte() {
	if [ -z "$VERSION" ]; then
			return 0
	fi
	eval version_compare "$VERSION" "$1"
}

version_compare() (
	set +x

	yy_a="$(echo "$1" | cut -d'.' -f1)"
	yy_b="$(echo "$2" | cut -d'.' -f1)"
	if [ "$yy_a" -lt "$yy_b" ]; then
		return 1
	fi
	if [ "$yy_a" -gt "$yy_b" ]; then
		return 0
	fi
	mm_a="$(echo "$1" | cut -d'.' -f2)"
	mm_b="$(echo "$2" | cut -d'.' -f2)"

	# trim leading zeros to accommodate CalVer
	mm_a="${mm_a#0}"
	mm_b="${mm_b#0}"

	if [ "${mm_a:-0}" -lt "${mm_b:-0}" ]; then
		return 1
	fi

	return 0
)

is_dry_run() {
	if [ -z "$DRY_RUN" ]; then
		return 1
	else
		return 0
	fi
}

is_wsl() {
	case "$(uname -r)" in
	*microsoft* ) true ;; # WSL 2
	*Microsoft* ) true ;; # WSL 1
	* ) false;;
	esac
}

is_darwin() {
	case "$(uname -s)" in
	*darwin* ) true ;;
	*Darwin* ) true ;;
	* ) false;;
	esac
}

deprecation_notice() {
	distro=$1
	distro_version=$2
	echo
	printf "\033[91;1mDEPRECATION WARNING\033[0m\n"
	printf "    This Linux distribution (\033[1m%s %s\033[0m) reached end-of-life and is no longer supported by this script.\n" "$distro" "$distro_version"
	echo   "    No updates or security fixes will be released for this distribution, and users are recommended"
	echo   "    to upgrade to a currently maintained version of $distro."
	echo
	printf   "Press \033[1mCtrl+C\033[0m now to abort this script, or wait for the installation to continue."
	echo
	sleep 10
}

get_distribution() {
	lsb_dist=""
	if [ -r /etc/os-release ]; then
		lsb_dist="$(. /etc/os-release && echo "$ID")"
	fi
	echo "$lsb_dist"
}

echo_docker_as_nonroot() {
	if is_dry_run; then
		return
	fi
	if command_exists docker && [ -e /var/run/docker.sock ]; then
		(
			set -x
			$sh_c 'docker version'
		) || true
	fi

	# intentionally mixed spaces and tabs here -- tabs are stripped by "<<-EOF", spaces are kept in the output
	echo
	echo "================================================================================"
	echo
	if version_gte "20.10"; then
		echo "To run Docker as a non-privileged user, consider setting up the"
		echo "Docker daemon in rootless mode for your user:"
		echo
		echo "    dockerd-rootless-setuptool.sh install"
		echo
		echo "Visit https://docs.docker.com/go/rootless/ to learn about rootless mode."
		echo
	fi
	echo
	echo "To run the Docker daemon as a fully privileged service, but granting non-root"
	echo "users access, refer to https://docs.docker.com/go/daemon-access/"
	echo
	echo "WARNING: Access to the remote API on a privileged Docker daemon is equivalent"
	echo "         to root access on the host. Refer to the 'Docker daemon attack surface'"
	echo "         documentation for details: https://docs.docker.com/go/attack-surface/"
	echo
	echo "================================================================================"
	echo
}

do_install() {
	echo "# Executing docker install script, commit: $SCRIPT_COMMIT_SHA"

	if command_exists docker; then
		cat >&2 <<-'EOF'
			Warning: the "docker" command appears to already exist on this system.

			If you already have Docker installed, this script can cause trouble, which is
			why we're displaying this warning and provide the opportunity to cancel the
			installation.

			If you installed the current Docker package using this script and are using it
			again to update Docker, you can safely ignore this message.

			You may press Ctrl+C now to abort this script.
		EOF
		( set -x; sleep 20 )
	fi

	user="$(id -un 2>/dev/null || true)"

	sh_c='sh -c'
	if [ "$user" != 'root' ]; then
		if command_exists sudo; then
			sh_c='sudo -E sh -c'
		elif command_exists su; then
			sh_c='su -c'
		else
			cat >&2 <<-'EOF'
			Error: this installer needs the ability to run commands as root.
			We are unable to find either "sudo" or "su" available to make this happen.
			EOF
			exit 1
		fi
	fi

	if is_dry_run; then
		sh_c="echo"
	fi

	# perform some very rudimentary platform detection
	lsb_dist=$( get_distribution )
	lsb_dist="$(echo "$lsb_dist" | tr '[:upper:]' '[:lower:]')"

	if is_wsl; then
		echo
		echo "WSL DETECTED: We recommend using Docker Desktop for Windows."
		echo "Please get Docker Desktop from https://www.docker.com/products/docker-desktop/"
		echo
		cat >&2 <<-'EOF'

			You may press Ctrl+C now to abort this script.
		EOF
		( set -x; sleep 20 )
	fi

	case "$lsb_dist" in

		kali)
			dist_version="$(. /etc/os-release && echo "$VERSION_ID")"
			case "$dist_version" in
				2023.*)
					dist_version="bookworm"
				;;
				2022.*)
					dist_version="bullseye"
				;;
				2021.*)
					dist_version="bullseye"
				;;
				2020.*)
					dist_version="buster"
					deprecation_notice "$lsb_dist" "$dist_version"
				;;
				2019.*)
					dist_version="buster"
					deprecation_notice "$lsb_dist" "$dist_version"
				;;
				*)
					printf "\033[91;1mKALI LINUX TO OLD\033[0m\n"
					echo "Pls download Kali Linux official repos"
					exit 1
				;;
			esac
		;;

		*)
			printf "\033[91;1mNOT A KALI LINUX\033[0m\n"
			echo "Run this script only on kali linux !"
			echo "================================================================================"
			echo "If you want to download Docker on another Linux distrib, pls refer to https://get.docker.com"
			echo "For download kali linux, go to : https://www.kali.org/get-kali/"
			exit 1
		;;

	esac


	pre_reqs="apt-transport-https ca-certificates curl"
	if ! command -v gpg > /dev/null; then
		pre_reqs="$pre_reqs gnupg"
	fi
	apt_repo="deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] $DOWNLOAD_URL/linux/debian $dist_version $CHANNEL"
	(
		if ! is_dry_run; then
			set -x
		fi
		$sh_c 'apt-get update -qq >/dev/null'
		$sh_c "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $pre_reqs >/dev/null"
		$sh_c 'install -m 0755 -d /etc/apt/keyrings'
		$sh_c "curl -fsSL \"$DOWNLOAD_URL/linux/debian/gpg\" | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg"
		$sh_c "chmod a+r /etc/apt/keyrings/docker.gpg"
		$sh_c "echo \"$apt_repo\" > /etc/apt/sources.list.d/docker.list"
		$sh_c 'apt-get update -qq >/dev/null'
	)
	pkg_version=""
	if [ -n "$VERSION" ]; then
		if is_dry_run; then
			echo "# WARNING: VERSION pinning is not supported in DRY_RUN"
		else
			# Will work for incomplete versions IE (17.12), but may not actually grab the "latest" if in the test channel
			pkg_pattern="$(echo "$VERSION" | sed 's/-ce-/~ce~.*/g' | sed 's/-/.*/g')"
			search_command="apt-cache madison docker-ce | grep '$pkg_pattern' | head -1 | awk '{\$1=\$1};1' | cut -d' ' -f 3"
			pkg_version="$($sh_c "$search_command")"
			echo "INFO: Searching repository for VERSION '$VERSION'"
			echo "INFO: $search_command"
			if [ -z "$pkg_version" ]; then
				echo
				echo "ERROR: '$VERSION' not found amongst apt-cache madison results"
				echo
				exit 1
			fi
			if version_gte "18.09"; then
					search_command="apt-cache madison docker-ce-cli | grep '$pkg_pattern' | head -1 | awk '{\$1=\$1};1' | cut -d' ' -f 3"
					echo "INFO: $search_command"
					cli_pkg_version="=$($sh_c "$search_command")"
			fi
			pkg_version="=$pkg_version"
		fi
	fi
	(
		pkgs="docker-ce${pkg_version%=}"
		if version_gte "18.09"; then
				# older versions didn't ship the cli and containerd as separate packages
				pkgs="$pkgs docker-ce-cli${cli_pkg_version%=} containerd.io"
		fi
		if version_gte "20.10"; then
				pkgs="$pkgs docker-compose-plugin docker-ce-rootless-extras$pkg_version"
		fi
		if version_gte "23.0"; then
				pkgs="$pkgs docker-buildx-plugin"
		fi
		if ! is_dry_run; then
			set -x
		fi
		$sh_c "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $pkgs >/dev/null"
	)
	echo_docker_as_nonroot
	exit 0
}

# wrapped up in a function so that we have some protection against only getting
# half the file during "curl | sh"
do_install