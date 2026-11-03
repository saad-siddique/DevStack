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
	var TABS = [ 'overview', 'php', 'services', 'upgrades', 'logs', 'cleanup', 'tools' ];
	var currentTab = 'overview';

	function setTab( name, push ) {
		if ( -1 === TABS.indexOf( name ) ) { name = 'overview'; }
		currentTab = name;
		document.querySelectorAll( '.nav-item' ).forEach( function ( b ) { b.setAttribute( 'aria-selected', b.getAttribute( 'data-tab' ) === name ? 'true' : 'false' ); } );
		document.querySelectorAll( '.tab' ).forEach( function ( sec ) { sec.hidden = sec.getAttribute( 'data-tab' ) !== name; } );
		try { localStorage.setItem( 'devstack.tab', name ); } catch ( e ) {}
		if ( false !== push && location.hash !== '#' + name ) { history.replaceState( null, '', '#' + name ); }
		if ( 'logs' === name ) { loadLog(); } else { clearTimeout( logTimer ); }
		if ( 'cleanup' === name ) { loadCleanup(); } else { clearTimeout( clTimer ); clearTimeout( compactTimer ); }
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
			var broken = p.broken_ext || [];
			if ( broken.length ) { state = broken.join( ', ' ) + ( 1 === broken.length ? ' fails' : ' fail' ) + ' to load'; }
			var actions = el( 'span', { 'class': 'actions' } );
			if ( broken.length ) {
				actions.appendChild( button( 'Repair', 'primary', function () { return post( 'php-repair', { php: p.version } ); } ) );
			}
			actions.appendChild( button( p.xdebug ? 'Xdebug off' : 'Xdebug on', p.xdebug ? 'quiet' : '', function () { return post( 'xdebug', { php: p.version, op: p.xdebug ? 'off' : 'on' } ); } ) );
			if ( running ) {
				actions.appendChild( button( 'Restart', '', function () { return post( 'service', { name: svcName, op: 'restart' } ); } ) );
				if ( ! p['default'] ) { actions.appendChild( button( 'Stop', 'quiet', function () { return post( 'service', { name: svcName, op: 'stop' } ); } ) ); }
			} else {
				actions.appendChild( button( 'Start', 'primary', function () { return post( 'service', { name: svcName, op: 'start' } ); } ) );
			}
			list.appendChild( el( 'li', { 'class': 'svc' + ( p['default'] ? ' is-default' : '' ) }, [
				el( 'span', { 'class': 'lamp' + ( running ? ' on' : '' ), 'aria-hidden': 'true' } ),
				el( 'span', { 'class': 'svc-name', text: 'PHP ' + ( p.full || p.version ) }, [ el( 'span', { 'class': 'svc-state' + ( broken.length ? ' bad' : '' ), title: broken.length ? 'Homebrew built these against another PHP ' + p.version + ' build. Repair reinstalls PHP ' + p.version + ' and its extensions.' : state, text: state } ) ] ),
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

	var sortBySize = 'size' === localStorage.getItem( 'sites.sort' );

	// Inline SVG icons (24×24, stroked) matching the app's symbols: compass = open, gear = wp-admin, person+key = log in, globe = share.
	var ICONS = {
		open:   '<circle cx="12" cy="12" r="9"/><path d="M15.6 8.4l-2.3 5.3-5.3 2.3 2.3-5.3z"/>',
		admin:  '<circle cx="12" cy="12" r="3"/><path d="M12 2.5v2.2M12 19.3v2.2M2.5 12h2.2M19.3 12h2.2M5.3 5.3l1.6 1.6M17.1 17.1l1.6 1.6M5.3 18.7l1.6-1.6M17.1 6.9l1.6-1.6"/><circle cx="12" cy="12" r="6.5"/>',
		login:  '<circle cx="9" cy="8" r="3.2"/><path d="M3.5 19.5c0-3.3 2.5-5.5 5.5-5.5 1.3 0 2.4.4 3.4 1"/><circle cx="17" cy="14" r="2.3"/><path d="M18.6 15.6l3 3M20.2 17.2l1.4-1.4"/>',
		share:  '<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3c2.8 3 2.8 15 0 18M12 3c-2.8 3-2.8 15 0 18"/>',
		stop:   '<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3c2.8 3 2.8 15 0 18M12 3c-2.8 3-2.8 15 0 18M5 5l14 14"/>',
		copy:   '<rect x="9" y="9" width="11" height="11" rx="2"/><path d="M5 15V6a2 2 0 0 1 2-2h9"/>'
	};
	function icon( name ) {
		var span = document.createElement( 'span' );
		span.innerHTML = '<svg viewBox="0 0 24 24" aria-hidden="true">' + ICONS[ name ] + '</svg>';
		return span.firstChild;
	}
	function iconLink( name, title, href ) {
		var a = el( 'a', { 'class': 'ic', href: href, target: '_blank', rel: 'noopener', title: title, 'aria-label': title } );
		a.appendChild( icon( name ) );
		return a;
	}
	function iconButton( name, title, extraClass ) {
		var b = el( 'button', { 'class': 'ic' + ( extraClass ? ' ' + extraClass : '' ), type: 'button', title: title, 'aria-label': title } );
		b.appendChild( icon( name ) );
		return b;
	}
	function fmtBytes( b ) { return fmtSize( b || 0 ); }

	function renderSites( s ) {
		var tbody = $( 'sites' ).querySelector( 'tbody' );
		tbody.textContent = '';
		var q = filterText.trim().toLowerCase();
		// The app hides its own tooling sites too; keep both lists identical.
		var rows = s.sites.filter( function ( site ) { return 'dashboard' !== site.name && 'phpmyadmin' !== site.name && ( ! q || -1 !== site.name.indexOf( q ) ); } );
		rows = rows.slice().sort( function ( a, b ) {
			if ( !! a.favorite !== !! b.favorite ) { return a.favorite ? -1 : 1; }          // favourites always first
			if ( sortBySize ) { return ( ( b.files_bytes || 0 ) + ( b.db_bytes || 0 ) ) - ( ( a.files_bytes || 0 ) + ( a.db_bytes || 0 ) ); }
			return a.name < b.name ? -1 : ( a.name > b.name ? 1 : 0 );
		} );
		$( 'sort-size' ).classList.toggle( 'on', sortBySize );
		$( 'sort-name' ).classList.toggle( 'on', ! sortBySize );
		var sharing = ( s.share && s.share.sites ) || [];
		rows.forEach( function ( site ) {
			var host = site.name + '.test';
			var php = 'default' === site.php ? ( ( s.php || [] ).filter( function ( p ) { return p['default']; } ).map( function ( p ) { return p.version; } )[ 0 ] || '8.4' ) : site.php;
			var star = el( 'button', { 'class': 'star' + ( site.favorite ? ' on' : '' ), type: 'button', title: site.favorite ? 'Remove from favourites' : 'Add to favourites', 'aria-pressed': site.favorite ? 'true' : 'false', text: site.favorite ? '★' : '☆' } );
			star.addEventListener( 'click', function () { star.disabled = true; post( 'favorite', { name: site.name, op: 'toggle' } ).then( refresh ); } );
			// Second line: PHP, HTTPS, footprint, cache, fatals — everything that used to be its own column.
			var meta = el( 'div', { 'class': 'meta' } );
			meta.appendChild( el( 'span', { 'class': 'badge' + ( '7.4' === php ? ' php74' : '' ), text: 'PHP ' + php } ) );
			meta.appendChild( el( 'span', { 'class': 'badge ' + ( site.secured ? 'https' : 'http' ), text: site.secured ? 'https' : 'http only' } ) );
			if ( null !== site.files_bytes || site.db_bytes ) {
				meta.appendChild( el( 'span', { 'class': 'size', title: 'folder' + ( site.db ? ' + database ' + site.db : '' ), text: ( null !== site.files_bytes ? fmtBytes( site.files_bytes ) : '?' ) + ( site.db_bytes ? ' + ' + fmtBytes( site.db_bytes ) + ' db' : '' ) } ) );
			}
			if ( site.object_cache ) { meta.appendChild( el( 'span', { 'class': 'badge cache', title: 'persistent object cache', text: site.object_cache } ) ); }
			if ( site.protected ) { meta.appendChild( el( 'span', { 'class': 'badge', title: 'Protected: tooling never removes it', text: 'protected' } ) ); }
			var liveUrl = shareUrlFor( s, site.name );
			if ( liveUrl ) {
				var live = el( 'span', { 'class': 'live-pill', title: 'Public through a Cloudflare tunnel' } );
				live.appendChild( el( 'i', { 'aria-hidden': 'true' } ) );
				live.appendChild( el( 'a', { href: liveUrl, target: '_blank', rel: 'noopener', text: liveUrl.replace( /^https?:\/\//, '' ) } ) );
				var copy = iconButton( 'copy', 'Copy public URL' );
				copy.addEventListener( 'click', function () { navigator.clipboard.writeText( liveUrl ).then( function () { copy.classList.add( 'done' ); setTimeout( function () { copy.classList.remove( 'done' ); }, 1200 ); } ); } );
				live.appendChild( copy );
				meta.appendChild( live );
			}
			if ( site.fatals_recent ) { meta.appendChild( el( 'span', { 'class': 'badge fatals', title: 'PHP fatal errors in debug.log today or yesterday — Logs tab, wp ' + site.name, text: site.fatals_recent + ( 1 === site.fatals_recent ? ' fatal' : ' fatals' ) } ) ); }
			var nameCell = el( 'td', { 'class': 'name' }, [
				el( 'div', { 'class': 'title' }, [ star, el( 'a', { href: 'https://' + host, target: '_blank', rel: 'noopener', text: host } ) ] ),
				meta
			] );
			// Actions: the things you do to a site.
			var actions = el( 'td', { 'class': 'actions' } );
			var group = el( 'div', { 'class': 'ic-group' } );
			actions.appendChild( group );
			group.appendChild( iconLink( 'open', 'Open ' + host, 'https://' + host ) );
			if ( site.wp ) {
				group.appendChild( iconLink( 'admin', 'Open wp-admin', 'https://' + host + '/wp-admin/' ) );
				var login = iconButton( 'login', 'Log in to wp-admin (one-time link)' );
				login.addEventListener( 'click', function () {
					login.disabled = true;
					post( 'login', { name: site.name } ).then( function ( r ) { login.disabled = false; if ( r && r.url ) { window.open( r.url, '_blank', 'noopener' ); } } );
				} );
				group.appendChild( login );
				var isShared = -1 !== sharing.indexOf( site.name );
				var shareBtn = iconButton( isShared ? 'stop' : 'share', isShared ? 'Stop sharing (public tunnel is up)' : 'Share publicly through a Cloudflare tunnel', isShared ? 'live' : '' );
				shareBtn.addEventListener( 'click', function () {
					shareBtn.disabled = true;
					post( 'share', isShared ? { op: 'stop', name: site.name } : { op: 'start', name: site.name } ).then( refresh );
				} );
				group.appendChild( shareBtn );
			}
			tbody.appendChild( el( 'tr', {}, [
				nameCell,
				el( 'td', { 'class': 'folder', title: site.path, text: ( site.path || '' ).replace( s.sites_dir, '~/Sites' ) } ),
				actions
			] ) );
		} );
		var total = s.sites.filter( function ( site ) { return 'dashboard' !== site.name && 'phpmyadmin' !== site.name; } ).length;
		$( 'sites-count' ).textContent = rows.length === total ? String( total ) : rows.length + ' of ' + total;
		renderSizes( s );
		var empty = $( 'sites-empty' );
		empty.hidden = rows.length > 0;
		empty.textContent = q ? 'No sites match “' + filterText.trim() + '”.' : 'No sites are linked yet. Run bin/site-new <name> to create one.';
	}

	function showError( msg ) {
		var bar = document.querySelector( '.error-bar' ) || document.querySelector( 'main' ).insertBefore( el( 'div', { 'class': 'error-bar', role: 'alert' } ), document.querySelector( 'main' ).firstChild );
		bar.textContent = msg;
		setTimeout( function () { if ( bar.parentNode ) { bar.parentNode.removeChild( bar ); } }, 8000 );
	}

	// Totals under the sites table + the button that starts a fresh du in the background.
	function renderSizes( s ) {
		var box = $( 'sizes' );
		box.textContent = '';
		var z = s.sizes || {};
		var parts = [];
		if ( z.files_total ) { parts.push( fmtBytes( z.files_total ) + ' in ~/Sites' ); }
		if ( z.db_total ) { parts.push( fmtBytes( z.db_total ) + ' in MySQL' ); }
		if ( z.computed_at ) { parts.push( 'folders measured ' + new Date( z.computed_at ).toLocaleString( [], { weekday: 'short', hour: '2-digit', minute: '2-digit' } ) ); }
		box.appendChild( el( 'span', { text: parts.length ? parts.join( '  ·  ' ) : 'Folder sizes not measured yet.' } ) );
		box.appendChild( document.createTextNode( ' ' ) );
		var b = el( 'button', { 'class': 'act quiet', type: 'button', text: 'Measure folders' } );
		b.addEventListener( 'click', function () {
			b.disabled = true; b.textContent = 'Measuring in the background…';
			post( 'sizes-refresh', {} ).then( function () { setTimeout( refresh, 90000 ); } );
		} );
		box.appendChild( b );
	}

	function render( s ) {
		last = s;
		$( 'summary' ).textContent = summary( s );
		renderAlert( s );
		renderUpgrades( s );
		renderShare( s );
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
	function setSort( bySize ) {
		sortBySize = bySize;
		localStorage.setItem( 'sites.sort', bySize ? 'size' : 'name' );
		if ( last ) { renderSites( last ); }
	}
	$( 'sort-size' ).addEventListener( 'click', function () { setSort( true ); } );
	$( 'sort-name' ).addEventListener( 'click', function () { setSort( false ); } );
	$( 'refresh' ).addEventListener( 'click', function () { refresh(); } );


	function fmtSize( b ) {
		if ( b < 1024 ) { return b + ' B'; }
		if ( b < 1048576 ) { return Math.round( b / 1024 ) + ' KB'; }
		if ( b < 1073741824 ) { return ( b / 1048576 ).toFixed( b < 10485760 ? 1 : 0 ) + ' MB'; }
		return ( b / 1073741824 ).toFixed( 1 ) + ' GB';
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

	// Public tunnel (bin/site-share): shown in the site's own row (renderSites), nothing up top.
	function renderShare( s ) { $( 'share' ).hidden = true; }
	function shareUrlFor( s, name ) {
		if ( ! s.share ) { return null; }
		var sites = s.share.sites || [ s.share.site ], urls = s.share.urls || [ s.share.url ];
		var i = sites.indexOf( name );
		return -1 === i ? null : ( urls[ i ] || urls[ 0 ] );
	}

	// Homebrew state of the stack (bin/stack-upgrade): what waits, what the last run did, and the nightly setting.
	var KIND = {
		major: { label: 'Major', order: 0, title: 'New major version: breaking changes are possible. Review before upgrading.' },
		minor: { label: 'Minor', order: 1, title: 'New features. Review before upgrading.' },
		patch: { label: 'Patch', order: 2, title: 'Bug and security fixes.' },
		rebuild: { label: 'Rebuild', order: 3, title: 'Same version, rebuilt by Homebrew against updated libraries.' }
	};
	function kindOf( a ) { return a.rebuild ? 'rebuild' : ( KIND[ a.kind ] ? a.kind : 'patch' ); }
	function when( iso ) { return new Date( iso ).toLocaleString( [], { weekday: 'short', hour: '2-digit', minute: '2-digit' } ); }
	function versionTable( head, rows ) {
		var tb = el( 'tbody' );
		rows.forEach( function ( r ) { tb.appendChild( el( 'tr', {}, r ) ); } );
		return el( 'table', { 'class': 'list' }, [
			el( 'thead', {}, [ el( 'tr', {}, head.map( function ( h ) { return el( 'th', { scope: 'col', 'class': h[ 1 ] || '', text: h[ 0 ] } ); } ) ) ] ),
			tb
		] );
	}

	function renderUpgrades( s ) {
		var u = s.upgrades || {};
		var avail = ( u.available || [] ).slice().sort( function ( a, b ) {
			return ( KIND[ kindOf( a ) ].order - KIND[ kindOf( b ) ].order ) || a.short.localeCompare( b.short );
		} );
		var review = avail.filter( function ( a ) { return 'patch' !== a.kind; } );
		var patches = avail.filter( function ( a ) { return 'patch' === a.kind; } );
		var run = u.last_run;
		var failed = ( run && run.failed ) || [];

		$( 'upg-checked' ).textContent = u.checked_at ? 'Homebrew releases for the stack. Checked ' + when( u.checked_at ) + '.' : 'Not checked yet.';
		$( 'upg-avail-count' ).textContent = avail.length ? String( avail.length ) : '';
		var count = $( 'upg-count' );
		count.textContent = String( avail.length );
		count.hidden = 0 === avail.length;
		navDot( 'upgrades', failed.length > 0 && Date.now() - Date.parse( run.at ) < 86400000 );

		var actions = $( 'upg-actions' );
		actions.textContent = '';
		if ( review.length ) { actions.appendChild( button( 'Upgrade all', 'primary', function () { return post( 'upgrade', { mode: 'all' } ); } ) ); }
		if ( patches.length ) { actions.appendChild( button( review.length ? 'Patches only' : 'Upgrade now', review.length ? '' : 'primary', function () { return post( 'upgrade', { mode: 'auto' } ); } ) ); }
		actions.appendChild( button( 'Check now', 'quiet', function () { return post( 'upgrade', { mode: 'check' } ); } ) );

		var cb = $( 'upg-auto' );
		cb.checked = 'off' !== ( u.auto || 'off' );
		cb.onchange = function () { post( 'upgrade-auto', { value: cb.checked ? 'patch' : 'off' } ).then( refresh ); };

		var box = $( 'upg-available' );
		box.textContent = '';
		if ( ! avail.length ) {
			box.appendChild( el( 'p', { 'class': 'empty-box', text: 'The stack is up to date.' } ) );
		} else {
			box.appendChild( versionTable( [ [ 'Package' ], [ 'Installed' ], [ '', 'arrow' ], [ 'Available' ], [ 'Change' ], [ 'Restarts', 'restarts' ] ], avail.map( function ( a ) {
				var k = kindOf( a );
				return [
					el( 'td', { 'class': 'pkg', text: a.short } ),
					el( 'td', { 'class': 'v', text: a.installed } ),
					el( 'td', { 'class': 'arrow', 'aria-hidden': 'true', text: '→' } ),
					el( 'td', { 'class': 'v to', text: a.current } ),
					el( 'td', {}, [ el( 'span', { 'class': 'kind ' + k, title: KIND[ k ].title, text: KIND[ k ].label } ) ] ),
					el( 'td', { 'class': 'restarts', title: 'Restarted after the upgrade when it is running', text: a.restarts || '—' } )
				];
			} ) ) );
		}

		var out = $( 'upg-run' );
		out.textContent = '';
		$( 'upg-run-meta' ).textContent = run && run.at ? when( run.at ) + ', ' + ( 'all' === run.mode ? 'everything outdated' : 'patch releases' ) : '';
		if ( ! run ) {
			out.appendChild( el( 'p', { 'class': 'empty-box', text: 'No upgrades have run yet.' } ) );
			return;
		}
		var rows = ( run.upgraded || [] ).map( function ( x ) {
			return [ el( 'td', { 'class': 'pkg', text: x.name } ), el( 'td', { 'class': 'v', text: x.from } ), el( 'td', { 'class': 'arrow', 'aria-hidden': 'true', text: '→' } ), el( 'td', { 'class': 'v to', text: x.to } ), el( 'td', { 'class': 'ok', text: 'Upgraded' } ) ];
		} ).concat( failed.map( function ( x ) {
			return [ el( 'td', { 'class': 'pkg', text: x.name } ), el( 'td', { 'class': 'v', text: '' } ), el( 'td', { 'class': 'arrow' } ), el( 'td', { 'class': 'v', text: '' } ), el( 'td', { 'class': 'bad', title: x.error || '', text: 'Failed' } ) ];
		} ) );
		if ( rows.length ) { out.appendChild( versionTable( [ [ 'Package' ], [ 'From' ], [ '', 'arrow' ], [ 'To' ], [ 'Result' ] ], rows ) ); }
		var restarted = run.restarted || [];
		out.appendChild( el( 'p', { 'class': 'run-note', text: ( rows.length ? '' : 'Nothing to upgrade. ' ) + ( restarted.length ? 'Restarted ' + restarted.join( ', ' ) + '.' : 'No running service needed a restart.' ) + ( failed.length ? ' Details: devstack logs upgrade.' : '' ) } ) );
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

	/* ---- Cleanup tab: databases no site owns (devstack cleanup) and MySQL's catalog (devstack mysql-compact) ---- */
	var cl = null;              // last ?api=cleanup answer
	var clTimer = null;
	var clSelected = {};        // run tag -> true
	var clSeen = false;         // the first load pre-ticks throwaway, idle, unpinned runs; later loads keep the person's choices
	var clArmed = null;         // 'drop' or 'compact' while a two-click confirm waits
	var clArmTimer = null;
	var clNotice = null;        // { text, error, load } shown above the strip; a load failure is cleared by the next good load, a drop result by the next action
	var clCompact = null;       // last ?api=mysql-compact answer
	var compactTimer = null;
	var compactStarted = 0;     // when Start was clicked: the state file appears a few seconds later

	function fmtIdle( sec ) {
		if ( sec < 5400 ) { return Math.max( 1, Math.round( sec / 60 ) ) + ' min'; }
		if ( sec < 172800 ) { return Math.round( sec / 3600 ) + ' h'; }
		return Math.round( sec / 86400 ) + ' d';
	}
	function fmtWhen( iso ) {
		if ( ! iso ) { return '–'; }
		return new Date( iso ).toLocaleString( [], { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' } );
	}
	function plural( n, one, many ) { return n + ' ' + ( 1 === n ? one : many ); }

	function postCleanup( op, names, extra ) {
		var data = new URLSearchParams();
		data.append( 'op', op );
		( names || [] ).forEach( function ( n ) { data.append( 'names[]', n ); } );
		Object.keys( extra || {} ).forEach( function ( k ) { data.append( k, extra[ k ] ); } );
		return fetch( '?api=cleanup', { method: 'POST', headers: { 'X-Devstack': '1' }, body: data } ).then( function ( r ) { return r.json(); } );
	}

	function selectedRuns() { return ( cl ? cl.runs : [] ).filter( function ( r ) { return clSelected[ r.tag ]; } ); }

	function arm( what ) { clArmed = what; clearTimeout( clArmTimer ); clArmTimer = setTimeout( disarm, 6000 ); updateDropButton(); renderCompact(); }
	function disarm() { clArmed = null; clearTimeout( clArmTimer ); updateDropButton(); renderCompact(); }

	function updateDropButton() {
		var b = $( 'cl-drop' ), note = $( 'cl-drop-note' ), sel = selectedRuns();
		var bytes = sel.reduce( function ( s, r ) { return s + r.files_bytes; }, 0 );
		var dbs = sel.reduce( function ( s, r ) { return s + r.databases.length; }, 0 );
		var unknown = sel.filter( function ( r ) { return 'throwaway' !== r.kind; } ).length;
		b.disabled = ! sel.length || busy;
		if ( 'drop' === clArmed ) {
			b.textContent = 'Click again to drop ' + plural( dbs, 'database', 'databases' ) + ' (' + fmtSize( bytes ) + ')';
			b.classList.add( 'armed' );
		} else {
			b.textContent = sel.length ? 'Drop ' + plural( dbs, 'database', 'databases' ) + ' selected' : 'Drop selected';
			b.classList.remove( 'armed' );
		}
		note.textContent = unknown ? plural( unknown, 'selected run is', 'selected runs are' ) + ' not recognised as throwaway: each database is dumped to ~/Backups/DevStack/_dropped first.' : '';
	}

	function renderCleanup() {
		var box = $( 'cl-runs' ), strip = $( 'cl-strip' ), note = $( 'cl-note' );
		note.hidden = ! clNotice;
		note.className = 'cl-note' + ( clNotice && clNotice.error ? ' err' : '' );
		note.textContent = clNotice ? clNotice.text : '';
		var warn = $( 'cl-warn' ), warnings = cl && cl.warnings ? cl.warnings : [];
		warn.hidden = ! warnings.length;
		warn.textContent = warnings.join( ' ' );
		box.textContent = '';
		strip.textContent = '';
		if ( ! cl ) { $( 'cl-count' ).textContent = ''; updateDropButton(); renderSweep(); renderCompact(); return; }
		[
			[ 'Disk free', fmtSize( cl.disk_free_bytes ) ],
			[ 'Databases', String( cl.mysql.databases ) ],
			[ 'No site owns', String( cl.mysql.unowned ) ],
			[ 'MySQL catalog', fmtSize( cl.mysql.catalog_bytes ) + ' (' + fmtSize( cl.mysql.catalog_free_bytes ) + ' free)' ]
		].forEach( function ( p ) {
			strip.appendChild( el( 'li', {}, [ el( 'span', { 'class': 'muted', text: p[ 0 ] } ), el( 'strong', { text: p[ 1 ] } ) ] ) );
		} );
		var runs = cl.runs, present = {};
		$( 'cl-count' ).textContent = runs.length ? '(' + plural( runs.length, 'run', 'runs' ) + ')' : '';
		runs.forEach( function ( r ) {
			present[ r.tag ] = r;
			if ( ! clSeen && 'throwaway' === r.kind && 'idle' === r.state && ! r.pinned ) { clSelected[ r.tag ] = true; }
		} );
		clSeen = true;
		Object.keys( clSelected ).forEach( function ( t ) {
			var r = present[ t ];
			if ( ! r || 'idle' !== r.state || r.pinned ) { delete clSelected[ t ]; }
		} );
		if ( ! runs.length ) {
			box.appendChild( el( 'p', { 'class': 'empty-box', text: 'No databases outside your sites. Nothing to clean up.' } ) );
		} else {
			var tbody = el( 'tbody' );
			runs.forEach( function ( r ) {
				var locked = 'locked' === r.state;
				var cb = el( 'input', { type: 'checkbox', 'aria-label': 'Select ' + r.tag } );
				cb.checked = !! clSelected[ r.tag ];
				cb.disabled = locked || r.pinned;
				cb.addEventListener( 'change', function () {
					if ( cb.checked ) { clSelected[ r.tag ] = true; } else { delete clSelected[ r.tag ]; }
					disarm();
				} );
				var looks = el( 'td', {}, [ el( 'span', { 'class': 'badge ' + ( 'throwaway' === r.kind ? 'throwaway' : 'unknown' ), text: r.kind } ) ] );
				if ( r.pinned ) { looks.appendChild( el( 'span', { 'class': 'badge pinned', text: 'pinned' } ) ); }
				var state = locked
					? el( 'span', { 'class': 'badge locked', title: 'connection' === r.locked_reason ? 'A client is connected' : 'Written to in the last 30 minutes', text: 'connection' === r.locked_reason ? 'in use' : 'just written' } )
					: el( 'span', { 'class': 'idle', text: 'idle ' + fmtIdle( r.idle_seconds ) } );
				var pin = el( 'button', { 'class': 'act quiet', type: 'button', text: r.pinned ? 'Unpin' : 'Pin' } );
				pin.addEventListener( 'click', function () {
					postCleanup( r.pinned ? 'unpin' : 'pin', [ r.tag ] ).then( function ( res ) {
						if ( res && res.error ) { showError( res.error ); }
					} ).catch( function ( e ) { showError( String( e ) ); } ).then( loadCleanup );
				} );
				tbody.appendChild( el( 'tr', {}, [
					el( 'td', { 'class': 'chk' }, [ cb ] ),
					el( 'td', { 'class': 'pkg' }, [ el( 'span', { text: r.tag } ), el( 'span', { 'class': 'count', text: r.lanes > 1 ? r.lanes + ' lanes' : '' } ) ] ),
					looks,
					el( 'td', { 'class': 'when', text: fmtWhen( r.created ) } ),
					el( 'td', { 'class': 'when', text: fmtWhen( r.last_write ) } ),
					el( 'td', {}, [ state ] ),
					el( 'td', { 'class': 'size', text: fmtSize( r.files_bytes ) } ),
					el( 'td', { 'class': 'restarts' }, [ pin ] )
				] ) );
			} );
			var head = el( 'tr', {}, [ '', 'Run', 'Looks', 'Created', 'Last write', 'State', 'Size', '' ].map( function ( h ) { return el( 'th', { scope: 'col', text: h } ); } ) );
			box.appendChild( el( 'table', { 'class': 'list cleanup' }, [ el( 'thead', {}, [ head ] ), tbody ] ) );
		}
		updateDropButton();
		renderSweep();
		renderCompact();
	}

	function renderSweep() {
		var box = $( 'cl-sweep' );
		if ( box.contains( document.activeElement ) && document.activeElement !== box ) { return; }   // do not rebuild under someone typing
		box.textContent = '';
		if ( ! cl ) { return; }
		var sw = cl.sweep, next = sw.next || [];
		var on = el( 'input', { type: 'checkbox', 'aria-label': 'Nightly sweep' } );
		on.checked = !! sw.enabled;
		var hours = el( 'input', { type: 'number', min: '1', max: '99999', value: String( sw.older_than_hours ), 'class': 'cl-hours', 'aria-label': 'Hours without a write before the sweep drops a lane database' } );
		box.appendChild( el( 'label', { 'class': 'upg-auto' }, [ on, document.createTextNode( ' Drop idle parallel-lane test databases every night at 03:00, after ' ), hours, document.createTextNode( ' hours without a write.' ) ] ) );
		on.addEventListener( 'change', function () {
			post( 'cleanup', { op: 'sweep', value: on.checked ? 'on' : 'off' } ).then( function ( r ) { if ( r && r.error ) { showError( r.error ); } } ).catch( function ( e ) { showError( String( e ) ); } ).then( loadCleanup );
		} );
		hours.addEventListener( 'change', function () {
			var v = parseInt( hours.value, 10 );
			if ( ! ( v >= 1 ) ) { hours.value = String( sw.older_than_hours ); return; }
			post( 'cleanup', { op: 'sweep', value: String( v ) } ).then( function ( r ) { if ( r && r.error ) { showError( r.error ); } } ).catch( function ( e ) { showError( String( e ) ); } ).then( loadCleanup );
		} );
		box.appendChild( el( 'p', { 'class': 'hint', text: 'Only databases whose name ends in _single_N or _multisite_N and that have a test options table. Never a site’s, one in use, an unrecognised one or a pinned run. Each drop is logged in ~/Library/Logs/DevStack/cleanup-sweep.log.' } ) );
		box.appendChild( el( 'p', { text: next.length
			? ( sw.enabled ? 'Tonight’s sweep drops: ' : 'With the sweep on, it would drop now: ' ) + next.join( ', ' ) + '.'
			: 'Nothing is idle long enough for the sweep right now.' } ) );
	}

	function loadCompact() {
		clearTimeout( compactTimer );
		fetch( '?api=mysql-compact', { cache: 'no-store' } ).then( function ( r ) { return r.json(); } ).then( function ( d ) {
			clCompact = d;
			renderCompact();
			var starting = compactStarted && Date.now() - compactStarted < 20000 && ! d.step;
			var running = d.step && 'verify' !== d.step && ! d.done;
			if ( ( running || starting ) && 'cleanup' === currentTab && ! document.hidden ) { compactTimer = setTimeout( loadCompact, 3000 ); }
		} ).catch( function () {} );
	}

	function compactCall( op ) {
		busy = true;
		post( 'mysql-compact', { op: op } ).then( function ( r ) {
			if ( r && r.error ) { showError( r.error ); } else if ( 'start' === op ) { compactStarted = Date.now(); }
		} ).catch( function ( e ) { showError( String( e ) ); } ).then( function () { busy = false; loadCompact(); loadCleanup(); } );
	}

	function renderCompact() {
		var box = $( 'cl-compact' );
		box.textContent = '';
		var m = cl && cl.mysql, st = clCompact || { step: null, done: false };
		var running = st.step && 'verify' !== st.step && ! st.done;
		var waiting = 'verify' === st.step && ! st.done;
		var starting = compactStarted && Date.now() - compactStarted < 20000 && ! st.step;
		box.appendChild( el( 'p', { 'class': 'hint', text: 'MySQL keeps the space of every table it ever held and never gives it back; dropping databases does not change that. Compacting dumps everything, starts a fresh data folder and restores it. MySQL is down for minutes, so every site and test run fails meanwhile.' } ) );
		if ( m ) {
			box.appendChild( el( 'p', { text: 'Catalog file: ' + fmtSize( m.catalog_bytes ) + ', of which ' + fmtSize( m.catalog_free_bytes ) + ' is free space a compaction gives back.' } ) );
			var throwaway = cl.runs.filter( function ( r ) { return 'throwaway' === r.kind; } ).reduce( function ( s, r ) { return s + r.databases.length; }, 0 );
			if ( throwaway ) { box.appendChild( el( 'p', { 'class': 'hint', text: plural( throwaway, 'throwaway database', 'throwaway databases' ) + ' would be dumped and restored too: drop them first.' } ) ); }
		}
		if ( running || starting ) {
			box.appendChild( el( 'p', { text: starting ? 'Starting…' : 'Running. Last completed step: ' + st.step + '. MySQL will be down for part of this.' } ) );
		} else if ( waiting ) {
			var fin = el( 'button', { 'class': 'act primary', type: 'button', text: 'Finish: delete the old data folder' } );
			var back = el( 'button', { 'class': 'act', type: 'button', text: 'Roll back' } );
			fin.addEventListener( 'click', function () { if ( ! busy ) { compactCall( 'finish' ); } } );
			back.addEventListener( 'click', function () { if ( ! busy ) { compactCall( 'rollback' ); } } );
			box.appendChild( el( 'p', { text: 'Compacted and checked: schema, table and user counts match. The old data folder is kept until you finish, which is when the space comes back.' } ) );
			box.appendChild( el( 'div', { 'class': 'row-actions' }, [ fin, back ] ) );
		} else {
			if ( st.done ) { box.appendChild( el( 'p', { text: 'The last compaction finished.' } ) ); }
			else if ( compactStarted && ! st.step ) { box.appendChild( el( 'p', { 'class': 'hint', text: 'It did not start: see ~/Library/Logs/DevStack/mysql-compact.log (most often another client is connected to MySQL).' } ) ); }
			var go = el( 'button', { 'class': 'act' + ( 'compact' === clArmed ? ' armed' : '' ), type: 'button', text: 'compact' === clArmed ? 'Click again: MySQL goes down now' : 'Compact MySQL…' } );
			go.addEventListener( 'click', function () {
				if ( busy ) { return; }
				if ( 'compact' !== clArmed ) { arm( 'compact' ); return; }
				disarm();
				compactStarted = 0;
				compactCall( 'start' );
			} );
			box.appendChild( el( 'div', { 'class': 'row-actions' }, [ go ] ) );
		}
	}

	function loadCleanup() {
		clearTimeout( clTimer );
		if ( 'cleanup' !== currentTab ) { return; }
		fetch( '?api=cleanup', { cache: 'no-store' } ).then( function ( r ) { return r.json(); } ).then( function ( d ) {
			if ( d && d.runs ) { cl = d; if ( clNotice && clNotice.load ) { clNotice = null; } } else { cl = null; clNotice = { error: true, load: true, text: d && d.error ? 'Cleanup: ' + d.error + '.' : 'Could not read the databases.' }; }
		} ).catch( function () { cl = null; clNotice = { error: true, load: true, text: 'Could not reach the dashboard backend.' }; } ).then( function () {
			renderCleanup();
			clTimer = setTimeout( function () { if ( ! document.hidden ) { loadCleanup(); } else { loadCleanupLater(); } }, REFRESH_MS );
		} );
		loadCompact();
	}
	function loadCleanupLater() { clTimer = setTimeout( function () { if ( ! document.hidden ) { loadCleanup(); } else { loadCleanupLater(); } }, REFRESH_MS ); }

	$( 'cl-refresh' ).addEventListener( 'click', function () { clNotice = null; loadCleanup(); } );
	function setNote( n ) {
		clNotice = n;
		var note = $( 'cl-note' );
		note.hidden = ! n;
		note.className = 'cl-note' + ( n && n.error ? ' err' : '' );
		note.textContent = n ? n.text : '';
	}

	// Databases per request. nginx gives a request 60 s, so dropping hundreds in one POST would end in a 504 while the
	// server went on dropping, and the person would click again. Names, not run tags, so one big run is split too: the
	// drop guard judges every name by its run, so a locked or pinned run is still refused whole.
	var DROP_BATCH = 25;
	function dropRuns( runs ) {
		var names = [], batches = [], done = 0, freed = 0, dropped = 0, refused = [], failure = null, i;
		runs.forEach( function ( r ) { r.databases.forEach( function ( d ) { names.push( d ); } ); } );
		for ( i = 0; i < names.length; i += DROP_BATCH ) { batches.push( names.slice( i, i + DROP_BATCH ) ); }
		return batches.reduce( function ( chain, batch ) {
			return chain.then( function () {
				if ( failure ) { return; }
				setNote( { error: false, text: 'Dropping… ' + done + ' of ' + plural( names.length, 'database', 'databases' ) + ' done.' } );
				return postCleanup( 'drop', batch ).then( function ( res ) {
					if ( ! res || ! res.dropped ) { failure = ( res && res.error ) || 'The drop failed.'; return; }
					dropped += res.dropped.length; freed += res.freed_bytes; refused = refused.concat( res.refused ); done += batch.length;
				} ).catch( function ( e ) { failure = String( e ); } );
			} );
		}, Promise.resolve() ).then( function () {
			var shown = refused.slice( 0, 5 ).map( function ( x ) { return x.name + ' (' + x.reason + ')'; } ).join( ', ' );
			var tail = refused.length ? ' Refused ' + refused.length + ': ' + shown + ( refused.length > 5 ? ' and ' + ( refused.length - 5 ) + ' more' : '' ) + '.' : '';
			var did = 'Dropped ' + plural( dropped, 'database', 'databases' ) + ', freed ' + fmtSize( freed ) + '.';
			setNote( failure ? { error: true, text: did + ' Stopped: ' + failure + tail } : { error: refused.length > 0, text: did + tail } );
		} );
	}

	$( 'cl-drop' ).addEventListener( 'click', function () {
		var sel = selectedRuns();
		if ( ! sel.length || busy ) { return; }
		if ( 'drop' !== clArmed ) { arm( 'drop' ); return; }
		disarm();
		busy = true;
		updateDropButton();
		dropRuns( sel ).then( function () {
			busy = false;
			clSelected = {};
			loadCleanup();
		} );
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
