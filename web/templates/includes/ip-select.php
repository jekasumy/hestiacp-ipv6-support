<?php
/*
 * Combined "IP Address" field for the Add/Edit Web Domain and DNS Zone
 * pages: one dropdown listing both the IPv4 addresses (pick one) and
 * the IPv6 addresses (tick any) the domain should use.
 *
 * Expects $ip_select = [
 *   "v4"          => [["value" => ..., "label" => ..., "ip6" => paired IPv6 or ""], ...],
 *   "v6"          => [["addr" => ..., "label" => ..., "note" => ...], ...],
 *   "v4_selected" => currently selected IPv4 value,
 *   "ip6_stored"  => stored IPV6 value ("" = default, "no", or a comma-separated list),
 *   "wildcard"    => IPv6 address used by default when the selected IPv4 has none paired
 *                    ("::" for web domains, "" for DNS zones) - not listed itself, the
 *                    dropdown only lists real paired addresses to tick one by one,
 *   "custom_v4"   => whether an arbitrary IPv4 can be typed in (DNS zones),
 * ]
 *
 * Submits v_ip (the IPv4) and v_ipv6 (in the same format IPV6 is stored
 * in: the stored value as-is when nothing was changed, otherwise "" when
 * the ticked addresses are exactly the default for the selected IPv4,
 * "no" when none are ticked, and the list otherwise).
 */

$ip_select_auto = function ($v4) use ($ip_select) {
	foreach ($ip_select["v4"] as $item) {
		if ($item["value"] === $v4 && $item["ip6"] !== "") {
			return [$item["ip6"]];
		}
	}
	return $ip_select["wildcard"] === "" ? [] : [$ip_select["wildcard"]];
};

$ip_select_v4 = (string) $ip_select["v4_selected"];
if ($ip_select_v4 === "" && !empty($ip_select["v4"])) {
	$ip_select_v4 = $ip_select["v4"][0]["value"];
}
$ip_select_known = in_array($ip_select_v4, array_column($ip_select["v4"], "value"), true);

$ip_select_stored = (string) $ip_select["ip6_stored"];
if ($ip_select_stored === "" || $ip_select_stored === "yes") {
	$ip_select_v6 = $ip_select_auto($ip_select_v4);
} elseif ($ip_select_stored === "no") {
	$ip_select_v6 = [];
} else {
	$ip_select_v6 = explode(",", $ip_select_stored);
}

// Make sure every ticked address is listed, even one that's no longer
// paired with any IP (except the default wildcard, which isn't listed)
$ip_select_v6_list = $ip_select["v6"];
foreach ($ip_select_v6 as $addr) {
	if ($addr !== $ip_select["wildcard"] && !in_array($addr, array_column($ip_select_v6_list, "addr"), true)) {
		$ip_select_v6_list[] = ["addr" => $addr, "label" => $addr, "note" => ""];
	}
}

$ip_select_state = [
	"v4list" => $ip_select["v4"],
	"v6list" => $ip_select_v6_list,
	"wildcard" => $ip_select["wildcard"],
	"v4" => $ip_select_v4,
	"custom" => $ip_select_known ? "" : $ip_select_v4,
	"useCustom" => !$ip_select_known && $ip_select_v4 !== "",
	"v6" => $ip_select_v6,
	"stored" => $ip_select_stored === "yes" ? "" : $ip_select_stored,
	"initialV4" => $ip_select_v4,
	"initialV6" => $ip_select_v6,
];
?>
<div
	class="u-mb20"
	x-data="{
		open: false,
		...<?= tohtml(json_encode($ip_select_state)) ?>,
		auto(v4) {
			const item = this.v4list.find((i) => i.value === v4);
			if (item && item.ip6) return [item.ip6];
			return this.wildcard ? [this.wildcard] : [];
		},
		same(a, b) {
			return a.length === b.length && a.every((x) => b.includes(x));
		},
		current() {
			return this.useCustom ? this.custom.trim() : this.v4;
		},
		pickV4(value, custom) {
			const wasAuto = this.same(this.v6, this.auto(this.current()));
			this.useCustom = custom;
			if (!custom) this.v4 = value;
			if (wasAuto) this.v6 = this.auto(this.current());
		},
		toggleV6(addr, on) {
			// the unlisted default wildcard gives way to explicitly ticked addresses
			const v6 = this.v6.filter((a) => a !== addr && a !== this.wildcard);
			this.v6 = on ? [...v6, addr] : v6;
		},
		get ipv6Value() {
			// untouched: keep what's stored, so an explicitly picked list
			// that happens to equal the default stays explicit
			if (this.current() === this.initialV4 && this.same(this.v6, this.initialV6)) return this.stored;
			if (this.same(this.v6, this.auto(this.current()))) return '';
			if (!this.v6.length) return 'no';
			return this.v6.join(',');
		},
		get summary() {
			const item = this.v4list.find((i) => i.value === this.current());
			const parts = [item ? item.label : this.current()];
			this.v6list.forEach((i) => { if (this.v6.includes(i.addr)) parts.push(i.label); });
			return parts.filter(Boolean).join(', ');
		},
	}"
	x-on:click.outside="open = false"
	x-on:keydown.escape="open = false"
