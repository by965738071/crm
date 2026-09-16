import { createRouter, createWebHistory } from 'vue-router'
import { useAuthStore } from '../stores/auth'

const S = (name) => () => import(`../views/student/${name}.vue`)
const A = (name) => () => import(`../views/admin/${name}.vue`)

const routes = [
  { path: '/login', name: 'login', component: S('Login'), meta: { guestOnly: true } },
  { path: '/register', name: 'register', component: S('Register'), meta: { guestOnly: true } },
  {
    path: '/',
    component: () => import('../layouts/StudentLayout.vue'),
    children: [
      { path: '', redirect: '/home' },
      { path: 'home', name: 'home', component: S('Home') },
      { path: 'announcements', name: 'announcements', component: S('Announcements') },
      { path: 'courses', name: 'courses', component: S('Courses') },
      { path: 'courses/:id', name: 'course-detail', component: S('CourseDetail'), props: true },
      { path: 'resources', name: 'resources', component: S('Resources') },
      // ---- 以下需登录 ----
      { path: 'lessons/:id', name: 'lesson', component: S('LessonLearn'), props: true, meta: { auth: true } },
      { path: 'practice', name: 'practice', component: S('Practice'), meta: { auth: true } },
      { path: 'wrong-book', name: 'wrong-book', component: S('WrongBook'), meta: { auth: true } },
      { path: 'exams', name: 'exams', component: S('Exams'), meta: { auth: true } },
      { path: 'exam-attempts/:id', name: 'exam-result', component: S('ExamResult'), props: true, meta: { auth: true } },
      { path: 'exam-taking/:attemptId', name: 'exam-taking', component: S('ExamTaking'), props: true, meta: { auth: true } },
      { path: 'me/courses', name: 'my-courses', component: S('MyCourses'), meta: { auth: true } },
      { path: 'me/notes', name: 'my-notes', component: S('MyNotes'), meta: { auth: true } },
      { path: 'me/favorites', name: 'my-favorites', component: S('MyFavorites'), meta: { auth: true } },
      { path: 'me/orders', name: 'my-orders', component: S('MyOrders'), meta: { auth: true } },
      { path: 'me/profile', name: 'profile', component: S('Profile'), meta: { auth: true } },
    ],
  },
  {
    path: '/admin',
    component: () => import('../layouts/AdminLayout.vue'),
    meta: { auth: true, admin: true },
    children: [
      { path: '', redirect: '/admin/dashboard' },
      { path: 'dashboard', name: 'admin-dashboard', component: A('Dashboard') },
      { path: 'users', name: 'admin-users', component: A('UserList') },
      { path: 'categories', name: 'admin-categories', component: A('CategoryManage') },
      { path: 'courses', name: 'admin-courses', component: A('CourseManage') },
      { path: 'courses/:id/lessons', name: 'admin-lessons', component: A('LessonEdit'), props: true },
      { path: 'resources', name: 'admin-resources', component: A('ResourceManage') },
      { path: 'questions', name: 'admin-questions', component: A('QuestionManage') },
      { path: 'exams', name: 'admin-exams', component: A('ExamManage') },
      { path: 'orders', name: 'admin-orders', component: A('OrderManage') },
      { path: 'announcements', name: 'admin-announcements', component: A('AnnouncementManage') },
    ],
  },
  { path: '/:pathMatch(.*)*', name: 'not-found', component: S('NotFound') },
]

const router = createRouter({ history: createWebHistory(), routes })

router.beforeEach(async (to) => {
  const auth = useAuthStore()
  // vue-router 4 的 to.meta 合并全部匹配链：父路由 meta.auth/admin 对子路由生效
  if (to.meta.auth || to.meta.admin) {
    // 首跳/刷新时 user 未知：先拉 /me，401 由 http 拦截器统一处理
    if (auth.unknown) {
      try {
        await auth.loadMe()
      } catch {
        return { path: '/login', query: to.fullPath === '/' ? undefined : { next: to.fullPath } }
      }
    }
    if (!auth.isLoggedIn) return { path: '/login', query: { next: to.fullPath } }
    // 非管理员直进 /admin：回学员端首页（菜单不展示入口，这里兜底手输 URL）
    if (to.meta.admin && !auth.isAdmin) return { path: '/home' }
  }
  if (to.meta.guestOnly && auth.isLoggedIn) return { path: '/home' }
  return true
})

export default router
