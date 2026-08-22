const { getDefaultConfig } = require('expo/metro-config')

const config = getDefaultConfig(__dirname)

// Enable package.json "exports" field resolution.
// Required for @noble/hashes, @noble/curves, @noble/ciphers subpath imports
// e.g. '@noble/hashes/sha256', '@noble/curves/p256'
config.resolver.unstable_enablePackageExports = true

module.exports = config
