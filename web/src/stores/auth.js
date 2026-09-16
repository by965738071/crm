import { defineStore } from 'pinia'
import { authApi } from '../api'

export const useAuthStore = defineStore('auth', {
  state: () => ({
    user: null,
    // 未拉取过 /me 时为 true（刷新页面后 App/守卫触发加载）
    unknown: true,
  }),
  getters: {
    isLoggedIn: (s) => !!s.user,
    isAdmin: (s) => s.user && (s.user.role === 'admin' || s.user.role === 'superadmin'),
    displayName: (s) => (s.user ? s.user.nickname || s.user.username : ''),
  },
  actions: {
    async loadMe() {
      this.user = await authApi.me()
      this.unknown = false
      return this.user
    },
    async login(payload) {
      this.user = await authApi.login(payload)
      this.unknown = false
      return this.user
    },
    async logout() {
      try {
        await authApi.logout()
      } finally {
        this.clear()
      }
    },
    clear() {
      this.user = null
      this.unknown = false
    },
    setUser(u) {
      this.user = u
      this.unknown = false
    },
  },
})
