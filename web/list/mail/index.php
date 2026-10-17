<?php
use function Hestiacp\quoteshellarg\quoteshellarg;
$TAB = "MAIL";

// Main include
include $_SERVER["DOCUMENT_ROOT"] . "/inc/main.php";

// Data & Render page
if (empty($_GET["domain"])) {
	exec(HESTIA_CMD . "v-list-mail-domains $user json", $output, $return_var);
	$data = json_decode(implode("", $output), true);
	if ($_SESSION["userSortOrder"] == "name") {
		ksort($data);
	} else {
		$data = array_reverse($data, true);
	}
	unset($output);

	render_page($user, $TAB, "list_mail");
} elseif (!empty($_GET["dns"])) {
	exec(
		HESTIA_CMD . "v-list-mail-domain " . $user . " " . quoteshellarg($_GET["domain"]) . " json",
		$output,
		$return_var,
	);
	$data = json_decode(implode("", $output), true);
	$data = array_reverse($data, true);
	unset($output);
	exec(HESTIA_CMD . "v-list-user-ips " . $user . " json", $output, $return_var);
	$ips = json_decode(implode("", $output), true);
	$ips = array_reverse($ips, true);
	unset($output);
	exec(
		HESTIA_CMD .
			"v-list-mail-domain-dkim-dns " .
			$user .
			" " .
			quoteshellarg($_GET["domain"]) .
			" json",
		$output,
		$return_var,
	);
	$dkim = json_decode(implode("", $output), true);
	$dkim = array_reverse($dkim, true);
	unset($output);

	// The IPv6 addresses the domain's mail host is reachable on (AAAA
	// records, SPF ip6:): the ones its website picked, or by default
	// the one paired with its IP - the same ones mail is sent from.
	$v_mail_ip = array_key_first($ips);
	$v_mail_ipv6 = "";
	exec(
		HESTIA_CMD . "v-list-web-domain " . $user . " " . quoteshellarg($_GET["domain"]) . " json",
		$output,
		$return_var,
	);
	if ($return_var == 0) {
		$web = json_decode(implode("", $output), true);
		$web = $web[$_GET["domain"]] ?? [];
		if (!empty($web["IP"]) && isset($ips[$web["IP"]])) {
			$v_mail_ip = $web["IP"];
		}
		$v_mail_ipv6 = $web["IPV6"] ?? "";
	}
	unset($output);
	if ($v_mail_ipv6 === "no") {
		$v_mail_ip6s = [];
	} elseif ($v_mail_ipv6 !== "" && $v_mail_ipv6 !== "yes") {
		$v_mail_ip6s = explode(",", web_ipv6_to_dns($v_mail_ipv6));
	} else {
		$v_mail_ip6s = [$ips[$v_mail_ip]["IP6"] ?? ""];
	}
	$v_mail_ip6s = array_values(array_filter($v_mail_ip6s));

	render_page($user, $TAB, "list_mail_dns");
} else {
	exec(
		HESTIA_CMD .
			"v-list-mail-accounts " .
			$user .
			" " .
			quoteshellarg($_GET["domain"]) .
			" json",
		$output,
		$return_var,
	);
	$data = json_decode(implode("", $output), true);
	if ($_SESSION["userSortOrder"] == "name") {
		ksort($data);
	} else {
		$data = array_reverse($data, true);
	}
	unset($output);

	render_page($user, $TAB, "list_mail_acc");
}

// Back uri
$_SESSION["back"] = $_SERVER["REQUEST_URI"];
