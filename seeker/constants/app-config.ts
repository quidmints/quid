export interface SolanaCluster {
  id: string
  label: string
  url: string
}

export class AppConfig {
  static name = 'QU!D'
  static uri = 'https://quid.so'
  static networks: SolanaCluster[] = [
    {
      id: 'solana:devnet',
      label: 'Devnet',
      url: 'https://api.devnet.solana.com',
    },
    {
      id: 'solana:testnet',
      label: 'Testnet',
      url: 'https://api.testnet.solana.com',
    },
    {
      // adb reverse tcp:8899 tcp:8899 — forwards device localhost to Mac validator
      id: 'solana:localnet',
      label: 'Localnet',
      url: 'http://localhost:8899',
    },
  ]
}
