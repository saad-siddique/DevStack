<?php
/**
 * local-devstack dashboard.
 *
 * GET  /               HTML shell (app.js fetches the JSON below every 5 s).
 * GET  /?api=status    bin/stack-status + Xdebug state + tool links.
 * POST /?api=service   name=<service> op=start|stop|restart   -> bin/service
 * POST /?api=xdebug    php=8.4|7.4  op=on|off                  -> bin/php-xdebug
 *
 * Writes need the request header X-Devstack: 1. A page on another origin cannot add that header without a
 * CORS preflight, which this endpoint never answers, so a stray tab cannot stop your services.
 */

declare( strict_types=1 );

$repo_bin = dirname( __DIR__ ) . '/bin';
$home     = getenv( 'HOME' ) ?: '/Users/' . get_current_user();
$api      = isset( $_GET['api'] ) ? (string) $_GET['api'] : '';

/**
 * Run one repo command with a sane environment and return [exit code, stdout, stderr].
 *
 * @param string[] $argv Command and arguments (escaped here).
 */
function devstack_run( array $argv, string $home ): array {
	$cmd  = implode( ' ', array_map( 'escapeshellarg', $argv ) );
	$env  = array(
		'HOME' => $home,
		'USER' => get_current_user(),
		'PATH' => '/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin:/bin:/usr/sbin:/sbin',
		'LANG' => 'en_US.UTF-8',
	);
	$spec = array( 1 => array( 'pipe', 'w' ), 2 => array( 'pipe', 'w' ) );
	$proc = proc_open( $cmd, $spec, $pipes, null, $env );
	if ( ! is_resource( $proc ) ) {
		return array( 1, '', 'could not start process' );
	}
	$out = (string) stream_get_contents( $pipes[1] );
	$err = (string) stream_get_contents( $pipes[2] );
	fclose( $pipes[1] );
	fclose( $pipes[2] );
	return array( proc_close( $proc ), $out, $err );
}

function devstack_json( int $status, array $payload ): void {
	http_response_code( $status );
	header( 'Content-Type: application/json; charset=utf-8' );
	header( 'Cache-Control: no-store' );
	echo json_encode( $payload, JSON_UNESCAPED_SLASHES );
	exit;
}

