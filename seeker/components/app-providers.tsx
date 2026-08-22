import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { PropsWithChildren } from 'react'
import { NetworkProvider } from '@/features/network/network-provider'
import { WalletProvider } from '@/context/WalletProvider'
import { useNetwork } from '@/features/network/use-network'

const queryClient = new QueryClient()

export function AppProviders({ children }: PropsWithChildren) {
  return (
    <QueryClientProvider client={queryClient}>
      <NetworkProvider>
        <SolanaNetworkProvider>{children}</SolanaNetworkProvider>
      </NetworkProvider>
    </QueryClientProvider>
  )
}

function SolanaNetworkProvider({ children }: PropsWithChildren) {
  const { selectedNetwork } = useNetwork()
  return (
    <WalletProvider chain={selectedNetwork.id} endpoint={selectedNetwork.url}>
      {children}
    </WalletProvider>
  )
}
