<?php
/**
 * local-devstack dashboard (interim, replaced by the menu-bar app later).
 * Served by Valet as https://dashboard.test from the repo's dashboard/ folder.
 */

$valet_home = ( getenv( 'HOME' ) ?: '/Users/' . get_current_user() ) . '/.config/valet';
$config     = json_decode( (string) @file_get_contents( $valet_home . '/config.json' ), true ) ?: array();
$tld        = isset( $config['tld'] ) ? $config['tld'] : 'test';
$sites      = array();

foreach ( glob( $valet_home . '/Sites/*' ) ?: array() as $link ) {
	$name   = basename( $link );
	$target = (string) readlink( $link );
	$nginx  = $valet_home . '/Nginx/' . $name . '.' . $tld;
	$php    = 'default';
	if ( is_file( $nginx ) && preg_match( '/valet(\d)(\d+)\.sock/', (string) file_get_contents( $nginx ), $m ) ) {
		$php = $m[1] . '.' . $m[2];
	}
	$sites[] = array(
		'name'    => $name,
		'target'  => $target,
		'secured' => is_file( $valet_home . '/Certificates/' . $name . '.' . $tld . '.crt' ),
		'php'     => $php,
	);
}
usort( $sites, static function ( $a, $b ) { return strcmp( $a['name'], $b['name'] ); } );

header( 'Content-Type: text/html; charset=utf-8' );
?>
<!doctype html>
<meta charset="utf-8">
<title>local-devstack</title>
<style>
	body { font: 14px/1.5 -apple-system, system-ui, sans-serif; margin: 2rem auto; max-width: 900px; color: #222; padding: 0 1rem; }
	table { border-collapse: collapse; width: 100%; }
	th, td { text-align: left; padding: .4rem .6rem; border-bottom: 1px solid #ddd; }
	.ok { color: #1a7f37; } .warn { color: #9a6700; }
</style>
<h1>local-devstack</h1>
<p>
	<a href="http://localhost:8025">Mail (Mailpit / MailHog on :8025)</a> ·
	<?php echo count( $sites ); ?> linked site(s) ·
	valet home <code><?php echo htmlspecialchars( $valet_home ); ?></code>
</p>
<table>
	<tr><th>Site</th><th>PHP</th><th>HTTPS</th><th>Folder</th></tr>
	<?php foreach ( $sites as $site ) : ?>
	<tr>
		<td><a href="https://<?php echo htmlspecialchars( $site['name'] . '.' . $tld ); ?>"><?php echo htmlspecialchars( $site['name'] . '.' . $tld ); ?></a></td>
		<td><?php echo htmlspecialchars( $site['php'] ); ?></td>
		<td class="<?php echo $site['secured'] ? 'ok' : 'warn'; ?>"><?php echo $site['secured'] ? 'secured' : 'http only'; ?></td>
		<td><code><?php echo htmlspecialchars( $site['target'] ); ?></code></td>
	</tr>
	<?php endforeach; ?>
</table>
