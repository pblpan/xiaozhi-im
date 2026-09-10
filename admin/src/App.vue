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
      <el-menu :default-active="tab" @select="tab = $event" background-color="#0F2620" text-color="#c0c4cc" active-text-color="#10B981">
        <el-menu-item index="dashboard">仪表盘</el-menu-item>
        <el-menu-item index="users">用户管理</el-menu-item>
        <el-menu-item index="groups">群组管理</el-menu-item>
        <el-menu-item index="friends">好友关系</el-menu-item>
        <el-menu-item index="files">文件管理</el-menu-item>
        <el-menu-item index="messages">消息管理</el-menu-item>
        <el-menu-item index="settings">系统设置</el-menu-item>
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
            <el-col :span="6" v-for="c in cards" :key="c.label">
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
            <p>· 如需修改管理员密码，请到「系统设置」页操作（无需重启服务）。</p>
          </el-card>
        </div>

        <!-- 用户管理 -->
        <div v-else-if="tab === 'users'">
          <div class="page-bar">
            <el-input v-model="userSearch" placeholder="搜索账号/昵称" clearable style="width:240px" />
            <el-button type="primary" @click="openUserDialog()">新建用户</el-button>
            <el-button @click="loadUsers">刷新</el-button>
          </div>
          <el-table :data="filteredUsers" border stripe>
            <el-table-column prop="id" label="ID" width="70" />
            <el-table-column prop="username" label="账号" />
            <el-table-column prop="nickname" label="昵称" />
            <el-table-column prop="role" label="角色" width="100">
              <template #default="{ row }">
                <el-tag :type="row.role === 'admin' ? 'danger' : 'info'">{{ row.role }}</el-tag>
              </template>
            </el-table-column>
            <el-table-column prop="created_at" label="注册时间" width="180">
              <template #default="{ row }">{{ fmtTime(row.created_at) }}</template>
            </el-table-column>
            <el-table-column label="操作" width="260">
              <template #default="{ row }">
                <el-button size="small" @click="openUserDialog(row)">编辑</el-button>
                <el-button size="small" @click="toggleRole(row)">{{ row.role === 'admin' ? '降为普通' : '设为管理员' }}</el-button>
                <el-button size="small" type="danger" @click="delUser(row)">删除</el-button>
              </template>
            </el-table-column>
          </el-table>
        </div>

        <!-- 群组管理 -->
        <div v-else-if="tab === 'groups'">
          <div class="page-bar">
            <el-button type="primary" @click="openGroupDialog()">新建群组</el-button>
            <el-button @click="loadGroups">刷新</el-button>
          </div>
          <el-table :data="groups" border stripe>
            <el-table-column prop="id" label="ID" width="70" />
            <el-table-column prop="name" label="群名" />
            <el-table-column prop="owner_name" label="群主" />
            <el-table-column prop="members" label="成员数" width="90" />
            <el-table-column prop="created_at" label="创建时间" width="180">
              <template #default="{ row }">{{ fmtTime(row.created_at) }}</template>
            </el-table-column>
            <el-table-column label="操作" width="200">
              <template #default="{ row }">
                <el-button size="small" @click="openGroupDialog(row)">编辑</el-button>
                <el-button size="small" type="danger" @click="delGroup(row)">解散</el-button>
              </template>
            </el-table-column>
          </el-table>
        </div>

        <!-- 好友关系 -->
        <div v-else-if="tab === 'friends'">
          <el-table :data="friendships" border stripe>
            <el-table-column prop="id" label="ID" width="70" />
            <el-table-column prop="user_name" label="用户" />
            <el-table-column prop="friend_name" label="好友" />
            <el-table-column prop="status" label="状态" width="100">
              <template #default="{ row }">
                <el-tag :type="row.status === 'accepted' ? 'success' : 'warning'">{{ row.status }}</el-tag>
              </template>
            </el-table-column>
            <el-table-column prop="created_at" label="创建时间" width="180">
              <template #default="{ row }">{{ fmtTime(row.created_at) }}</template>
            </el-table-column>
            <el-table-column label="操作" width="120">
              <template #default="{ row }">
                <el-button size="small" type="danger" @click="delFriend(row)">删除</el-button>
              </template>
            </el-table-column>
          </el-table>
        </div>

        <!-- 文件管理 -->
        <div v-else-if="tab === 'files'">
          <div class="page-bar">
            <span>磁盘占用：<b>{{ fmtBytes(info.files_disk_bytes) }}</b></span>
          </div>
          <el-table :data="files" border stripe>
            <el-table-column prop="id" label="ID" width="70" />
            <el-table-column label="预览" width="80">
              <template #default="{ row }">
                <el-image v-if="isImage(row.mime)" :src="`/files/${row.path}`" style="width:48px;height:48px;object-fit:cover" fit="cover" :preview-src-list="[`/files/${row.path}`]" hide-on-click-modal />
                <span v-else style="color:#909399">—</span>
              </template>
            </el-table-column>
            <el-table-column prop="name" label="原始文件名" />
            <el-table-column prop="owner" label="上传者" width="120" />
            <el-table-column prop="mime" label="类型" width="160" />
            <el-table-column prop="size" label="大小" width="100">
              <template #default="{ row }">{{ fmtBytes(row.size) }}</template>
            </el-table-column>
            <el-table-column prop="created_at" label="上传时间" width="180">
              <template #default="{ row }">{{ fmtTime(row.created_at) }}</template>
            </el-table-column>
            <el-table-column label="操作" width="200">
              <template #default="{ row }">
                <el-button size="small" @click="downloadFile(row)">下载</el-button>
                <el-button size="small" type="danger" @click="delFile(row)">删除</el-button>
              </template>
            </el-table-column>
          </el-table>
        </div>

        <!-- 消息管理 -->
        <div v-else-if="tab === 'messages'">
          <div class="page-bar">
            <el-select v-model="msgKind" placeholder="全部类型" clearable style="width:130px" @change="loadMessages">
              <el-option label="全部类型" value="" />
              <el-option label="文字" value="text" />
              <el-option label="图片" value="image" />
              <el-option label="文件" value="file" />
              <el-option label="语音" value="audio" />
            </el-select>
            <el-input v-model="msgQ" placeholder="搜索消息内容" clearable style="width:220px" @keyup.enter="loadMessages" />
            <el-button type="primary" @click="loadMessages">搜索</el-button>
            <el-button @click="resetMsgFilter">重置</el-button>
            <el-button @click="loadMessages">刷新</el-button>
          </div>
          <el-table :data="messages" border stripe>
            <el-table-column prop="id" label="ID" width="70" />
            <el-table-column prop="sender_name" label="发送者" width="120" />
            <el-table-column prop="conversation_id" label="会话" width="80" />
            <el-table-column prop="kind" label="类型" width="80">
              <template #default="{ row }">
                <el-tag size="small" :type="kindTag(row.kind)">{{ kindLabel(row.kind) }}</el-tag>
              </template>
            </el-table-column>
            <el-table-column label="状态" width="90">
              <template #default="{ row }">
                <el-tag v-if="row.deleted" size="small" type="info">已撤回</el-tag>
                <el-tag v-else-if="row.edited" size="small" type="warning">已编辑</el-tag>
                <span v-else style="color:#c0c4cc">—</span>
              </template>
            </el-table-column>
            <el-table-column label="内容" show-overflow-tooltip>
              <template #default="{ row }">
                <span v-if="row.deleted" style="color:#c0c4cc;font-style:italic">消息已撤回</span>
                <span v-else-if="row.kind === 'text'">{{ row.content }}</span>
                <span v-else-if="row.kind === 'audio'" style="color:#909399">语音 · {{ row.content }} 秒</span>
                <span v-else-if="row.kind === 'image'" style="color:#909399">图片 · {{ row.content }}</span>
                <span v-else style="color:#909399">文件 · {{ row.content || '—' }}</span>
              </template>
            </el-table-column>
            <el-table-column prop="created_at" label="发送时间" width="180">
              <template #default="{ row }">{{ fmtTime(row.created_at) }}</template>
            </el-table-column>
            <el-table-column label="操作" width="100">
              <template #default="{ row }">
                <el-button size="small" type="danger" @click="delMessage(row)">删除</el-button>
              </template>
            </el-table-column>
          </el-table>
        </div>

        <!-- 系统设置 -->
        <div v-else-if="tab === 'settings'">
          <el-row :gutter="16">
            <el-col :span="12">
              <el-card>
                <template #header>修改管理员密码</template>
                <el-form :model="pwd" label-width="100px">
                  <el-form-item label="旧密码">
                    <el-input v-model="pwd.old" type="password" show-password />
                  </el-form-item>
                  <el-form-item label="新密码">
                    <el-input v-model="pwd.neu" type="password" show-password />
                  </el-form-item>
                  <el-form-item label="确认新密码">
                    <el-input v-model="pwd.neu2" type="password" show-password />
                  </el-form-item>
                  <el-form-item>
                    <el-button type="primary" :loading="pwdBusy" @click="changePassword">提交</el-button>
                  </el-form-item>
                </el-form>
              </el-card>
            </el-col>
            <el-col :span="12">
              <el-card>
                <template #header>服务器信息</template>
                <el-descriptions :column="1" border>
                  <el-descriptions-item label="监听端口">{{ info.port }}</el-descriptions-item>
                  <el-descriptions-item label="数据目录">{{ info.data_dir }}</el-descriptions-item>
                  <el-descriptions-item label="数据库路径">{{ info.db_path }}</el-descriptions-item>
                  <el-descriptions-item label="文件存储">{{ info.files_dir }}</el-descriptions-item>
                  <el-descriptions-item label="磁盘占用">{{ fmtBytes(info.files_disk_bytes) }}</el-descriptions-item>
                  <el-descriptions-item label="单文件上限">{{ info.max_file_mb }} MB</el-descriptions-item>
                  <el-descriptions-item label="Node 版本">{{ info.node }}</el-descriptions-item>
                </el-descriptions>
              </el-card>
            </el-col>
          </el-row>
        </div>
      </el-main>
    </el-container>

    <!-- 用户编辑对话框 -->
    <el-dialog v-model="userDlg" :title="userForm.id ? '编辑用户' : '新建用户'" width="480px">
      <el-form :model="userForm" label-width="80px">
        <el-form-item label="账号">
          <el-input v-model="userForm.username" :disabled="!!userForm.id" placeholder="登录账号（创建后不可改）" />
        </el-form-item>
        <el-form-item label="昵称">
          <el-input v-model="userForm.nickname" placeholder="显示昵称" />
        </el-form-item>
        <el-form-item label="角色">
          <el-radio-group v-model="userForm.role">
            <el-radio value="user">普通用户</el-radio>
            <el-radio value="admin">管理员</el-radio>
          </el-radio-group>
        </el-form-item>
        <el-form-item :label="userForm.id ? '重置密码' : '密码'">
          <el-input v-model="userForm.password" type="password" show-password
                    :placeholder="userForm.id ? '留空表示不修改' : '至少 6 位'" />
        </el-form-item>
      </el-form>
      <template #footer>
        <el-button @click="userDlg = false">取消</el-button>
        <el-button type="primary" :loading="userDlgBusy" @click="saveUser">保存</el-button>
      </template>
    </el-dialog>

    <!-- 群组编辑对话框 -->
    <el-dialog v-model="groupDlg" :title="groupForm.id ? '编辑群组' : '新建群组'" width="560px">
      <el-form :model="groupForm" label-width="90px">
        <el-form-item label="群名">
          <el-input v-model="groupForm.name" placeholder="群组名称" />
        </el-form-item>
        <el-form-item label="群主">
          <el-select v-model="groupForm.owner_id" filterable placeholder="选择群主" style="width:100%">
            <el-option v-for="u in users" :key="u.id" :label="`${u.username} (${u.nickname || ''})`" :value="u.id" />
          </el-select>
        </el-form-item>
        <el-form-item label="成员">
          <el-select v-model="groupForm.member_ids" multiple filterable collapse-tags collapse-tags-tooltip
                     placeholder="选择成员（可多选）" style="width:100%">
            <el-option v-for="u in users" :key="u.id" :label="`${u.username} (${u.nickname || ''})`" :value="u.id" />
          </el-select>
        </el-form-item>
        <p style="color:#909399;font-size:12px;margin:0 0 0 90px">
          * 创建时群主自动加入成员列表；编辑时改动成员会同步会话成员。
        </p>
      </el-form>
      <template #footer>
        <el-button @click="groupDlg = false">取消</el-button>
        <el-button type="primary" :loading="groupDlgBusy" @click="saveGroup">保存</el-button>
      </template>
    </el-dialog>
  </el-container>
