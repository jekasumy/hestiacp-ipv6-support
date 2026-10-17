#!/bin/bash

#===========================================================================#
#                                                                           #
# Hestia Control Panel - Firewall Function Library                          #
#                                                                           #
#===========================================================================#

heal_iptables_links() {
	# Also heal ip6tables/-save/-restore links, the same way
	# iptables/-save/-restore were healed above - without this,
	# v-update-firewall's IPv6 mirroring silently no-ops on any box
	# where /sbin/ip6tables isn't already a ready-made symlink.
	packages="iptables iptables-save iptables-restore ip6tables ip6tables-save ip6tables-restore"
	for package in $packages; do
		if [ ! -e "/sbin/${package}" ]; then
			if which ${package}; then
				ln -s "$(which ${package})" /sbin/${package}
			elif [ -e "/usr/sbin/${package}" ]; then
				ln -s /usr/sbin/${package} /sbin/${package}
			elif whereis -B /bin /sbin /usr/bin /usr/sbin -f -b ${package}; then
				autoiptables=$(whereis -B /bin /sbin /usr/bin /usr/sbin -f -b ${package} | cut -d '' -f 2)
				if [ -x "$autoiptables" ]; then
					ln -s "$autoiptables" /sbin/${package}
				fi
			fi
		fi
	done
}
