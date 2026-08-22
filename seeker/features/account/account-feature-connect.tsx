import { Button } from 'react-native'
import React from 'react'
import { useWallet } from '@/hooks/useWallet'

export function AccountFeatureConnect() {
  const { account, connect } = useWallet()

  return <Button disabled={!!account} title="Connect" onPress={connect} />
}
