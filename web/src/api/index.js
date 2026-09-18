import http from './http'

// 与后端 §7 API 一一对应。约定：所有列表返回 { items, total, page, size }。

export const authApi = {
  register: (d) => http.post('/auth/register', d),
  login: (d) => http.post('/auth/login', d),
  logout: () => http.post('/auth/logout'),
  me: () => http.get('/auth/me', { silent: true }),
  updateProfile: (d) => http.put('/auth/profile', d),
  changePassword: (d) => http.put('/auth/password', d),
}

export const projectApi = {
  list: () => http.get('/projects'),
}

export const categoryApi = {
  // 可选 { project_id }：只返回该专业根分类下的科目子树
  tree: (params) => http.get('/categories', { params }),
}

export const courseApi = {
  list: (params) => http.get('/courses', { params }),
  detail: (id) => http.get(`/courses/${id}`),
  enroll: (id) => http.post(`/courses/${id}/enroll`),
}

export const learningApi = {
  myEnrollments: (params) => http.get('/me/enrollments', { params }),
  myProgress: (courseId) => http.get('/me/progress', { params: { course_id: courseId } }),
  reportProgress: (d) => http.post('/learning/progress', d),
  heartbeat: (d) => http.post('/learning/heartbeat', d),
}

export const resourceApi = {
  list: (params) => http.get('/resources', { params }),
  downloadUrl: (id) => `/api/resources/${id}/download`,
}

export const practiceApi = {
  start: (d) => http.post('/practice/start', d),
  submit: (d) => http.post('/practice/submit', d),
  wrongList: (params) => http.get('/practice/wrong', { params }),
  masterWrong: (id) => http.post(`/practice/wrong/${id}/master`),
  favQuestions: (params) => http.get('/practice/favorites', { params }),
  toggleFavQuestion: (id) => http.post(`/questions/${id}/favorite`),
}

export const examApi = {
  list: (params) => http.get('/exams', { params }),
  start: (id) => http.post(`/exams/${id}/start`),
  saveAnswers: (attemptId, answers) => http.post(`/exam-attempts/${attemptId}/answer`, { answers }),
  submit: (attemptId, answers) => http.post(`/exam-attempts/${attemptId}/submit`, { answers }),
  attempts: (params) => http.get('/exam-attempts', { params }),
  attemptDetail: (id) => http.get(`/exam-attempts/${id}`),
}

export const orderApi = {
  myOrders: (params) => http.get('/orders', { params }),
}

export const announcementApi = {
  list: (params) => http.get('/announcements', { params }),
  detail: (id) => http.get(`/announcements/${id}`),
}

export const favoriteApi = {
  add: (d) => http.post('/favorites', d),
  // 框架协议层拒收 DELETE 带 body，取消走 query 参数
  remove: (targetType, targetId) =>
    http.delete('/favorites', { params: { target_type: targetType, target_id: targetId } }),
  list: (params) => http.get('/favorites', { params }),
}

export const noteApi = {
  create: (d) => http.post('/notes', d),
  list: (params) => http.get('/notes', { params }),
  update: (id, d) => http.put(`/notes/${id}`, d),
  remove: (id) => http.delete(`/notes/${id}`),
}