</template>

<script setup>
import { ref, computed, onMounted, watch } from 'vue';
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
const friendships = ref([]);
const files = ref([]);
const messages = ref([]);
const msgKind = ref('');
const msgQ = ref('');
const info = ref({});

const cards = [
  { key: 'users', label: '用户数' },
  { key: 'groups', label: '群组数' },
  { key: 'messages', label: '消息总数' },
  { key: 'text', label: '文字消息' },
  { key: 'images', label: '图片消息' },
  { key: 'audios', label: '语音消息' },
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
  try {
    const [s, u, g, fs, fr, ms, inf] = await Promise.all([
      api.get('/admin/stats'),
      api.get('/admin/users'),
      api.get('/admin/groups'),
      api.get('/admin/files'),
      api.get('/admin/friendships'),
      api.get('/admin/messages?limit=300'),
      api.get('/admin/info'),
    ]);
    stats.value = s.data;
    users.value = u.data;
    groups.value = g.data;
    files.value = fs.data;
    friendships.value = fr.data;
    messages.value = ms.data;
    info.value = inf.data;
  } catch (e) {
    ElMessage.error('加载失败：' + (e.response?.data?.error || e.message));
  }
}

// 切换 tab 时按需加载
async function loadTab() {
  if (tab.value === 'dashboard') {
    const { data } = await api.get('/admin/stats');
    stats.value = data;
  } else if (tab.value === 'users') await loadUsers();
  else if (tab.value === 'groups') await loadGroups();
  else if (tab.value === 'friends') await loadFriends();
  else if (tab.value === 'files') await loadFiles();
  else if (tab.value === 'messages') await loadMessages();
  else if (tab.value === 'settings') await loadInfo();
}
async function loadUsers() { users.value = (await api.get('/admin/users')).data; }
async function loadGroups() { groups.value = (await api.get('/admin/groups')).data; }
async function loadFriends() { friendships.value = (await api.get('/admin/friendships')).data; }
async function loadFiles() { files.value = (await api.get('/admin/files')).data; }
async function loadMessages() {
  const p = new URLSearchParams({ limit: '300' });
  if (msgKind.value) p.set('kind', msgKind.value);
  if (msgQ.value.trim()) p.set('q', msgQ.value.trim());
  messages.value = (await api.get('/admin/messages?' + p.toString())).data;
}

