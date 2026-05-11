/** @type {import('next').NextConfig} */
const nextConfig = {
  output: 'standalone',
  reactStrictMode: true,
  webpack: (config) => {
    config.watchOptions = {
      ...config.watchOptions,
      ignored: ['**/node_modules/**', '**/evm/**', '**/svm/**'],
    }
    // borsh references text-encoding-utf-8 + encoding for legacy Node support.
    // Modern Node has TextEncoder/TextDecoder built in, so these can be marked
    // false (resolved to empty modules at build time).
    config.resolve = config.resolve || {}
    config.resolve.fallback = {
      ...(config.resolve.fallback || {}),
      'text-encoding-utf-8': false,
      'encoding': false,
      // @coral-xyz/anchor's workspace module references these for the Node
      // CLI side (reading Anchor.toml). The frontend never executes that
      // codepath but webpack still tries to resolve the imports. Setting
      // false makes them no-ops in the browser bundle.
      'toml': false,
      'fs': false,
      'path': false,
    }
    return config
  },
}

module.exports = nextConfig
