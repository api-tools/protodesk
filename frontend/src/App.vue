<script setup lang="ts">
import ServerTopBar from '@/components/ServerTopBar.vue'
</script>

<template>
  <div class="app">
    <ServerTopBar />
    <main>
      <!-- 3-column layout will be implemented here -->
      <router-view></router-view>
    </main>
  </div>
</template>

<style>
.app {
  font-family: 'Nunito', sans-serif;
  -webkit-font-smoothing: antialiased;
  -moz-osx-font-smoothing: grayscale;
  height: 100vh;
  display: flex;
  flex-direction: column;
  font-size: 0.8rem;
}

main {
  flex: 1;
  min-height: 0;
  display: flex;
  flex-direction: column;
  height: 100%;
  overflow: hidden;
}
</style>
