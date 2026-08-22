import { useQuery } from '@tanstack/react-query'
import { useWallet } from '@/hooks/useWallet'

export function useNetworkGetVersion() {
  const { chain, connection } = useWallet()
  return useQuery({
    queryKey: ['getVersion', chain],
    queryFn: () =>
      connection.getVersion().then((version) => ({
        core: version['solana-core'],
        features: version['feature-set'],
      })),
  })
}