function resetMsgFilter() {
  msgKind.value = '';
  msgQ.value = '';
  loadMessages();
}

function kindLabel(k) {
  return { text: '文字', image: '图片', file: '文件', audio: '语音', emoji: '表情' }[k] || k;
}

function kindTag(k) {
  return { text: 'success', image: 'warning', audio: 'danger', file: 'info' }[k] || 'info';
}
async function loadInfo() { info.value = (await api.get('/admin/info')).data; }

// 监听 tab 切换
watch(tab, loadTab);

/* ====== Users ====== */
const userSearch = ref('');
const filteredUsers = computed(() => {
  const k = userSearch.value.trim().toLowerCase();
  if (!k) return users.value;
  return users.value.filter((u) => (u.username + (u.nickname || '')).toLowerCase().includes(k));
});
const userDlg = ref(false);
const userDlgBusy = ref(false);
const userForm = ref({ id: null, username: '', nickname: '', role: 'user', password: '' });
function openUserDialog(row) {
  if (row) {
    userForm.value = { id: row.id, username: row.username, nickname: row.nickname || '', role: row.role, password: '' };
  } else {
    userForm.value = { id: null, username: '', nickname: '', role: 'user', password: '' };
  }
  userDlg.value = true;
}
async function saveUser() {
  const f = userForm.value;
  if (!f.username) return ElMessage.warning('请填账号');
  if (!f.id && !f.password) return ElMessage.warning('请填密码');
  userDlgBusy.value = true;
  try {
    if (f.id) {
      const body = { nickname: f.nickname, role: f.role };
      if (f.password) body.password = f.password;
      await api.patch(`/admin/users/${f.id}`, body);
    } else {
      await api.post('/admin/users', { username: f.username, password: f.password, nickname: f.nickname, role: f.role });
    }
    ElMessage.success('已保存');
    userDlg.value = false;
    await loadUsers();
    const { data } = await api.get('/admin/stats'); stats.value = data;
  } catch (e) {
    ElMessage.error(e.response?.data?.error || '保存失败');
  } finally {
    userDlgBusy.value = false;
  }
}
async function toggleRole(row) {
  try {
    await api.post(`/admin/users/${row.id}/role`, { role: row.role === 'admin' ? 'user' : 'admin' });
    ElMessage.success('已更新角色');
    await loadUsers();
  } catch (e) {
    ElMessage.error(e.response?.data?.error || '更新失败');
  }
}
async function delUser(row) {
  try {
    await ElMessageBox.confirm(`确认删除用户 ${row.username}？该用户相关的群成员/好友关系也会被清理。`, '警告', { type: 'warning' });
  } catch { return; }
  try {
    await api.delete(`/admin/users/${row.id}`);
    ElMessage.success('已删除');
    await loadUsers();
    const { data } = await api.get('/admin/stats'); stats.value = data;
  } catch (e) {
    ElMessage.error(e.response?.data?.error || '删除失败');
  }
}

