<?php
/**
 * Plugin Name: UO Local Auto-login (dev only)
 * Description: One-time login links for local .test sites, minted by `devstack login <site>`. The token lives 60 seconds, is stored hashed, works once, and this file does nothing on any other host.
 * Author: local-devstack
 */

add_action(
	'init',
	function () {
		if ( empty( $_GET['uo_login'] ) || defined( 'WP_CLI' ) ) {
			return;
		}
		$host = isset( $_SERVER['HTTP_HOST'] ) ? (string) $_SERVER['HTTP_HOST'] : '';
		if ( '.test' !== substr( $host, -5 ) ) {
			return;
		}
		$token  = preg_replace( '/[^a-f0-9]/', '', (string) $_GET['uo_login'] );
		$stored = json_decode( (string) get_transient( 'uo_local_autologin' ), true );
		delete_transient( 'uo_local_autologin' );
		if ( ! is_array( $stored ) || empty( $stored['hash'] ) || empty( $stored['user'] ) || ! hash_equals( (string) $stored['hash'], hash( 'sha256', $token ) ) ) {
			wp_die( 'This login link has expired. Run `devstack login <site>` again.', 'Login link expired', array( 'response' => 403 ) );
		}
		$user = get_user_by( 'id', (int) $stored['user'] );
		if ( ! $user ) {
			wp_die( 'The user for this login link no longer exists.', 'Login failed', array( 'response' => 403 ) );
		}
		wp_set_current_user( $user->ID );
		wp_set_auth_cookie( $user->ID, true );
		do_action( 'wp_login', $user->user_login, $user );
		wp_safe_redirect( admin_url() );
		exit;
	},
	1
);
