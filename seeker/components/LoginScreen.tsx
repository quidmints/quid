/**
 * LoginScreen.tsx
 *
 * QU!D entry screen. Connects via Mobile Wallet Adapter, derives the
 * Ethereum cross-chain key, and navigates to the main app on success.
 * TODO we dont need to derive an ethereum cross chain key, the user's
 * phantom should already have both existing ethereum address and solana key
 * Route: app/index.tsx (Expo Router) → renders this component.
 */

import React, { useEffect } from "react";
import {
  ActivityIndicator,
  Pressable,
  StyleSheet,
  Text,
  View,
} from "react-native";
import { useRouter } from "expo-router";
import { useAuth } from "../hooks/useAuth";

// ── Status label map ──────────────────────────────────────────────────────────

const STATUS_LABEL: Record<string, string> = {
  idle: "Connect wallet to continue",
  connecting: "Opening wallet…",
  deriving: "Deriving cross-chain keys…",
  registering: "Registering device on-chain…",
  ready: "Authenticated",
  error: "Connection failed",
};

// ── Component ─────────────────────────────────────────────────────────────────

export default function LoginScreen() {
  const router = useRouter();
  const { status, walletAddress, ethKey, deviceSeedHex, error, connect } =
    useAuth();

  const isLoading = ["connecting", "deriving", "registering"].includes(status);

  // Navigate to home once auth is complete
  useEffect(() => {
    if (status === "connected" || status === "ready") {
      router.replace("/home");
    }
  }, [status, router]);

  return (
    <View style={styles.container}>
      {/* Logo / title */}
      <View style={styles.header}>
        <Text style={styles.title}>QU!D</Text>
        <Text style={styles.subtitle}>
          Synthetic exposure, collateralised on Solana
        </Text>
      </View>

      {/* Status area */}
      <View style={styles.statusArea}>
        {isLoading ? (
          <>
            <ActivityIndicator size="large" color="#9945FF" />
            <Text style={styles.statusText}>
              {STATUS_LABEL[status] ?? "Working…"}
            </Text>
          </>
        ) : status === "error" ? (
          <>
            <Text style={styles.errorText}>⚠ {error}</Text>
            <Text style={styles.hintText}>
              Make sure a Solana wallet (Phantom / Solflare) is installed.
            </Text>
          </>
        ) : (
          <Text style={styles.statusText}>{STATUS_LABEL[status]}</Text>
        )}
      </View>

      {/* Debug info — dev only */}
      {__DEV__ && walletAddress && (
        <View style={styles.debugBox}>
          <Text style={styles.debugLabel}>Wallet</Text>
          <Text style={styles.debugValue} numberOfLines={1}>
            {walletAddress}
          </Text>
          {deviceSeedHex && (
            <>
              <Text style={styles.debugLabel}>
                Device Seed (PDA, 32 bytes)
              </Text>
              <Text style={styles.debugValue} numberOfLines={1}>
                {deviceSeedHex}
              </Text>
            </>
          )}
          {ethKey && (
            <>
              <Text style={styles.debugLabel}>ETH Address</Text>
              <Text style={styles.debugValue} numberOfLines={1}>
                {ethKey.ethAddress}
              </Text>
            </>
          )}
        </View>
      )}

      {/* Connect button */}
      {!isLoading && status !== "ready" && (
        <Pressable
          style={({ pressed }) => [
            styles.connectButton,
            pressed && styles.connectButtonPressed,
          ]}
          onPress={connect}
          accessibilityRole="button"
          accessibilityLabel="Connect Solana wallet"
        >
          <Text style={styles.connectButtonText}>Connect Wallet</Text>
        </Pressable>
      )}

      <Text style={styles.footer}>Powered by Solana + LayerZero</Text>
    </View>
  );
}

// ── Styles ────────────────────────────────────────────────────────────────────

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: "#0a0a0f",
    alignItems: "center",
    justifyContent: "center",
    paddingHorizontal: 28,
    gap: 28,
  },
  header: {
    alignItems: "center",
    gap: 8,
  },
  title: {
    fontSize: 52,
    fontWeight: "800",
    color: "#ffffff",
    letterSpacing: 4,
  },
  subtitle: {
    fontSize: 13,
    color: "#888",
    textAlign: "center",
    lineHeight: 18,
  },
  statusArea: {
    alignItems: "center",
    minHeight: 64,
    gap: 12,
    justifyContent: "center",
  },
  statusText: {
    color: "#aaa",
    fontSize: 15,
  },
  errorText: {
    color: "#ff6b6b",
    fontSize: 15,
    textAlign: "center",
  },
  hintText: {
    color: "#666",
    fontSize: 12,
    textAlign: "center",
    maxWidth: 280,
  },
  connectButton: {
    backgroundColor: "#9945FF",
    paddingVertical: 16,
    paddingHorizontal: 48,
    borderRadius: 12,
    width: "100%",
    alignItems: "center",
    shadowColor: "#9945FF",
    shadowOpacity: 0.45,
    shadowRadius: 16,
    shadowOffset: { width: 0, height: 6 },
    elevation: 8,
  },
  connectButtonPressed: {
    opacity: 0.8,
    transform: [{ scale: 0.98 }],
  },
  connectButtonText: {
    color: "#fff",
    fontSize: 17,
    fontWeight: "700",
    letterSpacing: 0.5,
  },
  debugBox: {
    backgroundColor: "#111",
    borderRadius: 8,
    padding: 12,
    width: "100%",
    gap: 2,
    borderWidth: 1,
    borderColor: "#222",
  },
  debugLabel: {
    color: "#555",
    fontSize: 10,
    textTransform: "uppercase",
    letterSpacing: 1,
    marginTop: 6,
  },
  debugValue: {
    color: "#14F195",
    fontSize: 11,
    fontFamily: "monospace",
  },
  footer: {
    color: "#333",
    fontSize: 11,
    position: "absolute",
    bottom: 32,
  },
});
