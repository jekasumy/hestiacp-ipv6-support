#!/bin/bash
#
# install-ipv6-patch.sh - deploy the IPv6 patch set onto an ALREADY
# INSTALLED, running HestiaCP server.
#
# Usage (as root):
#   ./install-ipv6-patch.sh
#
# Run this from the root of this repository (the directory it was cloned
# or extracted into): the patched Hestia files are the bin/, func/,
# install/ and web/ folders next to this script, in the same layout as
# in $HESTIA (/usr/local/hestia).
#
# What it does, in order:
#   1. Backs up every file under $HESTIA that this patch is about to
#      touch, into a timestamped backup directory, together with a
#      manifest that records which of those files already existed
#      (so they can be restored) and which did not (so they can be
#      removed again). uninstall-ipv6-patch.sh uses that manifest to
#      reverse this install exactly.
#   2. Copies every file from bin/, func/, install/ and web/ into its real $HESTIA-relative
#      location, with the ownership/permissions Hestia itself uses
#      (root:root, 755 for bin/*, 644 for everything else).
#   3. Refreshes the web/mail/DNS templates, rebuilds every existing
#      user's domains, regenerates the per-system-IP catch-all vhosts
#      for every IP already on the server, and reloads the firewall -
#      so the running server actually picks up the change instead of
#      just having new files sitting on disk.
#
# Safe to re-run, e.g. to install a newer version of the patch over an
# older one: the backup of the ORIGINAL (unpatched) files made by the
# first install is kept and reused, so uninstall-ipv6-patch.sh always
# goes back to the stock files. Only files the newer version touches for
# the first time are added to it, and files an older version patched but
# the newer one no longer does are put back to their original state.

set -u
set -o pipefail

if [ "$(id -u)" -ne 0 ]; then
	echo "Error: this script must be run as root." >&2
	exit 1
