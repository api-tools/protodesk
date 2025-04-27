import { createRouter, createWebHashHistory } from 'vue-router'
import HomeView from '../views/HomeView.vue'
import ProtoDefinitionsView from '../views/ProtoDefinitionsView.vue'

export const router = createRouter({
  history: createWebHashHistory(),
  routes: [
    {
      path: '/',
      name: 'home',
      component: HomeView
    },
    {
      path: '/proto-definitions',
      name: 'proto-definitions',
      component: ProtoDefinitionsView
    }
  ]
})
