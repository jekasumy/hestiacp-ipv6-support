#!/bin/bash

#===========================================================================#
#                                                                           #
# Hestia Control Panel - IP/Network Function Library                        #
#                                                                           #
#===========================================================================#

# Global definitions
REGEX_IPV4="^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)(\.|$)){4}$"

# Check ip ownership
is_ip_owner() {
	owner=$(grep 'OWNER=' $HESTIA/data/ips/$ip | cut -f 2 -d \')
	if [ "$owner" != "$user" ]; then
		check_result "$E_FORBIDEN" "$ip is not owned by $user"
	fi
}

# Check if ip address is free
is_ip_free() {
	if [ -e "$HESTIA/data/ips/$ip" ]; then
		check_result "$E_EXISTS" "$ip is already exists"
	fi
}

# Get the IPv6 address paired with a system IP, if any. Used when
# generating web/webmail configs so a domain can listen on a specific
# IPv6 address instead of the server's wildcard IPv6 listener. Echoes
# nothing (empty string) when no IPv6 address is paired with $1.
get_ip6_value() {
	local sip="${1-$ip}"
	if [ -e "$HESTIA/data/ips/$sip" ]; then
		grep "^IP6=" "$HESTIA/data/ips/$sip" | cut -f 2 -d \'
	fi
}

# List every IPv6 address paired with any system IP, one per line
get_all_ip6_values() {
	local f
	for f in "$HESTIA"/data/ips/*; do
		[ -e "$f" ] || continue
		grep "^IP6=" "$f" | cut -f 2 -d \'
	done | grep -v '^$' | sort -u
}

# Detect an IPv6 address that's already configured on a network
# interface outside of Hestia (assigned by the provider via SLAAC/DHCPv6,
# or added by hand) - so v-add-sys-ip/v-change-sys-ip-ipv6 can offer to
# pair it automatically instead of requiring the admin to copy the
# address in by hand. Only considers global-scope addresses, and skips
# temporary/deprecated ones (privacy-extension addresses that rotate
# periodically, and addresses in the process of being retired) since
# those aren't suitable for a stable pairing. Echoes nothing if the
# interface has no such address.
detect_iface_global_ipv6() {
	local iface="$1" exclude_ip="${2-}" addr
	# Skip addresses still being set up or that failed duplicate address
	# detection, as well as ones already paired with another system IP
	# (two IPs paired with the same address would give the server two
	# conflicting default vhosts for it)
	for addr in $(ip -6 -o addr show dev "$iface" scope global 2> /dev/null \
		| grep -v -e 'temporary' -e 'deprecated' -e 'tentative' -e 'dadfailed' \
		| awk '{print $4}' | cut -d/ -f1); do
		addr="$(normalize_ip6 "$addr")"
		if [ -z "$(get_ip6_owner "$addr" "$exclude_ip")" ]; then
			echo "$addr"
			return
		fi
	done
}

# The system IP (other than $2) the IPv6 address $1 is paired with, if any
get_ip6_owner() {
	local addr="$1" exclude_ip="${2-}" f
	for f in "$HESTIA"/data/ips/*; do
		[ -e "$f" ] || continue
		[ "$(basename "$f")" = "$exclude_ip" ] && continue
		if grep -qx "IP6='$addr'" "$f"; then
			basename "$f"
			return
		fi
	done
}

# Whether IPv6 address $1 is configured on any interface of this server
# (exact address comparison, in canonical form)
is_ip6_on_system() {
	local addr
	for addr in $(ip -6 -o addr show 2> /dev/null | awk '{print $4}' | cut -d/ -f1); do
		if [ "$(normalize_ip6 "$addr")" = "$1" ]; then
			return 0
		fi
	done
	return 1
}

# Check that IPv6 address $1 (canonical form) can be paired with system
# IP $2: a specific, globally routable unicast address a web server can
# bind to, and not already paired with another system IP.
is_ip6_pairable() {
	local addr="$1" ip="$2" owner
	case "$addr" in
		:: | ::1 | fe[89ab]?:* | ff??:* | ::ffff:*)
			check_result "$E_INVALID" "$addr can't be paired with an IP (unspecified, loopback, link-local, multicast or IPv4-mapped address)"
			;;
	esac
	owner="$(get_ip6_owner "$addr" "$ip")"
	if [ -n "$owner" ]; then
		check_result "$E_EXISTS" "$addr is already paired with $owner"
	fi
}

# Remove IPv6 address $1/$2 from interface $3 and from the persistent
# network config Hestia wrote it to (see v-add-sys-ip)
deprovision_ip6() {
	local addr="$1" prefix="$2" iface="$3" ip6_str
	if [ -n "$iface" ]; then
		ip -6 addr del "$addr/$prefix" dev "$iface" 2> /dev/null
	fi
	if [ -f "/etc/netplan/60-hestia.yaml" ]; then
		sed -i "/^ *- ${addr}\/[0-9]*$/d" /etc/netplan/60-hestia.yaml
		if ! grep -q '^ *- ' /etc/netplan/60-hestia.yaml; then
			rm /etc/netplan/60-hestia.yaml
		fi
	elif [ -e "/etc/network/interfaces" ]; then
		ip6_str="$(grep -n "^address $addr$" /etc/network/interfaces | cut -f1 -d: | head -n1)"
		if [ -n "$ip6_str" ]; then
			sed -i "$((ip6_str - 2)),$((ip6_str + 1)) d" /etc/network/interfaces
		fi
	fi
}

# Bring everything that uses the IPv6 address paired with system IP $1
# up to date after that pairing changed (or the IP was deleted). $2 is
# the previously paired address, if any.
#  - the IP's own catch-all vhosts (unless the IP is gone)
#  - every user's web domains / DNS zones that picked the old address
#    explicitly: it's dropped from their list (an emptied list falls
#    back to the default - whatever is paired with the domain's own IP)
#  - web domains and webmail of the IP's users (the default follows the
#    pairing)
#  - DNS zones on this IP, and those whose list changed: AAAA records
#    and SPF ip6: mechanisms (the old address is passed on, so records
#    still pointing at it are cleaned up)
sync_ip6_pairing_change() {
	local ip="$1" old_ip6="${2-}" restart="${3-yes}" nat user_dir sys_user conf row domain value new_value zone_ip
	local web_users='' dns_jobs=''

	if [ -e "$HESTIA/data/ips/$ip" ]; then
		write_sys_ip_catchall_configs "$ip"
		nat="$(grep "^NAT=" "$HESTIA/data/ips/$ip" | cut -f 2 -d \')"
		web_users="$(grep "^U_SYS_USERS=" "$HESTIA/data/ips/$ip" | cut -f 2 -d \' | tr ',' ' ')"
	fi

	for user_dir in "$HESTIA"/data/users/*; do
		[ -d "$user_dir" ] || continue
		sys_user="$(basename "$user_dir")"

		# Drop the old address from explicit lists
		for conf in "$user_dir/web.conf" "$user_dir/dns.conf"; do
			[ -n "$old_ip6" ] && [ -f "$conf" ] || continue
			while IFS= read -r row; do
				value="$(echo "$row" | sed -n "s/.* IPV6='\([^']*\)'.*/\1/p")"
				[[ ",$value," == *",$old_ip6,"* ]] || continue
				new_value="$(echo ",$value," | sed "s/,$old_ip6,/,/; s/^,//; s/,$//")"
				domain="$(echo "$row" | sed -n "s/^DOMAIN='\([^']*\)'.*/\1/p")"
				sed -i "s/^\(DOMAIN='$domain' .*\)IPV6='$value'/\1IPV6='$new_value'/" "$conf"
				if [ "$conf" = "$user_dir/web.conf" ]; then
					web_users="$web_users $sys_user"
				else
					dns_jobs="$dns_jobs $sys_user:$domain"
				fi
			done < <(grep " IPV6='[^']" "$conf")
		done

		# DNS zones on this IP (by local or NAT address)
		if [ -f "$user_dir/dns.conf" ]; then
			while IFS= read -r row; do
				zone_ip="$(echo "$row" | sed -n "s/.* IP='\([^']*\)'.*/\1/p")"
				if [ "$zone_ip" = "$ip" ] || { [ -n "$nat" ] && [ "$zone_ip" = "$nat" ]; }; then
					domain="$(echo "$row" | sed -n "s/^DOMAIN='\([^']*\)'.*/\1/p")"
					dns_jobs="$dns_jobs $sys_user:$domain"
				fi
			done < "$user_dir/dns.conf"
		fi
	done

	if [ -n "$WEB_SYSTEM" ]; then
		for sys_user in $(echo $web_users | tr ' ' '\n' | sort -u); do
			[ -d "$HESTIA/data/users/$sys_user" ] || continue
			$BIN/v-rebuild-web-domains "$sys_user" no
			if [ -n "$MAIL_SYSTEM" ]; then
				$BIN/v-rebuild-mail-domains "$sys_user"
			fi
		done
	fi

	if [ -n "$DNS_SYSTEM" ]; then
		for job in $(echo $dns_jobs | tr ' ' '\n' | sort -u); do
			sys_user="${job%%:*}"
			domain="${job#*:}"
			value="$(grep "^DOMAIN='$domain' " "$HESTIA/data/users/$sys_user/dns.conf" | sed -n "s/.* IPV6='\([^']*\)'.*/\1/p")"
			[ "$value" = 'yes' ] && value=''
			$BIN/v-change-dns-domain-ipv6 "$sys_user" "$domain" "$value" 'no' "$old_ip6"
		done
		$BIN/v-restart-dns
	fi

	if [ "$restart" != 'no' ]; then
		$BIN/v-restart-web
		$BIN/v-restart-proxy
	fi

	# The firewall accepts traffic from the server's own IPv6 addresses
	if [ -n "$FIREWALL_SYSTEM" ]; then
		$BIN/v-update-firewall
	fi
}

