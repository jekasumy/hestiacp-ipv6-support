#!/bin/bash

#===========================================================================#
#                                                                           #
# Hestia Control Panel - Domain Function Library                            #
#                                                                           #
#===========================================================================#

#----------------------------------------------------------#
#                   GENERAL FUNCTIONS                      #
#----------------------------------------------------------#

# Prepares a string for safe use in sed.
# Escapes backslashes, '|', and '&'.
sed_escape_replacement() {
	printf '%s' "$1" | sed -e 's/[\&|]/\\&/g'
}

#----------------------------------------------------------#
#                        WEB                               #
#----------------------------------------------------------#

# Web template check
is_web_template_valid() {
	if [ -n "$WEB_SYSTEM" ]; then
		tpl="$WEBTPL/$WEB_SYSTEM/$WEB_BACKEND/$1.tpl"
		stpl="$WEBTPL/$WEB_SYSTEM/$WEB_BACKEND/$1.stpl"
		if [ ! -e "$tpl" ] || [ ! -e "$stpl" ]; then
			check_result "$E_NOTEXIST" "$1 web template doesn't exist"
		fi
	fi
}

# Proxy template check
is_proxy_template_valid() {
	if [ -n "$PROXY_SYSTEM" ]; then
		tpl="$WEBTPL/$PROXY_SYSTEM/$1.tpl"
		stpl="$WEBTPL/$PROXY_SYSTEM/$1.stpl"
		if [ ! -e "$tpl" ] || [ ! -e "$stpl" ]; then
			check_result "$E_NOTEXIST" "$1 proxy template doesn't exist"
		fi
	fi
}

# Backend template check
is_backend_template_valid() {
	if [ -n "$WEB_BACKEND" ]; then
		if [ ! -e "$WEBTPL/$WEB_BACKEND/$1.tpl" ]; then
			check_result "$E_NOTEXIST" "$1 backend template doesn't exist"
		fi
	fi
}