/* ====== Groups ====== */
const groupDlg = ref(false);
const groupDlgBusy = ref(false);
const groupForm = ref({ id: null, name: '', owner_id: null, member_ids: [] });
async function openGroupDialog(row) {
  if (!users.value.length) await loadUsers();
  if (row) {
    // 编辑时：留空成员选择 = 不动成员；用户主动勾选 = 全量替换（增/删都会自动跳过群主）
    groupForm.value = { id: row.id, name: row.name, owner_id: row.owner_id, member_ids: [] };
  } else {
    groupForm.value = { id: null, name: '', owner_id: null, member_ids: [] };
  }
  groupDlg.value = true;
}
async function saveGroup() {
  const f = groupForm.value;
  if (!f.name) return ElMessage.warning('请填群名');
  groupDlgBusy.value = true;
  try {
    if (f.id) {
      const body = { name: f.name, owner_id: f.owner_id };
      // 编辑时若用户没勾选成员，不传 member_ids 避免清空
      if (f.member_ids.length) body.member_ids = f.member_ids;
      await api.patch(`/admin/groups/${f.id}`, body);
    } else {
      if (!f.owner_id) return ElMessage.warning('请选群主');
      await api.post('/admin/groups', { name: f.name, owner_id: f.owner_id, member_ids: f.member_ids });
    }
    ElMessage.success('已保存');
    groupDlg.value = false;
    await loadGroups();
    const { data } = await api.get('/admin/stats'); stats.value = data;
  } catch (e) {
    ElMessage.error(e.response?.data?.error || '保存失败');
  } finally {
    groupDlgBusy.value = false;
  }
}
async function delGroup(row) {
  try {
    await ElMessageBox.confirm(`确认解散群组 ${row.name}？`, '警告', { type: 'warning' });
  } catch { return; }
  try {
    await api.delete(`/admin/groups/${row.id}`);
    ElMessage.success('已解散');
    await loadGroups();
    const { data } = await api.get('/admin/stats'); stats.value = data;
  } catch (e) {
    ElMessage.error(e.response?.data?.error || '删除失败');
  }
}