>
	<label for="v_ip_button" class="form-label"><?= tohtml(_("IP Address")) ?></label>
	<div class="u-pos-relative">
		<button
			type="button"
			id="v_ip_button"
			class="form-select"
			style="text-align: left; white-space: nowrap; overflow: hidden; text-overflow: ellipsis;"
			aria-haspopup="true"
			x-bind:aria-expanded="open"
			x-on:click="open = !open"
			x-text="summary"
		><?= tohtml($ip_select_v4) ?></button>
		<div
			class="form-control"
			style="position: absolute; z-index: 10; left: 0; right: 0; margin-top: 4px; max-height: 360px; overflow-y: auto; box-shadow: 0 4px 16px rgb(0 0 0 / 30%);"
			x-cloak
			x-show="open"
		>
			<p class="form-label u-mb5"><?= tohtml(_("IPv4")) ?></p>
			<template x-for="item in v4list" x-bind:key="item.value">
				<div class="form-check u-mb5">
					<input
						class="form-check-input"
						type="radio"
						name="v_ip_select"
						x-bind:id="'v_ip_' + item.value"
						x-bind:checked="!useCustom && v4 === item.value"
						x-on:change="pickV4(item.value, false)"
					>
					<label x-bind:for="'v_ip_' + item.value" x-text="item.label"></label>
				</div>
			</template>
			<?php if (!empty($ip_select["custom_v4"])) { ?>
				<div class="form-check u-mb5">
					<input class="form-check-input" type="radio" name="v_ip_select" id="v_ip_custom" x-bind:checked="useCustom" x-on:change="pickV4('', true)">
					<label for="v_ip_custom"><?= tohtml(_("Other IP")) ?></label>
				</div>
				<div class="u-mb5" x-show="useCustom">
					<input type="text" class="form-control" x-model="custom" aria-label="<?= tohtml(_("Other IP")) ?>">
				</div>
			<?php } ?>
			<p class="form-label u-mt10 u-mb5"><?= tohtml(_("IPv6")) ?></p>
			<template x-for="item in v6list" x-bind:key="item.addr">
				<div class="form-check u-mb5">
					<input
						class="form-check-input"
						type="checkbox"
						x-bind:id="'v_ipv6_' + item.addr"
						x-bind:checked="v6.includes(item.addr)"
						x-on:change="toggleV6(item.addr, $event.target.checked)"
					>
					<label x-bind:for="'v_ipv6_' + item.addr">
						<span x-text="item.label"></span>
						<small class="hint" x-show="item.note" x-text="item.note"></small>
					</label>
				</div>
			</template>
			<template x-if="!v6list.length">
				<p class="hint"><?= tohtml(_("No IPv6 addresses are paired with your IPs yet - pair one on the Edit IP page.")) ?></p>
			</template>
		</div>
	</div>
	<input type="hidden" name="v_ip" value="<?= tohtml($ip_select_v4) ?>" x-bind:value="current()">
	<input type="hidden" name="v_ipv6" value="<?= tohtml($ip_select_state["stored"]) ?>" x-bind:value="ipv6Value">
</div>
