import axios from 'axios';

const api = axios.create({ baseURL: '/api' });

api.interceptors.request.use((cfg) => {
  const t = localStorage.getItem('xz_token');
  if (t) cfg.headers.Authorization = `Bearer ${t}`;
  return cfg;
});

// 401 = token 失效（旧 secret 失效 / 服务重启 / 被踢）。
// 自动清掉并派发 xz-unauthorized 事件，App.vue 收到后跳回登录页。
// 403 + code=LICENSE_REQUIRED = 授权到期/不可用，**不是权限问题**。
// 单独派一个事件让 App.vue 跳到「授权管理」并解释原因。
// 刻意不按 401 处理：那会把刚登录成功的管理员又踢回登录页，
// 而他其实有权限 —— 只是这台机器的授权到期了。
api.interceptors.response.use(
  (resp) => resp,
  (err) => {
    const res = err.response;
    if (res && res.status === 403 && res.data && res.data.code === 'LICENSE_REQUIRED') {
      window.dispatchEvent(new CustomEvent('xz-license-blocked', { detail: res.data }));
    }
    if (res && res.status === 401) {
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
