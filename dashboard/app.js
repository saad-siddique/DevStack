/* local-devstack dashboard — reads ?api=status every 5 s, sends actions with the X-Devstack header. */
(function () {
	'use strict';

	var SERVICE_ORDER = [ 'nginx', 'dnsmasq', 'php@8.4', 'php@7.4', 'mysql@8.4', 'mailpit' ];
	var LABELS = { 'nginx': 'nginx', 'dnsmasq': 'dnsmasq', 'php@8.4': 'PHP 8.4', 'php@7.4': 'PHP 7.4', 'mysql@8.4': 'MySQL 8.4', 'mailpit': 'Mailpit' };
	var ROLES  = { 'nginx': 'web server', 'dnsmasq': '.test DNS', 'php@8.4': 'php-fpm', 'php@7.4': 'php-fpm', 'mysql@8.4': 'database', 'mailpit': 'mail catcher' };
	var REFRESH_MS = 5000;
	var busy = false;
	var timer = null;
	var last = null;
	var filterText = '';

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
		var php = s.services.filter( function ( x ) { return /^php@/.test( x.name ) && 'started' === x.status; } ).map( function ( x ) { return x.name.replace( 'php@', '' ); } );
		var parts = [ sites + ( 1 === sites ? ' site' : ' sites' ) ];
		if ( php.length ) { parts.push( 'PHP ' + php.join( ' and ' ) ); }
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
			var state = on ? role + 'running' + ( svc.user ? ' as ' + svc.user : '' ) : role + ( 'none' === svc.status ? 'stopped' : svc.status );
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

		var xd = $( 'xdebug' );
		xd.textContent = '';
		Object.keys( s.xdebug || {} ).sort().reverse().forEach( function ( v ) {
			var on = true === s.xdebug[ v ];
			var actions = el( 'span', { 'class': 'actions' }, [
				button( on ? 'Turn off' : 'Turn on', on ? 'quiet' : 'primary', function () { return post( 'xdebug', { php: v, op: on ? 'off' : 'on' } ); } )
			] );
			xd.appendChild( el( 'li', { 'class': 'svc' }, [
				el( 'span', { 'class': 'lamp' + ( on ? ' on' : '' ), 'aria-hidden': 'true' } ),
				el( 'span', { 'class': 'svc-name', text: 'Xdebug for PHP ' + v }, [ el( 'span', { 'class': 'svc-state', text: on ? 'on, waits for a trigger on port 9003' : 'off, no overhead' } ) ] ),
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
		var ports = Object.keys( s.ports || {} ).map( function ( p ) { return p + ' ' + ( s.ports[ p ] || 'free' ); } ).join( ', ' );
		list.appendChild( el( 'li', { text: 'Ports: ' + ports } ) );
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
		renderServices( s );
		renderTools( s );
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

	$( 'filter' ).addEventListener( 'input', function ( e ) {
		filterText = e.target.value;
		if ( last ) { renderSites( last ); }
	} );
	document.addEventListener( 'visibilitychange', function () { if ( ! document.hidden ) { refresh(); } } );
	refresh();
}() );
