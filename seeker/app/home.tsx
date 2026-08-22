import { useRouter } from 'expo-router'
import { useAuth } from '@/hooks/useAuth'
import { useWallet } from '@/hooks/useWallet'
import HomeScreen from '@/components/HomeScreen'
import { View, ActivityIndicator } from 'react-native'

export default function HomeRoute() {
  const router = useRouter()
  const { walletAddress } = useAuth()
  const { disconnect } = useWallet()

  const handleDisconnect = async () => {
    await disconnect()
    router.replace('/')
  }

  if (!walletAddress) {
    return (
      <View style={{ flex: 1, alignItems: 'center', justifyContent: 'center', backgroundColor: '#0a0a0f' }}>
        <ActivityIndicator color="#9945FF" />
      </View>
    )
  }

  return <HomeScreen walletAddress={walletAddress} onDisconnect={handleDisconnect} />
}
