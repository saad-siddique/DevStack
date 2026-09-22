/* local-devstack dashboard — reads ?api=status every 5 s, sends actions with the X-Devstack header. */
(function () {
	'use strict';

	var SERVICE_ORDER = [ 'nginx', 'dnsmasq', 'mysql@8.4', 'mailpit', 'redis', 'memcached' ];
	var LABELS = { 'nginx': 'nginx', 'dnsmasq': 'dnsmasq', 'mysql@8.4': 'MySQL 8.4', 'mailpit': 'Mailpit', 'redis': 'Redis', 'memcached': 'Memcached' };
	var ROLES  = { 'nginx': 'web server', 'dnsmasq': '.test DNS', 'mysql@8.4': 'database', 'mailpit': 'mail catcher', 'redis': 'object cache', 'memcached': 'object cache' };
	var REFRESH_MS = 5000;
	var busy = false;
	var timer = null;
	var last = null;
	var filterText = '';
	var logSource = null;      // { source: 'php' } or { source: 'wp', site: 'x' }
	var logFilter = '';
	var logTimer = null;
	var logData = null;

	var $ = function ( id ) { return document.getElementById( id ); };
	var el = function ( tag, attrs, children ) {
		var node = document.createElement( tag );
		Object.keys( attrs || {} ).forEach( function ( k ) {
			if ( 'text' === k ) { node.textContent = attrs[ k ]; } else if ( 'html' === k ) { node.innerHTML = attrs[ k ]; } else { node.setAttribute( k, attrs[ k ] ); }
		} );
		( children || [] ).forEach( function ( c ) { node.appendChild( c ); } );
		return node;
	};

	function fetchStatus() {
		return fetch( '?api=status', { cache: 'no-store' } ).then( function ( r ) { return r.json(); } );
	}

	function post( api, body ) {
		var data = new URLSearchParams( body );
		return fetch( '?api=' + api, { method: 'POST', headers: { 'X-Devstack': '1' }, body: data } ).then( function ( r ) { return r.json(); } );
	}

	function summary( s ) {
		var sites = s.sites.length;
		var running = ( s.php || [] ).filter( function ( p ) { return 'started' === p.fpm; } ).map( function ( p ) { return p.version; } );
		var parts = [ sites + ( 1 === sites ? ' site' : ' sites' ) ];
		if ( s.php && s.php.length ) { parts.push( s.php.length + ' PHP versions installed, ' + ( running.length ? running.join( ' and ' ) + ' running' : 'none running' ) ); }
		if ( s.mysql && s.mysql.version ) { parts.push( 'MySQL ' + s.mysql.version + ( null !== s.mysql.qps ? ' at ' + Math.round( s.mysql.qps ) + ' queries/s' : '' ) ); }
		if ( s.mail && s.mail.backend ) { parts.push( ( 'mailpit' === s.mail.backend ? 'Mailpit' : 'MailHog' ) + ' holding ' + s.mail.total + ( 1 === s.mail.total ? ' message' : ' messages' ) ); }
		return parts.join( ', ' ) + '.';
	}

	function renderServices( s ) {
		var list = $( 'services' );
		list.textContent = '';
		var byName = {};
		s.services.forEach( function ( x ) { byName[ x.name ] = x; } );
		SERVICE_ORDER.forEach( function ( name ) {
			var svc = byName[ name ];
			if ( ! svc ) { return; }
			var on = 'started' === svc.status;
			var role  = ROLES[ name ] ? ROLES[ name ] + ', ' : '';
			var state = on ? role + 'running' + ( svc.user ? ' (' + ( 'root' === svc.user ? 'root' : 'you' ) + ')' : '' ) : role + ( 'none' === svc.status ? 'stopped' : svc.status );
			var actions = el( 'span', { 'class': 'actions' } );
			if ( on ) {
				actions.appendChild( button( 'Restart', '', function () { return post( 'service', { name: name, op: 'restart' } ); } ) );
				actions.appendChild( button( 'Stop', 'quiet', function () { return post( 'service', { name: name, op: 'stop' } ); } ) );
			} else {
				actions.appendChild( button( 'Start', 'primary', function () { return post( 'service', { name: name, op: 'start' } ); } ) );
			}
			list.appendChild( el( 'li', { 'class': 'svc' }, [
				el( 'span', { 'class': 'lamp' + ( on ? ' on' : '' ), 'aria-hidden': 'true' } ),
				el( 'span', { 'class': 'svc-name', text: LABELS[ name ] || name }, [ el( 'span', { 'class': 'svc-state', text: state } ) ] ),
				actions
			] ) );
		} );

	}

	function renderPhp( s ) {
		var list = $( 'php' );
		list.textContent = '';
		( s.php || [] ).forEach( function ( p ) {
			var running = 'started' === p.fpm;
			var svcName = 'php@' + p.version;
			var state;
			if ( p['default'] ) { state = 'default for new sites, ' + p.sites + ( 1 === p.sites ? ' site' : ' sites' ); }
			else if ( p.sites > 0 ) { state = p.sites + ( 1 === p.sites ? ' site' : ' sites' ) + ( running ? '' : ', php-fpm stopped' ); }
			else { state = running ? 'php-fpm running, no sites' : 'idle, php-fpm stopped'; }
			if ( p.xdebug ) { state += ', Xdebug on'; }
			var actions = el( 'span', { 'class': 'actions' } );
			actions.appendChild( button( p.xdebug ? 'Xdebug off' : 'Xdebug on', p.xdebug ? 'quiet' : '', function () { return post( 'xdebug', { php: p.version, op: p.xdebug ? 'off' : 'on' } ); } ) );
			if ( running ) {
				actions.appendChild( button( 'Restart', '', function () { return post( 'service', { name: svcName, op: 'restart' } ); } ) );
				if ( ! p['default'] ) { actions.appendChild( button( 'Stop', 'quiet', function () { return post( 'service', { name: svcName, op: 'stop' } ); } ) ); }
			} else {
				actions.appendChild( button( 'Start', 'primary', function () { return post( 'service', { name: svcName, op: 'start' } ); } ) );
			}
			list.appendChild( el( 'li', { 'class': 'svc' + ( p['default'] ? ' is-default' : '' ) }, [
				el( 'span', { 'class': 'lamp' + ( running ? ' on' : '' ), 'aria-hidden': 'true' } ),
				el( 'span', { 'class': 'svc-name', text: 'PHP ' + ( p.full || p.version ) }, [ el( 'span', { 'class': 'svc-state', text: state } ) ] ),
				actions
			] ) );
		} );
	}

	function button( label, kind, action ) {
		var b = el( 'button', { 'class': 'act' + ( kind ? ' ' + kind : '' ), type: 'button', text: label } );
		b.addEventListener( 'click', function () {
			if ( busy ) { return; }
			busy = true;
			document.querySelectorAll( 'button.act' ).forEach( function ( x ) { x.disabled = true; } );
			b.textContent = label + '…';
			action().then( function ( res ) {
				if ( res && res.error ) { showError( res.error ); }
			} ).catch( function ( e ) { showError( String( e ) ); } ).then( function () {
				busy = false;
				refresh();
			} );
		} );
		return b;
	}

	function renderTools( s ) {
		var list = $( 'tools' );
		list.textContent = '';
		list.appendChild( el( 'li', {}, [ el( 'a', { href: s.tools.phpmyadmin, target: '_blank', rel: 'noopener', text: 'phpMyAdmin' } ), document.createTextNode( ' signed in as root' ) ] ) );
		list.appendChild( el( 'li', {}, [ el( 'a', { href: s.tools.mailpit, target: '_blank', rel: 'noopener', text: 'Mailpit' } ), document.createTextNode( ' catches all outgoing mail' ) ] ) );
		var byOwner = {};
		Object.keys( s.ports || {} ).forEach( function ( p ) { var o = s.ports[ p ] || 'free'; ( byOwner[ o ] = byOwner[ o ] || [] ).push( p ); } );
		var ports = Object.keys( byOwner ).sort().map( function ( o ) { return o + ' ' + byOwner[ o ].join( ', ' ); } ).join( '; ' );
		list.appendChild( el( 'li', { text: 'Ports: ' + ports + '.' } ) );
	}

	function renderSites( s ) {
		var tbody = $( 'sites' ).querySelector( 'tbody' );
		tbody.textContent = '';
		var q = filterText.trim().toLowerCase();
		var rows = s.sites.filter( function ( site ) { return ! q || -1 !== site.name.indexOf( q ); } );
		rows.forEach( function ( site ) {
			var host = site.name + '.test';
			var php = 'default' === site.php ? '8.4' : site.php;
			var open = el( 'td', {} );
			open.appendChild( el( 'a', { href: 'https://' + host, target: '_blank', rel: 'noopener', text: 'Site' } ) );
			if ( site.wp ) {
				open.appendChild( document.createTextNode( '  ' ) );
				open.appendChild( el( 'a', { href: 'https://' + host + '/wp-admin/', target: '_blank', rel: 'noopener', text: 'wp-admin' } ) );
			}
			tbody.appendChild( el( 'tr', {}, [
				el( 'td', { 'class': 'name' }, [ el( 'a', { href: 'https://' + host, target: '_blank', rel: 'noopener', text: host } ) ] ),
				el( 'td', {}, [ el( 'span', { 'class': 'badge' + ( '7.4' === php ? ' php74' : '' ), text: 'PHP ' + php } ) ] ),
				el( 'td', {}, [ el( 'span', { 'class': 'badge ' + ( site.secured ? 'https' : 'http' ), text: site.secured ? 'https' : 'http only' } ) ] ),
				open,
				el( 'td', { 'class': 'folder', title: site.path, text: ( site.path || '' ).replace( s.sites_dir, '~/Sites' ) } )
			] ) );
		} );
		$( 'sites-count' ).textContent = rows.length === s.sites.length ? String( s.sites.length ) : rows.length + ' of ' + s.sites.length;
		var empty = $( 'sites-empty' );
		empty.hidden = rows.length > 0;
		empty.textContent = q ? 'No sites match “' + filterText.trim() + '”.' : 'No sites are linked yet. Run bin/site-new <name> to create one.';
	}

	function showError( msg ) {
		var bar = document.querySelector( '.error-bar' ) || document.querySelector( 'main' ).insertBefore( el( 'div', { 'class': 'error-bar', role: 'alert' } ), document.querySelector( 'main' ).firstChild );
		bar.textContent = msg;
		setTimeout( function () { if ( bar.parentNode ) { bar.parentNode.removeChild( bar ); } }, 8000 );
	}

	function render( s ) {
		last = s;
		$( 'summary' ).textContent = summary( s );
		renderAlert( s );
		renderServices( s );
		renderPhp( s );
		renderTools( s );
		renderLogTabs( s );
		renderSites( s );
		var pulse = $( 'pulse' );
		pulse.classList.remove( 'stale' );
		pulse.classList.remove( 'tick' );
		void pulse.offsetWidth;
		pulse.classList.add( 'tick' );
	}

	function refresh() {
		clearTimeout( timer );
		fetchStatus().then( render ).catch( function () {
			$( 'pulse' ).classList.add( 'stale' );
			$( 'summary' ).textContent = 'Could not read the stack. Is nginx or php-fpm restarting? Retrying…';
		} ).then( function () { timer = setTimeout( refresh, REFRESH_MS ); } );
	}


	function fmtSize( b ) {
		if ( b < 1024 ) { return b + ' B'; }
		if ( b < 1048576 ) { return Math.round( b / 1024 ) + ' KB'; }
		return ( b / 1048576 ).toFixed( 1 ) + ' MB';
	}

	function renderAlert( s ) {
		var box = $( 'alert' );
		var errs = s.services.filter( function ( x ) { return /^error/.test( x.status ); } ).map( function ( x ) { return x.name; } );
		var crashes = s.crashes ? s.crashes.count : 0;
		var parts = [];
		if ( crashes ) {
			var procs = s.crashes.reports.map( function ( r ) { return r.process; } ).filter( function ( v, i, a ) { return a.indexOf( v ) === i; } );
			parts.push( crashes + ( 1 === crashes ? ' crash report' : ' crash reports' ) + ' in the last 24 hours (' + procs.join( ', ' ) + ')' );
		}
		if ( errs.length ) { parts.push( 'launchd reports errors for ' + errs.join( ', ' ) ); }
		box.hidden = 0 === parts.length;
		box.textContent = parts.join( '. ' ) + ( parts.length ? '. Check the php-fpm and nginx logs below.' : '' );
		$( 'pulse' ).classList.toggle( 'stale', parts.length > 0 );
	}

	function logKey( d ) { return d.source + ( d.site ? ':' + d.site : '' ); }

	function renderLogTabs( s ) {
		var tabs = $( 'log-tabs' );
		var list = ( s.logs || [] ).slice();
		tabs.textContent = '';
		if ( ! logSource && list.length ) { logSource = { source: list[ 0 ].source.split( ' ' )[ 0 ], site: list[ 0 ].site || null }; }
		list.forEach( function ( l ) {
			var src = l.source.split( ' ' )[ 0 ];
			var d = { source: src, site: l.site || null };
			var selected = logSource && logKey( logSource ) === logKey( d );
			var b = el( 'button', { 'class': 'log-tab', type: 'button', role: 'tab', 'aria-selected': selected ? 'true' : 'false' }, [
				document.createTextNode( l.site ? l.site : l.source ),
				el( 'span', { 'class': 'sz', text: l.exists ? fmtSize( l.size ) : '' } )
			] );
			b.addEventListener( 'click', function () { logSource = d; logData = null; renderLogTabs( last ); loadLog(); } );
			tabs.appendChild( b );
		} );
		if ( logSource && ! logData ) { loadLog(); }
	}

	function loadLog() {
		clearTimeout( logTimer );
		if ( ! logSource ) { return; }
		var q = '?api=log&source=' + encodeURIComponent( logSource.source ) + ( logSource.site ? '&site=' + encodeURIComponent( logSource.site ) : '' ) + '&n=300';
		fetch( q, { cache: 'no-store' } ).then( function ( r ) { return r.json(); } ).then( function ( d ) {
			if ( d && d.lines ) { logData = d; renderLog(); }
		} ).catch( function () {} ).then( function () { logTimer = setTimeout( loadLog, REFRESH_MS ); } );
	}

	function renderLog() {
		var pre = $( 'log-body' );
		var meta = $( 'log-meta' );
		if ( ! logData ) { return; }
		var q = logFilter.trim().toLowerCase();
		var lines = logData.lines.filter( function ( l ) { return ! q || -1 !== l.text.toLowerCase().indexOf( q ); } );
		var atBottom = pre.scrollHeight - pre.scrollTop - pre.clientHeight < 40;
		pre.textContent = '';
		if ( ! lines.length ) {
			pre.appendChild( el( 'span', { 'class': 'empty-log', text: logData.lines.length ? 'No lines match “' + logFilter.trim() + '”.' : 'Nothing logged yet. That is the good outcome.' } ) );
		} else {
			lines.forEach( function ( l ) { pre.appendChild( el( 'span', { 'class': 'l-' + l.level, text: l.text + '\n' } ) ); } );
		}
		if ( atBottom ) { pre.scrollTop = pre.scrollHeight; }
		var errors = logData.lines.filter( function ( l ) { return 'error' === l.level; } ).length;
		meta.textContent = logData.path.replace( last && last.sites_dir ? last.sites_dir : '~/Sites', '~/Sites' ) + ', ' + fmtSize( logData.size ) + ', last ' + logData.lines.length + ' lines' + ( errors ? ', ' + errors + ' error lines' : '' );
	}

	$( 'log-filter' ).addEventListener( 'input', function ( e ) { logFilter = e.target.value; renderLog(); } );
	$( 'log-clear' ).addEventListener( 'click', function () {
		if ( ! logSource || busy ) { return; }
		busy = true;
		post( 'log-clear', { source: logSource.source, site: logSource.site || '' } ).then( function ( r ) {
			if ( r && r.error ) { showError( r.error ); }
		} ).catch( function ( e ) { showError( String( e ) ); } ).then( function () { busy = false; logData = null; loadLog(); refresh(); } );
	} );

	$( 'filter' ).addEventListener( 'input', function ( e ) {
		filterText = e.target.value;
		if ( last ) { renderSites( last ); }
	} );
	document.addEventListener( 'visibilitychange', function () { if ( ! document.hidden ) { refresh(); } } );
	refresh();
}() );