# Check ip address specific value
is_ip_key_empty() {
	key="$1"
	string=$(cat $HESTIA/data/ips/$ip)
	eval $string
	eval value="$key"
	if [ -n "$value" ] && [ "$value" != '0' ]; then
		key="$(echo $key | sed -e "s/\$U_//")"
		check_result "$E_EXISTS" "IP is in use / $key = $value"
	fi
}

is_ip_rdns_valid() {
	local ip="$1"
	local network_ip=$(echo $ip | cut -d"." -f1-3)
	local awk_ip=$(echo $network_ip | sed 's|\.|/\&\&/|g')
	local rev_awk_ip=$(echo $awk_ip | rev)

	if [ -z "$rdns" ]; then
		local rdns=$(dig +short -x "$ip" | head -n 1 | sed 's/.$//') || unset rdns
	fi

	if [ -n "$rdns" ] && [ ! $(echo $rdns | awk "/$awk_ip/ || /$rev_awk_ip/") ]; then
		echo $rdns
		return 0 # True
	fi

	return 1 # False
}

# Update ip address value
update_ip_value() {
	key="$1"
	value="$2"
	conf="$HESTIA/data/ips/$ip"
	str=$(cat $conf)
	eval $str
	c_key=$(echo "${key//$/}")
	eval old="${key}"
	old=$(echo "$old" | sed -e 's/\\/\\\\/g' -e 's/&/\\&/g' -e 's/\//\\\//g')
	new=$(echo "$value" | sed -e 's/\\/\\\\/g' -e 's/&/\\&/g' -e 's/\//\\\//g')
	sed -i "$str_number s/$c_key='${old//\*/\\*}'/$c_key='${new//\*/\\*}'/g" \
		$conf
}