# Web domain existence check
is_web_domain_new() {
	web=$(grep -F -H "DOMAIN='$1'" $HESTIA/data/users/*/web.conf)
	if [ -n "$web" ]; then
		if [ "$type" == 'web' ]; then
			check_result "$E_EXISTS" "Web domain $1 exists"
		fi
		web_user=$(echo "$web" | cut -f 7 -d /)
		if [ "$web_user" != "$user" ]; then
			check_result "$E_EXISTS" "Web domain $1 exists"
		fi
	fi
}

# Web alias existence check
is_web_alias_new() {
	grep -wH "$1" $HESTIA/data/users/*/web.conf | while read -r line; do
		user=$(echo $line | cut -f 7 -d /)
		string=$(echo $line | cut -f 2- -d ':')
		parse_object_kv_list $string
		if [ -n "$ALIAS" ]; then
			a1=$(echo "'$ALIAS'" | grep -F "'$1'")
			if [ -n "$a1" ] && [ "$2" == "web" ]; then
				return "$E_EXISTS"
			fi
			if [ -n "$a1" ] && [ "$user" != "$user" ]; then
				return "$E_EXISTS"
			fi
			a2=$(echo "'$ALIAS'" | grep -F "'$1,")
			if [ -n "$a2" ] && [ "$2" == "web" ]; then
				return "$E_EXISTS"
			fi
			if [ -n "$a2" ] && [ "$user" != "$user" ]; then
				return "$E_EXISTS"
			fi
			a3=$(echo "'$ALIAS'" | grep -F ",$1,")
			if [ -n "$a3" ] && [ "$2" == "web" ]; then
				return "$E_EXISTS"
			fi
			if [ -n "$a3" ] && [ "$user" != "$user" ]; then
				return "$E_EXISTS"
			fi
			a4=$(echo "'$ALIAS'" | grep -F ",$1'")
			if [ -n "$a4" ] && [ "$2" == "web" ]; then
				return "$E_EXISTS"
			fi
			if [ -n "$a4" ] && [ "$user" != "$user" ]; then
				return "$E_EXISTS"
			fi
		fi
	done
	if [ $? -ne 0 ]; then
		check_result "$E_EXISTS" "Web alias $1 exists"
	fi
}

# Prepare web backend
prepare_web_backend() {
	# Accept first function argument as backend template otherwise fallback to $template global variable
	local backend_template=${1:-$template}

	pool=$(find -L /etc/php/ -name "$domain.conf" -exec dirname {} \;)
	# Check if multiple-PHP installed
	regex="socket-(\d+)_(\d+)"
	if [[ $backend_template =~ ^.*PHP-([0-9])\_([0-9])$ ]]; then
		backend_version="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
		pool=$(find -L /etc/php/$backend_version -type d \( -name "pool.d" -o -name "*fpm.d" \))
	else
		backend_version=$(multiphp_default_version)
		if [ -z "$pool" ] || [ -z "$BACKEND" ]; then
			pool=$(find -L /etc/php/$backend_version -type d \( -name "pool.d" -o -name "*fpm.d" \))
		fi
	fi

	if [ ! -e "$pool" ]; then
		check_result $E_NOTEXIST "php-fpm pool doesn't exist"
	fi
	backend_type="$domain"
	if [ "$WEB_BACKEND_POOL" = 'user' ]; then
		backend_type="$user"
	fi
	if [ -e "$pool/$backend_type.conf" ]; then
		backend_lsnr=$(grep "listen =" $pool/$backend_type.conf)
		backend_lsnr=$(echo "$backend_lsnr" | cut -f 2 -d = | sed "s/ //")
		if [ -n "$(echo $backend_lsnr | grep /)" ]; then
			backend_lsnr="unix:$backend_lsnr"
		fi
	fi
}

# Delete web backend
delete_web_backend() {
	find -L /etc/php/ -type f -name "$backend_type.conf" -exec rm -f {} \;
}

# Prepare web aliases
prepare_web_aliases() {
	i=1
	for tmp_alias in ${1//,/ }; do
		tmp_alias_idn="$tmp_alias"
		if [[ "$tmp_alias" = *[![:ascii:]]* ]]; then
			tmp_alias_idn=$(idn2 --quiet $tmp_alias)
		fi
		if [[ $i -eq 1 ]]; then
			aliases="$tmp_alias"
			aliases_idn="$tmp_alias_idn"
			alias_string="ServerAlias $tmp_alias_idn"
		else
			aliases="$aliases,$tmp_alias"
			aliases_idn="$aliases_idn,$tmp_alias_idn"
			if (($i % 100 == 0)); then
				alias_string="$alias_string\n    ServerAlias $tmp_alias_idn"
			else
				alias_string="$alias_string $tmp_alias_idn"
			fi
		fi
		alias_number=$i
		((i++))
	done
}

# Update web domain values
prepare_web_domain_values() {
	if [[ "$domain" = *[![:ascii:]]* ]]; then
		domain_idn=$(idn2 --quiet $domain)
	else
		domain_idn=$domain
	fi
	group="$user"
	docroot="$HOMEDIR/$user/web/$domain/public_html"
	sdocroot="$docroot"
	if [ "$SSL_HOME" = 'single' ]; then
		sdocroot="$HOMEDIR/$user/web/$domain/public_shtml"
		$BIN/v-add-fs-directory "$user" "$HOMEDIR/$user/web/$domain/public_shtml"
		chmod 751 $HOMEDIR/$user/web/$domain/public_shtml
		chown www-data:$user $HOMEDIR/$user/web/$domain/public_shtml
	fi

	if [ -n "$WEB_BACKEND" ]; then
		prepare_web_backend "$BACKEND"
	fi

	server_alias=''
	alias_string=''
	aliases_idn=''
	ssl_ca_str=''
	prepare_web_aliases $ALIAS

	ssl_crt="$HOMEDIR/$user/conf/web/$domain/ssl/$domain.crt"
	ssl_key="$HOMEDIR/$user/conf/web/$domain/ssl/$domain.key"
	ssl_pem="$HOMEDIR/$user/conf/web/$domain/ssl/$domain.pem"
	ssl_ca="$HOMEDIR/$user/conf/web/$domain/ssl/$domain.ca"
	if [ ! -e "$USER_DATA/ssl/$domain.ca" ]; then
		ssl_ca_str='#'
	fi

	# Set correct document root
	if [ -n "$CUSTOM_DOCROOT" ]; then
		# Custom document root has been set by the user, import from configuration
		custom_docroot="$CUSTOM_DOCROOT"
		docroot="$custom_docroot"
		sdocroot="$docroot"
	elif [ -n "$CUSTOM_DOCROOT" ] && [ -n "$target_directory" ]; then
		# Custom document root has been specified with a different target than public_html
		if [ -d "$HOMEDIR/$user/web/$target_domain/public_html/$target_directory/" ]; then
			custom_docroot="$HOMEDIR/$user/web/$target_domain/public_html/$target_directory"
			docroot="$custom_docroot"
			sdocroot="$docroot"
		fi
	elif [ -n "$CUSTOM_DOCROOT" ] && [ -z "$target_directory" ]; then
		# Set custom document root to target domain's public_html folder
		custom_docroot="$HOMEDIR/$user/web/$target_domain/public_html"
		docroot="$custom_docroot"
		sdocroot="$docroot"
	else
		# No custom document root specified, use default
		docroot="$HOMEDIR/$user/web/$domain/public_html"
		sdocroot="$docroot"
	fi

	if [ "$SUSPENDED" = 'yes' ]; then
		docroot="$HESTIA/data/templates/web/suspend"
		sdocroot="$HESTIA/data/templates/web/suspend"
		if [ "$PROXY_SYSTEM" == "nginx" ]; then
			PROXY="suspended"
		else
			TPL="suspended"
		fi
	fi
}

# Print web/webmail template $2 (for web/proxy system $1) with its IPv6
# listen addresses filled in for the comma-separated list $3 (see
# resolve_ip6_list): nginx gets one standalone listen line per address;
# Apache one "[address]:port" segment per address in its <VirtualHost>
# line. An empty list drops them altogether - nginx's standalone line
# outright, Apache's segment while keeping the IPv4 part of the line -
# rather than leaving an empty/invalid address behind.
read_web_tpl_ip6() {
	local system="$1" tpl="$2" list="$3" port segment addr
	local sed_args=()
	if [ "$system" = 'apache2' ]; then
		for port in web_port web_ssl_port proxy_port proxy_ssl_port; do
			segment=''
			for addr in ${list//,/ }; do
				segment="$segment [$addr]:%$port%"
			done
			sed_args+=(-e "s| \\[%ip6%\\]:%$port%|$segment|g")
		done
		sed "${sed_args[@]}" "$tpl"
	elif [ -z "$list" ]; then
		grep -v '\[%ip6%\]' "$tpl"
	else
		awk -v list="$list" '
			index($0, "[%ip6%]") {
				n = split(list, addr, ",")
				for (i = 1; i <= n; i++) {
					line = $0
					gsub(/%ip6%/, addr[i], line)
					print line
				}
				next
			}
			{ print }
		' "$tpl"
	fi
}

# The outgoing address(es) for mail domain $domain - the content of its
# "ip" file, read by exim's remote_smtp transport ("interface"): the IPv4
# address $1, plus the IPv6 address the domain uses (the first of its
# website's IPv6 list - see resolve_ip6_list - or whatever is paired with
# $1) when there is one. Exim picks the address of the right family for
# each connection.
mail_outgoing_ip() {
	local ip="$1" setting ip6
	setting="$(grep "^DOMAIN='$domain' " "$USER_DATA/web.conf" 2> /dev/null | sed -n "s/.* IPV6='\\([^']*\\)'.*/\\1/p")"
	ip6="$(resolve_ip6_list "$setting" "$ip" | tr ',' '\n' | grep -vx '::' | head -n1)"
	if [ -n "$ip6" ]; then
		echo "<; $ip ; $ip6"
	else
		echo "$ip"
	fi
}

# Add web config
add_web_config() {
	# Check if folder already exists
	if [ ! -d "$HOMEDIR/$user/conf/web/$domain" ]; then
		mkdir -p "$HOMEDIR/$user/conf/web/$domain/"
	fi

	conf="$HOMEDIR/$user/conf/web/$domain/$1.conf"
	if [[ "$2" =~ stpl$ ]]; then
		conf="$HOMEDIR/$user/conf/web/$domain/$1.ssl.conf"
	fi

	domain_idn=$domain
	format_domain_idn

	WEBTPL_LOCATION="$WEBTPL/$1"
	if [ "$1" != "$PROXY_SYSTEM" ] && [ -n "$WEB_BACKEND" ] && [ -d "$WEBTPL_LOCATION/$WEB_BACKEND" ]; then
		if [ -f "$WEBTPL_LOCATION/$WEB_BACKEND/$2" ]; then
			# check for backend specific template
			WEBTPL_LOCATION="$WEBTPL/$1/$WEB_BACKEND"
		fi
	fi

	# Note: Removing or renaming template variables will lead to broken custom templates.
	#   -If possible custom templates should be automatically upgraded to use the new format
	#   -Alternatively a depreciation period with proper notifications should be considered

	docroot_escaped="$(sed_escape_replacement "$docroot")"
	sdocroot_escaped="$(sed_escape_replacement "$sdocroot")"

	# A system IP can optionally have a specific IPv6 address paired
	# with it (set on the IP itself, in the "Edit IP" page). By
	# default a domain listens on whichever IPv6 address is paired
	# with its own IPv4 ($local_ip) - but the IP Address dropdown on
	# the Add/Edit Web Domain page also lists every IPv6 address
	# paired with any of the user's system IPs, and lets the domain
	# listen on any set of them, independently of which IPv4 the
	# domain itself uses. $IPV6 in web.conf holds the result (see
	# resolve_ip6_list()):
	#   - unset/empty  -> default: use $local_ip's own paired address
	#                     (this is also the correct, unchanged
	#                     behavior for a domain added before this
	#                     picker existed, which has no IPV6= key in
	#                     its web.conf entry at all)
	#   - 'no'          -> IPv6 disabled entirely for this domain
	#   - a comma-separated list -> listen on exactly those addresses
	# $IPV6 is populated by get_domain_values/parse_object_kv_list,
	# which (like source_conf) only ever sets a variable a web.conf
	# entry actually declares - it never clears one an entry omits, so
	# callers that loop over several domains in one process must reset
	# $IPV6 before each get_domain_values 'web' call; see
	# rebuild_web_domain_conf().
	ip6_listen_list="$(resolve_ip6_list "$IPV6" "$local_ip" '::')"
	template_data="$(read_web_tpl_ip6 "$1" "${WEBTPL_LOCATION}/$2" "$ip6_listen_list")"
	# Any remaining %ip6% outside the listen patterns read_web_tpl_ip6
	# expands (custom templates) gets the first address
	ip6_listen="${ip6_listen_list%%,*}"

	echo "$template_data" \
		| sed -e "s|%ip%|$local_ip|g" \
			-e "s|%ip6%|$ip6_listen|g" \
			-e "s|%domain%|$domain|g" \
			-e "s|%domain_idn%|$domain_idn|g" \
			-e "s|%alias%|${aliases//,/ }|g" \
			-e "s|%alias_idn%|${aliases_idn//,/ }|g" \
			-e "s|%alias_string%|$alias_string|g" \
			-e "s|%email%|info@$domain|g" \
			-e "s|%web_system%|$WEB_SYSTEM|g" \
			-e "s|%web_port%|$WEB_PORT|g" \
			-e "s|%web_ssl_port%|$WEB_SSL_PORT|g" \
			-e "s|%backend_lsnr%|$backend_lsnr|g" \
			-e "s|%rgroups%|$WEB_RGROUPS|g" \
			-e "s|%proxy_system%|$PROXY_SYSTEM|g" \
			-e "s|%proxy_port%|$PROXY_PORT|g" \
			-e "s|%proxy_ssl_port%|$PROXY_SSL_PORT|g" \
			-e "s/%proxy_extentions%/${PROXY_EXT//,/|}/g" \
			-e "s/%proxy_extensions%/${PROXY_EXT//,/|}/g" \
			-e "s|%user%|$user|g" \
			-e "s|%group%|$user|g" \
			-e "s|%home%|$HOMEDIR|g" \
			-e "s|%docroot%|$docroot_escaped|g" \
			-e "s|%sdocroot%|$sdocroot_escaped|g" \
			-e "s|%ssl_crt%|$ssl_crt|g" \
			-e "s|%ssl_key%|$ssl_key|g" \
			-e "s|%ssl_pem%|$ssl_pem|g" \
			-e "s|%ssl_ca_str%|$ssl_ca_str|g" \
			-e "s|%ssl_ca%|$ssl_ca|g" \
			> $conf

	process_http2_directive "$conf"

	chown root:$user $conf
	chmod 640 $conf

	if [[ "$2" =~ stpl$ ]]; then
		rm -f /etc/$1/conf.d/domains/$domain.ssl.conf
		ln -s $conf /etc/$1/conf.d/domains/$domain.ssl.conf

		# Rename/Move extra SSL config files
		find=$(find $HOMEDIR/$user/conf/web/*.$domain.org* 2> /dev/null)
		for f in $find; do
			if [[ $f =~ .*/s(nginx|apache2)\.$domain\.conf(.*) ]]; then
				ServerType="${BASH_REMATCH[1]}"
				CustomConfigName="${BASH_REMATCH[2]}"
				if [ "$CustomConfigName" = "_letsencrypt" ]; then
					rm -f "$f"
					continue
				fi
				mv "$f" "$HOMEDIR/$user/conf/web/$domain/$ServerType.ssl.conf_old$CustomConfigName"
			fi
		done
	else
		rm -f /etc/$1/conf.d/domains/$domain.conf
		ln -s $conf /etc/$1/conf.d/domains/$domain.conf
		# Rename/Move extra config files
		find=$(find $HOMEDIR/$user/conf/web/*.$domain.org* 2> /dev/null)
		for f in $find; do
			if [[ $f =~ .*/(nginx|apache2)\.$domain\.conf(.*) ]]; then
				ServerType="${BASH_REMATCH[1]}"
				CustomConfigName="${BASH_REMATCH[2]}"
				if [ "$CustomConfigName" = "_letsencrypt" ]; then
					rm -f "$f"
					continue
				fi
				mv "$f" "$HOMEDIR/$user/conf/web/$domain/$ServerType.conf_old$CustomConfigName"
			elif [[ $f =~ .*/forcessl\.(nginx|apache2)\.$domain\.conf ]]; then
				ServerType="${BASH_REMATCH[1]}"
				mv "$f" "$HOMEDIR/$user/conf/web/$domain/$ServerType.forcessl.conf"
			fi
		done
	fi

	trigger="${2/.*pl/.sh}"
	if [ -x "${WEBTPL_LOCATION}/$trigger" ]; then
		$WEBTPL_LOCATION/$trigger \
			$user $domain $local_ip $HOMEDIR \
			$HOMEDIR/$user/web/$domain/public_html
	fi
}

