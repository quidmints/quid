import { PublicKey } from '@solana/web3.js'
import { Button, View } from 'react-native'
import { appStyles } from '@/constants/app-styles'
import { useWallet } from '@/hooks/useWallet'

export function AccountFeatureSignMessage({ address }: { address: PublicKey }) {
  const { signMessage } = useWallet()
  async function submit() {
    try {
      const msg = new TextEncoder().encode(`Signing a message with ${address.toString()}`)
      await signMessage(msg)
      console.log('Message signed!')
    } catch (e) {
      console.log(`Error signing message: ${e}`)
    }
  }
  return (
    <View style={appStyles.stack}>
      <Button onPress={submit} title="Sign Message" />
    </View>
  )
}
