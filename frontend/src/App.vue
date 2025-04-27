<script setup lang="ts">
// App component using Vue Router
</script>

<template>
  <div class="app">
    <nav>
      <router-link to="/">Home</router-link>
      <router-link to="/proto-definitions">Proto Definitions</router-link>
    </nav>
    <main>
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
}

nav {
  padding: 1rem;
  background-color: #f8f9fa;
  border-bottom: 1px solid #ddd;
}

nav a {
  color: #2c3e50;
  text-decoration: none;
  padding: 0.5rem 1rem;
}

nav a.router-link-active {
  color: #42b983;
}

main {
  flex: 1;
  overflow-y: auto;
}
</style>