if ( '' !== $api ) {
	$is_write = 'POST' === ( $_SERVER['REQUEST_METHOD'] ?? 'GET' );

	if ( $is_write && '1' !== ( $_SERVER['HTTP_X_DEVSTACK'] ?? '' ) ) {
		devstack_json( 403, array( 'error' => 'Missing X-Devstack header.' ) );
	}

	if ( 'status' === $api && ! $is_write ) {
		list( $code, $out ) = devstack_run( array( $repo_bin . '/stack-status' ), $home );
		$status             = json_decode( $out, true );
		if ( 0 !== $code || ! is_array( $status ) ) {
			devstack_json( 500, array( 'error' => 'stack-status failed' ) );
		}
		list( , $xout )   = devstack_run( array( $repo_bin . '/php-xdebug', 'status', '--json' ), $home );
		$status['xdebug'] = json_decode( $xout, true ) ?: array();
		list( , $cout )    = devstack_run( array( $repo_bin . '/logs', 'crashes', '--hours', '24', '--json' ), $home );
		$status['crashes'] = json_decode( $cout, true ) ?: array( 'hours' => 24, 'count' => 0, 'reports' => array() );
		list( , $lout )    = devstack_run( array( $repo_bin . '/logs', 'list', '--json' ), $home );
		$status['logs']    = json_decode( $lout, true ) ?: array();
		$status['tools']  = array(
			'phpmyadmin' => 'https://phpmyadmin.test',
			'mailpit'    => 'http://localhost:8025',
		);
		$status['sites_dir'] = $home . '/Sites';
		devstack_json( 200, $status );
	}

	if ( 'log' === $api && ! $is_write ) {
		$source = (string) ( $_GET['source'] ?? '' );
		$site   = (string) ( $_GET['site'] ?? '' );
		$n      = (string) max( 20, min( 1000, (int) ( $_GET['n'] ?? 200 ) ) );
		$argv   = array( $repo_bin . '/logs' );
		if ( 'wp' === $source ) {
			if ( ! preg_match( '/^[a-z0-9][a-z0-9-]*$/', $site ) ) {
				devstack_json( 400, array( 'error' => 'Bad site name.' ) );
			}
			array_push( $argv, 'wp', $site );
		} elseif ( in_array( $source, array( 'nginx', 'php', 'php-fpm', 'mysql', 'redis', 'mailpit', 'prune' ), true ) ) {
			$argv[] = $source;
		} else {
			devstack_json( 400, array( 'error' => 'Unknown log source.' ) );
		}
		array_push( $argv, '-n', $n, '--json' );
		list( $code, $out ) = devstack_run( $argv, $home );
		devstack_json( 0 === $code ? 200 : 500, json_decode( $out, true ) ?: array( 'error' => 'logs failed' ) );
	}

	if ( 'log-clear' === $api && $is_write ) {
		$source = (string) ( $_POST['source'] ?? '' );
		$site   = (string) ( $_POST['site'] ?? '' );
		$argv   = array( $repo_bin . '/logs', 'clear' );
		if ( 'wp' === $source && preg_match( '/^[a-z0-9][a-z0-9-]*$/', $site ) ) {
			array_push( $argv, 'wp', $site );
		} elseif ( in_array( $source, array( 'nginx', 'php', 'php-fpm', 'mysql', 'redis', 'mailpit', 'prune' ), true ) ) {
			$argv[] = $source;
		} else {
			devstack_json( 400, array( 'error' => 'Unknown log source.' ) );
		}
		list( $code, , $err ) = devstack_run( $argv, $home );
		devstack_json( 0 === $code ? 200 : 500, array( 'cleared' => 0 === $code, 'error' => 0 === $code ? null : trim( $err ) ) );
	}

	if ( 'service' === $api && $is_write ) {
		$allowed_names = array( 'nginx', 'dnsmasq', 'mysql@8.4', 'mailpit', 'redis', 'memcached' );
		foreach ( glob( '/opt/homebrew/etc/php/*/conf.d', GLOB_ONLYDIR ) ?: array() as $conf_dir ) {
			$allowed_names[] = 'php@' . basename( dirname( $conf_dir ) );
		}
		$allowed_ops   = array( 'start', 'stop', 'restart' );
		$name          = (string) ( $_POST['name'] ?? '' );
		$op            = (string) ( $_POST['op'] ?? '' );
		if ( ! in_array( $name, $allowed_names, true ) || ! in_array( $op, $allowed_ops, true ) ) {
			devstack_json( 400, array( 'error' => 'Unknown service or operation.' ) );
		}
		list( $code, $out, $err ) = devstack_run( array( $repo_bin . '/service', $name, $op, '--json' ), $home );
		devstack_json( 0 === $code ? 200 : 500, json_decode( $out, true ) ?: array( 'error' => trim( $err ) ?: 'service failed' ) );
	}

	if ( 'xdebug' === $api && $is_write ) {
		$php = (string) ( $_POST['php'] ?? '' );
		$op  = (string) ( $_POST['op'] ?? '' );
		$php_versions = array_map( static function ( $d ) { return basename( dirname( $d ) ); }, glob( '/opt/homebrew/etc/php/*/conf.d', GLOB_ONLYDIR ) ?: array() );
		if ( ! in_array( $php, $php_versions, true ) || ! in_array( $op, array( 'on', 'off' ), true ) ) {
			devstack_json( 400, array( 'error' => 'Unknown PHP version or operation.' ) );
		}
		list( $code, $out, $err ) = devstack_run( array( $repo_bin . '/php-xdebug', $op, '--php', $php, '--json' ), $home );
		devstack_json( 0 === $code ? 200 : 500, json_decode( $out, true ) ?: array( 'error' => trim( $err ) ?: 'php-xdebug failed' ) );
	}

	devstack_json( 404, array( 'error' => 'Unknown api.' ) );
}

