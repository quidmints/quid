import { createContext, ReactNode, useMemo, useState } from 'react'
import { AppConfig, SolanaCluster } from '@/constants/app-config'

export interface NetworkProviderContextValue {
  getExplorerUrl(path: string): string
  networks: SolanaCluster[]
  selectedNetwork: SolanaCluster
  setSelectedNetwork: (network: SolanaCluster) => void
}

export const NetworkProviderContext = createContext<NetworkProviderContextValue>({} as NetworkProviderContextValue)

export function NetworkProvider({ children }: { children: ReactNode }) {
  const [selectedNetwork, setSelectedNetwork] = useState<SolanaCluster>(AppConfig.networks[0])
  const value: NetworkProviderContextValue = useMemo(
    () => ({
      selectedNetwork,
      networks: [...AppConfig.networks].sort((a, b) => a.label.localeCompare(b.label)),
      setSelectedNetwork: (network: SolanaCluster) => setSelectedNetwork(network),
      getExplorerUrl: (path: string) => `https://explorer.solana.com/${path}${getExplorerUrlParam(selectedNetwork)}`,
    }),
    [selectedNetwork],
  )
  return <NetworkProviderContext.Provider value={value}>{children}</NetworkProviderContext.Provider>
}

function getExplorerUrlParam(network: SolanaCluster): string {
  switch (network.id) {
    case 'solana:devnet':
      return `?cluster=devnet`
    case 'solana:testnet':
      return `?cluster=testnet`
    case 'solana:localnet':
      return `?cluster=custom&customUrl=${encodeURIComponent(network.url)}`
    default:
      return ''
  }
}
