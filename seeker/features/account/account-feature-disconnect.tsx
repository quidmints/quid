import { Button } from 'react-native'
import React from 'react'
import { useWallet } from '@/hooks/useWallet'

export function AccountFeatureDisconnect() {
  const { account, disconnect } = useWallet()

  return <Button disabled={!account} title="Disconnect" onPress={disconnect} />
}
