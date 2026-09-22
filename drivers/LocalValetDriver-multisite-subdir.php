<?php
/**
 * Valet driver for a WordPress subdirectory multisite.
 * Mirrors the two rewrite rules WordPress core generates for subdirectory installs.
 * Installed by local-devstack as <site>/LocalValetDriver.php.
 */
class LocalValetDriver extends WordPressValetDriver {

	/**
	 * Strip the sub-site prefix from core paths: /automator/wp-admin/x -> /wp-admin/x
	 */
	private function strip_subsite_prefix( string $uri ): string {
		$uri = preg_replace( '#^/[_0-9a-zA-Z-]+(/wp-(content|admin|includes)/.*)$#', '$1', $uri );
		return preg_replace( '#^/[_0-9a-zA-Z-]+(/.*\.php)$#', '$1', $uri );
	}

	public function isStaticFile( $sitePath, $siteName, $uri ) {
		return parent::isStaticFile( $sitePath, $siteName, $this->strip_subsite_prefix( $uri ) );
	}

	public function frontControllerPath( $sitePath, $siteName, $uri ) {
		return parent::frontControllerPath( $sitePath, $siteName, $this->strip_subsite_prefix( $uri ) );
	}
}
