import { useQuery } from '@tanstack/react-query'
import { useWallet } from '@/hooks/useWallet'

export function useNetworkGetGenesisHash() {
  const { chain, connection } = useWallet()
  return useQuery({
    queryKey: ['getGenesisHash', chain],
    queryFn: () => connection.getGenesisHash(),
  })
}