header( 'Content-Type: text/html; charset=utf-8' );
header( 'Cache-Control: no-store' );
?>
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>local-devstack</title>
<meta name="color-scheme" content="light dark">
<link rel="stylesheet" href="style.css?v=<?php echo (int) filemtime( __DIR__ . '/style.css' ); ?>">
</head>
<body>
<div class="shell">
	<aside class="rail" aria-label="Sections">
		<div class="brand">
			<span class="pulse" id="pulse" title="Live" aria-hidden="true"></span>
			<h1>local-devstack</h1>
		</div>
		<nav class="nav" role="tablist" aria-orientation="vertical">
			<button class="nav-item" role="tab" data-tab="overview" aria-selected="true" aria-controls="tab-overview">Overview<span class="dot" hidden></span></button>
			<button class="nav-item" role="tab" data-tab="php" aria-selected="false" aria-controls="tab-php">PHP<span class="dot" hidden></span></button>
			<button class="nav-item" role="tab" data-tab="services" aria-selected="false" aria-controls="tab-services">Services<span class="dot" hidden></span></button>
			<button class="nav-item" role="tab" data-tab="logs" aria-selected="false" aria-controls="tab-logs">Logs<span class="dot" hidden></span></button>
			<button class="nav-item" role="tab" data-tab="tools" aria-selected="false" aria-controls="tab-tools">Tools<span class="dot" hidden></span></button>
		</nav>
		<div class="rail-foot">
			<button class="act" type="button" id="refresh">Refresh</button>
			<span id="age" aria-live="polite"></span>
			<p>Reloads once a minute while this tab is visible. Actions run <code>bin/service</code> and <code>bin/php-xdebug</code>.</p>
		</div>
	</aside>

	<main class="content">
		<p class="alert" id="alert" hidden role="status"></p>

		<section class="tab" id="tab-overview" role="tabpanel" data-tab="overview">
			<header class="tab-head">
				<h2>Overview</h2>
				<p class="summary" id="summary" aria-live="polite">Reading the stack…</p>
			</header>
			<ul class="strip" id="strip" aria-label="Service status"></ul>
			<div class="panel-head">
				<h3>Sites <span class="count" id="sites-count"></span></h3>
				<label class="filter"><span class="visually-hidden">Filter sites</span><input type="search" id="filter" placeholder="Filter sites" autocomplete="off"></label>
			</div>
			<table class="sites" id="sites">
				<thead><tr><th scope="col">Site</th><th scope="col">PHP</th><th scope="col">HTTPS</th><th scope="col">Open</th><th scope="col">Folder</th></tr></thead>
				<tbody></tbody>
			</table>
			<p class="empty" id="sites-empty" hidden></p>
		</section>

		<section class="tab" id="tab-php" role="tabpanel" data-tab="php" hidden>
			<header class="tab-head">
				<h2>PHP</h2>
				<p class="hint">php-fpm only runs for versions a site uses. Put a site on a version with <code>bin/site-new name --php 8.2</code> or <code>valet isolate php@8.2 --site=name</code>.</p>
			</header>
			<ul class="switchboard php" id="php"></ul>
		</section>

		<section class="tab" id="tab-services" role="tabpanel" data-tab="services" hidden>
			<header class="tab-head">
				<h2>Services</h2>
				<p class="hint">Valet runs nginx, dnsmasq and php-fpm as root. MySQL, Mailpit, Redis and Memcached run as you.</p>
			</header>
			<ul class="switchboard" id="services"></ul>
			<p class="ports" id="ports"></p>
		</section>

		<section class="tab" id="tab-logs" role="tabpanel" data-tab="logs" hidden>
			<header class="tab-head">
				<h2>Logs</h2>
				<p class="hint">Rotated daily at 04:00. Today and yesterday are kept; nothing older than 48 hours.</p>
			</header>
			<div class="log-pick">
				<div class="log-tabs" id="log-tabs" role="tablist" aria-label="Stack logs"></div>
				<label class="log-site"><span class="visually-hidden">Site log</span><select id="log-site"><option value="">Site log…</option></select></label>
			</div>
			<div class="log-tools">
				<label class="filter"><span class="visually-hidden">Filter log lines</span><input type="search" id="log-filter" placeholder="Filter lines" autocomplete="off"></label>
				<span class="log-meta" id="log-meta"></span>
				<button class="act quiet" type="button" id="log-clear">Clear this log</button>
			</div>
			<pre class="log" id="log-body" tabindex="0" aria-live="off"></pre>
		</section>

		<section class="tab" id="tab-tools" role="tabpanel" data-tab="tools" hidden>
			<header class="tab-head">
				<h2>Tools</h2>
			</header>
			<ul class="tools" id="tools"></ul>
			<h3>From the terminal</h3>
			<pre class="cheat">bin/site-new name --php 8.2        new WordPress site at https://name.test
bin/site-import name export.zip    LocalWP export, or any folder + .sql
bin/site-remove name --yes         unlink, unsecure, drop database, delete folder
bin/php-xdebug on --php 8.4        trigger mode on port 9003
bin/service redis restart          nginx dnsmasq mysql@8.4 mailpit redis memcached php@X.Y
bin/logs php -n 100                nginx php php-fpm mysql redis mailpit, wp &lt;site&gt;, crashes</pre>
		</section>
	</main>
</div>
<script src="app.js?v=<?php echo (int) filemtime( __DIR__ . '/app.js' ); ?>"></script>
</body>
</html>
