<?php
/**
 * Plugin Name: UO Local Share (dev only)
 * Description: When a request arrives through a Cloudflare tunnel (devstack share), WordPress answers under the public hostname: home/siteurl follow the request so pages, assets and REST callbacks work remotely. Inert for normal .test requests.
 * Author: DevStack
 */

$uo_share_host = isset( $_SERVER['HTTP_HOST'] ) ? (string) $_SERVER['HTTP_HOST'] : '';
$uo_via_tunnel = isset( $_SERVER['HTTP_CF_RAY'] ) || isset( $_SERVER['HTTP_CF_CONNECTING_IP'] );

if ( '' !== $uo_share_host && $uo_via_tunnel && '.test' !== substr( $uo_share_host, -5 ) && ! defined( 'WP_CLI' ) ) {
	$_SERVER['HTTPS'] = 'on';   // the tunnel terminates TLS; is_ssl() must agree or WordPress redirects in a loop
	$uo_public_url    = 'https://' . preg_replace( '/[^a-zA-Z0-9.\-:]/', '', $uo_share_host );
	$uo_public_filter = static function () use ( $uo_public_url ) {
		return $uo_public_url;
	};
	add_filter( 'option_home', $uo_public_filter, 1 );
	add_filter( 'option_siteurl', $uo_public_filter, 1 );
	add_filter( 'pre_option_home', $uo_public_filter, 1 );
	add_filter( 'pre_option_siteurl', $uo_public_filter, 1 );
	add_filter( 'redirect_canonical', '__return_false' );
}
