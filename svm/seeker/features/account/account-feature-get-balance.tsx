import { Text } from 'react-native'
import { PublicKey } from '@solana/web3.js'
import { useAccountGetBalance } from './use-account-get-balance'

export function AccountFeatureGetBalance({ address }: { address: PublicKey }) {
  const { data, isLoading } = useAccountGetBalance({ address })
  const sol = data != null ? (data / 1e9).toFixed(4) : '—'
  return <Text>Balance: {isLoading ? 'Loading…' : `${sol} SOL`}</Text>
}
