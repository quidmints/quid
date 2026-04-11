/** @type {import('next').NextConfig} */
const nextConfig = {
  output: 'standalone',
  reactStrictMode: true,
  webpack: (config) => {
    config.watchOptions = {
      ...config.watchOptions,
      ignored: ['**/node_modules/**', '**/evm/**', '**/svm/**'],
    }
    return config
  },
}

module.exports = nextConfig