fi

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The patched files: the Hestia-layout folders next to this script (and
# nothing else from this repository - not .git, the README or the scripts)
FILES_DIR="$SRC_DIR"
PATCH_DIRS=()
for patch_dir in bin func install web; do
	[ -d "$SRC_DIR/$patch_dir" ] && PATCH_DIRS+=("$SRC_DIR/$patch_dir")
done

if [ "${#PATCH_DIRS[@]}" -eq 0 ]; then
	echo "Error: no bin/, func/, install/ or web/ folder found next to this script in '$SRC_DIR'." >&2
	echo "Run this script from the root of the repository (or extracted archive)." >&2
	exit 1
fi

if [ ! -f /etc/hestiacp/hestia.conf ]; then
	echo "Error: /etc/hestiacp/hestia.conf not found - this doesn't look like a HestiaCP server." >&2
	exit 1
fi

# shellcheck source=/etc/hestiacp/hestia.conf
source /etc/hestiacp/hestia.conf
HESTIA="${HESTIA:-/usr/local/hestia}"

if [ ! -d "$HESTIA" ]; then
	echo "Error: HESTIA directory '$HESTIA' not found." >&2
	exit 1
fi

TIMESTAMP="$(date +%d%m%Y%H%M%S)"
POINTER_FILE="/root/.hestia_ipv6_patch_last_backup"

# The installed Hestia version: a backup of original files is only valid
# for the version it was taken from - after Hestia itself was upgraded,
# its files are the new originals.
HESTIA_VERSION="$(grep "^VERSION=" "$HESTIA/conf/hestia.conf" 2> /dev/null | cut -f 2 -d \')"

# Already installed (and not uninstalled since) on this same Hestia
# version? Reuse that install's backup of the original files instead of
# backing up patched ones.
RERUN='no'
if [ -f "$POINTER_FILE" ] && [ -d "$(cat "$POINTER_FILE")" ] \
	&& [ "$(cat "$(cat "$POINTER_FILE")/hestia_version.txt" 2> /dev/null || echo "$HESTIA_VERSION")" = "$HESTIA_VERSION" ]; then
	BACKUP_DIR="$(cat "$POINTER_FILE")"
	RERUN='yes'
else
	BACKUP_DIR="/root/hst_backups/ipv6-patch-$TIMESTAMP"
	# never reuse an existing directory for a fresh backup
	n=1
	while [ -e "$BACKUP_DIR" ]; do
		BACKUP_DIR="/root/hst_backups/ipv6-patch-$TIMESTAMP-$n"
		n=$((n + 1))
	done
fi

# Earlier versions of this script made a fresh backup on every run - of
# the already-patched files, on a re-run. Rebuild the backup of the
# original files once from all of those: the earliest backup of each file
# is its original (a file first touched by a later install was still
# original until then).
if [ "$RERUN" = 'yes' ] && [ ! -f "$BACKUP_DIR/.baseline" ]; then
	merged_dir="/root/hst_backups/ipv6-patch-$TIMESTAMP-merged"
	mkdir -p "$merged_dir/existing"
	: > "$merged_dir/manifest-existing.txt"
	: > "$merged_dir/manifest-new.txt"
	# Oldest first, by the timestamp in the name (ipv6-patch-DDMMYYYYhhmmss
	# - not the directory's mtime, which later writes into it change)
	for old_dir in $(ls -d /root/hst_backups/ipv6-patch-* 2> /dev/null \
		| sed -n 's#^\(.*ipv6-patch-\([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{4\}\)\([0-9]*\)\)$#\4\3\2\5 \1#p' \
		| sort | cut -d' ' -f2); do
		[ "$old_dir" = "$merged_dir" ] && continue
		while IFS= read -r rel_path; do
			[ -z "$rel_path" ] && continue
			grep -qxF "$rel_path" "$merged_dir/manifest-existing.txt" "$merged_dir/manifest-new.txt" && continue
			if [ -f "$old_dir/existing/$rel_path" ]; then
				mkdir -p "$(dirname "$merged_dir/existing/$rel_path")"
				cp -a "$old_dir/existing/$rel_path" "$merged_dir/existing/$rel_path"
				echo "$rel_path" >> "$merged_dir/manifest-existing.txt"
			fi
		done < "$old_dir/manifest-existing.txt"
		while IFS= read -r rel_path; do
			[ -z "$rel_path" ] && continue
			grep -qxF "$rel_path" "$merged_dir/manifest-existing.txt" "$merged_dir/manifest-new.txt" && continue
			echo "$rel_path" >> "$merged_dir/manifest-new.txt"
		done < "$old_dir/manifest-new.txt"
	done
	BACKUP_DIR="$merged_dir"
	touch "$BACKUP_DIR/.baseline"
	echo "$BACKUP_DIR" > "$POINTER_FILE"
fi

BACKUP_FILES_DIR="$BACKUP_DIR/existing"
MANIFEST_EXISTING="$BACKUP_DIR/manifest-existing.txt"
MANIFEST_NEW="$BACKUP_DIR/manifest-new.txt"
INSTALL_LOG="$BACKUP_DIR/install-$TIMESTAMP.log"

mkdir -p "$BACKUP_FILES_DIR"
touch "$MANIFEST_EXISTING" "$MANIFEST_NEW" "$BACKUP_DIR/.baseline"
echo "$HESTIA" > "$BACKUP_DIR/hestia_path.txt"
[ -f "$BACKUP_DIR/hestia_version.txt" ] || echo "$HESTIA_VERSION" > "$BACKUP_DIR/hestia_version.txt"

echo "============================================================================="
echo " HestiaCP IPv6 patch - install"
echo "============================================================================="
echo "HESTIA directory:  $HESTIA"
echo "Backup directory:  $BACKUP_DIR"
if [ "$RERUN" = 'yes' ]; then
	echo "                   (already installed - reusing the backup of the original files)"
fi
echo

# ---------------------------------------------------------------------------
# Step 1: back up every file this patch is about to overwrite, and set the
# ownership/permissions Hestia itself uses on each kind of file.
# ---------------------------------------------------------------------------
echo "[1/3] Backing up files that will be overwritten..."

backup_count=0
new_count=0

while IFS= read -r -d '' src_file; do
	rel_path="${src_file#"$FILES_DIR"/}"
	target_file="$HESTIA/$rel_path"

	# Already recorded by an earlier install: its original is backed up
	if grep -qxF "$rel_path" "$MANIFEST_EXISTING" "$MANIFEST_NEW"; then
		continue
	fi

	if [ -f "$target_file" ] || [ -L "$target_file" ]; then
		backup_target="$BACKUP_FILES_DIR/$rel_path"
		mkdir -p "$(dirname "$backup_target")"
		cp -a "$target_file" "$backup_target"
		echo "$rel_path" >> "$MANIFEST_EXISTING"
		backup_count=$((backup_count + 1))
	else
		echo "$rel_path" >> "$MANIFEST_NEW"
		new_count=$((new_count + 1))
	fi
done < <(find "${PATCH_DIRS[@]}" -type f -print0)

echo "      backed up $backup_count existing file(s), $new_count file(s) are new on this server."

# Files an earlier version of the patch changed but this one doesn't:
# put them back to their original state
if [ "$RERUN" = 'yes' ]; then
	reverted_count=0
	while IFS= read -r rel_path; do
		[ -z "$rel_path" ] || [ -f "$FILES_DIR/$rel_path" ] && continue
		if [ -f "$BACKUP_FILES_DIR/$rel_path" ]; then
			cp -a "$BACKUP_FILES_DIR/$rel_path" "$HESTIA/$rel_path"
			reverted_count=$((reverted_count + 1))
		fi
	done < "$MANIFEST_EXISTING"
	while IFS= read -r rel_path; do
		[ -z "$rel_path" ] || [ -f "$FILES_DIR/$rel_path" ] && continue
		if [ -f "$HESTIA/$rel_path" ]; then
			rm -f "$HESTIA/$rel_path"
			reverted_count=$((reverted_count + 1))
		fi
	done < "$MANIFEST_NEW"
	echo "      put back $reverted_count file(s) no longer part of the patch."
fi
echo

# ---------------------------------------------------------------------------
# Step 2: deploy the patched files.
# ---------------------------------------------------------------------------
echo "[2/3] Deploying patched files into $HESTIA..."

deployed_count=0

while IFS= read -r -d '' src_file; do
	rel_path="${src_file#"$FILES_DIR"/}"
	target_file="$HESTIA/$rel_path"

	mkdir -p "$(dirname "$target_file")"
	cp -a "$src_file" "$target_file"

	case "$rel_path" in
		bin/*)
			chmod 755 "$target_file"
			;;
		*)
			chmod 644 "$target_file"
			;;
	esac
	chown root:root "$target_file"

	deployed_count=$((deployed_count + 1))
done < <(find "${PATCH_DIRS[@]}" -type f -print0)

echo "      deployed $deployed_count file(s)."
echo "$BACKUP_DIR" > "$POINTER_FILE"
echo

# ---------------------------------------------------------------------------
# Step 3: refresh templates, rebuild existing domains, regenerate per-IP
# catch-all configs, reload the firewall - so the live server actually
# picks up the change. Each sub-step is logged to $INSTALL_LOG; failures
# here are reported but don't stop the rest of the run, since the files
# are already safely deployed and backed up by this point.
# ---------------------------------------------------------------------------
echo "[3/3] Refreshing templates and rebuilding existing domains..."
echo "      (full output logged to $INSTALL_LOG)"

(
	echo "=== $(date) - refresh begins ==="
	overall_rc=0

	# Hestia's own func/* files (and the scripts in $BIN) are not
	# written to be "set -u" safe - func/main.sh itself references
	# $user before it's ever assigned (expecting the shell to treat
	# that as an empty string, not throw "unbound variable"). This
	# script's own backup/manifest logic above ran with -u on
	# deliberately; turn it off here, in this subshell only, before
	# touching any Hestia code.
	set +u

	# shellcheck source=/usr/local/hestia/func/main.sh
	source "$HESTIA/func/main.sh" || overall_rc=1
	# shellcheck source=/usr/local/hestia/func/ip.sh
	source "$HESTIA/func/ip.sh" || overall_rc=1
	# shellcheck source=/usr/local/hestia/func/domain.sh
	source "$HESTIA/func/domain.sh" || overall_rc=1

	echo "--- v-update-web-templates"
	"$BIN/v-update-web-templates" "no" "skip" || overall_rc=1

	echo "--- v-update-mail-templates"
	"$BIN/v-update-mail-templates" "no" "skip" || overall_rc=1

	echo "--- v-update-dns-templates"
	"$BIN/v-update-dns-templates" || overall_rc=1

	echo "--- rebuilding existing users' web/mail/dns domains"
	for user in $("$BIN/v-list-users" list); do
		echo "    - $user"
		if [ -n "${WEB_SYSTEM:-}" ]; then
			"$BIN/v-rebuild-web-domains" "$user" 'no' || overall_rc=1
		fi
		if [ -n "${DNS_SYSTEM:-}" ]; then
			"$BIN/v-rebuild-dns-domains" "$user" 'no' || overall_rc=1
		fi
		if [ -n "${MAIL_SYSTEM:-}" ]; then
			"$BIN/v-rebuild-mail-domains" "$user" || overall_rc=1
		fi
	done

	# Regenerate the one catch-all vhost Hestia renders per *system IP*
	# (not per domain) for every IP that already exists on this server,
	# so each one also gets an IPv6 listener. This mirrors exactly what
	# v-add-sys-ip itself does when an IP is first added, and what
	# install/upgrade/versions/1.10.7.sh does for a package upgrade -
	# reproduced here directly so this script doesn't depend on that
	# upgrade script's own bookkeeping ($HESTIA_BACKUP/upgrade.conf),
	# which is only ever populated by the real deb-package upgrade path.
	echo "--- regenerating per-IP catch-all vhosts"
	for sys_ip in $("$BIN/v-list-sys-ips" plain | cut -f1); do
		write_sys_ip_catchall_configs "$sys_ip" || overall_rc=1
	done

	# Same service config changes as the package upgrade step
	# (install/upgrade/versions/1.10.7.sh): IPv6 in exim (mail in and out
	# over IPv6 - the mail domains' "ip" files were rewritten with their
	# IPv6 address by the rebuild above), and FTP dual-stack. Also drops
	# the IPv4-only outgoing setting an earlier version of this patch set.
	if [ "${MAIL_SYSTEM:-}" = 'exim4' ] && [ -f /etc/exim4/exim4.conf.template ] \
		&& grep -q -e '^disable_ipv6 = true$' -e '^dns_ipv4_lookup = \*$' /etc/exim4/exim4.conf.template; then
		echo "--- exim: enabling IPv6"
		sed -i -e '/^disable_ipv6 = true$/d' -e '/^dns_ipv4_lookup = \*$/d' /etc/exim4/exim4.conf.template
		sed -i 's/^hostlist relay_from_hosts = 127.0.0.1$/hostlist relay_from_hosts = <; 127.0.0.1 ; ::1/' /etc/exim4/exim4.conf.template
		"$BIN/v-restart-mail" || overall_rc=1
	fi
	if [ "${FTP_SYSTEM:-}" = 'vsftpd' ] && [ -f /etc/vsftpd.conf ] && [ -e /proc/net/if_inet6 ] \
		&& grep -q '^listen=YES$' /etc/vsftpd.conf && ! grep -q '^listen_ipv6=YES$' /etc/vsftpd.conf; then
		echo "--- vsftpd: listening on IPv6 too"
		sed -i -e 's/^listen=YES$/listen=NO/' -e '/^listen_ipv6=/d' /etc/vsftpd.conf
		sed -i '/^listen=NO$/a listen_ipv6=YES' /etc/vsftpd.conf
		"$BIN/v-restart-ftp" || overall_rc=1
	fi

	# Everything above rebuilt configs on disk with restarts suppressed
	# (RESTART='no'), to avoid restarting the web/DNS service once per
	# domain/user. Do that restart exactly once now that every config
	# is in its final state. Each v-restart-* helper runs its own
	# configtest first and only restarts if that passes, emailing the
	# root user and reporting failure here if it doesn't - so a bad
	# config is reported, not silently left running on the old config.
	echo "--- restarting web/proxy/DNS services"
	if [ -n "${WEB_SYSTEM:-}" ]; then
		"$BIN/v-restart-web" || overall_rc=1
	fi
	if [ -n "${PROXY_SYSTEM:-}" ]; then
		"$BIN/v-restart-proxy" || overall_rc=1
	fi
	if [ -n "${DNS_SYSTEM:-}" ]; then
		"$BIN/v-restart-dns" || overall_rc=1
	fi

	echo "--- v-update-firewall"
	"$BIN/v-update-firewall" || overall_rc=1

	echo "=== $(date) - refresh finished (status $overall_rc) ==="
	exit "$overall_rc"
) > "$INSTALL_LOG" 2>&1
refresh_status=$?

if [ "$refresh_status" -eq 0 ]; then
	echo "      done."
else
	echo "      WARNING: one of the refresh steps reported an error (exit $refresh_status)."
	echo "      The patched files are deployed and backed up either way - check $INSTALL_LOG for details,"
	echo "      then re-run the failing command by hand if needed."
fi

echo
echo "============================================================================="
echo " Install complete."
echo "============================================================================="
echo "Backup of previous files: $BACKUP_DIR"
echo "To undo this install, run: ./uninstall-ipv6-patch.sh"
echo "(it will restore from this exact backup automatically)"
