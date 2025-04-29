<script setup lang="ts">
import ServerTopBar from '@/components/ServerTopBar.vue'
import StatusBar from './components/StatusBar.vue'
import { ref, computed } from 'vue'
import { useServerProfileStore } from '@/stores/serverProfile'

const profileStore = useServerProfileStore()
const profiles = computed(() => profileStore.profiles)
const selectedProfileId = computed(() => profileStore.activeProfile?.id ?? undefined)
const connectionStatus = ref<'connected' | 'not_connected' | 'unknown'>('unknown')

// Optionally, you may want to update connectionStatus based on your app logic
</script>

<template>
  <div id="app" class="app flex flex-col min-h-screen h-screen w-full">
    <ServerTopBar />
    <main class="flex-1 flex flex-col min-h-0">
      <router-view />
    </main>
    <StatusBar :connection-status="connectionStatus" :selected-profile-id="selectedProfileId" :profiles="profiles" />
  </div>
</template>

<style>
.app {
  font-family: 'Nunito', sans-serif;
  -webkit-font-smoothing: antialiased;
  -moz-osx-font-smoothing: grayscale;
  min-height: 100vh;
  height: 100vh;
  display: flex;
  flex-direction: column;
  font-size: 0.8rem;
}

main {
  flex: 1 1 0%;
  min-height: 0;
  display: flex;
  flex-direction: column;
}
</style>
