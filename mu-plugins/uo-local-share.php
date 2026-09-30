<?php
/**
 * Plugin Name: UO Local Share (dev only)
 * Description: While a connected cloudflared tunnel serves this .test site, WordPress answers under the tunnel's public hostname in every context (browser, tunnel, WP-Cron, WP-CLI), so everything built from home_url() carries one hostname. Inert when no tunnel serves the site.
 * Author: DevStack
 */

/**
 * Public hostnames that running cloudflared connectors serve, keyed by .test host: array( 'site.test' => 'public.host' ).
 *
 * The truth comes from each connector's own metrics server (127.0.0.1:20241-20245, cloudflared's default range):
 * /ready says it is connected, /config lists the ingress it is serving right now, /quicktunnel names a quick tunnel.
 * A rule that only sits in config.yml therefore pins nothing while its tunnel is down, whoever runs cloudflared
 * (devstack share, or `cloudflared tunnel run` by hand). Cached for 15 s in devstack's data dir so one probe serves
 * every site; bin/site-share deletes the cache when it starts or stops a tunnel.
 *
 * @param string $home_dir Home directory of the user PHP runs as.
 * @return array
 */
function uo_local_share_pins( $home_dir ) {
	$cache = $home_dir . '/.local/share/devstack/share-live.json';
	$hit   = json_decode( (string) @file_get_contents( $cache ), true );
	if ( is_array( $hit ) && isset( $hit['at'], $hit['pins'] ) && 15 > time() - (int) $hit['at'] ) {
		return (array) $hit['pins'];
	}

	$pins = array();
	$ctx  = stream_context_create( array( 'http' => array( 'timeout' => 0.5, 'ignore_errors' => true ) ) );
	for ( $port = 20241; $port <= 20245; $port++ ) {
		$ready = json_decode( (string) @file_get_contents( 'http://127.0.0.1:' . $port . '/ready', false, $ctx ), true );
		if ( ! is_array( $ready ) || empty( $ready['readyConnections'] ) ) {
			continue;   // nothing listening (refused at once), or a connector that is not connected
		}
		$config = json_decode( (string) @file_get_contents( 'http://127.0.0.1:' . $port . '/config', false, $ctx ), true );
		$quick  = json_decode( (string) @file_get_contents( 'http://127.0.0.1:' . $port . '/quicktunnel', false, $ctx ), true );
		$quick  = is_array( $quick ) && ! empty( $quick['hostname'] ) ? (string) $quick['hostname'] : '';
		$rules  = isset( $config['config']['ingress'] ) && is_array( $config['config']['ingress'] ) ? $config['config']['ingress'] : array();
		foreach ( $rules as $rule ) {
			// A quick tunnel's rule has no hostname of its own; its public name is the quick tunnel's.
			$public = ! empty( $rule['hostname'] ) ? (string) $rule['hostname'] : $quick;
			$site   = (string) wp_parse_url( isset( $rule['service'] ) ? (string) $rule['service'] : '', PHP_URL_HOST );
			if ( '.test' !== substr( $site, -5 ) && ! empty( $rule['originRequest']['httpHostHeader'] ) ) {
				$site = (string) $rule['originRequest']['httpHostHeader'];   // service: http://localhost + httpHostHeader
			}
			if ( '' !== $public && false === strpos( $public, '*' ) && '.test' === substr( $site, -5 ) && ! isset( $pins[ $site ] ) ) {
				$pins[ $site ] = $public;
			}
		}
	}

	$tmp = $cache . '.' . getmypid();
	if ( @file_put_contents( $tmp, json_encode( array( 'at' => time(), 'pins' => (object) $pins ) ) ) ) {
		@rename( $tmp, $cache );
	}
	return $pins;
}

// Resolve from the site's own home (the raw DB value: get_option() would already return a WP_HOME constant).
// DEVSTACK_NO_PIN=1 keeps devstack's own WP-CLI checks (the smoke test) on the site's .test identity.
$uo_all         = wp_load_alloptions();
$uo_site_host   = (string) wp_parse_url( (string) ( isset( $uo_all['home'] ) ? $uo_all['home'] : get_option( 'home' ) ), PHP_URL_HOST );
$uo_public_host = '';

if ( '.test' === substr( $uo_site_host, -5 ) && ! getenv( 'DEVSTACK_NO_PIN' ) ) {
	$uo_home_dir = function_exists( 'posix_getpwuid' ) ? ( posix_getpwuid( posix_geteuid() )['dir'] ?? '' ) : (string) getenv( 'HOME' );
	if ( '' !== $uo_home_dir ) {
		$uo_pins        = uo_local_share_pins( $uo_home_dir );
		$uo_public_host = isset( $uo_pins[ $uo_site_host ] ) ? (string) $uo_pins[ $uo_site_host ] : '';
	}

	// A connector whose metrics devstack cannot see (a custom --metrics address): only a request that arrives through
	// Cloudflare says what its public hostname is (the Host header itself, or a proxy's X-Forwarded-Host).
	if ( '' === $uo_public_host && ! defined( 'WP_CLI' ) && ( isset( $_SERVER['HTTP_CF_RAY'] ) || isset( $_SERVER['HTTP_CF_CONNECTING_IP'] ) ) ) {
		$uo_host = isset( $_SERVER['HTTP_HOST'] ) ? (string) $_SERVER['HTTP_HOST'] : '';
		if ( '' !== $uo_host && '.test' !== substr( $uo_host, -5 ) ) {
			$uo_public_host = $uo_host;
		} elseif ( ! empty( $_SERVER['HTTP_X_FORWARDED_HOST'] ) ) {
			$uo_public_host = (string) $_SERVER['HTTP_X_FORWARDED_HOST'];
		}
	}
}

if ( '' !== $uo_public_host ) {
	$uo_public_host = preg_replace( '/[^a-zA-Z0-9.\-:]/', '', $uo_public_host );
	// The Host the request arrived with (devstack's tunnels send <site>.test): uo-local-autologin checks this one.
	$_SERVER['UO_LOCAL_HOST'] = isset( $_SERVER['HTTP_HOST'] ) ? (string) $_SERVER['HTTP_HOST'] : '';
	// Forceful override, as the old per-developer wp-config block did: plugins that read $_SERVER directly
	// (instead of home_url()) also see the public host. Multisite has already picked its blog by now.
	$_SERVER['HTTP_HOST']   = $uo_public_host;
	$_SERVER['SERVER_NAME'] = $uo_public_host;
	$_SERVER['SERVER_PORT'] = '443';
	$_SERVER['HTTPS']       = 'on';   // the tunnel terminates TLS; is_ssl() must agree or WordPress redirects in a loop
	$uo_public_url          = 'https://' . $uo_public_host;
	$uo_public_filter = static function () use ( $uo_public_url ) {
		return $uo_public_url;
	};
	// Priority 99: WP_HOME / WP_SITEURL constants are applied by core on these same filters at priority 10.
	add_filter( 'option_home', $uo_public_filter, 99 );
	add_filter( 'option_siteurl', $uo_public_filter, 99 );
	add_filter( 'pre_option_home', $uo_public_filter, 99 );
	add_filter( 'pre_option_siteurl', $uo_public_filter, 99 );
	add_filter( 'redirect_canonical', '__return_false' );
}
