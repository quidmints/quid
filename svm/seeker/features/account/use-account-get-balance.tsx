import { useQuery } from '@tanstack/react-query'
import { PublicKey } from '@solana/web3.js'
import { useWallet } from '@/hooks/useWallet'

export function useAccountGetBalance({ address }: { address: PublicKey }) {
  const { chain, connection } = useWallet()
  return useQuery({
    queryKey: ['get-balance', chain, address.toString()],
    queryFn: () => connection.getBalance(address),
  })
}
