#!/bin/bash
#
# uninstall-ipv6-patch.sh - undo install-ipv6-patch.sh, restoring the
# exact files that were on this server before the IPv6 patch was
# installed.
#
# Usage (as root):
#   ./uninstall-ipv6-patch.sh                 # restores the most recent install
#   ./uninstall-ipv6-patch.sh /root/hst_backups/ipv6-patch-XXXXXXXXXXXXXX
#                                              # restores a specific backup
#
# What it does, in order:
#   1. Locates the backup directory install-ipv6-patch.sh created (the
#      most recent one, unless a specific one is given on the command
#      line).
#   2. Restores every file that existed before the patch back to its
#      original content/ownership/permissions, and removes every file
#      that the patch created from scratch (i.e. did not exist on this
#      server before the install).
#   3. Re-runs the same refresh steps the installer ran (template
#      refresh, domain rebuild, per-IP catch-all regeneration, firewall
#      reload), so the live server actually reflects the restored
#      (pre-patch) files instead of just having them sit on disk.
#
# Safe to re-run.

set -u
set -o pipefail

if [ "$(id -u)" -ne 0 ]; then
	echo "Error: this script must be run as root." >&2
	exit 1
fi

POINTER_FILE="/root/.hestia_ipv6_patch_last_backup"

BACKUP_DIR="${1:-}"
if [ -z "$BACKUP_DIR" ]; then
	if [ -f "$POINTER_FILE" ]; then
		BACKUP_DIR="$(cat "$POINTER_FILE")"
	else
		echo "Error: no backup directory given, and $POINTER_FILE doesn't exist." >&2
		echo "Pass the backup directory explicitly, e.g.:" >&2
		echo "  $0 /root/hst_backups/ipv6-patch-XXXXXXXXXXXXXX" >&2
		exit 1
	fi
fi

MANIFEST_EXISTING="$BACKUP_DIR/manifest-existing.txt"
MANIFEST_NEW="$BACKUP_DIR/manifest-new.txt"
BACKUP_FILES_DIR="$BACKUP_DIR/existing"
HESTIA_PATH_FILE="$BACKUP_DIR/hestia_path.txt"
UNINSTALL_LOG="$BACKUP_DIR/uninstall.log"

if [ ! -d "$BACKUP_DIR" ] || [ ! -f "$MANIFEST_EXISTING" ] || [ ! -f "$MANIFEST_NEW" ] || [ ! -f "$HESTIA_PATH_FILE" ]; then
	echo "Error: '$BACKUP_DIR' doesn't look like a backup made by install-ipv6-patch.sh" >&2
	echo "(expected manifest-existing.txt, manifest-new.txt and hestia_path.txt inside it)." >&2
	exit 1
fi

HESTIA="$(cat "$HESTIA_PATH_FILE")"

if [ ! -d "$HESTIA" ]; then
	echo "Error: HESTIA directory '$HESTIA' (recorded in this backup) not found." >&2
	exit 1
fi

echo "============================================================================="
echo " HestiaCP IPv6 patch - uninstall"
echo "============================================================================="
echo "HESTIA directory:  $HESTIA"
echo "Restoring from:    $BACKUP_DIR"
echo

# ---------------------------------------------------------------------------
# Step 1: restore files that existed before the patch.
# ---------------------------------------------------------------------------
echo "[1/3] Restoring original files..."

