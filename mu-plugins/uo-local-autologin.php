<?php
/**
 * Plugin Name: UO Local Auto-login (dev only)
 * Description: One-time login links for local .test sites, minted by `devstack login <site>`. The token lives 60 seconds, is stored hashed, works once, and this file does nothing on any other host. With `--to <path>` it lands on that page of the site instead of the dashboard.
 * Author: DevStack
 */

add_action(
	'init',
	function () {
		if ( empty( $_GET['uo_login'] ) || defined( 'WP_CLI' ) ) {
			return;
		}
		// While a tunnel pins the site, uo-local-share has rewritten HTTP_HOST to the public host; the Host the request
		// arrived with (devstack's tunnels send <site>.test) is kept in UO_LOCAL_HOST.
		$host = isset( $_SERVER['UO_LOCAL_HOST'] ) ? (string) $_SERVER['UO_LOCAL_HOST'] : ( isset( $_SERVER['HTTP_HOST'] ) ? (string) $_SERVER['HTTP_HOST'] : '' );
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
		// `devstack login --to <path>` stores a landing page with the token. The transient is only data, so take it only
		// when it is a plain same-site path (one leading slash, no backslash, no control characters), and let home_url()
		// put it on this site: the host can never come from the path.
		$target = admin_url();
		if ( ! empty( $stored['to'] ) && is_string( $stored['to'] ) && strlen( $stored['to'] ) <= 2000 && 1 === preg_match( '#^/(?![/\\\\])[^\\\\\x00-\x1f\x7f]*\z#', $stored['to'] ) ) {
			$target = home_url( $stored['to'] );
		}
		wp_safe_redirect( $target );
		exit;
	},
	1
);