# Get config top and bottom line number
get_web_config_lines() {
	tpl_lines=$(egrep -ni "name %domain_idn%" $1 | grep -w %domain_idn%)
	tpl_lines=$(echo "$tpl_lines" | cut -f 1 -d :)
	tpl_last_line=$(wc -l $1 | cut -f 1 -d ' ')
	if [ -z "$tpl_lines" ]; then
		check_result $E_PARSING "can't parse template $1"
	fi

	domain_idn=$domain
	format_domain_idn
	vhost_lines=$(grep -niF "name $domain_idn" $2)
	vhost_lines=$(echo "$vhost_lines" | egrep "$domain_idn($| |;)")
	vhost_lines=$(echo "$vhost_lines" | cut -f 1 -d :)
	if [ -z "$vhost_lines" ]; then
		check_result $E_PARSING "can't parse config $2"
	fi

	top_line=$((vhost_lines + 1 - tpl_lines))
	bottom_line=$((top_line - 1 + tpl_last_line))
	multi=$(sed -n "$top_line,$bottom_line p" $2 | grep ServerAlias | wc -l)
	if [ "$multi" -ge 2 ]; then
		bottom_line=$((bottom_line + multi - 1))
	fi
}

# Replace web config
replace_web_config() {
	conf="$HOMEDIR/$user/conf/web/$domain/$1.conf"
	if [[ "$2" =~ stpl$ ]]; then
		conf="$HOMEDIR/$user/conf/web/$domain/$1.ssl.conf"
	fi

	if [ -e "$conf" ]; then
		sed -i "s|$old|$new|g" $conf
	fi
}

# Delete web configuration
del_web_config() {
	conf="$HOMEDIR/$user/conf/web/$domain/$1.conf"
	local confname="$domain.conf"
	if [[ "$2" =~ stpl$ ]]; then
		conf="$HOMEDIR/$user/conf/web/$domain/$1.ssl.conf"
		confname="$domain.ssl.conf"
	fi

	# Clean up legacy configuration files
	if [ ! -e "$conf" ]; then
		local legacyconf="$HOMEDIR/$user/conf/web/$1.conf"
		if [[ "$2" =~ stpl$ ]]; then
			legacyconf="$HOMEDIR/$user/conf/web/s$1.conf"
		fi
		rm -f $legacyconf

		# Remove old global includes file
		rm -f /etc/$1/conf.d/hestia.conf
	fi

	# Remove domain configuration files and clean up symbolic links
	rm -f "$conf"

	if [ -n "$WEB_SYSTEM" ] && [ "$WEB_SYSTEM" = "$1" ]; then
		rm -f "/etc/$WEB_SYSTEM/conf.d/domains/$confname"
	fi
	if [ -n "$PROXY_SYSTEM" ] && [ "$PROXY_SYSTEM" = "$1" ]; then
		rm -f "/etc/$PROXY_SYSTEM/conf.d/domains/$confname"
	fi
}

# SSL certificate verification
is_web_domain_cert_valid() {
	if [ ! -e "$ssl_dir/$domain.crt" ]; then
		check_result "$E_NOTEXIST" "$ssl_dir/$domain.crt not found"
	fi

	if [ ! -e "$ssl_dir/$domain.key" ]; then
		check_result "$E_NOTEXIST" "$ssl_dir/$domain.key not found"
	fi

	crt_vrf=$(openssl verify $ssl_dir/$domain.crt 2>&1)
	if [ -n "$(echo $crt_vrf | grep 'unable to load')" ]; then
		check_result "$E_INVALID" "SSL Certificate is not valid"
	fi

	if [ -n "$(echo $crt_vrf | grep 'unable to get local issuer')" ]; then
		if [ ! -e "$ssl_dir/$domain.ca" ]; then
			check_result "$E_NOTEXIST" "Certificate Authority not found"
		fi
	fi

	if [ -e "$ssl_dir/$domain.ca" ]; then
		s1=$(openssl x509 -noout -in $ssl_dir/$domain.crt -issuer 2> /dev/null | cut -d = -f2-)
		s2=$(openssl x509 -noout -in $ssl_dir/$domain.ca -subject 2> /dev/null | cut -d = -f2-)
		if [ "$s1" != "$s2" ]; then
			check_result "$E_NOTEXIST" "SSL intermediate chain is not valid"
		fi
	fi

	key_vrf=$(grep 'PRIVATE KEY' $ssl_dir/$domain.key | wc -l)
	if [ "$key_vrf" -ne 2 ]; then
		check_result "$E_INVALID" "SSL Key is not valid"
	fi
	if [ -n "$(grep 'ENCRYPTED' $ssl_dir/$domain.key)" ]; then
		check_result "$E_FORBIDEN" "SSL Key is protected (remove pass_phrase)"
	fi

	if pgrep -x "openssl" > /dev/null; then
		pkill openssl
	fi

	openssl s_server -quiet -cert $ssl_dir/$domain.crt \
		-key $ssl_dir/$domain.key >> /dev/null 2>&1 &
	pid=$!
	sleep 0.5
	disown &> /dev/null
	kill $pid &> /dev/null
	check_result $? "ssl certificate key pair is not valid" $E_INVALID
}

#----------------------------------------------------------#
#                        DNS                               #
#----------------------------------------------------------#

# DNS template check
is_dns_template_valid() {
	if [ ! -e "$DNSTPL/$1.tpl" ]; then
		check_result "$E_NOTEXIST" "$1 dns template doesn't exist"
	fi
}

