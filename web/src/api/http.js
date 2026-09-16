import axios from 'axios'
import { ElMessage } from 'element-plus'

const http = axios.create({ baseURL: '/api', timeout: 20000, withCredentials: true })

let onUnauthorized = null
/** App.vue 注入 401 处理钩子（避免 http↔router/store 循环导入） */
export function setUnauthorizedHook(fn) {
  onUnauthorized = fn
}

http.interceptors.response.use(
  (res) => {
    // 后端成功包：{ ok: true, data }。直接返回 data 给调用方。
    const d = res.data
    return d && d.ok === true ? d.data : d
  },
  (err) => {
    let msg = '网络错误，请稍后再试'
    if (err.response) {
      const d = err.response.data
      // AppError 渲染为 text/plain 中文文案；路由级 404 是 JSON
      msg = typeof d === 'string' && d ? d : d?.error?.message || '请求失败'
      if (err.response.status === 401 && onUnauthorized) onUnauthorized()
    } else if (err.code === 'ECONNABORTED') {
      msg = '请求超时'
    }
    // silent：静默请求（如刷新时恢复登录态的 /me），401 属预期，不弹错误提示
    if (!err.config?.silent) ElMessage.error(msg)
    return Promise.reject(err)
  },
)

export default http
