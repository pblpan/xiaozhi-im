<template>
  <div class="login-wrap" v-if="!token">
    <el-card class="login-card">
      <h2 style="text-align:center;margin-bottom:18px">小智 IM 管理后台</h2>
      <el-alert v-if="err" :title="err" type="error" show-icon :closable="false" style="margin-bottom:12px" />
      <el-input v-model="form.username" placeholder="管理员账号" @keyup.enter="login" />
      <el-input v-model="form.password" type="password" placeholder="密码" style="margin-top:12px" @keyup.enter="login" />
      <el-button type="primary" style="width:100%;margin-top:18px" :loading="loading" @click="login">登录</el-button>
      <p style="margin-top:10px;color:#999;font-size:12px;text-align:center">默认 admin / admin123，请在部署时修改</p>
    </el-card>
  </div>

  <el-container v-else style="height:100vh">
    <el-aside width="200px" class="aside">
      <div class="logo">小智 IM</div>
      <el-menu :default-active="tab" @select="tab = $event" background-color="#1f2d3d" text-color="#c0c4cc" active-text-color="#409eff">
        <el-menu-item index="dashboard">仪表盘</el-menu-item>
        <el-menu-item index="users">用户管理</el-menu-item>
        <el-menu-item index="groups">群组管理</el-menu-item>
      </el-menu>
      <div class="aside-foot">
        <span>服务端运行中</span>
        <el-button text type="danger" size="small" @click="logout">退出</el-button>
      </div>
    </el-aside>

    <el-container>
      <el-header class="hdr">小智 IM · 服务端可视化管理</el-header>
      <el-main>
        <!-- 仪表盘 -->
        <div v-if="tab === 'dashboard'">
          <el-row :gutter="16">
            <el-col :span="4" v-for="c in cards" :key="c.label">
              <el-card shadow="hover" class="stat">
                <div class="stat-num">{{ stats[c.key] ?? '—' }}</div>
                <div class="stat-label">{{ c.label }}</div>
              </el-card>
            </el-col>
          </el-row>
          <el-card style="margin-top:18px">
            <template #header>系统说明</template>
            <p>· 数据 100% 存储于本机（飞牛/群晖/绿联/麒麟等私有服务器）。</p>
            <p>· 客户端支持 Windows / Android（仿 Tailchat 界面），后续扩展 Mac / iOS。</p>
            <p>· 如需修改管理员密码，请到服务端环境变量 ADMIN_PASSWORD 重新部署。</p>
          </el-card>
        </div>

        <!-- 用户管理 -->
        <div v-else-if="tab === 'users'">
          <el-table :data="users" border stripe>
            <el-table-column prop="id" label="ID" width="70" />
            <el-table-column prop="username" label="账号" />
            <el-table-column prop="nickname" label="昵称" />
            <el-table-column prop="role" label="角色" width="100">
              <template #default="{ row }">
                <el-tag :type="row.role === 'admin' ? 'danger' : 'info'">{{ row.role }}</el-tag>
              </template>
            </el-table-column>
            <el-table-column label="操作" width="200">
              <template #default="{ row }">
                <el-button size="small" @click="toggleRole(row)">{{ row.role === 'admin' ? '降为普通' : '设为管理员' }}</el-button>
                <el-button size="small" type="danger" @click="delUser(row)">删除</el-button>
              </template>
            </el-table-column>
          </el-table>
        </div>

        <!-- 群组管理 -->
        <div v-else-if="tab === 'groups'">
          <el-table :data="groups" border stripe>
            <el-table-column prop="id" label="ID" width="70" />
            <el-table-column prop="name" label="群名" />
            <el-table-column prop="owner_name" label="群主" />
            <el-table-column prop="members" label="成员数" width="90" />
            <el-table-column label="操作" width="120">
              <template #default="{ row }">
                <el-button size="small" type="danger" @click="delGroup(row)">解散</el-button>
              </template>
            </el-table-column>
          </el-table>
        </div>
      </el-main>
    </el-container>
  </el-container>
</template>

<script setup>
import { ref, onMounted, computed } from 'vue';
import { ElMessage, ElMessageBox } from 'element-plus';
import api from './api';

const token = ref(localStorage.getItem('xz_token') || '');
const form = ref({ username: '', password: '' });
const loading = ref(false);
const err = ref('');
const tab = ref('dashboard');
const stats = ref({});
const users = ref([]);
const groups = ref([]);

const cards = [
  { key: 'users', label: '用户数' },
  { key: 'groups', label: '群组数' },
  { key: 'messages', label: '消息数' },
  { key: 'files', label: '文件数' },
  { key: 'friendships', label: '好友关系' },
];

async function login() {
  err.value = '';
  loading.value = true;
  try {
    const { data } = await api.post('/auth/login', form.value);
    if (data.token) {
      token.value = data.token;
      localStorage.setItem('xz_token', data.token);
      loadAll();
    } else {
      err.value = '登录失败';
    }
  } catch (e) {
    err.value = e.response?.data?.error || '登录失败';
  } finally {
    loading.value = false;
  }
}

function logout() {
  token.value = '';
  localStorage.removeItem('xz_token');
}

async function loadAll() {
  const [s, u, g] = await Promise.all([
    api.get('/admin/stats'),
    api.get('/admin/users'),
    api.get('/admin/groups'),
  ]);
  stats.value = s.data;
  users.value = u.data;
  groups.value = g.data;
}

async function toggleRole(row) {
  await api.post(`/admin/users/${row.id}/role`, { role: row.role === 'admin' ? 'user' : 'admin' });
  ElMessage.success('已更新角色');
  loadAll();
}

async function delUser(row) {
  await ElMessageBox.confirm(`确认删除用户 ${row.username}？`, '警告', { type: 'warning' });
  await api.delete(`/admin/users/${row.id}`);
  ElMessage.success('已删除');
  loadAll();
}

async function delGroup(row) {
  await ElMessageBox.confirm(`确认解散群组 ${row.name}？`, '警告', { type: 'warning' });
  await api.delete(`/admin/groups/${row.id}`);
  ElMessage.success('已解散');
  loadAll();
}

onMounted(() => { if (token.value) loadAll(); });
</script>

<style>
body { margin: 0; font-family: -apple-system, "Microsoft YaHei", sans-serif; }
.login-wrap { height: 100vh; display: flex; align-items: center; justify-content: center; background: #f0f2f5; }
.login-card { width: 340px; }
.aside { background: #1f2d3d; display: flex; flex-direction: column; }
.logo { color: #fff; font-size: 20px; font-weight: 700; text-align: center; padding: 18px 0; }
.aside-foot { margin-top: auto; padding: 12px; color: #8a8f99; font-size: 12px; display: flex; justify-content: space-between; align-items: center; }
.hdr { background: #fff; border-bottom: 1px solid #ebeef5; display: flex; align-items: center; font-weight: 600; }
.stat { text-align: center; }
.stat-num { font-size: 28px; font-weight: 700; color: #409eff; }
.stat-label { color: #909399; margin-top: 6px; }
</style>
