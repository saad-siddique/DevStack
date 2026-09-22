<?php
/**
 * Plugin Name: UO Local SSL (dev only)
 * Description: Lets WordPress trust the local Valet certificate authority for same-site HTTPS requests. Installed by local-devstack; only active on .test hosts and WP-CLI.
 * Author: local-devstack
 */

$uo_local_host = isset( $_SERVER['HTTP_HOST'] ) ? (string) $_SERVER['HTTP_HOST'] : '';

if ( '' === $uo_local_host || '.test' === substr( $uo_local_host, -5 ) || defined( 'WP_CLI' ) ) {
	add_filter( 'https_ssl_verify', '__return_false' );
	add_filter( 'https_local_ssl_verify', '__return_false' );
}