# DNS domain existence check
is_dns_domain_new() {
	dns=$(ls $HESTIA/data/users/*/dns/$1.conf 2> /dev/null)
	if [ -n "$dns" ]; then
		if [ "$2" == 'dns' ]; then
			check_result "$E_EXISTS" "DNS domain $1 exists"
		fi
		dns_user=$(echo "$dns" | cut -f 7 -d /)
		if [ "$dns_user" != "$user" ]; then
			check_result "$E_EXISTS" "DNS domain $1 exists"
		fi
	fi
}

# Safely parse KEY='value' pairs from dns.conf lines without using eval
parse_dns_record_line() {
	local line="$1"
	local json

	json=$(
		$HESTIA_PHP -- "$line" << 'EOPHP'
<?php
$line = $argv[1];
$allowed_keys = array('ID','RECORD','TYPE','PRIORITY','VALUE','SUSPENDED','TIME','DATE','TTL');
$pattern = "/([A-Za-z](?:[A-Za-z0-9_]{0,64}[A-Za-z])?)='([^']*)'/";

$matches = [];
if (!preg_match_all($pattern, $line, $matches, PREG_SET_ORDER)) {
	fwrite(STDERR, "no key/value pairs");
	exit(1);
}

$remainder = trim(preg_replace($pattern, '', $line));
if ($remainder !== '') {
	fwrite(STDERR, "leftover content");
	exit(1);
}

$result = [];
foreach ($matches as $match) {
	[, $key, $value] = $match;
	if (!in_array($key, $allowed_keys, true)) {
		fwrite(STDERR, "invalid key $key");
		exit(1);
	}
	$result[$key] = $value;
}

echo json_encode($result, JSON_THROW_ON_ERROR | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
EOPHP
	)
	check_result $? "invalid dns record format in $USER_DATA/dns/$domain.conf line: $line" $E_INVALID

	RECORD=$(jq -r '.RECORD // empty' <<< "$json")
	TYPE=$(jq -r '.TYPE // empty' <<< "$json")
	PRIORITY=$(jq -r '.PRIORITY // empty' <<< "$json")
	VALUE=$(jq -r '.VALUE // empty' <<< "$json")
	SUSPENDED=$(jq -r '.SUSPENDED // empty' <<< "$json")
	TIME=$(jq -r '.TIME // empty' <<< "$json")
	DATE=$(jq -r '.DATE // empty' <<< "$json")
	TTL=$(jq -r '.TTL // empty' <<< "$json")
}

# Update domain zone
update_domain_zone() {
	local serial_base=3000000000
	domain_param=$(grep "DOMAIN='$domain'" $USER_DATA/dns.conf)
	parse_object_kv_list "$domain_param"
	local zone_ttl="$TTL"
	local value_for_zone
	SOA=$(idn2 --quiet "$SOA")
	if [ -z "$SERIAL" ]; then
		SERIAL=$serial_base
	fi
	if [[ "$domain" = *[![:ascii:]]* ]]; then
		domain_idn=$(idn2 --quiet "$domain")
	else
		domain_idn=$domain
	fi

	# Set SOA refresh value based on TLD
	tld="${domain_idn##*.}"
	case "$tld" in
		de | cz | pl | pt)
			refresh=1800
			;;
		*)
			refresh=3600
			;;
	esac

	zn_conf="$HOMEDIR/$user/conf/dns/$domain.db"
	echo "\$TTL $zone_ttl
@    IN    SOA    $SOA.    root.$domain_idn. (
                                            $SERIAL
                                            14400
                                            $refresh
                                            1209600
                                            3600 )
" > "$zn_conf"

	while IFS= read -r line; do
		unset TTL RECORD TYPE PRIORITY VALUE SUSPENDED TIME DATE
		parse_dns_record_line "$line"

		# inherit zone TTL if record lacks explicit TTL value
		[ -z "$TTL" ] && TTL="$zone_ttl"

		RECORD=$(idn2 --quiet "$RECORD")
		if [ "$TYPE" = 'CNAME' ] || [ "$TYPE" = 'MX' ]; then
			VALUE=$(idn2 --quiet "$VALUE")
		elif [ "$TYPE" = 'SRV' ]; then
			# SRV value is "weight port target" (the priority is stored separately
			# in the PRIORITY field). Only the trailing target is a host name, so
			# parse the fields and convert just that, leaving the numeric
			# weight/port and a "." target (service unavailable) untouched.
			read -r srv_weight srv_port srv_target <<< "$VALUE"
			if [ "$srv_target" != "." ]; then
				srv_target=$(idn2 --quiet "$srv_target")
			fi
			VALUE="$srv_weight $srv_port $srv_target"
		fi

		if [ "$TYPE" = 'TXT' ]; then
			# Restore single quotes before chunking so %quote% tokens are not split mid-way
			VALUE=${VALUE//%quote%/\'}
			txtlength=${#VALUE}
			if [ $txtlength -gt 255 ]; then
				already_chunked=0
				if [[ $VALUE == *"\" \""* ]] || [[ $VALUE == *"\"\""* ]]; then
					already_chunked=1
				fi
				if [ $already_chunked -eq 0 ]; then
					if [[ ${VALUE:0:1} = '"' ]]; then
						txtlength=$(($txtlength - 2))
						VALUE=${VALUE:1:txtlength}
					fi
					VALUE=$(echo "$VALUE" | fold -w 255 | xargs -I '$' echo -n '"$"')
				fi
			fi
		fi

		if [ "$SUSPENDED" != 'yes' ]; then
			value_for_zone=${VALUE//%quote%/\'}
			printf "%s\t%s\tIN\t%s\t%s\t%s\n" "$RECORD" "$TTL" "$TYPE" "$PRIORITY" "$value_for_zone" >> "$zn_conf"
		fi
	done < "$USER_DATA/dns/$domain.conf"
}

# Update zone serial
update_domain_serial() {
	local serial_base=3000000000
	local serial_max=4294967295
	local zn_conf="$HOMEDIR/$user/conf/dns/$domain.db"
	local zn_serial
	local serial

	if [[ -f "$zn_conf" ]]; then
		zn_serial=$(head "$zn_conf" | grep -m1 'SOA' -A1 | tail -n1 | tr -d ' ')
	fi

	# Old format YYYYMMDDNN, years 2000-2029
	local old_format_re='^20[0-2][0-9](0[1-9]|1[0-2])(0[1-9]|[12][0-9]|3[01])[0-9]{2}$'

	if [[ -z "$zn_serial" ]] || [[ ! "$zn_serial" =~ ^[0-9]+$ ]] \
		|| [[ "$zn_serial" =~ $old_format_re ]]; then
		serial=$serial_base
	else
		serial=$((10#$zn_serial + 1))

		if ((serial > serial_max)); then
			serial=1
		fi
	fi

	serial=$(printf '%010u' "$serial")

	add_object_key 'dns' 'DOMAIN' "$domain" 'SERIAL' 'RECORDS'
	update_object_value 'dns' 'DOMAIN' "$domain" '$SERIAL' "$serial"
}

# Get next DNS record ID
# Resolve a domain's stored IPv6 setting ($IPV6 in web.conf/dns.conf, as
# picked in the IP Address dropdown on the Add/Edit Web Domain and DNS
# Zone pages) into the comma-separated list of IPv6 addresses it should
# actually use:
#   ''/'yes'  -> default: whatever is paired with the domain's own IP
#                ($2); falls back to $3 when nothing is paired (web
#                domains pass '::' to keep listening on the server's
#                wildcard IPv6 address, DNS zones pass nothing since
#                there's no such thing as a wildcard AAAA record)
#   'no'      -> empty (IPv6 disabled)
#   a list    -> used as-is - any IPv6 addresses, which don't need to
#                be the one paired with the domain's own IP
resolve_ip6_list() {
	local value="$1" sip="$2" fallback="${3-}"
	if [ "$value" = 'no' ]; then
		return
	fi
	if [ -n "$value" ] && [ "$value" != 'yes' ]; then
		echo "$value"
		return
	fi
	local paired
	paired="$(get_paired_ip6 "$sip")"
	echo "${paired:-$fallback}"
}

# The IPv6 address paired with system IP $1, if any. Like get_ip6_value()
# in func/ip.sh (inlined here since not every caller of the domain
# functions, e.g. rebuild_dns_domain_conf via the DNS record commands,
# sources func/ip.sh), but also accepts an IP's public NAT address - DNS
# zones store that one, while the IP's data file is named after the
# local address.
get_paired_ip6() {
	local sip="$1" f
	f="$HESTIA/data/ips/$sip"
	if [ ! -e "$f" ]; then
		f="$(grep -lx "NAT='$sip'" "$HESTIA"/data/ips/* 2> /dev/null | head -n1)"
	fi
	if [ -n "$f" ] && [ -e "$f" ]; then
		grep "^IP6=" "$f" | cut -f 2 -d \'
	fi
}

# Add AAAA records for host $3 of DNS zone $2 (user $1) next to an A record
# just added for it pointing at the zone's IP $4 - one per IPv6 address
# the zone publishes (see resolve_ip6_list), skipping ones that exist.
add_dns_host_ip6_records() {
	local user="$1" zone="$2" host="$3" ip="$4" restart="${5-}" setting addr
	setting="$(grep "^DOMAIN='$zone' " "$HESTIA/data/users/$user/dns.conf" | sed -n "s/.* IPV6='\\([^']*\\)'.*/\\1/p")"
	for addr in $(resolve_ip6_list "$setting" "$ip" | tr ',' ' '); do
		if ! awk -v q="'" -v h="$host" -v a="$addr" '
			index($0, "RECORD=" q h q " TYPE=" q "AAAA" q) && index($0, "VALUE=" q a q) { found = 1 }
			END { exit !found }' "$HESTIA/data/users/$user/dns/$zone.conf"; then
			$BIN/v-add-dns-record "$user" "$zone" "$host" AAAA "$addr" '' '' "$restart" '' 'yes'
		fi
	done
	# Keep them next to the host's A record
	if [ -n "$(sort_dns_aaaa_records "$HESTIA/data/users/$user/dns/$zone.conf")" ] && [ "$DNS_CLUSTER" = "yes" ]; then
		# Record IDs changed: resync the whole zone to the cluster
		if ! grep -q "domain $user $zone " "$HESTIA/data/queue/dns-cluster.pipe" 2> /dev/null; then
			echo "$BIN/v-add-remote-dns-domain $user $zone yes" >> "$HESTIA/data/queue/dns-cluster.pipe"
		fi
	fi
}

# Move the AAAA records of DNS zone record file $1 right after the A
# record(s) of the same host, so IPv4 and IPv6 sit next to each other in
# the record list (records added later, e.g. when an IPv6 address gets
# paired, are otherwise appended at the end). AAAA records of hosts
# without an A record stay where they are. The record IDs already in
# use are handed out again in the new order, so records before the
# first moved one keep their IDs. Prints "changed" if anything moved.
sort_dns_aaaa_records() {
	local conf="$1" result
	[ -s "$conf" ] || return 0
	result="$(awk -v q="'" '
		function field(line, k,   m) {
			if (match(line, "(^| )" k "=" q "[^" q "]*" q)) {
				m = substr(line, RSTART, RLENGTH)
				sub("^ ?" k "=" q, "", m)
				sub(q "$", "", m)
				return m
			}
			return ""
		}
		{
			n++; line[n] = $0; rec[n] = field($0, "RECORD"); type[n] = field($0, "TYPE")
			id[n] = field($0, "ID") + 0
			if (type[n] == "A") last_a[rec[n]] = n
		}
		END {
			# AAAA records of hosts that have an A record, in their current order
			for (i = 1; i <= n; i++) {
				if (type[i] == "AAAA" && (rec[i] in last_a)) {
					moved[i] = 1
					cnt[rec[i]]++
					aaaa[rec[i], cnt[rec[i]]] = i
				}
			}
			m = 0
			for (i = 1; i <= n; i++) {
				if (i in moved) continue
				order[++m] = i
				if (type[i] == "A" && last_a[rec[i]] == i) {
					for (j = 1; j <= cnt[rec[i]]; j++) order[++m] = aaaa[rec[i], j]
				}
			}
			changed = 0
			for (i = 1; i <= n; i++) if (order[i] != i) changed = 1
			if (!changed) exit 0
			# The IDs in use, ascending, handed out in the new order
			for (i = 1; i <= n; i++) ids[i] = id[i]
			for (i = 2; i <= n; i++) {
				v = ids[i]; j = i - 1
				while (j > 0 && ids[j] > v) { ids[j + 1] = ids[j]; j-- }
				ids[j + 1] = v
			}
			for (i = 1; i <= n; i++) {
				l = line[order[i]]
				sub("^ID=" q "[0-9]+" q, "ID=" q ids[i] q, l)
				print l > (FILENAME ".tmp")
			}
			close(FILENAME ".tmp")
			print "changed"
		}
	' "$conf")"
	if [ "$result" = "changed" ] && [ -s "$conf.tmp" ]; then
		mv -f "$conf.tmp" "$conf"
		echo changed
	fi
	rm -f "$conf.tmp"
}

# Expand the %ip6% (AAAA) lines of a DNS zone template read from stdin
# for a comma-separated list of IPv6 addresses ($1, see
# resolve_ip6_list()): one copy of each such line per
# address, renumbering record IDs so the copies don't collide. With an
# empty list the AAAA lines are dropped outright, since an AAAA record
# with an empty value would be an invalid zone entry.
dns_tpl_expand_ip6() {
	if [ -z "$1" ]; then
		grep -v '%ip6%'
		return 0
	fi
	awk -v list="$1" '
		index($0, "%ip6%") {
			n = split(list, addr, ",")
			for (i = 1; i <= n; i++) {
				line = $0
				gsub(/%ip6%/, addr[i], line)
				print line
			}
			next
		}
		{ print }
	' | awk -v q="'" '{ sub("^ID=" q "[0-9]+" q, "ID=" q NR q); print }'
}

# SPF counterpart of dns_tpl_expand_ip6: the value of the %ip6_spf%
# template macro - one " ip6:<address>" mechanism per address (with the
# leading space, so it drops in right after the template's ip4:
# mechanism), or nothing at all for an empty list, since an empty "ip6:"
# mechanism would be invalid SPF syntax.
dns_tpl_ip6_spf() {
	local addr
	for addr in ${1//,/ }; do
		printf ' ip6:%s' "$addr"
	done
}

get_next_dnsrecord() {
	if [ -z "$id" ]; then
		curr_str=$(grep "ID=" $USER_DATA/dns/$domain.conf | cut -f 2 -d \' \
			| sort -n | tail -n1)
		id="$((curr_str + 1))"
	fi
}

# Sort DNS records
sort_dns_records() {
	conf="$USER_DATA/dns/$domain.conf"
	cat $conf | sort -n -k 2 -t \' > $conf.tmp
	mv -f $conf.tmp $conf
}

# Check if this is a last record
is_dns_record_critical() {
	str=$(grep "ID='$id'" $USER_DATA/dns/$domain.conf)
	parse_object_kv_list "$str"
	if [ "$TYPE" = 'A' ] || [ "$TYPE" = 'NS' ]; then
		records=$(grep "TYPE='$TYPE'" $USER_DATA/dns/$domain.conf | wc -l)
		if [ $records -le 1 ]; then
			echo "Error: at least one $TYPE record should remain active"
			log_event "$E_INVALID" "$ARGUMENTS"
			exit "$E_INVALID"
		fi
	fi
}

# Check if dns record is valid
is_dns_fqnd() {
	t=$1
	r=$2
	if [ "$t" = 'SRV' ]; then
		first_field=$(echo "$r" | awk '{print $1}')
		last_field=$(echo "$r" | awk '{print $NF}')
		if [ "$first_field" = "." ] || [ "$last_field" = "." ]; then
			return
		fi
	fi
	fqdn_type=$(echo $t | grep "^NS\|CNAME\|MX\|PTR\|SRV")
	tree_length=3
	if [[ $t = 'CNAME' || $t = 'MX' || $t = 'PTR' ]]; then
		tree_length=2
	fi
	if [ -n "$fqdn_type" ]; then
		dots=$(echo $dvalue | grep -o "\." | wc -l)
		if [ "$dots" -lt "$tree_length" ]; then
			r=$(echo $r | sed -e "s/\.$//")
			msg="$t record $r should be a fully qualified domain name (FQDN)"
			echo "Error: $msg"
			log_event "$E_INVALID" "$ARGUMENTS"
			exit "$E_INVALID"
		fi
	fi
}

# Validate nameserver
is_dns_nameserver_valid() {
	d=$1
	t=$2
	r=$3
	if [ "$t" = 'NS' ]; then
		remote=$(echo $r | grep ".$domain.$")
		if [ -n "$remote" ]; then
			zone=$USER_DATA/dns/$d.conf
			a_record=${r%.$d.}
			n_record=$(grep "RECORD='$a_record'" $zone | grep "TYPE='A'")
			if [ -z "$n_record" ]; then
				check_result "$E_NOTEXIST" "IN A $a_record.$d does not exist"
			fi
		fi
	fi
}

#----------------------------------------------------------#
#                       MAIL                               #
#----------------------------------------------------------#

# Mail domain existence check
is_mail_domain_new() {
	mail=$(ls $HESTIA/data/users/*/mail/$1.conf 2> /dev/null)
	if [ -n "$mail" ]; then
		if [ "$2" == 'mail' ]; then
			check_result $E_EXISTS "Mail domain $1 exists"
		fi
		mail_user=$(echo "$mail" | cut -f 7 -d /)
		if [ "$mail_user" != "$user" ]; then
			check_result "$E_EXISTS" "Mail domain $1 exists"
		fi
	fi
	mail_sub=$(echo "$1" | cut -f 1 -d .)
	mail_nosub=$(echo "$1" | cut -f 1 -d . --complement)
	for mail_reserved in $(echo "mail $WEBMAIL_ALIAS"); do
		if [ -n "$(ls $HESTIA/data/users/*/mail/$mail_reserved.$1.conf 2> /dev/null)" ]; then
			if [ "$2" == 'mail' ]; then
				check_result "$E_EXISTS" "Required subdomain \"$mail_reserved.$1\" already exists"
			fi
		fi
		if [ -n "$(ls $HESTIA/data/users/*/mail/$mail_nosub.conf 2> /dev/null)" ] && [ "$mail_sub" = "$mail_reserved" ]; then
			if [ "$2" == 'mail' ]; then
				check_result "$E_INVALID" "The subdomain \"$mail_sub.\" is reserved by \"$mail_nosub\""
			fi
		fi
	done
}

# Checking mail account existence
is_mail_new() {
	check_acc=$(grep "ACCOUNT='$1'" $USER_DATA/mail/$domain.conf)
	if [ -n "$check_acc" ]; then
		check_result "$E_EXISTS" "mail account $1 already exists"
	fi
	check_als=$(awk -F "ALIAS='" '{print $2}' $USER_DATA/mail/$domain.conf)
	match=$(echo "$check_als" | cut -f 1 -d "'" | grep $1)
	if [ -n "$match" ]; then
		parse_object_kv_list $(grep "ALIAS='$match'" $USER_DATA/mail/$domain.conf)
		check_als=$(echo ",$ALIAS," | grep ",$1,")
		if [ -n "$check_als" ]; then
			check_result "$E_EXISTS" "mail alias $1 already exists"
		fi
	fi
}

# Add mail server SSL configuration
add_mail_ssl_config() {
	# Ensure that SSL certificate directories exists
	if [ ! -d "$HOMEDIR/$user/conf/mail/$domain/ssl/" ]; then
		mkdir -p $HOMEDIR/$user/conf/mail/$domain/ssl/
	fi

	if [ ! -d "$HESTIA/ssl/mail" ]; then
		mkdir -p $HESTIA/ssl/mail
	fi

	if [ ! -d /etc/dovecot/conf.d/domains ]; then
		mkdir -p /etc/dovecot/conf.d/domains
	fi

	# Add certificate to Hestia user configuration data directory
	if [ -f "$ssl_dir/$domain.crt" ]; then
		cp -f $ssl_dir/$domain.crt $USER_DATA/ssl/mail.$domain.crt
		cp -f $ssl_dir/$domain.key $USER_DATA/ssl/mail.$domain.key
		cp -f $ssl_dir/$domain.crt $USER_DATA/ssl/mail.$domain.pem
		if [ -e "$ssl_dir/$domain.ca" ]; then
			cp -f $ssl_dir/$domain.ca $USER_DATA/ssl/mail.$domain.ca
			echo >> $USER_DATA/ssl/mail.$domain.pem
			cat $USER_DATA/ssl/mail.$domain.ca >> $USER_DATA/ssl/mail.$domain.pem
		fi
	fi

	chmod 660 $USER_DATA/ssl/mail.$domain.*

	# Add certificate to user home directory
	cp -f $USER_DATA/ssl/mail.$domain.crt $HOMEDIR/$user/conf/mail/$domain/ssl/$domain.crt
	cp -f $USER_DATA/ssl/mail.$domain.key $HOMEDIR/$user/conf/mail/$domain/ssl/$domain.key
	cp -f $USER_DATA/ssl/mail.$domain.pem $HOMEDIR/$user/conf/mail/$domain/ssl/$domain.pem
	if [ -e "$USER_DATA/ssl/mail.$domain.ca" ]; then
		cp -f $USER_DATA/ssl/mail.$domain.ca $HOMEDIR/$user/conf/mail/$domain/ssl/$domain.ca
	fi

	# Clean up dovecot configuration (if it exists)
	if [ -f /etc/dovecot/conf.d/domains/$domain.conf ]; then
		rm -f /etc/dovecot/conf.d/domains/$domain.conf
	fi

	# Check if using custom / wildcard mail certificate
	wildcard_domain="\\*.$(echo "$domain" | cut -f 1 -d . --complement)"
	mail_cert_match=$($BIN/v-list-mail-domain-ssl $user $domain | awk '/SUBJECT|ALIASES/' | grep -wE " $domain| $wildcard_domain")
	dovecot_version="$(dovecot --version | cut -f -2 -d .)"

	if [ -n "$mail_cert_match" ]; then
		if [[ "$dovecot_version" = "2.4" ]]; then
			# Add domain SSL configuration to dovecot
			echo "" >> /etc/dovecot/conf.d/domains/$domain.conf
			echo "local_name $domain {" >> /etc/dovecot/conf.d/domains/$domain.conf
			echo "  ssl_server_cert_file = $HOMEDIR/$user/conf/mail/$domain/ssl/$domain.pem" >> /etc/dovecot/conf.d/domains/$domain.conf
			echo "  ssl_server_key_file = $HOMEDIR/$user/conf/mail/$domain/ssl/$domain.key" >> /etc/dovecot/conf.d/domains/$domain.conf
			echo "}" >> /etc/dovecot/conf.d/domains/$domain.conf
		else
			echo "" >> /etc/dovecot/conf.d/domains/$domain.conf
			echo "local_name $domain {" >> /etc/dovecot/conf.d/domains/$domain.conf
			echo "  ssl_cert = <$HOMEDIR/$user/conf/mail/$domain/ssl/$domain.pem" >> /etc/dovecot/conf.d/domains/$domain.conf
			echo "  ssl_key = <$HOMEDIR/$user/conf/mail/$domain/ssl/$domain.key" >> /etc/dovecot/conf.d/domains/$domain.conf
			echo "}" >> /etc/dovecot/conf.d/domains/$domain.conf
		fi
		# Add domain SSL configuration to exim4
		ln -s $HOMEDIR/$user/conf/mail/$domain/ssl/$domain.pem $HESTIA/ssl/mail/$domain.crt
		ln -s $HOMEDIR/$user/conf/mail/$domain/ssl/$domain.key $HESTIA/ssl/mail/$domain.key
	fi

	# Add domain SSL configuration to dovecot
	if [[ "$dovecot_version" = "2.4" ]]; then
		# Add domain SSL configuration to dovecot
		echo "" >> /etc/dovecot/conf.d/domains/$domain.conf
		echo "local_name mail.$domain {" >> /etc/dovecot/conf.d/domains/$domain.conf
		echo "  ssl_server_cert_file = $HOMEDIR/$user/conf/mail/$domain/ssl/$domain.pem" >> /etc/dovecot/conf.d/domains/$domain.conf
		echo "  ssl_server_key_file = $HOMEDIR/$user/conf/mail/$domain/ssl/$domain.key" >> /etc/dovecot/conf.d/domains/$domain.conf
		echo "}" >> /etc/dovecot/conf.d/domains/$domain.conf
	else
		echo "" >> /etc/dovecot/conf.d/domains/$domain.conf
		echo "local_name mail.$domain {" >> /etc/dovecot/conf.d/domains/$domain.conf
		echo "  ssl_cert = <$HOMEDIR/$user/conf/mail/$domain/ssl/$domain.pem" >> /etc/dovecot/conf.d/domains/$domain.conf
		echo "  ssl_key = <$HOMEDIR/$user/conf/mail/$domain/ssl/$domain.key" >> /etc/dovecot/conf.d/domains/$domain.conf
		echo "}" >> /etc/dovecot/conf.d/domains/$domain.conf
	fi

	# Add domain SSL configuration to exim4
	ln -s $HOMEDIR/$user/conf/mail/$domain/ssl/$domain.pem $HESTIA/ssl/mail/mail.$domain.crt
	ln -s $HOMEDIR/$user/conf/mail/$domain/ssl/$domain.key $HESTIA/ssl/mail/mail.$domain.key

	# Set correct permissions on certificates
	chmod 0750 $HOMEDIR/$user/conf/mail/$domain/ssl
	chown -R $MAIL_USER:mail $HOMEDIR/$user/conf/mail/$domain/ssl
	chmod 0644 $HOMEDIR/$user/conf/mail/$domain/ssl/*
	chown -h $user:mail $HOMEDIR/$user/conf/mail/$domain/ssl/*
	chmod -R 0644 $HESTIA/ssl/mail/*
	chown -h $user:mail $HESTIA/ssl/mail/*
}

# Delete SSL support for mail domain
del_mail_ssl_config() {
	# Check to prevent accidental removal of mismatched certificate
	wildcard_domain="\\*.$(echo "$domain" | cut -f 1 -d . --complement)"
	mail_cert_match=$($BIN/v-list-mail-domain-ssl $user $domain | awk '/SUBJECT|ALIASES/' | grep -wE " $domain| $wildcard_domain")

	# Remove old mail certificates
	rm -f $HOMEDIR/$user/conf/mail/$domain/ssl/*

	# Remove dovecot configuration
	rm -f /etc/dovecot/conf.d/domains/$domain.conf

	# Remove SSL vhost configuration
	rm -f $HOMEDIR/$user/conf/mail/$domain/*.*ssl.conf
	rm -f /etc/$WEB_SYSTEM/conf.d/domains/$WEBMAIL_ALIAS.$domain.ssl.conf
	rm -f /etc/$PROXY_SYSTEM/conf.d/domains/$WEBMAIL_ALIAS.$domain.ssl.conf

	# Remove SSL certificates
	rm -f $HOMEDIR/$user/conf/mail/$domain/ssl/*
	if [ -n "$mail_cert_match" ]; then
		rm -f $HESTIA/ssl/mail/$domain.crt $HESTIA/ssl/mail/$domain.key
	fi
	rm -f $HESTIA/ssl/mail/mail.$domain.crt $HESTIA/ssl/mail/mail.$domain.key
}

# Delete generated certificates from user configuration data directory
del_mail_ssl_certificates() {
	rm -f $USER_DATA/ssl/mail.$domain.ca
	rm -f $USER_DATA/ssl/mail.$domain.crt
	rm -f $USER_DATA/ssl/mail.$domain.key
	rm -f $USER_DATA/ssl/mail.$domain.pem
	rm -f $HOMEDIR/$user/conf/mail/$domain/ssl/*
}

# Add webmail config
add_webmail_config() {
	mkdir -p "$HOMEDIR/$user/conf/mail/$domain"
	conf="$HOMEDIR/$user/conf/mail/$domain/$1.conf"
	if [[ "$2" =~ stpl$ ]]; then
		conf="$HOMEDIR/$user/conf/mail/$domain/$1.ssl.conf"
	fi

	domain_idn=$domain
	format_domain_idn

	ssl_crt="$HOMEDIR/$user/conf/mail/$domain/ssl/$domain.crt"
	ssl_key="$HOMEDIR/$user/conf/mail/$domain/ssl/$domain.key"
	ssl_pem="$HOMEDIR/$user/conf/mail/$domain/ssl/$domain.pem"
	ssl_ca="$HOMEDIR/$user/conf/mail/$domain/ssl/$domain.ca"

	override_alias=""
	if [ "$WEBMAIL_ALIAS" != "mail" ]; then
		override_alias="mail.$domain"
		override_alias_idn="mail.$domain_idn"
	fi

	# Note: Removing or renaming template variables will lead to broken custom templates.
	#   -If possible custom templates should be automatically upgraded to use the new format
	#   -Alternatively a depreciation period with proper notifications should be considered

	# Webmail listens on the same IPv6 addresses as the domain's website,
	# if it has one (its IPV6 setting - see add_web_config), and on the
	# IP's own paired address (or the wildcard) otherwise
	webmail_ip6="$(grep "^DOMAIN='$domain' " "$USER_DATA/web.conf" 2> /dev/null | sed -n "s/.* IPV6='\\([^']*\\)'.*/\\1/p")"
	ip6_listen_list="$(resolve_ip6_list "$webmail_ip6" "$local_ip" '::')"
	ip6_listen="${ip6_listen_list%%,*}"

	read_web_tpl_ip6 "$1" "$MAILTPL/$1/$2" "$ip6_listen_list" \
		| sed -e "s|%ip%|$local_ip|g" \
			-e "s|%ip6%|$ip6_listen|g" \
			-e "s|%domain%|$WEBMAIL_ALIAS.$domain|g" \
			-e "s|%domain_idn%|$WEBMAIL_ALIAS.$domain_idn|g" \
			-e "s|%root_domain%|$domain|g" \
			-e "s|%alias%|$override_alias|g" \
			-e "s|%alias_idn%|$override_alias_idn|g" \
			-e "s|%alias_string%|$alias_string|g" \
			-e "s|%email%|info@$domain|g" \
			-e "s|%web_system%|$WEB_SYSTEM|g" \
			-e "s|%web_port%|$WEB_PORT|g" \
			-e "s|%web_ssl_port%|$WEB_SSL_PORT|g" \
			-e "s|%backend_lsnr%|$backend_lsnr|g" \
			-e "s|%rgroups%|$WEB_RGROUPS|g" \
			-e "s|%proxy_system%|$PROXY_SYSTEM|g" \
			-e "s|%proxy_port%|$PROXY_PORT|g" \
			-e "s|%proxy_ssl_port%|$PROXY_SSL_PORT|g" \
			-e "s/%proxy_extensions%/${PROXY_EXT//,/|}/g" \
			-e "s|%user%|$user|g" \
			-e "s|%group%|$user|g" \
			-e "s|%home%|$HOMEDIR|g" \
			-e "s|%docroot%|$docroot|g" \
			-e "s|%sdocroot%|$sdocroot|g" \
			-e "s|%ssl_crt%|$ssl_crt|g" \
			-e "s|%ssl_key%|$ssl_key|g" \
			-e "s|%ssl_pem%|$ssl_pem|g" \
			-e "s|%ssl_ca_str%|$ssl_ca_str|g" \
			-e "s|%ssl_ca%|$ssl_ca|g" \
			> $conf

	process_http2_directive "$conf"

	chown root:$user $conf
	chmod 640 $conf

	if [[ "$2" =~ stpl$ ]]; then
		if [ -n "$WEB_SYSTEM" ]; then
			forcessl="$HOMEDIR/$user/conf/mail/$domain/$WEB_SYSTEM.forcessl.conf"
			rm -f /etc/$1/conf.d/domains/$WEBMAIL_ALIAS.$domain.ssl.conf
			ln -s $conf /etc/$1/conf.d/domains/$WEBMAIL_ALIAS.$domain.ssl.conf
		fi
		if [ -n "$PROXY_SYSTEM" ]; then
			forcessl="$HOMEDIR/$user/conf/mail/$domain/$PROXY_SYSTEM.forcessl.conf"
			rm -f /etc/$1/conf.d/domains/$WEBMAIL_ALIAS.$domain.ssl.conf
			ln -s $conf /etc/$1/conf.d/domains/$WEBMAIL_ALIAS.$domain.ssl.conf
		fi

		# Add rewrite rules to force HTTPS/SSL connections
		if [ -n "$PROXY_SYSTEM" ] || [ "$WEB_SYSTEM" = 'nginx' ]; then
			echo 'return 301 https://$server_name$request_uri;' > $forcessl
		else
			echo 'RewriteEngine On' > $forcessl
			echo 'RewriteRule ^(.*)$ https://%{HTTP_HOST}$1 [R=301,L]' >> $forcessl
		fi

		# Remove old configurations
		find $HOMEDIR/$user/conf/mail/ -maxdepth 1 -type f \( -name "$domain.*" -o -name "ssl.$domain.*" -o -name "*nginx.$domain.*" \) -exec rm {} \;
	else
		if [ -n "$WEB_SYSTEM" ]; then
			rm -f /etc/$1/conf.d/domains/$WEBMAIL_ALIAS.$domain.conf
			ln -s $conf /etc/$1/conf.d/domains/$WEBMAIL_ALIAS.$domain.conf
		fi
		if [ -n "$PROXY_SYSTEM" ]; then
			rm -f /etc/$1/conf.d/domains/$WEBMAIL_ALIAS.$domain.conf
			ln -s $conf /etc/$1/conf.d/domains/$WEBMAIL_ALIAS.$domain.conf
		fi
		# Clear old configurations
		find $HOMEDIR/$user/conf/mail/ -maxdepth 1 -type f \( -name "$domain.*" \) -exec rm {} \;
	fi
}

# Delete webmail support
del_webmail_config() {
	if [ -n "$WEB_SYSTEM" ]; then
		rm -f $HOMEDIR/$user/conf/mail/$domain/$WEB_SYSTEM.conf
		rm -f /etc/$WEB_SYSTEM/conf.d/domains/$WEBMAIL_ALIAS.$domain.conf
	fi

	if [ -n "$PROXY_SYSTEM" ]; then
		rm -f $HOMEDIR/$user/conf/mail/$domain/$PROXY_SYSTEM.*conf
		rm -f /etc/$PROXY_SYSTEM/conf.d/domains/$WEBMAIL_ALIAS.$domain.conf
	fi
}

# Delete SSL webmail support
del_webmail_ssl_config() {
	if [ -n "$WEB_SYSTEM" ]; then
		rm -f $HOMEDIR/$user/conf/mail/$domain/$WEB_SYSTEM.*ssl.conf
		rm -f /etc/$WEB_SYSTEM/conf.d/domains/$WEBMAIL_ALIAS.$domain.ssl.conf
	fi

	if [ -n "$PROXY_SYSTEM" ]; then
		rm -f $HOMEDIR/$user/conf/mail/$domain/$PROXY_SYSTEM.*ssl.conf
		rm -f /etc/$PROXY_SYSTEM/conf.d/domains/$WEBMAIL_ALIAS.$domain.ssl.conf
	fi
}

#----------------------------------------------------------#
#                        CMN                               #
#----------------------------------------------------------#

# Checking domain existence
is_domain_new() {
	type=$1
	for object in ${2//,/ }; do
		if [ -n "$WEB_SYSTEM" ]; then
			is_web_domain_new $object $type
			is_web_alias_new $object $type
		fi
		if [ -n "$DNS_SYSTEM" ]; then
			is_dns_domain_new $object $type
		fi
		if [ -n "$MAIL_SYSTEM" ]; then
			is_mail_domain_new $object $type
		fi
	done
}

# Get domain variables
get_domain_values() {
	parse_object_kv_list $(grep "DOMAIN='$domain'" $USER_DATA/$1.conf)
}

#----------------------------------------------------------#
# 2 Char domain name detection                             #
#----------------------------------------------------------#

is_valid_extension() {
	local psl
	psl="https://publicsuffix.org/list/public_suffix_list.dat"
	if [ ! -e "$HESTIA/data/extensions/public_suffix_list.dat" ]; then
		mkdir -p "$HESTIA/data/extensions/"
		chmod 750 "$HESTIA/data/extensions/"
		if /usr/bin/wget --tries=3 --timeout=15 --read-timeout=15 --waitretry=3 --no-dns-cache --quiet -O "$HESTIA/data/extensions/public_suffix_list.dat.tmp" "$psl"; then
			mv "$HESTIA/data/extensions/public_suffix_list.dat.tmp" "$HESTIA/data/extensions/public_suffix_list.dat"
		else
			rm -f "$HESTIA/data/extensions/public_suffix_list.dat.tmp"
		fi
	elif find "$HESTIA/data/extensions/public_suffix_list.dat" -mtime +7 2> /dev/null | grep -q .; then
		mv "$HESTIA/data/extensions/public_suffix_list.dat" "$HESTIA/data/extensions/public_suffix_list.dat.save"
		if /usr/bin/wget --tries=3 --timeout=15 --read-timeout=15 --waitretry=3 --no-dns-cache --quiet -O "$HESTIA/data/extensions/public_suffix_list.dat.tmp" "$psl"; then
			mv "$HESTIA/data/extensions/public_suffix_list.dat.tmp" "$HESTIA/data/extensions/public_suffix_list.dat"
			rm -f "$HESTIA/data/extensions/public_suffix_list.dat.save"
		else
			rm -f "$HESTIA/data/extensions/public_suffix_list.dat.tmp"
			mv "$HESTIA/data/extensions/public_suffix_list.dat.save" "$HESTIA/data/extensions/public_suffix_list.dat"
		fi
	fi
	if [ ! -e "$HESTIA/data/extensions/public_suffix_list.dat" ]; then
		check_result "$E_NOTEXIST" "public_suffix_list.dat not found"
	fi
	test_domain=$(idn2 -d "$1")
	extension="${test_domain##*.}"
	exten=$(grep -Fx "$extension" "$HESTIA/data/extensions/public_suffix_list.dat")
}

is_valid_2_part_extension() {
	local psl
	psl="https://publicsuffix.org/list/public_suffix_list.dat"
	if [ ! -e "$HESTIA/data/extensions/public_suffix_list.dat" ]; then
		mkdir -p "$HESTIA/data/extensions/"
		chmod 750 "$HESTIA/data/extensions/"
		if /usr/bin/wget --tries=3 --timeout=15 --read-timeout=15 --waitretry=3 --no-dns-cache --quiet -O "$HESTIA/data/extensions/public_suffix_list.dat.tmp" "$psl"; then
			mv "$HESTIA/data/extensions/public_suffix_list.dat.tmp" "$HESTIA/data/extensions/public_suffix_list.dat"
		else
			rm -f "$HESTIA/data/extensions/public_suffix_list.dat.tmp"
		fi
	elif find "$HESTIA/data/extensions/public_suffix_list.dat" -mtime +7 2> /dev/null | grep -q .; then
		mv "$HESTIA/data/extensions/public_suffix_list.dat" "$HESTIA/data/extensions/public_suffix_list.dat.save"
		if /usr/bin/wget --tries=3 --timeout=15 --read-timeout=15 --waitretry=3 --no-dns-cache --quiet -O "$HESTIA/data/extensions/public_suffix_list.dat.tmp" "$psl"; then
			mv "$HESTIA/data/extensions/public_suffix_list.dat.tmp" "$HESTIA/data/extensions/public_suffix_list.dat"
			rm -f "$HESTIA/data/extensions/public_suffix_list.dat.save"
		else
			rm -f "$HESTIA/data/extensions/public_suffix_list.dat.tmp"
			mv "$HESTIA/data/extensions/public_suffix_list.dat.save" "$HESTIA/data/extensions/public_suffix_list.dat"
		fi
	fi
	if [ ! -e "$HESTIA/data/extensions/public_suffix_list.dat" ]; then
		check_result "$E_NOTEXIST" "public_suffix_list.dat not found"
	fi
	test_domain=$(idn2 -d "$1")
	extension=$(/bin/echo "${test_domain}" | awk -F. '{print $(NF-1)"."$NF}')
	exten=$(grep -Fx "$extension" "$HESTIA/data/extensions/public_suffix_list.dat")
}

get_base_domain() {
	test_domain=$1
	is_valid_extension "$test_domain"
	if [ $? -ne 0 ]; then
		basedomain=$(/bin/echo "${test_domain}" | /usr/bin/rev | /usr/bin/cut -d "." --output-delimiter="." -f 1-2 | /usr/bin/rev)
	else
		is_valid_2_part_extension "$test_domain"
		if [ $? -ne 0 ]; then
			basedomain=$(/bin/echo "${test_domain}" | /usr/bin/rev | /usr/bin/cut -d "." --output-delimiter="." -f 1-2 | /usr/bin/rev)
		else
			extension=$(/bin/echo "${test_domain}" | /usr/bin/rev | /usr/bin/cut -d "." --output-delimiter="." -f 1-2 | /usr/bin/rev)
			partdomain=$(/bin/echo "${test_domain}" | /usr/bin/rev | /usr/bin/cut -d "." --output-delimiter="." -f 3 | /usr/bin/rev)
			basedomain="$partdomain.$extension"
		fi
	fi
}

is_base_domain_owner() {
	for object in ${1//,/ }; do
		if [ "$object" != "none" ]; then
			get_base_domain $object
			web=$(grep -F -H -h "DOMAIN='$basedomain'" $HESTIA/data/users/*/web.conf)
			if [ "$ENFORCE_SUBDOMAIN_OWNERSHIP" = "yes" ]; then
				if [ -n "$web" ]; then
					parse_object_kv_list "$web"
					if [ -z "$ALLOW_USERS" ] || [ "$ALLOW_USERS" != "yes" ]; then
						# Don't care if $basedomain all ready exists only if the owner is of the base domain is the current user
						check=$(is_domain_new "" $basedomain)
						if [ $? -ne 0 ]; then
							echo "Error: Unable to add $object. $basedomain belongs to a different user"
							exit 4
						fi
					fi
				else
					check=$(is_domain_new "" "$basedomain")
					if [ $? -ne 0 ]; then
						echo "Error: Unable to add $object. $basedomain belongs to a different user"
						exit 4
					fi
				fi
			fi
		fi
	done
}

#----------------------------------------------------------#
#           Process "http2" directive for NGINX            #
#----------------------------------------------------------#

# Escape a literal string for use as a sed (basic) regex - e.g. an IPv6
# listen line's "[2001:db8::1]" would otherwise be read as a bracket
# expression and never match
sed_escape_regex() {
	printf '%s' "$1" | sed 's/[][\\/.*^$]/\\&/g'
}

process_http2_directive() {
	if [ -e /etc/nginx/conf.d/http2-directive.conf ]; then
		while IFS= read -r old_param; do
			new_param="$(echo "$old_param" | sed 's/\shttp2//')"
			sed -i "s/$(sed_escape_regex "$old_param")/$new_param/" "$1"
		done < <(grep -E "listen.*(\bssl\b(\s|.+){1,}\bhttp2\b|\bhttp2\b(\s|.+){1,}\bssl\b).*;" "$1")
	else
		if version_ge "$(nginx -v 2>&1 | cut -d'/' -f2)" "1.25.1"; then
			echo "http2 on;" > /etc/nginx/conf.d/http2-directive.conf

			while IFS= read -r old_param; do
				new_param="$(echo "$old_param" | sed 's/\shttp2//')"
				sed -i "s/$(sed_escape_regex "$old_param")/$new_param/" "$1"
			done < <(grep -E "listen.*(\bssl\b(\s|.+){1,}\bhttp2\b|\bhttp2\b(\s|.+){1,}\bssl\b).*;" "$1")
		else
			listen_ssl="$(grep -E "listen.*\s\bssl\b(?:\s)*.*;" "$1")"
			listen_http2="$(grep -E "listen.*(\bssl\b(\s|.+){1,}\bhttp2\b|\bhttp2\b(\s|.+){1,}\bssl\b).*;" "$1")"

			if [ -n "$listen_ssl" ] && [ -z "$listen_http2" ]; then
				while IFS= read -r old_param; do
					new_param="$(echo "$old_param" | sed 's/\sssl/ ssl http2/')"
					sed -i "s/$(sed_escape_regex "$old_param")/$new_param/" "$1"
				done < <(grep -E "listen.*\s\bssl\b(?:\s)*.*;" "$1")
			fi
		fi
	fi
}
