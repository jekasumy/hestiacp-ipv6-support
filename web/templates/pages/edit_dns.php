<!-- Begin toolbar -->
<div class="toolbar">
	<div class="toolbar-inner">
		<div class="toolbar-buttons">
			<a class="button button-secondary button-back js-button-back" href="/list/dns/">
				<i class="fas fa-arrow-left icon-blue"></i><?= tohtml( _("Back")) ?>
			</a>
		</div>
		<div class="toolbar-buttons">
			<button type="submit" class="button" form="main-form">
				<i class="fas fa-floppy-disk icon-purple"></i><?= tohtml( _("Save")) ?>
			</button>
		</div>
	</div>
</div>
<!-- End toolbar -->

<div class="container">

	<form id="main-form" name="v_edit_dns" method="post" class="<?= tohtml($v_status) ?>">
		<input type="hidden" name="token" value="<?= tohtml($_SESSION["token"]) ?>">
		<input type="hidden" name="save" value="save">

		<div class="form-container">
			<h1 class="u-mb20"><?= tohtml( _("Edit DNS Domain")) ?></h1>
			<?php show_alert_message($_SESSION); ?>
			<div class="u-mb10">
				<label for="v_domain" class="form-label"><?= tohtml( _("Domain")) ?></label>
				<input type="text" class="form-control" name="v_domain" id="v_domain" value="<?= tohtml(trim($v_domain, "'")) ?>" disabled required>
				<input type="hidden" name="v_domain" value="<?= tohtml(trim($v_domain, "'")) ?>">
			</div>
			<?php
			$ip_select = ip_select_options($v_ips, true);
			$ip_select += [
				"v4_selected" => trim($v_ip, "'"),
				"ip6_stored" => $v_ipv6,
				"wildcard" => "",
				"custom_v4" => true,
			];
			require $_SERVER["HESTIA"] . "/web/templates/includes/ip-select.php";
			?>
			<?php if ($_SESSION["userContext"] === "admin" || ($_SESSION["userContext"] === "user" && $_SESSION["POLICY_USER_EDIT_DNS_TEMPLATES"] === "yes")) { ?>
				<div class="u-mb10">
					<label for="v_template" class="form-label">
						<?= tohtml( _("Template")) ?> <span class="optional"><?= tohtml(strtoupper($_SESSION["DNS_SYSTEM"])) ?></span>
					</label>
					<select class="form-select" name="v_template" id="v_template">
						<?php
							foreach ($templates as $key => $value) {
								echo "\t\t\t\t<option value=\"".htmlentities($value)."\"";
								$svalue = "'".$value."'";
								if ((!empty($v_template)) && ( $value == $v_template ) || ($svalue == $v_template)){
									echo ' selected' ;
								}
								echo ">".htmlentities($value)."</option>\n";
							}
						?>
					</select>
				</div>
			<?php } ?>
			<?php if ($_SESSION["DNS_CLUSTER_SYSTEM"] == "hestia-zone" && $_SESSION["SUPPORT_DNSSEC"] == "yes") { ?>
				<div class="form-check u-mb10">
					<input class="form-check-input" type="checkbox" name="v_dnssec" id="v_dnssec" value="yes" <?php if ($v_dnssec === 'yes'){ echo ' checked'; } ?>>
					<label for="v_dnssec">
						<?= tohtml( _("Enable DNSSEC")) ?>
					</label>
				</div>
			<?php } ?>
			<div class="u-mb10">
				<label for="v_exp" class="form-label">
					<?= tohtml( _("Expiration Date")) ?><span class="optional">(<?= tohtml( _("YYYY-MM-DD")) ?>)</span>
				</label>
				<input type="text" class="form-control" name="v_exp" id="v_exp" value="<?= tohtml(trim($v_exp, "'")) ?>">
			</div>
			<div class="u-mb10">
				<label for="v_soa" class="form-label"><?= tohtml( _("SOA")) ?></label>
				<input type="text" class="form-control" name="v_soa" id="v_soa" value="<?= tohtml(trim($v_soa, "'")) ?>">
			</div>
			<div class="u-mb10">
				<label for="v_ttl" class="form-label"><?= tohtml( _("TTL")) ?></label>
				<input type="text" class="form-control" name="v_ttl" id="v_ttl" value="<?= tohtml(trim($v_ttl, "'")) ?>">
			</div>
		</div>

	</form>

</div>
