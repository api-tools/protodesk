<script setup lang="ts">
import { ref, onMounted } from 'vue'
import { Greet } from '@wailsjs/go/app/App'
import { useServerProfileStore } from '@/stores/serverProfile'

const name = ref('')
const resultText = ref('')

async function greet() {
  resultText.value = await Greet(name.value)
}

// Server profile form
const profileStore = useServerProfileStore()
const newProfile = ref({
  name: '',
  host: '',
  port: 50051,
  tlsEnabled: false,
  certificatePath: ''
})

const editingProfileId = ref<string | null>(null)
const editProfileData = ref({
  name: '',
  host: '',
  port: 50051,
  tlsEnabled: false,
  certificatePath: ''
})

function addProfile() {
  if (!newProfile.value.name || !newProfile.value.host || !newProfile.value.port) return
  profileStore.addProfile({
    id: Date.now().toString(),
    name: newProfile.value.name,
    host: newProfile.value.host,
    port: Number(newProfile.value.port),
    tlsEnabled: newProfile.value.tlsEnabled,
    certificatePath: newProfile.value.certificatePath || undefined,
    createdAt: new Date(),
    updatedAt: new Date()
  })
  newProfile.value = { name: '', host: '', port: 50051, tlsEnabled: false, certificatePath: '' }
}

function removeProfile(id: string) {
  profileStore.removeProfile(id)
}

function startEditProfile(profile: any) {
  editingProfileId.value = profile.id
  editProfileData.value = {
    name: profile.name,
    host: profile.host,
    port: profile.port,
    tlsEnabled: profile.tlsEnabled,
    certificatePath: profile.certificatePath || ''
  }
}

function saveEditProfile(id: string) {
  profileStore.updateProfile(id, {
    name: editProfileData.value.name,
    host: editProfileData.value.host,
    port: Number(editProfileData.value.port),
    tlsEnabled: editProfileData.value.tlsEnabled,
    certificatePath: editProfileData.value.certificatePath || undefined,
    updatedAt: new Date()
  })
  editingProfileId.value = null
}

function cancelEditProfile() {
  editingProfileId.value = null
}

onMounted(() => {
  profileStore.loadProfiles()
})
</script>

<template>
  <div class="home">
    <h1>Welcome to ProtoDesk</h1>
    <div class="input-box">
      <input v-model="name" type="text" placeholder="Enter your name" @keyup.enter="greet">
      <button @click="greet">Greet</button>
    </div>
    <div class="result" v-if="resultText">{{ resultText }}</div>

    <section class="profile-section">
      <h2>Add Server Profile</h2>
      <form @submit.prevent="addProfile" class="profile-form">
        <input v-model="newProfile.name" type="text" placeholder="Profile Name" required>
        <input v-model="newProfile.host" type="text" placeholder="Host" required>
        <input v-model.number="newProfile.port" type="number" placeholder="Port" min="1" required>
        <label><input v-model="newProfile.tlsEnabled" type="checkbox"> TLS Enabled</label>
        <input v-model="newProfile.certificatePath" type="text" placeholder="Certificate Path (optional)">
        <button type="submit">Add Profile</button>
      </form>
      <div v-if="profileStore.profiles.length > 0" class="profile-list">
        <h3>Existing Profiles</h3>
        <ul>
          <li v-for="profile in profileStore.profiles" :key="profile.id">
            <template v-if="editingProfileId === profile.id">
              <input v-model="editProfileData.name" type="text" placeholder="Profile Name" required>
              <input v-model="editProfileData.host" type="text" placeholder="Host" required>
              <input v-model.number="editProfileData.port" type="number" placeholder="Port" min="1" required>
              <label><input v-model="editProfileData.tlsEnabled" type="checkbox"> TLS Enabled</label>
              <input v-model="editProfileData.certificatePath" type="text" placeholder="Certificate Path (optional)">
              <button class="save-btn" @click="saveEditProfile(profile.id)">Save</button>
              <button class="cancel-btn" @click="cancelEditProfile">Cancel</button>
            </template>
            <template v-else>
              <strong>{{ profile.name }}</strong> ({{ profile.host }}:{{ profile.port }})
              <span v-if="profile.tlsEnabled">🔒</span>
              <span v-if="profile.certificatePath">[Cert: {{ profile.certificatePath }}]</span>
              <button class="edit-btn" @click="startEditProfile(profile)">Edit</button>
              <button class="delete-btn" @click="removeProfile(profile.id)">Delete</button>
            </template>
          </li>
        </ul>
      </div>
    </section>
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
  background-color: #29323b;
  border-radius: 4px;
}

.profile-section {
  margin-top: 2rem;
  text-align: left;
  max-width: 500px;
  margin-left: auto;
  margin-right: auto;
}

.profile-form {
  display: flex;
  flex-wrap: wrap;
  gap: 0.5rem;
  align-items: center;
  margin-bottom: 1rem;
}

.profile-form input[type="text"],
.profile-form input[type="number"] {
  flex: 1 1 120px;
}

.profile-form label {
  flex: 1 1 120px;
  display: flex;
  align-items: center;
  gap: 0.25rem;
}

.profile-list {
  margin-top: 1rem;
}

.profile-list ul {
  list-style: none;
  padding: 0;
}

.profile-list li {
  margin-bottom: 0.5rem;
}

.delete-btn {
  margin-left: 1rem;
  background-color: #b71c1c;
  color: white;
}

.delete-btn:hover {
  background-color: #7f1d1d;
}

.save-btn {
  margin-left: 1rem;
  background-color: #1976d2;
  color: white;
}

.save-btn:hover {
  background-color: #0d47a1;
}

.cancel-btn {
  margin-left: 0.5rem;
  background-color: #757575;
  color: white;
}

.cancel-btn:hover {
  background-color: #424242;
}

.edit-btn {
  margin-left: 1rem;
  background-color: #ffb300;
  color: #222;
}

.edit-btn:hover {
  background-color: #ff8f00;
}
</style>
