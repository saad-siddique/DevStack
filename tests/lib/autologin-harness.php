<?php
/**
 * Runs mu-plugins/uo-local-autologin.php against stand-ins for the few WordPress functions it calls, so its decisions
 * can be tested without a WordPress install. One scenario per process (the plugin ends with exit):
 *   php autologin-harness.php '<json>'   json: {"stored": <transient value or null>, "token": "...", "host": "alpha.test"}
 * It prints what the plugin did, one line each: DELETED (token spent), COOKIE (signed in), REDIRECT <url>, DIE <code>.
 * home_url() and admin_url() follow WordPress: the path is appended to the site's own URL after its leading slashes
 * are stripped, so the host can never come from the path.
 */
$scenario = json_decode( (string) ( $argv[1] ?? '{}' ), true );
$GLOBALS['uo_cb'] = null;

function add_action( $tag, $cb ) { $GLOBALS['uo_cb'] = $cb; }
function get_transient( $key ) { global $scenario; return null === $scenario['stored'] ? false : json_encode( $scenario['stored'] ); }
function delete_transient( $key ) { echo "DELETED\n"; }
function get_user_by( $field, $id ) { return (object) array( 'ID' => (int) $id, 'user_login' => 'admin' ); }
function wp_set_current_user( $id ) {}
function wp_set_auth_cookie( $id, $remember ) { echo "COOKIE\n"; }
function do_action( $tag, ...$args ) {}
function admin_url( $path = '' ) { return 'https://alpha.test/wp-admin/' . ltrim( $path, '/' ); }
function home_url( $path = '' ) { return 'https://alpha.test/' . ltrim( $path, '/' ); }
function wp_safe_redirect( $url ) { echo 'REDIRECT ' . $url . "\n"; }
function wp_die( $message, $title = '', $args = array() ) { echo 'DIE ' . ( $args['response'] ?? 200 ) . "\n"; exit; }

require dirname( __DIR__, 2 ) . '/mu-plugins/uo-local-autologin.php';
$_GET['uo_login']     = $scenario['token'];
$_SERVER['HTTP_HOST'] = $scenario['host'] ?? 'alpha.test';
( $GLOBALS['uo_cb'] )();
echo "NO-EXIT\n";
