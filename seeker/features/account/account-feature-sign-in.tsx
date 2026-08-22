import { PublicKey } from '@solana/web3.js'
import { Button, View } from 'react-native'
import { appStyles } from '@/constants/app-styles'
import { useWallet } from '@/hooks/useWallet'

export function AccountFeatureSignIn({ address }: { address: PublicKey }) {
  const { signIn } = useWallet()
  async function submit() {
    try {
      await signIn()
      console.log('Signed in!')
    } catch (e) {
      console.log(`Error signing in: ${e}`)
    }
  }
  return (
    <View style={appStyles.stack}>
      <Button onPress={submit} title="Sign In" />
    </View>
  )
}
