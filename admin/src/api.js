import axios from 'axios';

const api = axios.create({ baseURL: '/api' });

api.interceptors.request.use((cfg) => {
  const t = localStorage.getItem('xz_token');
  if (t) cfg.headers.Authorization = `Bearer ${t}`;
  return cfg;
});

// 401 = token 失效（旧 secret 失效 / 服务重启 / 被踢）。
// 自动清掉并派发 xz-unauthorized 事件，App.vue 收到后跳回登录页。
api.interceptors.response.use(
  (resp) => resp,
  (err) => {
    if (err.response && err.response.status === 401) {
      const t = localStorage.getItem('xz_token');
      if (t) {
        localStorage.removeItem('xz_token');
        window.dispatchEvent(new CustomEvent('xz-unauthorized'));
      }
    }
    return Promise.reject(err);
  }
);

export default api;