// 管理后台（role ≥ admin）。字段与 src/web/handlers 各 admin 接口逐一对齐。
export const adminApi = {
  // 用户
  users: (params) => http.get('/admin/users', { params }),
  user: (id) => http.get(`/admin/users/${id}`),
  setUserStatus: (id, status) => http.put(`/admin/users/${id}/status`, { status }),
  setUserRole: (id, role) => http.put(`/admin/users/${id}/role`, { role }),
  resetUserPassword: (id, password) => http.post(`/admin/users/${id}/reset-password`, { password }),
  // 专业（考试项目；根分类随专业自动创建，不在分类管理里单独维护）
  projects: () => http.get('/admin/projects'),
  createProject: (d) => http.post('/admin/projects', d),
  updateProject: (id, d) => http.put(`/admin/projects/${id}`, d),
  deleteProject: (id) => http.delete(`/admin/projects/${id}`),
  // 分类（列表复用公开 categoryApi.tree）
  createCategory: (d) => http.post('/admin/categories', d),
  updateCategory: (id, d) => http.put(`/admin/categories/${id}`, d),
  deleteCategory: (id) => http.delete(`/admin/categories/${id}`),
  // 课程/章节/课时
  courses: (params) => http.get('/admin/courses', { params }),
  course: (id) => http.get(`/admin/courses/${id}`),
  createCourse: (d) => http.post('/admin/courses', d),
  updateCourse: (id, d) => http.put(`/admin/courses/${id}`, d),
  deleteCourse: (id) => http.delete(`/admin/courses/${id}`),
  createChapter: (d) => http.post('/admin/chapters', d),
  updateChapter: (id, d) => http.put(`/admin/chapters/${id}`, d),
  deleteChapter: (id) => http.delete(`/admin/chapters/${id}`),
  createLesson: (d) => http.post('/admin/lessons', d),
  updateLesson: (id, d) => http.put(`/admin/lessons/${id}`, d),
  deleteLesson: (id) => http.delete(`/admin/lessons/${id}`),
  // 资料（上传 multipart 字段：file/name/category_id/is_public；category_id 必选；大文件放宽超时）
  resources: (params) => http.get('/admin/resources', { params }),
  resourceStats: () => http.get('/admin/resource-stats'),
  courseStats: () => http.get('/admin/course-stats'),
  questionStats: () => http.get('/admin/question-stats'),
  examStats: () => http.get('/admin/exam-stats'),
  uploadResource: (fd) => http.post('/admin/upload', fd, { timeout: 300000 }),
  // 题目图片：multipart 字段 file（png/jpg/jpeg/gif/webp，≤5MB）→ { url, size }
  uploadImage: (file) => {
    const fd = new FormData()
    fd.append('file', file)
    return http.post('/admin/upload-image', fd, { timeout: 60000 })
  },
  updateResource: (id, d) => http.put(`/admin/resources/${id}`, d),
  deleteResource: (id) => http.delete(`/admin/resources/${id}`),
  // 题库
  questions: (params) => http.get('/admin/questions', { params }),
  question: (id) => http.get(`/admin/questions/${id}`),
  createQuestion: (d) => http.post('/admin/questions', d),
  updateQuestion: (id, d) => http.put(`/admin/questions/${id}`, d),
  deleteQuestion: (id) => http.delete(`/admin/questions/${id}`),
  importQuestions: (d) => http.post('/admin/questions/import', d),
  // 试卷
  exams: (params) => http.get('/admin/exams', { params }),
  exam: (id) => http.get(`/admin/exams/${id}`),
  createExam: (d) => http.post('/admin/exams', d),
  updateExam: (id, d) => http.put(`/admin/exams/${id}`, d),
  deleteExam: (id) => http.delete(`/admin/exams/${id}`),
  // 订单
  orders: (params) => http.get('/admin/orders', { params }),
  createOrder: (d) => http.post('/admin/orders', d),
  payOrder: (id, d) => http.post(`/admin/orders/${id}/pay`, d || {}),
  cancelOrder: (id) => http.post(`/admin/orders/${id}/cancel`),
  // 公告
  announcements: (params) => http.get('/admin/announcements', { params }),
  announcement: (id) => http.get(`/admin/announcements/${id}`),
  createAnnouncement: (d) => http.post('/admin/announcements', d),
  updateAnnouncement: (id, d) => http.put(`/admin/announcements/${id}`, d),
  deleteAnnouncement: (id) => http.delete(`/admin/announcements/${id}`),
  publishAnnouncement: (id) => http.post(`/admin/announcements/${id}/publish`),
  unpublishAnnouncement: (id) => http.post(`/admin/announcements/${id}/unpublish`),
  // 统计
  stats: () => http.get('/admin/stats'),
  // 审计日志
  auditLogs: (params) => http.get('/admin/audit-logs', { params }),
}