/* ====== Friendships ====== */
async function delFriend(row) {
  try {
    await ElMessageBox.confirm(`删除好友关系 ${row.user_name} ⇄ ${row.friend_name}？`, '警告', { type: 'warning' });
  } catch { return; }
  try {
    await api.delete(`/admin/friendships/${row.id}`);
    ElMessage.success('已删除');
    await loadFriends();
    const { data } = await api.get('/admin/stats'); stats.value = data;
  } catch (e) {
    ElMessage.error(e.response?.data?.error || '删除失败');
  }
}

/* ====== Files ====== */
function isImage(m) { return typeof m === 'string' && m.startsWith('image/'); }
function downloadFile(row) {
  const a = document.createElement('a');
  a.href = `/files/${row.path}`;
  a.download = row.name;
  a.target = '_blank';
  document.body.appendChild(a); a.click(); a.remove();
}
async function delFile(row) {
  try {
    await ElMessageBox.confirm(`删除文件 ${row.name}？相关消息里的文件占位也会被清除。`, '警告', { type: 'warning' });
  } catch { return; }
  try {
    await api.delete(`/admin/files/${row.id}`);
    ElMessage.success('已删除');
    await loadFiles();
    await loadInfo();
    const { data } = await api.get('/admin/stats'); stats.value = data;
  } catch (e) {
    ElMessage.error(e.response?.data?.error || '删除失败');
  }
}