# New method that is improved on a later date we need to check if we can improve it for other locations
update_ip_value_new() {
	key="$1"
	value="$2"
	conf="$HESTIA/data/ips/$ip"
	check_ckey=$(grep "^$key='" $conf)
	if [ -z "$check_ckey" ]; then
		echo "$key='$value'" >> $conf
	else
		sed -i "s|^$key=.*|$key='$value'|g" $conf
	fi
}

# Get ip name
get_ip_alias() {
	ip_name=$(grep "NAME=" $HESTIA/data/ips/$local_ip | cut -f 2 -d \')
	if [ -n "$ip_name" ]; then
		echo "${1//./-}.$ip_name"
	fi
}

# Increase ip value
increase_ip_value() {
	sip=${1-ip}
	USER=${2-$user}
	web_key='U_WEB_DOMAINS'
	usr_key='U_SYS_USERS'
	current_web=$(grep "$web_key=" $HESTIA/data/ips/$sip | cut -f 2 -d \')
	current_usr=$(grep "$usr_key=" $HESTIA/data/ips/$sip | cut -f 2 -d \')
	if [ -z "$current_web" ]; then
		echo "Error: Parsing error"
		log_event "$E_PARSING" "$ARGUMENTS"
		exit "$E_PARSING"
	fi
	new_web=$((current_web + 1))
	if [ -z "$current_usr" ]; then
		new_usr="$USER"
	else
		check_usr=$(echo -e "${current_usr//,/\\n}" | grep -x "$USER")
		if [ -z "$check_usr" ]; then
			new_usr="$current_usr,$USER"
		else
			new_usr="$current_usr"
		fi
	fi

	# Make sure users list does not contain duplicates
	new_usr=$(echo "$new_usr" \
		| sed "s/,/\n/g" \
		| sort -u \
		| sed ':a;N;$!ba;s/\n/,/g')

	sed -i "s/$web_key='$current_web'/$web_key='$new_web'/g" \
		$HESTIA/data/ips/$sip
	sed -i "s/$usr_key='$current_usr'/$usr_key='$new_usr'/g" \
		$HESTIA/data/ips/$sip
}

# Decrease ip value
decrease_ip_value() {
	sip=${1-ip}
	local user=${2-$user}
	web_key='U_WEB_DOMAINS'
	usr_key='U_SYS_USERS'

	current_web=$(grep "$web_key=" $HESTIA/data/ips/$sip | cut -f 2 -d \')
	current_usr=$(grep "$usr_key=" $HESTIA/data/ips/$sip | cut -f 2 -d \')

	if [ -z "$current_web" ]; then
		check_result $E_PARSING "Parsing error"
	fi

	new_web=$((current_web - 1))
	check_ip=$(grep $sip $USER_DATA/web.conf | wc -l)
	if [[ $check_ip = 0 ]]; then
		new_usr=$(echo "$current_usr" \
			| sed "s/,/\n/g" \
			| sed "s/^$user$//g" \
			| sed "/^$/d" \
			| sort -u \
			| sed ':a;N;$!ba;s/\n/,/g')
	else
		new_usr="$current_usr"
	fi

	sed -i "s/$web_key='$current_web'/$web_key='$new_web'/g" \
		$HESTIA/data/ips/$sip
	sed -i "s/$usr_key='$current_usr'/$usr_key='$new_usr'/g" \
		$HESTIA/data/ips/$sip
}

# Get ip address value
get_ip_value() {
	key="$1"
	string=$(cat $HESTIA/data/ips/$ip)
	eval $string
	eval value="$key"
	echo "$value"
}

# Get real ip address
get_real_ip() {
	if [ -e "$HESTIA/data/ips/$1" ]; then
		echo "$1"
	else
		nat=$(grep -H "^NAT='$1'" $HESTIA/data/ips/* | head -n1)
		if [ -n "$nat" ]; then
			echo "$nat" | cut -f 1 -d : | cut -f 7 -d /
		fi
	fi
}

# Convert CIDR to netmask
convert_cidr() {
	set -- $((5 - ($1 / 8))) 255 255 255 255 \
		$(((255 << (8 - ($1 % 8))) & 255)) 0 0 0
	if [[ $1 -gt 1 ]]; then
		shift $1
	else
		shift
	fi
	echo ${1-0}.${2-0}.${3-0}.${4-0}
}

# Convert netmask to CIDR
convert_netmask() {
	nbits=0
	IFS=.
	for dec in $1; do
		case $dec in
			255) let nbits+=8 ;;
			254) let nbits+=7 ;;
			252) let nbits+=6 ;;
			248) let nbits+=5 ;;
			240) let nbits+=4 ;;
			224) let nbits+=3 ;;
			192) let nbits+=2 ;;
			128) let nbits+=1 ;;
			0) ;;
		esac
	done
	echo "$nbits"
}

# Calculate broadcast address
get_broadcast() {
	OLD_IFS=$IFS
	IFS=.
	typeset -a I=($1)
	typeset -a N=($2)
	IFS=$OLD_IFS

	echo "$((${I[0]} | (255 ^ ${N[0]}))).$((${I[1]} | (255 ^ ${N[1]}))).$((${I[2]} | (255 ^ ${N[2]}))).$((${I[3]} | (255 ^ ${N[3]})))"
}

# Get user ips
get_user_ips() {
	dedicated=$(grep -H "OWNER='$user'" $HESTIA/data/ips/*)
	dedicated=$(echo "$dedicated" | cut -f 1 -d : | sed 's=.*/==' | grep -E ${REGEX_IPV4})
	shared=$(grep -H -A1 "OWNER='$ROOT_USER'" $HESTIA/data/ips/* | grep shared)
	shared=$(echo "$shared" | cut -f 1 -d : | sed 's=.*/==' | cut -f 1 -d \- | grep -E ${REGEX_IPV4})
	for dedicated_ip in $dedicated; do
		shared=$(echo "$shared" | grep -v $dedicated_ip)
	done
	echo -e "$dedicated\n$shared" | sed "/^$/d"
}

# Get user ip
get_user_ip() {
	ip=$(get_user_ips | head -n1)
	if [ -z "$ip" ]; then
		check_result $E_NOTEXIST "no IP is available"
	fi
	local_ip=$ip
	nat=$(grep "^NAT" $HESTIA/data/ips/$ip | cut -f 2 -d \')
	if [ -n "$nat" ]; then
		ip=$nat
	fi
}

# Validate ip address
is_ip_valid() {
	local_ip="$1"
	if [ ! -e "$HESTIA/data/ips/$1" ]; then
		nat=$(grep -H "^NAT='$1'" $HESTIA/data/ips/*)
		if [ -z "$nat" ]; then
			check_result "$E_NOTEXIST" "IP $1 doesn't exist"
		else
			nat=$(echo "$nat" | cut -f1 -d: | cut -f7 -d/)
			local_ip=$nat
		fi
	fi
	if [ -n "$2" ]; then
		if [ -z "$nat" ]; then
			ip_data=$(cat $HESTIA/data/ips/$1)
		else
			ip_data=$(cat $HESTIA/data/ips/$nat)
		fi
		ip_owner=$(echo "$ip_data" | grep OWNER= | cut -f2 -d \')
		ip_status=$(echo "$ip_data" | grep STATUS= | cut -f2 -d \')
		if [ "$ip_owner" != "$user" ] && [ "$ip_status" = 'dedicated' ]; then
			check_result "$E_FORBIDEN" "$user user can't use IP $1"
		fi
		get_user_owner
		if [ "$ip_owner" != "$user" ] && [ "$ip_owner" != "$owner" ]; then
			check_result "$E_FORBIDEN" "$user user can't use IP $1"
		fi
	fi
}

# (Re)write the per-system-IP catch-all configs - the default vhost of
# the web server (/etc/$WEB_SYSTEM/conf.d/$1.conf) and of the proxy
# (/etc/$PROXY_SYSTEM/conf.d/$1.conf) - for system IP $1. They also
# listen on the IPv6 address paired with the IP, if any. An IP with no
# IPv6 paired gets no IPv6 listener at all here: there is only one
# wildcard ([::]) address per port, so a "default_server" (nginx) or
# "Listen" (apache) on it per IP would collide as soon as a server has
# two such IPs. Requires func/domain.sh (process_http2_directive).
write_sys_ip_catchall_configs() {
	local ip="$1" ip6 web_conf proxy_conf
	ip6="$(get_ip6_value "$ip")"

	if [ -n "$WEB_SYSTEM" ]; then
		web_conf="/etc/$WEB_SYSTEM/conf.d/$ip.conf"
		rm -f "$web_conf"

		if [ "$WEB_SYSTEM" = 'httpd' ] || [ "$WEB_SYSTEM" = 'apache2' ]; then
			if [ -z "$(/usr/sbin/apachectl -v | grep Apache/2.4)" ]; then
				echo "NameVirtualHost $ip:$WEB_PORT" > "$web_conf"
				[ -n "$ip6" ] && echo "NameVirtualHost [$ip6]:$WEB_PORT" >> "$web_conf"
			fi
			echo "Listen $ip:$WEB_PORT" >> "$web_conf"
			[ -n "$ip6" ] && echo "Listen [$ip6]:$WEB_PORT" >> "$web_conf"
			if [ -n "$ip6" ]; then
				cat "$HESTIA_INSTALL_DIR/apache2/unassigned.conf" >> "$web_conf"
			else
				# Leave out the <VirtualHost [directIP6]:...> blocks
				awk '/^<VirtualHost \[directIP6\]/ { skip = 1 } !skip { print } /^<\/VirtualHost>/ { skip = 0 }' \
					"$HESTIA_INSTALL_DIR/apache2/unassigned.conf" >> "$web_conf"
			fi
			# directIP6 before directIP: directIP is a literal prefix of
			# directIP6
			sed -i -e "s/directIP6/$ip6/g" -e "s/directIP/$ip/g" -e "s/directPORT/$WEB_PORT/g" "$web_conf"

		elif [ "$WEB_SYSTEM" = 'nginx' ]; then
			if [ -n "$ip6" ]; then
				cp -f "$HESTIA_INSTALL_DIR/nginx/unassigned.inc" "$web_conf"
			else
				grep -v 'directIP6' "$HESTIA_INSTALL_DIR/nginx/unassigned.inc" > "$web_conf"
			fi
			sed -i -e "s/directIP6/$ip6/g" -e "s/directIP/$ip/g" "$web_conf"
			process_http2_directive "$web_conf"
		fi

		if [ "$WEB_SSL" = 'mod_ssl' ]; then
			if [ -z "$(/usr/sbin/apachectl -v | grep Apache/2.4)" ]; then
				[ -n "$ip6" ] && sed -i "1s/^/NameVirtualHost [$ip6]:$WEB_SSL_PORT\n/" "$web_conf"
				sed -i "1s/^/NameVirtualHost $ip:$WEB_SSL_PORT\n/" "$web_conf"
			fi
			[ -n "$ip6" ] && sed -i "1s/^/Listen [$ip6]:$WEB_SSL_PORT\n/" "$web_conf"
			sed -i "1s/^/Listen $ip:$WEB_SSL_PORT\n/" "$web_conf"
			sed -i 's/directSSLPORT/'$WEB_SSL_PORT'/g' "$web_conf"
		fi
	fi

	if [ -n "$PROXY_SYSTEM" ]; then
		proxy_conf="/etc/$PROXY_SYSTEM/conf.d/$ip.conf"
		if [ -n "$ip6" ]; then
			cat "$WEBTPL/$PROXY_SYSTEM/proxy_ip.tpl"
		else
			grep -v '%ip6%' "$WEBTPL/$PROXY_SYSTEM/proxy_ip.tpl"
		fi | sed -e "s/%ip%/$ip/g" \
			-e "s/%ip6%/$ip6/g" \
			-e "s/%web_port%/$WEB_PORT/g" \
			-e "s/%proxy_port%/$PROXY_PORT/g" \
			-e "s/%proxy_ssl_port%/$PROXY_SSL_PORT/g" \
			> "$proxy_conf"
		process_http2_directive "$proxy_conf"
	fi
}

# Check that every address in IPv6 list $1 (see resolve_ip6_list in
# func/domain.sh) may be used by $user: each must be paired with a system
# IP the user is allowed to use (same rules as is_ip_valid - shared IPs
# of the user's owner, or the user's own dedicated ones). "::" (the
# server's wildcard IPv6 address) is always allowed for web domains.
# Without this a user could put their domain on another user's
# dedicated IPv6 address, or on one that isn't configured on the server
# at all - which the web server can't bind to, taking it down for
# everyone on its next restart.
is_ip6_list_available() {
	local addr owner_ip rc
	[ "$1" = 'no' ] && return
	for addr in ${1//,/ }; do
		[ "$addr" = '::' ] && continue
		owner_ip="$(get_ip6_owner "$addr")"
		if [ -z "$owner_ip" ]; then
			check_result "$E_NOTEXIST" "IPv6 address $addr isn't paired with any IP of this server"
		fi
		# Subshell: is_ip_valid sets globals (local_ip, nat) the caller
		# may still rely on for the domain's own IP
		(is_ip_valid "$owner_ip" "$user")
		rc=$?
		if [ "$rc" -ne 0 ]; then
			exit "$rc"
		fi
	done
}

# For restoring a backup (possibly taken on another server): keep only the
# addresses of IPv6 list $1 that are paired with an IP of this server ("::"
# is kept too); a list left empty falls back to the default (''). "no" and
# "" are printed unchanged.
#
# With a user ($2, for web domains), only addresses that user may use
# are kept (see is_ip6_list_available).
filter_ip6_list_to_server() {
	if [ -z "$1" ] || [ "$1" = 'no' ]; then
		echo "$1"
		return
	fi
	[ "$1" = 'yes' ] && return
	local addr owner_ip out=''
	for addr in ${1//,/ }; do
		if [ "$addr" = '::' ]; then
			out="$out,$addr"
			continue
		fi
		owner_ip="$(get_ip6_owner "$addr")"
		[ -z "$owner_ip" ] && continue
		if [ -n "${2-}" ] && ! (user="$2" is_ip_valid "$owner_ip" "$2") > /dev/null 2>&1; then
			continue
		fi
		out="$out,$addr"
	done
	echo "${out#,}"
}

# After restoring DNS zone $2 of user $1 from a backup taken on another
# server (its IPv4 address already rewritten to this server's, $3): bring
# its IPv6 records over to this server as well. AAAA records of hosts that
# point at the zone's IP, whose address isn't one of this server's, are
# the old server's - replace them with this server's per the zone's IPv6
# setting ($4).
restore_dns_zone_ip6() {
	local user="$1" domain="$2" ip="$3" setting="$4" zone prev='' a_hosts host addr
	zone="$HESTIA/data/users/$user/dns/$domain.conf"
	[ -f "$zone" ] || return
	a_hosts="$(grep "TYPE='A' " "$zone" | grep "VALUE='$ip'" | sed -n "s/.*RECORD='\([^']*\)'.*/\1/p" | sort -u)"
	while IFS= read -r host; do
		[ -z "$host" ] && continue
		for addr in $(awk -v q="'" -v h="RECORD=" -v r="$host" '
			index($0, "RECORD=" q r q " TYPE=" q "AAAA" q) {
				if (match($0, "VALUE=" q "[^" q "]*" q)) print substr($0, RSTART + 7, RLENGTH - 8)
			}' "$zone"); do
			if [ -z "$(get_ip6_owner "$addr")" ] && [[ ",$prev," != *",$addr,"* ]]; then
				prev="$prev,$addr"
			fi
		done
	done <<< "$a_hosts"
	"$BIN/v-change-dns-domain-ipv6" "$user" "$domain" "$setting" 'no' "${prev#,}"
}
