<?php
$TAB = "USER";

// Main include
include $_SERVER["DOCUMENT_ROOT"] . "/inc/main.php";

// Do not show the users list for regular users
if ($_SESSION["userContext"] === "user") {
	header("Location: /login/");
	exit();
}

// Do not show the users list if user is impersonating another user
if (!empty($_SESSION["look"])) {
	header("Location: /login/");
	exit();
}

// Data
if ($_SESSION["userContext"] === "admin") {
	exec(HESTIA_CMD . "v-list-users json", $output, $return_var);
} else {
	exec(HESTIA_CMD . "v-list-user " . $user . " json", $output, $return_var);
}
$data = json_decode(implode("", $output), true);
if ($_SESSION["userSortOrder"] == "name") {
	ksort($data);
} else {
	$data = array_reverse($data, true);
}

// IPv6 addresses paired with each user's IPs: counted in the "IPs"
// column next to the IPs themselves (IP_OWNED only counts the IPv4
// records, an IPv6 address is paired with one rather than an IP of its own)
$v_ip6_owned = [];
exec(HESTIA_CMD . "v-list-sys-ips json", $output, $return_var);
if ($return_var == 0) {
	foreach (json_decode(implode("", $output), true) ?: [] as $ip_data) {
		if (!empty($ip_data["IP6"]) && !empty($ip_data["OWNER"])) {
			$v_ip6_owned[$ip_data["OWNER"]] = ($v_ip6_owned[$ip_data["OWNER"]] ?? 0) + 1;
		}
	}
}
unset($output);

// Render page
render_page($user, $TAB, "list_user");

// Back uri
$_SESSION["back"] = $_SERVER["REQUEST_URI"];