restored_count=0
while IFS= read -r rel_path; do
	[ -z "$rel_path" ] && continue
	backup_file="$BACKUP_FILES_DIR/$rel_path"
	target_file="$HESTIA/$rel_path"

	if [ ! -e "$backup_file" ]; then
		echo "      WARNING: backup copy of '$rel_path' is missing, skipping." >&2
		continue
	fi

	mkdir -p "$(dirname "$target_file")"
	cp -a "$backup_file" "$target_file"

	case "$rel_path" in
		bin/*)
			chmod 755 "$target_file"
			;;
		*)
			chmod 644 "$target_file"
			;;
	esac
	chown root:root "$target_file"

	restored_count=$((restored_count + 1))
done < "$MANIFEST_EXISTING"

echo "      restored $restored_count file(s)."

# ---------------------------------------------------------------------------
# Step 2: remove files the patch created from scratch (didn't exist before).
# ---------------------------------------------------------------------------
echo "[2/3] Removing files that didn't exist before the patch..."

removed_count=0
while IFS= read -r rel_path; do
	[ -z "$rel_path" ] && continue
	target_file="$HESTIA/$rel_path"
	if [ -e "$target_file" ]; then
		rm -f "$target_file"
		removed_count=$((removed_count + 1))
	fi
done < "$MANIFEST_NEW"

echo "      removed $removed_count file(s)."
echo

# ---------------------------------------------------------------------------
# Step 3: re-run the same refresh steps the installer ran, so the live
# server reflects the restored files.
# ---------------------------------------------------------------------------
# Not installed anymore: the next install starts a fresh backup of the
# (then) original files
if [ "$(cat "$POINTER_FILE" 2> /dev/null)" = "$BACKUP_DIR" ]; then
	rm -f "$POINTER_FILE"
fi

echo "[3/3] Refreshing templates and rebuilding existing domains..."
echo "      (full output logged to $UNINSTALL_LOG)"

(
	echo "=== $(date) - refresh begins ==="
	overall_rc=0

	# See the matching comment in install-ipv6-patch.sh: Hestia's own
	# func/* files are not "set -u" safe (func/main.sh references
	# $user before it's ever assigned), so turn -u off in this
	# subshell only, before touching any Hestia code.
	set +u

	# shellcheck source=/etc/hestiacp/hestia.conf
	source /etc/hestiacp/hestia.conf || overall_rc=1
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

	# Regenerate the per-system-IP catch-all vhosts again, now from the
	# restored (pre-patch) unassigned.inc/unassigned.conf templates, so
	# they go back to not having an IPv6 listener either.
	echo "--- regenerating per-IP catch-all vhosts"
	if [ -n "${WEB_SYSTEM:-}" ]; then
		for sys_ip in $("$BIN/v-list-sys-ips" plain | cut -f1); do
			if [ "$WEB_SYSTEM" = 'nginx' ]; then
				web_conf="/etc/$WEB_SYSTEM/conf.d/$sys_ip.conf"
				if [ -f "$web_conf" ]; then
					cp -f "$HESTIA_INSTALL_DIR/nginx/unassigned.inc" "$web_conf"
					sed -i 's/directIP/'"$sys_ip"'/g' "$web_conf"
					process_http2_directive "$web_conf"
				fi
			elif [ "$WEB_SYSTEM" = 'httpd' ] || [ "$WEB_SYSTEM" = 'apache2' ]; then
				web_conf="/etc/$WEB_SYSTEM/conf.d/$sys_ip.conf"
				if [ -f "$web_conf" ]; then
					rm -f "$web_conf"
					if [ -z "$(/usr/sbin/apachectl -v | grep Apache/2.4)" ]; then
						echo "NameVirtualHost $sys_ip:$WEB_PORT" > "$web_conf"
					fi
					echo "Listen $sys_ip:$WEB_PORT" >> "$web_conf"
					cat "$HESTIA_INSTALL_DIR/apache2/unassigned.conf" >> "$web_conf"
					sed -i 's/directIP/'"$sys_ip"'/g' "$web_conf"
					sed -i 's/directPORT/'"$WEB_PORT"'/g' "$web_conf"

					if [ "$WEB_SSL" = 'mod_ssl' ]; then
						if [ -z "$(/usr/sbin/apachectl -v | grep Apache/2.4)" ]; then
							sed -i "1s/^/NameVirtualHost $sys_ip:$WEB_SSL_PORT\n/" "$web_conf"
						fi
						sed -i "1s/^/Listen $sys_ip:$WEB_SSL_PORT\n/" "$web_conf"
						sed -i 's/directSSLPORT/'"$WEB_SSL_PORT"'/g' "$web_conf"
					fi
				fi
			fi

			if [ -n "${PROXY_SYSTEM:-}" ]; then
				proxy_conf="/etc/$PROXY_SYSTEM/conf.d/$sys_ip.conf"
				if [ -f "$proxy_conf" ]; then
					cat "$WEBTPL/$PROXY_SYSTEM/proxy_ip.tpl" \
						| sed -e "s/%ip%/$sys_ip/g" \
							-e "s/%ip6%//g" \
							-e "s/%web_port%/$WEB_PORT/g" \
							-e "s/%proxy_port%/$PROXY_PORT/g" \
							-e "s/%proxy_ssl_port%/$PROXY_SSL_PORT/g" \
							> "$proxy_conf"
					process_http2_directive "$proxy_conf"
				fi
			fi
		done
	fi

	# The stock firewall never manages ip6tables, so it would leave the
	# patch's IPv6 ruleset (DROP policy included) in place for good - open
	# IPv6 back up the way it was before, and stop restoring it at boot.
	if [ -x /sbin/ip6tables ]; then
		echo "--- removing the IPv6 firewall ruleset"
		/sbin/ip6tables -P INPUT ACCEPT
		/sbin/ip6tables -F INPUT
		for chain in $(/sbin/ip6tables -S 2> /dev/null | sed -n 's/^-N \(fail2ban-.*\)$/\1/p'); do
			/sbin/ip6tables -F "$chain"
			/sbin/ip6tables -X "$chain"
		done
		rm -f /etc/ip6tables.rules /etc/sysconfig/ip6tables
		if [ -f /lib/systemd/system/hestia-iptables.service ]; then
			sed -i '/ip6tables-restore/d' /lib/systemd/system/hestia-iptables.service
			systemctl daemon-reload > /dev/null 2>&1
		fi
	fi

	# Exim: back to IPv4 only, as configured before (the mail domains'
	# "ip" files were already rewritten IPv4-only by the rebuild above)
	if [ -f /etc/exim4/exim4.conf.template ] && grep -q '^hostlist relay_from_hosts = <; 127.0.0.1 ; ::1$' /etc/exim4/exim4.conf.template; then
		echo "--- exim: back to IPv4 only"
		sed -i '/^dns_ipv4_lookup = \*$/d' /etc/exim4/exim4.conf.template
		if ! grep -q '^disable_ipv6 = true$' /etc/exim4/exim4.conf.template; then
			sed -i 's/^hostlist relay_from_hosts = <; 127.0.0.1 ; ::1$/disable_ipv6 = true\nhostlist relay_from_hosts = 127.0.0.1/' /etc/exim4/exim4.conf.template
		else
			sed -i 's/^hostlist relay_from_hosts = <; 127.0.0.1 ; ::1$/hostlist relay_from_hosts = 127.0.0.1/' /etc/exim4/exim4.conf.template
		fi
		"$BIN/v-restart-mail" || overall_rc=1
	fi

	# See the matching comment in install-ipv6-patch.sh: restart once,
	# now that every restored config is in its final state, instead of
	# once per domain/user.
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
) > "$UNINSTALL_LOG" 2>&1
refresh_status=$?

if [ "$refresh_status" -eq 0 ]; then
	echo "      done."
else
	echo "      WARNING: one of the refresh steps reported an error (exit $refresh_status)."
	echo "      The original files are restored either way - check $UNINSTALL_LOG for details,"
	echo "      then re-run the failing command by hand if needed."
fi

echo
echo "============================================================================="
echo " Uninstall complete. Original files restored from: $BACKUP_DIR"
echo "============================================================================="