/* ====== Messages ====== */
async function delMessage(row) {
  try {
    await ElMessageBox.confirm(`确认删除消息 #${row.id}？`, '警告', { type: 'warning' });
  } catch { return; }
  try {
    await api.delete(`/admin/messages/${row.id}`);
    ElMessage.success('已删除');
    await loadMessages();
    const { data } = await api.get('/admin/stats'); stats.value = data;
  } catch (e) {
    ElMessage.error(e.response?.data?.error || '删除失败');
  }
}

/* ====== Settings ====== */
const pwd = ref({ old: '', neu: '', neu2: '' });
const pwdBusy = ref(false);
async function changePassword() {
  if (!pwd.value.old || !pwd.value.neu) return ElMessage.warning('请填旧密码与新密码');
  if (pwd.value.neu !== pwd.value.neu2) return ElMessage.warning('两次新密码不一致');
  if (pwd.value.neu.length < 6) return ElMessage.warning('新密码至少 6 位');
  pwdBusy.value = true;
  try {
    await api.post('/admin/change-password', { old_password: pwd.value.old, new_password: pwd.value.neu });
    ElMessage.success('密码已修改，请用新密码重新登录');
    pwd.value = { old: '', neu: '', neu2: '' };
    setTimeout(logout, 1500);
  } catch (e) {
    ElMessage.error(e.response?.data?.error || '修改失败');
  } finally {
    pwdBusy.value = false;
  }
}

/* ====== utils ====== */
function fmtTime(ms) {
  if (!ms) return '—';
  const d = new Date(Number(ms));
  const pad = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}
function fmtBytes(b) {
  if (!b && b !== 0) return '—';
  if (b < 1024) return `${b} B`;
  if (b < 1024 * 1024) return `${(b / 1024).toFixed(1)} KB`;
  if (b < 1024 * 1024 * 1024) return `${(b / 1024 / 1024).toFixed(1)} MB`;
  return `${(b / 1024 / 1024 / 1024).toFixed(2)} GB`;
}

function bindUnauthorized() {
  window.addEventListener('xz-unauthorized', () => {
    token.value = '';
  });
}

onMounted(() => {
  bindUnauthorized();
  if (token.value) loadAll();
});
</script>

<style>
body { margin: 0; font-family: -apple-system, "Microsoft YaHei", sans-serif; }
.login-wrap { height: 100vh; display: flex; align-items: center; justify-content: center; background: #f0f2f5; }
.login-card { width: 340px; }
.aside { background: #0F2620; display: flex; flex-direction: column; }
.logo { color: #fff; font-size: 20px; font-weight: 700; text-align: center; padding: 18px 0; }
.aside-foot { margin-top: auto; padding: 12px; color: #8a8f99; font-size: 12px; display: flex; justify-content: space-between; align-items: center; }
.hdr { background: #fff; border-bottom: 1px solid #ebeef5; display: flex; align-items: center; font-weight: 600; }
.stat { text-align: center; }
.stat-num { font-size: 28px; font-weight: 700; color: #10B981; }
.stat-label { color: #909399; margin-top: 6px; }
.page-bar { display: flex; align-items: center; gap: 12px; margin-bottom: 12px; }
.el-menu { border-right: none !important; }
</style>