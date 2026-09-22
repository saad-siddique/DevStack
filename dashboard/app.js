/* DevStack dashboard — reads ?api=status once a minute while visible, sends actions with the X-Devstack header. */
(function () {
	'use strict';

	var SERVICE_ORDER = [ 'nginx', 'dnsmasq', 'mysql@8.4', 'mailpit', 'redis', 'memcached' ];
	var LABELS = { 'nginx': 'nginx', 'dnsmasq': 'dnsmasq', 'mysql@8.4': 'MySQL 8.4', 'mailpit': 'Mailpit', 'redis': 'Redis', 'memcached': 'Memcached' };
	var ROLES  = { 'nginx': 'web server', 'dnsmasq': '.test DNS', 'mysql@8.4': 'database', 'mailpit': 'mail catcher', 'redis': 'object cache', 'memcached': 'object cache' };
	var REFRESH_MS = 60000;          // status once a minute; nothing while the tab is hidden. The Refresh button is instant.
	var lastLoaded = 0;
	var busy = false;
	var timer = null;
	var last = null;
	var filterText = '';
	var logSource = null;      // { source: 'php' } or { source: 'wp', site: 'x' }
	var logFilter = '';
	var logTimer = null;
	var logData = null;

	var $ = function ( id ) { return document.getElementById( id ); };
	var TABS = [ 'overview', 'php', 'services', 'logs', 'tools' ];
	var currentTab = 'overview';

	function setTab( name, push ) {
		if ( -1 === TABS.indexOf( name ) ) { name = 'overview'; }
		currentTab = name;
		document.querySelectorAll( '.nav-item' ).forEach( function ( b ) { b.setAttribute( 'aria-selected', b.getAttribute( 'data-tab' ) === name ? 'true' : 'false' ); } );
		document.querySelectorAll( '.tab' ).forEach( function ( sec ) { sec.hidden = sec.getAttribute( 'data-tab' ) !== name; } );
		try { localStorage.setItem( 'devstack.tab', name ); } catch ( e ) {}
		if ( false !== push && location.hash !== '#' + name ) { history.replaceState( null, '', '#' + name ); }
		if ( 'logs' === name ) { loadLog(); } else { clearTimeout( logTimer ); }
	}
	document.querySelectorAll( '.nav-item' ).forEach( function ( b ) { b.addEventListener( 'click', function () { setTab( b.getAttribute( 'data-tab' ) ); } ); } );
	window.addEventListener( 'hashchange', function () { setTab( location.hash.replace( '#', '' ), false ); } );
	function navDot( tab, on ) { var d = document.querySelector( '.nav-item[data-tab="' + tab + '"] .dot' ); if ( d ) { d.hidden = ! on; } }
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
		var quick = $( 'quick' );
		quick.textContent = '';
		quick.appendChild( el( 'a', { 'class': 'act', href: s.tools.phpmyadmin, target: '_blank', rel: 'noopener', title: 'Every database, signed in as root', text: 'phpMyAdmin' } ) );
		quick.appendChild( el( 'a', { 'class': 'act', href: s.tools.mailpit, target: '_blank', rel: 'noopener', title: 'Every outgoing mail from every site', text: 'Mailpit' } ) );
		var list = $( 'tools' );
		list.textContent = '';
		list.appendChild( el( 'li', {}, [ el( 'a', { href: '?api=status', target: '_blank', rel: 'noopener', text: 'Status JSON' } ), document.createTextNode( ' — what this page reads (bin/stack-status)' ) ] ) );
		list.appendChild( el( 'li', {}, [ el( 'a', { href: s.tools.phpmyadmin, target: '_blank', rel: 'noopener', text: 'phpMyAdmin' } ), document.createTextNode( ' and ' ), el( 'a', { href: s.tools.mailpit, target: '_blank', rel: 'noopener', text: 'Mailpit' } ), document.createTextNode( ' also sit top right on Overview.' ) ] ) );
	}

	function renderPorts( s ) {
		var byOwner = {};
		Object.keys( s.ports || {} ).forEach( function ( p ) { var o = s.ports[ p ] || 'free'; ( byOwner[ o ] = byOwner[ o ] || [] ).push( p ); } );
		$( 'ports' ).textContent = 'Ports: ' + Object.keys( byOwner ).sort().map( function ( o ) { return o + ' ' + byOwner[ o ].join( ', ' ); } ).join( '; ' ) + '.';
	}

	function renderStrip( s ) {
		var strip = $( 'strip' );
		strip.textContent = '';
		var byName = {};
		s.services.forEach( function ( x ) { byName[ x.name ] = x; } );
		SERVICE_ORDER.forEach( function ( name ) {
			var svc = byName[ name ];
			if ( ! svc ) { return; }
			var on = 'started' === svc.status;
			var b = el( 'button', { type: 'button', title: 'Open Services' }, [ el( 'span', { 'class': 'lamp' + ( on ? ' on' : '' ), 'aria-hidden': 'true' } ), el( 'span', { text: LABELS[ name ] || name } ), el( 'span', { 'class': 'muted', text: on ? '' : 'off' } ) ] );
			b.addEventListener( 'click', function () { setTab( 'services' ); } );
			strip.appendChild( el( 'li', {}, [ b ] ) );
		} );
		( s.php || [] ).filter( function ( p ) { return 'started' === p.fpm; } ).forEach( function ( p ) {
			var b = el( 'button', { type: 'button', title: 'Open PHP' }, [ el( 'span', { 'class': 'lamp on', 'aria-hidden': 'true' } ), el( 'span', { text: 'PHP ' + p.version } ), el( 'span', { 'class': 'muted', text: p['default'] ? 'default' : p.sites + ( 1 === p.sites ? ' site' : ' sites' ) } ) ] );
			b.addEventListener( 'click', function () { setTab( 'php' ); } );
			strip.appendChild( el( 'li', {}, [ b ] ) );
		} );
	}

	function renderSites( s ) {
		var tbody = $( 'sites' ).querySelector( 'tbody' );
		tbody.textContent = '';
		var q = filterText.trim().toLowerCase();
		var rows = s.sites.filter( function ( site ) { return ! q || -1 !== site.name.indexOf( q ); } );
		rows.forEach( function ( site ) {
			var host = site.name + '.test';
			var php = 'default' === site.php ? '8.4' : site.php;
			// The name column already opens the site; this column is wp-admin only (empty for PHP/static sites).
			var open = el( 'td', {} );
			if ( site.wp ) {
				open.appendChild( el( 'a', { href: 'https://' + host + '/wp-admin/', target: '_blank', rel: 'noopener', text: 'wp-admin' } ) );
			}
			var nameCell = el( 'td', { 'class': 'name' }, [ el( 'a', { href: 'https://' + host, target: '_blank', rel: 'noopener', text: host } ) ] );
			if ( site.fatals_recent ) {
				nameCell.appendChild( el( 'span', { 'class': 'badge fatals', title: site.fatals_recent + ' PHP fatal error(s) in debug.log today or yesterday — Logs tab, wp ' + site.name, text: site.fatals_recent + ( 1 === site.fatals_recent ? ' fatal' : ' fatals' ) } ) );
			}
			tbody.appendChild( el( 'tr', {}, [
				nameCell,
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
		renderUpgrades( s );
		renderStrip( s );
		renderServices( s );
		renderPorts( s );
		renderPhp( s );
		renderTools( s );
		renderLogTabs( s );
		renderSites( s );
		var pulse = $( 'pulse' );
		pulse.classList.remove( 'stale' );
		pulse.classList.remove( 'tick' );
		void pulse.offsetWidth;
		pulse.classList.add( 'tick' );
		lastLoaded = Date.now();
		updateAge();
	}

	function updateAge() {
		var el2 = $( 'age' );
		if ( ! el2 || ! lastLoaded ) { return; }
		var sec = Math.round( ( Date.now() - lastLoaded ) / 1000 );
		el2.textContent = sec < 5 ? 'updated just now' : ( sec < 90 ? 'updated ' + sec + ' s ago' : 'updated ' + Math.round( sec / 60 ) + ' min ago' );
	}
	setInterval( updateAge, 5000 );

	function refresh() {
		clearTimeout( timer );
		var btn = $( 'refresh' );
		if ( btn ) { btn.disabled = true; }
		return fetchStatus().then( render ).catch( function () {
			$( 'pulse' ).classList.add( 'stale' );
			$( 'summary' ).textContent = 'Could not read the stack. Is nginx or php-fpm restarting? Use Refresh to try again.';
		} ).then( function () {
			if ( btn ) { btn.disabled = false; }
			if ( ! document.hidden ) { timer = setTimeout( refresh, REFRESH_MS ); }
			if ( 'logs' === currentTab ) { logData = null; loadLog(); }
		} );
	}
	$( 'refresh' ).addEventListener( 'click', function () { refresh(); } );


	function fmtSize( b ) {
		if ( b < 1024 ) { return b + ' B'; }
		if ( b < 1048576 ) { return Math.round( b / 1024 ) + ' KB'; }
		return ( b / 1048576 ).toFixed( 1 ) + ' MB';
	}

	function renderAlert( s ) {
		var box = $( 'alert' );
		var errs = s.services.filter( function ( x ) { return /^error/.test( x.status ); } ).map( function ( x ) { return x.name; } );
		var reports = ( s.crashes && s.crashes.reports ) || [];
		var crashes = reports.filter( function ( r ) { return 'crash' === r.kind; } );
		var resource = reports.filter( function ( r ) { return 'crash' !== r.kind; } );
		var uniq = function ( a ) { return a.filter( function ( v, i, arr ) { return arr.indexOf( v ) === i; } ); };
		var parts = [];
		if ( crashes.length ) { parts.push( crashes.length + ( 1 === crashes.length ? ' crash' : ' crashes' ) + ' in the last 24 hours (' + uniq( crashes.map( function ( r ) { return r.process; } ) ).join( ', ' ) + ')' ); }
		if ( errs.length ) { parts.push( 'launchd reports errors for ' + errs.join( ', ' ) ); }
		if ( resource.length ) { parts.push( 'macOS flagged ' + uniq( resource.map( function ( r ) { return r.process + ' for ' + r.kind; } ) ).join( ', ' ) + ' (runaway process?)' ); }
		var severe = crashes.length > 0 || errs.length > 0;
		box.hidden = 0 === parts.length;
		box.classList.toggle( 'warn', ! severe );
		box.textContent = parts.join( '. ' ) + ( parts.length ? ( severe ? '. Check the php-fpm and nginx logs.' : '. See devstack logs crashes.' ) : '' );
		$( 'pulse' ).classList.toggle( 'stale', severe );
		navDot( 'services', errs.length > 0 );
		navDot( 'logs', crashes.length > 0 );
	}

	// Homebrew state of the stack (bin/stack-upgrade): what the nightly run did, what waits, and the nightly setting.
	function renderUpgrades( s ) {
		var box = $( 'upgrades' );
		var u = s.upgrades;
		box.textContent = '';
		if ( ! u ) { box.hidden = true; return; }
		var avail = u.available || [];
		var review = avail.filter( function ( a ) { return 'patch' !== a.kind; } );
		var patches = avail.filter( function ( a ) { return 'patch' === a.kind; } );
		var run = u.last_run;
		var recent = run && run.at && ( Date.now() - Date.parse( run.at ) ) < 86400000 && ( ( run.upgraded || [] ).length || ( run.failed || [] ).length );
		var line = function ( a ) { return a.short + ' ' + a.installed + ' → ' + a.current; };
		var rows = [];
		if ( recent && ( run.upgraded || [] ).length ) {
			rows.push( el( 'p', { 'class': 'ok', text: 'Upgraded ' + new Date( run.at ).toLocaleString( [], { hour: '2-digit', minute: '2-digit', weekday: 'short' } ) + ': ' + run.upgraded.map( function ( x ) { return x.name + ' ' + x.from + ' → ' + x.to; } ).join( ', ' ) } ) );
		}
		if ( recent && ( run.failed || [] ).length ) {
			rows.push( el( 'p', { 'class': 'bad', text: 'Failed: ' + run.failed.map( function ( x ) { return x.name; } ).join( ', ' ) + ' — see the upgrade log.' } ) );
		}
		if ( review.length ) { rows.push( el( 'p', { text: review.length + ( 1 === review.length ? ' upgrade' : ' upgrades' ) + ' to review: ' + review.map( line ).join( ', ' ) } ) ); }
		if ( patches.length ) { rows.push( el( 'p', { 'class': 'muted', text: patches.length + ( 1 === patches.length ? ' patch release' : ' patch releases' ) + ( 'off' === u.auto ? ' available: ' : ' apply tonight: ' ) + patches.map( line ).join( ', ' ) } ) ); }
		if ( ! rows.length && u.checked_at ) { rows.push( el( 'p', { 'class': 'muted', text: 'Stack up to date (checked ' + new Date( u.checked_at ).toLocaleString( [], { hour: '2-digit', minute: '2-digit', weekday: 'short' } ) + ').' } ) ); }
		var actions = el( 'div', { 'class': 'actions' } );
		if ( review.length ) { actions.appendChild( button( 'Upgrade all', 'primary', function () { return post( 'upgrade', { mode: 'all' } ); } ) ); }
		if ( patches.length ) { actions.appendChild( button( review.length ? 'Patches only' : 'Upgrade now', review.length ? '' : 'primary', function () { return post( 'upgrade', { mode: 'auto' } ); } ) ); }
		actions.appendChild( button( 'Check now', 'quiet', function () { return post( 'upgrade', { mode: 'check' } ); } ) );
		var auto = el( 'label', { 'class': 'auto' } );
		var cb = el( 'input', { type: 'checkbox' } );
		cb.checked = 'off' !== u.auto;
		cb.addEventListener( 'change', function () { post( 'upgrade-auto', { value: cb.checked ? 'patch' : 'off' } ).then( refresh ); } );
		auto.appendChild( cb );
		auto.appendChild( document.createTextNode( ' Apply patch releases automatically at 03:30' ) );
		actions.appendChild( auto );
		box.appendChild( el( 'div', { 'class': 'text' }, rows ) );
		box.appendChild( actions );
		box.hidden = false;
		navDot( 'overview', review.length > 0 || ( recent && ( run.failed || [] ).length > 0 ) );
	}

	function logKey( d ) { return d.source + ( d.site ? ':' + d.site : '' ); }

	function renderLogTabs( s ) {
		var tabs = $( 'log-tabs' );
		var sel = $( 'log-site' );
		var list = ( s.logs || [] );
		var stack = list.filter( function ( l ) { return ! l.site; } );
		var sites = list.filter( function ( l ) { return l.site; } );
		if ( ! logSource && stack.length ) { logSource = { source: stack[ 0 ].source, site: null }; }
		tabs.textContent = '';
		stack.forEach( function ( l ) {
			var d = { source: l.source, site: null };
			var selected = logSource && logKey( logSource ) === logKey( d );
			var b = el( 'button', { 'class': 'log-tab', type: 'button', role: 'tab', 'aria-selected': selected ? 'true' : 'false' }, [
				document.createTextNode( l.source ),
				el( 'span', { 'class': 'sz', text: l.exists && l.size ? fmtSize( l.size ) : '' } )
			] );
			b.addEventListener( 'click', function () { logSource = d; logData = null; sel.value = ''; renderLogTabs( last ); loadLog(); } );
			tabs.appendChild( b );
		} );
		var keep = sel.value;
		while ( sel.options.length > 1 ) { sel.remove( 1 ); }
		sites.forEach( function ( l ) {
			var o = document.createElement( 'option' );
			o.value = l.site; o.textContent = l.site + ( l.exists && l.size ? ' (' + fmtSize( l.size ) + ')' : '' );
			sel.appendChild( o );
		} );
		sel.value = logSource && 'wp' === logSource.source ? logSource.site : ( keep || '' );
		if ( 'logs' === currentTab && logSource && ! logData ) { loadLog(); }
	}
	$( 'log-site' ).addEventListener( 'change', function ( e ) {
		if ( ! e.target.value ) { return; }
		logSource = { source: 'wp', site: e.target.value }; logData = null;
		renderLogTabs( last ); loadLog();
	} );

	function loadLog() {
		clearTimeout( logTimer );
		if ( ! logSource || 'logs' !== currentTab ) { return; }
		var q = '?api=log&source=' + encodeURIComponent( logSource.source ) + ( logSource.site ? '&site=' + encodeURIComponent( logSource.site ) : '' ) + '&n=300';
		fetch( q, { cache: 'no-store' } ).then( function ( r ) { return r.json(); } ).then( function ( d ) {
			if ( d && d.lines ) { logData = d; renderLog(); }
		} ).catch( function () {} );
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
	document.addEventListener( 'visibilitychange', function () { if ( document.hidden ) { clearTimeout( timer ); } else { refresh(); } } );
	var initial = location.hash.replace( '#', '' );
	if ( ! initial ) { try { initial = localStorage.getItem( 'devstack.tab' ) || 'overview'; } catch ( e ) { initial = 'overview'; } }
	setTab( initial, false );
	refresh();
}() );
