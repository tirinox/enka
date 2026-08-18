import { createApp } from 'vue'
import { createPinia } from 'pinia'
import App from './App.vue'
import router from './router'
import './styles/tokens.css'
import './styles/base.css'

const saved = localStorage.getItem('enka.theme')
if (saved === 'light' || saved === 'dark') {
  document.documentElement.dataset.theme = saved
}

createApp(App).use(createPinia()).use(router).mount('#app')
