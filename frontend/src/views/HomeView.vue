<script setup lang="ts">
import { ref } from 'vue'
import { Greet } from '@wailsjs/go/app/App'

const name = ref('')
const resultText = ref('')

async function greet() {
  resultText.value = await Greet(name.value)
}
</script>

<template>
  <div class="home">
    <h1>Welcome to ProtoDesk</h1>
    <div class="input-box">
      <input v-model="name" type="text" placeholder="Enter your name" @keyup.enter="greet">
      <button @click="greet">Greet</button>
    </div>
    <div class="result" v-if="resultText">{{ resultText }}</div>
  </div>
</template>

<style scoped>
.home {
  text-align: center;
  padding: 2rem;
}

.input-box {
  margin: 1rem 0;
}

input {
  padding: 0.5rem;
  margin-right: 0.5rem;
  border: 1px solid #ddd;
  border-radius: 4px;
}

button {
  padding: 0.5rem 1rem;
  background-color: #4CAF50;
  color: white;
  border: none;
  border-radius: 4px;
  cursor: pointer;
}

button:hover {
  background-color: #45a049;
}

.result {
  margin-top: 1rem;
  padding: 1rem;
  background-color: #f8f9fa;
  border-radius: 4px;
}
</style>
