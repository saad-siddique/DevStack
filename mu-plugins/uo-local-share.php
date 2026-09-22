<?php
/**
 * Plugin Name: UO Local Share (dev only)
 * Description: When a request arrives through a Cloudflare tunnel (devstack share), WordPress answers under the public hostname: home/siteurl follow it so pages, assets and REST callbacks work remotely. Inert for normal .test requests.
 * Author: DevStack
 */

$uo_via_tunnel = isset( $_SERVER['HTTP_CF_RAY'] ) || isset( $_SERVER['HTTP_CF_CONNECTING_IP'] );

if ( $uo_via_tunnel && ! defined( 'WP_CLI' ) ) {
	$uo_host = isset( $_SERVER['HTTP_HOST'] ) ? (string) $_SERVER['HTTP_HOST'] : '';
	$uo_public_host = '';

	if ( '.test' !== substr( $uo_host, -5 ) ) {
		// Quick tunnel: the public hostname arrives as the Host header itself.
		$uo_public_host = $uo_host;
	} elseif ( ! empty( $_SERVER['HTTP_X_FORWARDED_HOST'] ) ) {
		$uo_public_host = (string) $_SERVER['HTTP_X_FORWARDED_HOST'];
	} else {
		// Named tunnel rewrites Host to <site>.test; the public hostname is in devstack's share state.
		$uo_site = substr( $uo_host, 0, -5 );
		$uo_home = function_exists( 'posix_getpwuid' ) ? posix_getpwuid( posix_geteuid() )['dir'] : getenv( 'HOME' );
		$uo_state = $uo_home ? @json_decode( (string) @file_get_contents( $uo_home . '/.local/share/devstack/share.json' ), true ) : null;
		if ( is_array( $uo_state ) && ! empty( $uo_state['pairs'] ) ) {
			foreach ( $uo_state['pairs'] as $uo_pair ) {
				if ( isset( $uo_pair['site'], $uo_pair['url'] ) && $uo_site === $uo_pair['site'] ) {
					$uo_public_host = (string) wp_parse_url( $uo_pair['url'], PHP_URL_HOST );
					break;
				}
			}
		}
	}

	if ( '' !== $uo_public_host ) {
		$_SERVER['HTTPS'] = 'on';   // the tunnel terminates TLS; is_ssl() must agree or WordPress redirects in a loop
		$uo_public_url    = 'https://' . preg_replace( '/[^a-zA-Z0-9.\-:]/', '', $uo_public_host );
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
}
