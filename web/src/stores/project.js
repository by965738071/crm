import { defineStore } from 'pinia'
import { projectApi } from '../api'

const KEY = 'crm_cu…t_id'

// 专业（考试项目）频道：currentId=0 表示「全部」；选中后学员端各列表按
// category_id=专业根分类 + sub=1 过滤（专业即一棵分类子树）。
export const useProjectStore = defineStore('project', {
  state: () => ({
    list: [],
    loaded: false,
    currentId: Number(localStorage.getItem(KEY) || 0),
  }),
  getters: {
    current: (s) => s.list.find((p) => p.id === s.currentId) || null,
    currentLabel: (s) => s.list.find((p) => p.id === s.currentId)?.name || '全部专业',
    // 科目树别称（每个专业可自定义：科目/章节/专业实务…），默认「科目」
    subjectLabel: (s) => s.list.find((p) => p.id === s.currentId)?.subject_label || '科目',
  },
  actions: {
    async load() {
      try {
        this.list = (await projectApi.list()) || []
      } catch {
        this.list = []
      }
      this.loaded = true
      // 记住的专业已被删除/停用时回退到「全部」
      if (this.currentId && !this.list.some((p) => p.id === this.currentId)) this.set(0)
    },
    set(id) {
      this.currentId = Number(id) || 0
      localStorage.setItem(KEY, String(this.currentId))
    },
    /**
     * 学员端列表查询参数：
     * - 选中专业：未选具体科目时圈定子树（根分类 + sub=1），选了科目则按科目子树；
     * - 全部专业：选了科目按科目子树-filter，否则不加分类条件。
     */
    scope(categoryId = 0) {
      const picked = Number(categoryId) || 0
      const cur = this.current
      if (cur) return { category_id: picked || cur.root_category_id, sub: 1 }
      return { category_id: picked, sub: picked ? 1 : 0 }
    },
  },
})
