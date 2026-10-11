<template>
  <div class="login-wrap" v-if="!token">
    <!-- 首次运行：这台服务器还没人给管理台定过密码 → 先请管理员自己设一个。
         为什么不能只靠安装程序那一页：数据目录在卸载/重装后是**刻意保留**的，
         它一存在，安装向导就会跳过「设置管理后台密码」那一页；飞牛 fpk 更是
         压根没有那一页（口令由装机脚本随机生成）。两种情况客户看到的都一样 ——
         只有一个登录页，却不知道该往里输什么。 -->
    <el-card class="login-card login-card-wide" v-if="needSetup">
      <h2 style="text-align:center;margin-bottom:6px">{{ brand }}</h2>
      <p style="text-align:center;color:#909399;font-size:12.5px;margin:0 0 14px">首次运行 · 初始化</p>
      <el-alert type="info" show-icon :closable="false" style="margin-bottom:12px"
        title="请为管理台设置一个登录密码"
        description="这台服务器还没有人设过管理密码。现在就设一个，以后用 admin 加这个密码登录。" />
      <el-alert v-if="err" :title="err" type="error" show-icon :closable="false" style="margin-bottom:12px" />
      <el-input v-model="setupForm.username" disabled />
      <el-input v-model="setupForm.password" type="password" show-password placeholder="设置密码" style="margin-top:12px" @keyup.enter="doSetup" />
      <el-input v-model="setupForm.confirm" type="password" show-password placeholder="再输一遍确认" style="margin-top:12px" @keyup.enter="doSetup" />
      <el-button type="primary" style="width:100%;margin-top:18px" :loading="loading" @click="doSetup">完成初始化并进入管理台</el-button>
      <p style="margin-top:10px;color:#999;font-size:12px;text-align:center">
        6~64 位，只能用字母、数字和 . _ - @ ! * + ? 这几种符号 ——
        这串密码还要写进配置文件，空格和引号会在那里出问题。
      </p>
      <p style="margin-top:4px;text-align:center">
        <a style="font-size:12px;color:#909399;cursor:pointer;text-decoration:none" @click="needSetup = false">我已经知道密码，直接登录</a>
      </p>
    </el-card>

    <el-card class="login-card" v-else>
      <h2 style="text-align:center;margin-bottom:6px">{{ brand }}</h2>
      <p style="text-align:center;color:#909399;font-size:12.5px;margin:0 0 16px">服务端可视化管理后台</p>
      <el-alert v-if="err" :title="err" type="error" show-icon :closable="false" style="margin-bottom:12px" />
      <el-input v-model="form.username" placeholder="管理员账号" @keyup.enter="login" />
      <el-input v-model="form.password" type="password" placeholder="密码" style="margin-top:12px" @keyup.enter="login" />
      <el-button type="primary" style="width:100%;margin-top:18px" :loading="loading" @click="login">登录</el-button>
      <!-- 不写默认密码：从前这里写着「默认 admin / admin123」，等于在登录页上
           教所有人用弱口令，而那段代码还在公开仓库里待过。 -->
      <p style="margin-top:10px;color:#999;font-size:12px;text-align:center">
        Windows 版忘记密码：双击安装目录里的「查看管理员密码.cmd」可以查回来
      </p>
    </el-card>
  </div>

  <el-container v-else style="height:100vh">
    <el-aside width="200px" class="aside">
      <div class="logo">{{ brand }}</div>
      <!-- 菜单区独立滚动：分类展开后总高仍可能超过视口，没有这层就是"点不到"。 -->
      <div class="aside-menu">
        <el-menu ref="menuRef" :default-active="tab" :default-openeds="openedGroups" unique-opened
                 @select="tab = $event"
                 background-color="#0F2620" text-color="#c0c4cc" active-text-color="#10B981">
          <el-menu-item index="dashboard">
            <el-icon><Odometer /></el-icon><span>仪表盘</span>
          </el-menu-item>

          <!-- 分类顺序按"管理员一天里的使用频度"排：先人、再日常、再对接、再业务、最后系统。 -->
          <el-sub-menu index="g-org">
            <template #title><el-icon><User /></el-icon><span>组织与用户</span></template>
            <el-menu-item index="users">用户管理</el-menu-item>
            <el-menu-item index="groups">群组管理</el-menu-item>
            <el-menu-item index="friends">好友关系</el-menu-item>
            <el-menu-item index="orgs">组织机构</el-menu-item>
          </el-sub-menu>

          <el-sub-menu index="g-office">
            <template #title><el-icon><Calendar /></el-icon><span>日常办公</span></template>
            <el-menu-item index="attendance">考勤管理</el-menu-item>
            <el-menu-item index="files">文件管理</el-menu-item>
            <el-menu-item index="messages">消息管理</el-menu-item>
          </el-sub-menu>

          <el-sub-menu index="g-link">
            <template #title><el-icon><Connection /></el-icon><span>对外对接</span></template>
            <el-menu-item index="integrations">集成对接</el-menu-item>
            <el-menu-item index="upstreams">上游接口</el-menu-item>
            <el-menu-item index="clientconfig">客户端配置</el-menu-item>
            <el-menu-item index="push">消息推送</el-menu-item>
          </el-sub-menu>

          <el-sub-menu index="g-biz">
            <template #title><el-icon><Goods /></el-icon><span>业务模块</span></template>
            <!-- 盘点分组：库房减货是盘点的子功能，收在"盘点"下，不再是并列入口 -->
            <el-sub-menu index="g-inv">
              <template #title><span>盘点</span></template>
              <el-menu-item index="master">商品档案</el-menu-item>
              <el-menu-item index="deduct">库房减货</el-menu-item>
            </el-sub-menu>
            <el-menu-item index="modules">动态模块</el-menu-item>
            <el-menu-item index="training">培训中心</el-menu-item>
          </el-sub-menu>

          <el-sub-menu index="g-sys">
            <template #title><el-icon><Setting /></el-icon><span>系统</span></template>
            <el-menu-item index="deploywizard">部署向导</el-menu-item>
            <el-menu-item index="settings">系统设置</el-menu-item>
            <el-menu-item index="health">数据体检</el-menu-item>
            <el-menu-item index="license">授权管理</el-menu-item>
            <el-menu-item index="help">系统帮助</el-menu-item>
          </el-sub-menu>
        </el-menu>
      </div>
      <div class="aside-foot">
        <span class="aside-status"><i class="dot"></i>服务端运行中</span>
        <el-button text size="small" class="aside-out" @click="logout">退出</el-button>
      </div>
    </el-aside>

    <el-container>
      <el-header class="hdr">
        <span>{{ brand }} · 服务端可视化管理</span>
        <el-tag v-if="info.version" type="success" effect="plain" size="small">v{{ info.version }}</el-tag>
        <!-- 授权状态常驻顶栏：到期前几个月就要看得见，不能等人点进授权页才发现 -->
        <el-tag v-if="licenseState" :type="licTagType" effect="plain" size="small"
                style="margin-left:6px;cursor:pointer" @click="tab = 'license'">{{ licHeadline }}</el-tag>
      </el-header>
      <el-main>
        <!-- 仪表盘 -->
        <div v-if="tab === 'dashboard'">
          <!-- 异常提醒：只在真出问题时出现，平时不占地方 -->
          <el-alert v-for="a in dashAlerts" :key="a.key" :type="a.type" show-icon :closable="false"
                    class="dash-alert">
            <template #title>
              <span class="dash-alert-title">{{ a.title }}</span>
              <el-button type="primary" link @click="tab = a.tab">{{ a.action }} →</el-button>
            </template>
            <div class="dash-alert-desc">{{ a.desc }}</div>
          </el-alert>

          <!-- 上手向导：按服务器真实状态动态打勾。新手进来先看这块，
               不用读文档也知道下一步该做什么、点哪儿。 -->
          <el-card class="setup" shadow="never">
            <template #header>
              <div class="card-hdr">
                <span>
                  上手向导
                  <span class="hint" style="margin-left:8px">照着做，几分钟把这套系统跑起来</span>
                </span>
                <div>
                  <el-tag :type="setupDone ? 'success' : 'primary'" effect="plain" size="small">
                    {{ setupDoneCount }} / {{ setupSteps.length }} 已完成
                  </el-tag>
                  <el-button v-if="setupDone" type="primary" link @click="setupOpen = !setupOpen">
                    {{ setupOpen ? '收起' : '展开' }}
                  </el-button>
                  <el-button type="primary" link @click="tab = 'help'">完整帮助 →</el-button>
                </div>
              </div>
            </template>
            <div v-show="!setupDone || setupOpen">
              <el-progress :percentage="setupPercent" :stroke-width="8" :show-text="false" class="setup-bar" />
              <div v-for="(s, i) in setupSteps" :key="s.key" class="setup-item" :class="{ done: s.done }">
                <span class="setup-mark">{{ s.done ? '✓' : i + 1 }}</span>
                <div class="setup-body">
                  <div class="setup-title">{{ s.title }}</div>
                  <div class="setup-desc">{{ s.desc }}</div>
                </div>
                <el-button size="small" :type="!s.done && s.primary ? 'primary' : 'default'"
                           @click="tab = s.tab">{{ s.actionText }}</el-button>
              </div>
              <div v-if="setupDone" class="setup-allgood">
                全部就绪 —— 剩下的就是把客户端发给同事用起来。
              </div>
            </div>
          </el-card>

          <!-- 指标：按用途分组，每组一个图标 + 一种配色；带「今日」的显示今天新增；
               带 tab 的整块可点，直达对应页面 -->
          <div class="dash-groups">
            <el-card v-for="g in metricGroups" :key="g.key" shadow="never" class="mgroup">
              <template #header>
                <div class="card-hdr">
                  <span class="mgroup-title">
                    <span class="mgroup-ic" :class="'tone-' + g.tone">{{ g.glyph }}</span>
                    {{ g.title }}
                  </span>
                  <el-button type="primary" link @click="tab = g.tab">{{ g.link }} →</el-button>
                </div>
              </template>
              <div class="mtiles">
                <div v-for="it in g.items" :key="it.key" class="mtile"
                     :class="{
                       clickable: !!it.tab,
                       'mtile-warn': it.warn && (stats[it.key] || 0) > 0,
                       'mtile-dim': it.dim,
                     }"
                     :title="it.tab ? '点击进入' + (it.label) : ''"
                     @click="it.tab && (tab = it.tab)">
                  <div class="mtile-k">{{ it.label }}</div>
                  <div class="mtile-v">{{ it.raw ?? (stats[it.key] ?? '—') }}</div>
                  <div class="mtile-d" v-if="it.today && (stats[it.today] || 0) > 0">
                    今日 +{{ stats[it.today] }}
                  </div>
                  <div class="mtile-d muted" v-else-if="it.today">今日 0</div>
                  <div class="mtile-d muted" v-else-if="it.hint">{{ it.hint }}</div>
                </div>
              </div>
            </el-card>
          </div>

          <!-- 系统说明：读一次就够的内容，默认收起，不占首屏 -->
          <el-card shadow="never" class="dash-doc">
            <template #header>
              <div class="card-hdr">
                <span>系统说明</span>
                <div>
                  <el-button type="primary" link @click="docOpen = !docOpen">
                    {{ docOpen ? '收起' : '展开' }}
                  </el-button>
                  <el-button type="primary" link @click="tab = 'help'">完整系统帮助 →</el-button>
                </div>
              </div>
            </template>
            <div v-show="docOpen" class="doc-body">
              <!-- 一句话定位：这是与公有云 IM 的根本区别，放最上面 -->
              <div class="doc-lead">
                <b>私有化部署</b>：服务端就是你家 NAS（飞牛 / 群晖 / 绿联 / 麒麟）上的一个 Docker 应用，
                数据 100% 存在你自己的机器上，<b>不经任何第三方云</b>；管理台就是当前这个网页。
              </div>

              <div class="doc-grid">
                <section class="doc-card">
                  <div class="doc-card-h">
                    <span class="mgroup-ic tone-blue">端</span>客户端
                    <span class="doc-tag">Windows / Android</span>
                  </div>
                  <ul>
                    <li><b>导航</b>：手机是底部标签栏、电脑是左侧导航条。普通模式「消息 / 通讯录 / 我」；
                      <b>工作模式多一个「工作台」</b>——考勤打卡、我的申请等入口都在里面。</li>
                    <li><b>消息</b>：文字 / 图片 / 文件 / 语音 / 表情 / 卡片；单聊与群聊、@ 提及、已读回执、
                      撤回、转发、收藏、置顶、免打扰、全局搜索。</li>
                    <li><b>群管理</b>：群公告、成员管理、禁言、群主转让。</li>
                    <li><b>通话与远程</b>：语音 / 视频通话（群内最多 6 人）；Windows 端可被<b>远程协助</b>接管屏幕。</li>
                    <li><b>安装</b>：Windows 装 exe、安卓装 APK，首次启动自动扫描局域网找服务器。
                      iOS 仍在开发中（需 Mac 打包），暂未提供安装包。</li>
                  </ul>
                </section>

                <section class="doc-card">
                  <div class="doc-card-h">
                    <span class="mgroup-ic tone-green">台</span>管理台
                    <span class="doc-tag">就是本页</span>
                  </div>
                  <ul>
                    <li><b>人员与组织</b>：用户、群组、好友关系；<b>工作模式</b>下另有组织机构
                      （部门 / 岗位 / 员工，支持 Excel 批量导入）与<b>考勤打卡</b>。</li>
                    <li><b>内容与存储</b>：消息检索与批量清理、文件查看与批量清理、
                      存储占用分析、孤儿文件巡检。</li>
                    <li><b>数据体检</b>（系统 → 数据体检）：本库没有外键约束，
                      页面会列出所有已知关联的孤儿行（指向已删除对象的残留记录），
                      可安全清理的会标「可清理」，<b>产品刻意保留的</b>
                      （离职员工的消息、考勤记录、审批留痕）标「保留」并说明原因，
                      服务端也会拒绝清理它们。</li>
                    <li><b>集成与下发</b>：入站推送、事件订阅、公钥接入；客户端配置（含强制升级）、
                      动态模块按人下发。</li>
                    <li><b>总览</b>：仪表盘 —— 今日新增、近 7 天活跃、异常提醒、上手向导。</li>
                  </ul>
                </section>
              </div>

              <div class="doc-grid">
                <section class="doc-card doc-soft">
                  <div class="doc-card-h"><span class="mgroup-ic tone-purple">启</span>从哪里开始</div>
                  <ul>
                    <li>回「<b>仪表盘</b>」看顶部<b>上手向导</b>：按服务器当前状态列出还差哪几步，点一下直达对应页面。</li>
                    <li><b>开户</b>：普通模式在「用户管理 → 新建用户」，或让同事自己在客户端注册；
                      工作模式在「组织机构 → 员工管理」按工号录入（工号 = 登录账号、初始密码 = 工号），人多用 Excel 批量导入。</li>
                    <li>细节问题（考勤怎么算、外网通话怎么通）见「<b>系统帮助</b>」页。</li>
                  </ul>
                </section>

                <section class="doc-card doc-soft">
                  <div class="doc-card-h"><span class="mgroup-ic tone-amber">!</span>两个高频注意点</div>
                  <ul>
                    <li><b>管理员密码</b>在「系统设置」里改，改完即生效，不用重启。</li>
                    <li><b>外网通话</b>要通，必须先配好音视频中继（见「系统帮助 → 音视频通话与网络穿透」）。
                      注意：两台都在同一个 Wi-Fi 下测不出问题，要用手机流量实测。</li>
                  </ul>
                </section>
              </div>
            </div>
          </el-card>
        </div>

        <!-- 部署向导：换云服务器一键部署（frps/TURN/隧道/地址候选） -->
        <div v-else-if="tab === 'deploywizard'">
          <el-alert type="info" show-icon :closable="false" style="margin-bottom:14px;">
            <template #title>换云服务器 / 首次部署。服务器自身有公网 IP 时选「本地公网直连」更省事；否则选「云服务器隧道」走 frps。</template>
          </el-alert>

          <el-form label-width="0" style="margin-bottom:14px;">
            <el-radio-group v-model="dw.shape">
              <el-radio-button value="vps">云服务器隧道（frps）</el-radio-button>
              <el-radio-button value="direct">本地公网直连（不走隧道）</el-radio-button>
            </el-radio-group>
          </el-form>

          <el-steps v-if="dw.shape === 'vps'" :active="dw.active" align-center finish-status="success" style="margin-bottom:16px;">
            <el-step title="云服务器" description="frps + TURN 一键部署" />
            <el-step title="隧道接入" description="frpc 自动切换" />
            <el-step title="通话中继" description="双 TURN 并存下发" />
            <el-step title="客户端地址" description="候选地址更新" />
          </el-steps>

          <!-- 第 1 步 -->
          <el-card v-if="dw.shape === 'vps'" shadow="never" style="margin-bottom:14px;">
            <template #header><b>🖥️ 第 1 步 · 云服务器信息</b></template>
            <el-form label-width="90px" size="default" style="max-width:640px;">
              <el-form-item label="公网 IP"><el-input v-model="dw.vps.host" placeholder="例如 185.242.233.140" /></el-form-item>
              <el-form-item label="SSH 端口"><el-input-number v-model="dw.vps.port" :min="1" :max="65535" /></el-form-item>
              <el-form-item label="用户名"><el-input v-model="dw.vps.user" /></el-form-item>
              <el-form-item label="root 密码">
                <el-input v-model="dw.vps.password" type="password" show-password
                  :placeholder="dw.hasVpsPw ? '已保存（留空沿用）' : '请输入密码'" />
              </el-form-item>
              <el-form-item label="端口配置">
                <div style="display:flex;gap:10px;flex-wrap:wrap;">
                  <div><div style="font-size:11px;color:#909399;margin-bottom:2px;">服务端口（默认3602）</div>
                    <el-input-number v-model="dw.ports.server" :min="1" :max="65535" controls-position="right" style="width:130px;" /></div>
                  <div><div style="font-size:11px;color:#909399;margin-bottom:2px;">frp 端口（默认7000）</div>
                    <el-input-number v-model="dw.ports.frp" :min="1" :max="65535" controls-position="right" style="width:130px;" /></div>
                  <div><div style="font-size:11px;color:#909399;margin-bottom:2px;">TURN 端口（默认3478）</div>
                    <el-input-number v-model="dw.ports.turn" :min="1" :max="65535" controls-position="right" style="width:130px;" /></div>
                </div>
                <div style="font-size:11px;color:#9ca3af;margin-top:4px;">改服务端口后，地址候选 / frpc 转发 / 健康检查全程跟随；服务端本身要配套改（飞牛改 docker/.env 的 PORT，Win 改 data\.env 的 PORT）。</div>
              </el-form-item>
            </el-form>
            <el-button @click="dwSave('vps')" :loading="dw.busy==='save-vps'">保存凭据</el-button>
            <el-button @click="dwTest('vps')" :loading="dw.busy==='test-vps'">测试连接</el-button>
            <el-button type="primary" @click="dwStart('vps-deploy')"
              :disabled="dw.task.state==='running' || !dw.vps.host">🚀 一键部署 frps + TURN</el-button>
            <pre v-if="dw.task.steps && dw.task.steps.length"
              style="margin-top:12px;background:#0f172a;color:#86efac;border-radius:8px;padding:10px 12px;font-size:12px;line-height:1.7;max-height:260px;overflow:auto;font-family:Consolas,monospace;white-space:pre-wrap;">{{ dw.task.logs.map(l => l.line).join('\n') }}</pre>
          </el-card>

          <!-- 第 2 步：形态自动判定 —— frpc 必须跟服务端同机 -->
          <el-card v-if="dw.shape === 'vps'" shadow="never" style="margin-bottom:14px;">
            <template #header><b>🔌 第 2 步 · frp 隧道接入</b>
              <el-tag size="small" :type="dwIsWin ? 'warning' : 'success'" style="margin-left:6px;">{{ dwIsWin ? 'Windows 服务端 · 本机模式' : '飞牛 NAS · SSH 模式' }}</el-tag>
            </template>
            <!-- Windows 本机模式：无 SSH，frpc.exe + 启动文件夹自启 -->
            <template v-if="dwIsWin">
              <div style="font-size:13px;line-height:1.9;color:#374151;">
                服务端就跑在本机（Windows），向导直接本机操作，<b>不用填任何 SSH</b>：<br />
                · <code style="background:#f3f4f6;padding:1px 6px;border-radius:4px;">frpc.toml</code> 自动生成到数据目录 frpc\ 下（本机服务 {{ dw.ports.server }} → 公网 {{ dw.ports.server }}）<br />
                · frpc.exe 首次自动从 GitHub 下载（已存在则跳过）<br />
                · 常驻 = 当前用户「启动」文件夹开机自启 + 立即启动
              </div>
              <el-button type="primary" style="margin-top:10px;" @click="dwStart('tunnel')"
                :disabled="dw.task.state==='running' || dw.active < 1 || !dw.vps.host">自动接入隧道</el-button>
            </template>
            <!-- 飞牛 SSH 模式 -->
            <template v-else>
              <el-form label-width="90px" size="default" style="max-width:640px;">
                <el-form-item label="飞牛地址"><el-input v-model="dw.fnos.host" /></el-form-item>
                <el-form-item label="SSH 端口"><el-input-number v-model="dw.fnos.port" :min="1" :max="65535" /></el-form-item>
                <el-form-item label="用户名"><el-input v-model="dw.fnos.user" /></el-form-item>
                <el-form-item label="密码">
                  <el-input v-model="dw.fnos.password" type="password" show-password
                    :placeholder="dw.hasFnosPw ? '已保存（留空沿用）' : '请输入密码'" />
                </el-form-item>
              </el-form>
              <el-button @click="dwSave('fnos')" :loading="dw.busy==='save-fnos'">保存凭据</el-button>
              <el-button @click="dwTest('fnos')" :loading="dw.busy==='test-fnos'">测试连接</el-button>
              <el-button type="primary" @click="dwStart('tunnel')"
                :disabled="dw.task.state==='running' || dw.active < 1">自动切换隧道到新服务器</el-button>
              <div style="margin-top:8px;color:#9ca3af;font-size:12px;">旧配置自动备份（frpc.toml.bak-*）；其他代理（工厂/网管等）原样保留，只换服务器地址与小智端口。</div>
            </template>
          </el-card>

          <!-- 第 3 步 -->
          <el-card v-if="dw.shape === 'vps'" shadow="never" style="margin-bottom:14px;">
            <template #header><b>📞 第 3 步 · 通话 TURN 中继</b></template>
            <el-button type="primary" @click="dwTurn" :disabled="dw.active < 2 || dw.busy==='turn'"
              :loading="dw.busy==='turn'">写入中继配置并重启生效</el-button>
            <div v-if="dw.ice" style="margin-top:10px;font-size:13px;">
              <el-tag :type="dw.ice.hasVps ? 'success' : 'danger'">{{ dw.ice.hasVps ? '✓ VPS 中继已进入下发' : '✗ VPS 中继未下发' }}</el-tag>
              <el-tag :type="dw.ice.hasCloudflare ? 'success' : 'info'" style="margin-left:6px;">Cloudflare {{ dw.ice.hasCloudflare ? '保留兜底' : '未配置' }}</el-tag>
            </div>
            <div style="margin-top:8px;color:#9ca3af;font-size:12px;">与 Cloudflare 托管中继并存，客户端自动挑通的用；重启服务端约 10~20 秒，期间管理台短暂失联。</div>
          </el-card>

          <!-- 第 4 步 / 本地公网直连：客户端地址候选 -->
          <el-card shadow="never" style="margin-bottom:14px;">
            <template #header><b>📱 客户端地址候选</b></template>

            <template v-if="dw.shape === 'vps'">
              <div style="font-size:13px;line-height:1.9;color:#374151;">
                到「<b>对外对接 → 客户端配置</b>」把服务器地址候选改为两条（客户端只吃前两条）：<br />
                <code style="background:#f3f4f6;padding:2px 6px;border-radius:4px;">http://&lt;飞牛内网IP&gt;:3602</code>
                （第 1 条 = 内网）
                <code style="background:#f3f4f6;padding:2px 6px;border-radius:4px;margin-left:8px;">http://&lt;VPS公网IP&gt;:3602</code>
                （第 2 条 = 外网）<br />
                发布后客户端启动时/每 30 分钟自动拉取，无需更新 App；内网外网自动探测互备。
              </div>
              <el-button style="margin-top:10px;" @click="tab = 'clientconfig'">前往客户端配置 →</el-button>
            </template>

            <template v-else>
              <div style="font-size:13px;line-height:1.9;color:#374151;margin-bottom:10px;">
                服务器本身有公网 IP，客户端直连即可（不走 frps 隧道）。填好下面地址，点「写入客户端地址候选」会直接发布到客户端配置中心；
                客户端按优先级并发探测 IPv4 / IPv6，哪个通连哪个。
              </div>
              <el-form label-width="110px" size="default" style="max-width:640px;">
                <el-form-item label="内网 LAN"><el-input v-model="dw.direct.lan" placeholder="http://192.168.x.x:3602（同局域网用）" /></el-form-item>
                <el-form-item label="公网 IPv4"><el-input v-model="dw.direct.ipv4" placeholder="http://你的公网IPv4:3602" /></el-form-item>
                <el-form-item label="公网 IPv6"><el-input v-model="dw.direct.ipv6" placeholder="http://[2001:db8::1]:3602（IPv6 用方括号）" /></el-form-item>
              </el-form>
              <el-button type="primary" :loading="dwDirectBusy" @click="dwWriteAddresses">写入客户端地址候选</el-button>
              <el-button @click="tab = 'clientconfig'">前往客户端配置细调 →</el-button>
            </template>
          </el-card>

          <!-- 健康检查 -->
          <el-card shadow="never">
            <template #header><b>🩺 健康检查</b> <el-button size="small" text @click="dwHealth" style="float:right;">刷新</el-button></template>
            <div v-for="h in dw.health" :key="h.key" style="display:flex;align-items:center;gap:8px;padding:6px 0;border-bottom:1px dashed #f0f0f0;font-size:13px;">
              <span :style="{width:'9px',height:'9px',borderRadius:'50%',flex:'none',background: h.ok ? '#10B981' : '#ef4444'}"></span>
              <span style="flex:1;">{{ h.label }}</span>
              <span style="color:#9ca3af;font-size:12px;">{{ h.detail || (h.ok ? '正常' : '不通') }}</span>
            </div>
          </el-card>
        </div>

        <!-- 系统帮助 -->
        <!-- 授权管理 -->
        <div v-else-if="tab === 'license'">
          <!-- 不可用时先讲清「为什么业务停了、怎么办」，再给操作入口。
               管理员登录进来看到的是满屏加载失败时，至少这里能告诉他根因。 -->
          <el-alert v-if="licenseState && !licenseState.ok" type="error" show-icon :closable="false" class="dash-alert">
            <template #title>{{ licenseState.message }}</template>
            <div class="dash-alert-desc">
              业务接口现在一律返回 403：员工登录不进来、消息发不出去、考勤打不了卡。登录与查看本页不受影响。
              把下面的机器码发给管理员换取授权码，粘贴到本页下方点「激活」即可立即恢复，<b>不需要重启服务</b>。
            </div>
          </el-alert>

          <el-card shadow="never">
            <template #header>
              <div class="card-hdr">
                <span>
                  授权状态
                </span>
                <el-button size="small" :loading="lic.loading" @click="loadLicense">刷新</el-button>
              </div>
            </template>

            <div v-if="licenseState" style="display:flex;align-items:center;gap:18px;flex-wrap:wrap">
              <el-tag :type="licTagType" effect="dark" size="large" style="font-size:15px;padding:0 14px;height:34px;line-height:34px">
                {{ licHeadline }}
              </el-tag>
              <div v-if="licenseState.daysLeft !== null && licenseState.daysLeft !== undefined"
                   style="display:flex;align-items:baseline;gap:6px">
                <b style="font-size:30px;line-height:1;color:#10B981">{{ licenseState.daysLeft }}</b>
                <span class="hint">天后到期</span>
              </div>
              <div v-else-if="licenseState.perpetual" style="display:flex;align-items:baseline;gap:6px">
                <b style="font-size:26px;line-height:1;color:#10B981">永久</b>
                <span class="hint">无需续费</span>
              </div>
            </div>

            <el-descriptions v-if="licenseState" :column="2" border style="margin-top:16px">
              <el-descriptions-item label="授权类型">{{ licModeText }}</el-descriptions-item>
              <el-descriptions-item label="到期时间">
                {{ licenseState.expiresAt ? licTime(licenseState.expiresAt) : '永久有效' }}
              </el-descriptions-item>
              <el-descriptions-item label="开始使用">{{ licenseState.installedAt ? licTime(licenseState.installedAt) : '-' }}</el-descriptions-item>
              <el-descriptions-item label="激活时间">{{ licenseState.activatedAt ? licTime(licenseState.activatedAt) : '未激活' }}</el-descriptions-item>
              <el-descriptions-item label="本机机器码" :span="2">
                <span style="font-family:ui-monospace,Consolas,monospace;font-size:15px;letter-spacing:1px;font-weight:600">
                  {{ licenseState.machineCode }}
                </span>
                <el-button type="primary" link style="margin-left:10px" @click="copyMc">复制</el-button>
                <span class="hint" style="margin-left:8px">出码时把这串发出去</span>
              </el-descriptions-item>
            </el-descriptions>

            <!-- 指纹来源必须可见：忘了挂载宿主机标识时，机器码会随容器重建而变，
                 那是最坏体验（升级一次授权就没了），必须提前警示而不是等出事。 -->
            <el-alert v-if="licenseState && licenseState.fingerprint && !licenseState.fingerprint.reliable"
                      type="warning" show-icon :closable="false" style="margin-top:12px">
              <template #title>机器码可能不稳定，重建容器后有失效风险</template>
              <div class="dash-alert-desc">{{ licenseState.fingerprint.hint }}</div>
            </el-alert>
            <p v-else-if="licenseState" class="hint" style="margin:12px 0 0">
              机器码来源：{{ licenseState.fingerprint.hint }}
              <span v-if="licenseState.locationMismatch">（数据目录变更过，仅作提示，不影响授权）</span>
            </p>
          </el-card>

          <el-card shadow="never" style="margin-top:16px">
            <template #header>
              <div class="card-hdr"><span>填写授权码</span></div>
            </template>
            <p class="hint" style="margin:0 0 10px">
              把上面的机器码发给管理员 → 拿到授权码 → 粘贴到这里 → 点激活。
              激活即时生效，不用重启服务；换机器后需要重新出码（这是防整套拷贝白嫖的机制）。
            </p>
            <el-input v-model="lic.token" type="textarea" :rows="3"
                      placeholder="粘贴授权码（一长串，形如 eyJ2IjoxLCJ0eXAiOiJkZXZpY2Ui…==.AbCdEf…）" />
            <div style="margin-top:12px;display:flex;align-items:center;gap:10px;flex-wrap:wrap">
              <el-button type="primary" :loading="lic.activating" @click="doActivate">激活</el-button>
              <el-button v-if="licenseState && licenseState.mode !== 'none'" @click="doDeactivate">解绑本机</el-button>
              <span class="hint">解绑后回到受限状态，试用期起点不会重置</span>
            </div>
          </el-card>
        </div>

        <div v-else-if="tab === 'help'">
          <el-card class="help">
            <template #header>
              <div class="card-hdr">
                <span>系统帮助</span>
                <span class="hint">输入关键词，搜索你遇到的问题</span>
              </div>
            </template>

            <el-alert type="success" :closable="false" style="margin-bottom:16px">
              <template #title>
                数据 100% 在你自己机器上，不经过任何第三方云 —— 这是本系统与公有云 IM 的根本区别。
              </template>
            </el-alert>

            <!-- 搜索框：输入即筛选下方常见问题（套工厂V2「搜索问题→解决问题」模式） -->
            <el-input v-model="helpSearch" size="large" clearable
              placeholder="搜索你遇到的问题，如：外网通话打不通、忘记密码、考勤看不到入口、客户端怎么更新…"
              style="margin-bottom:4px">
              <template #prefix><span style="font-size:16px;color:#909399">🔍</span></template>
            </el-input>
            <div class="hint" style="margin-bottom:16px">输入关键词即时筛选下方常见问题；没有匹配时请往下看各章节的完整说明。</div>

            <!-- 常见问题（可搜索问答） -->
            <section class="help-sec">
              <h3>常见问题（输入即筛选）</h3>
              <el-empty v-if="helpSearch && !helpFaqFiltered.length" description="没有匹配的问答，换个更短的关键词，或查看下方各章节的完整说明" />
              <el-collapse v-else :model-value="helpSearch ? helpFaqFiltered.map((_, i) => String(i)) : []">
                <el-collapse-item v-for="(it, i) in helpFaqFiltered" :key="i" :name="String(i)">
                  <template #title><span class="faq-q">{{ it.q }}</span></template>
                  <div class="faq-a" v-html="it.a"></div>
                </el-collapse-item>
              </el-collapse>
            </section>

            <section class="help-sec">
              <h3>一、这是什么</h3>
              <ul>
                <li><b>服务端</b>跑在自家 NAS（飞牛 FnOS，Docker 方式），提供消息收发、文件存储、通话信令与中继、以及对外集成接口。</li>
                <li><b>客户端</b>是 Windows / Android 应用，采用宽屏双栏 / 窄屏跳转的自适应布局
                  （手机底部标签栏、电脑左侧导航条；工作模式多一个「工作台」）；
                  首次启动会自动探测服务器地址，也可在 App 内「服务器设置」手动指定。
                  <b>iOS 仍在开发中</b>（需要 Mac 打包），暂未提供安装包。</li>
                <li><b>管理台</b>就是当前这个网页，管用户、群组、好友关系、文件、消息，以及和外部系统的对接。</li>
              </ul>
            </section>

            <section class="help-sec">
              <h3>二、五分钟上手</h3>
              <el-alert type="success" :closable="false" style="margin-bottom:14px">
                <template #title>
                  <b>不想读文档？</b>回「仪表盘」，顶上有一份<b>上手向导</b>：它会按服务器当前状态列出还没做的事，
                  每一条都能一键跳到对应页面，跟着做完系统就能用了。
                </template>
              </el-alert>

              <p><b>管理员这边（服务端）</b></p>
              <el-steps :active="4" align-center style="margin:6px 0 14px">
                <el-step title="设公司名" description="客户端显示「××小智」" />
                <el-step title="开户" description="普通模式建用户 / 工作模式录员工" />
                <el-step title="配中继" description="手机在外也能通话" />
                <el-step title="发客户端" description="装 exe / APK 给同事" />
              </el-steps>

              <p><b>同事这边（客户端）</b></p>
              <el-steps :active="3" align-center style="margin:6px 0 14px">
                <el-step title="装客户端" description="Windows 装 exe / 安卓装 APK" />
                <el-step title="连服务器" description="自动扫描局域网，或手填内网地址" />
                <el-step title="开聊" description="搜索同事发消息（工作模式下同事已互为好友）" />
              </el-steps>

              <ul>
                <li>Windows 端解压后双击 <code class="mono">xiaozhi_im_client.exe</code>；<b>dll 与 data/ 目录必须一起保留</b>，不能只拷 exe。</li>
                <li>手机装 APK 时，若提示已存在旧版，请确认新包的文件名版本号比旧的高 —— <b>版本号不涨，安卓会静默跳过覆盖安装</b>。</li>
                <li><b>普通模式</b>：给同事开户用「用户管理 → 新建用户」，也可以让同事自己在客户端注册。</li>
                <li><b>工作模式</b>：登记用「组织机构 → 员工管理」（工号 = 登录账号、初始密码 = 工号），
                  人多就用<b>批量导入</b>把 Excel 名单粘进去；关掉自助注册后，别人也注册不了。</li>
              </ul>
            </section>

            <section class="help-sec">
              <h3>三、客户端能做什么</h3>
              <table class="help-table">
                <thead><tr><th style="width:130px">能力</th><th>说明</th></tr></thead>
                <tbody>
                  <tr><td>界面结构</td><td>手机底部标签栏、电脑左侧导航条。<b>普通模式</b>：消息 / 通讯录 / 我；
                    <b>工作模式</b>：消息 / <b>工作台</b> / 通讯录 / 我 —— 考勤打卡、我的申请、自定义应用都在「工作台」里。
                    原来收在右上角「⋮」菜单里的工作台、组织机构、个人信息，现在都是一级入口。</td></tr>
                  <tr><td>消息类型</td><td>文字 / 图片 / 文件 / 语音 / 表情 / 卡片（卡片由外部系统推送，用于告警、日报等结构化信息）</td></tr>
                  <tr><td>会话</td><td>单聊、群聊、群公告、群成员管理、禁言、群主转让；免打扰</td></tr>
                  <tr><td>@ 提及</td><td>群内 @某人 / @所有人，被 @ 的人会在会话列表看到红字提示</td></tr>
                  <tr><td>消息操作</td><td>撤回（限时窗口内）、转发、收藏、复制、置顶</td></tr>
                  <tr><td>已读回执</td><td>单聊显示对方读到哪；群聊显示「所有人都读到」的水位</td></tr>
                  <tr><td>全局搜索</td><td>跨会话搜文字与卡片内容（图片/文件/语音不参与，因为内容不是可读文本）</td></tr>
                  <tr><td>好友</td><td>认证附言（附言模板最多 10 条）、<b>好友备注</b>（只自己可见，不改变对方昵称）；对方不在线时发出的申请，他下次上线会收到提醒</td></tr>
                  <tr><td>个人资料</td><td>头像、昵称、个性签名、性别、地区、生日；<b>修改密码</b>在「个人信息 → 账号」</td></tr>
                  <tr><td>音视频通话</td><td>单聊语音 / 视频通话（群内最多 6 人同时通话），含来电界面与断线重连</td></tr>
                  <tr><td>首次连接</td><td>装好后首次启动会<b>自动扫描局域网找服务器</b>；扫不到可在「服务器设置」手填内网地址，如 <code class="mono">http://192.168.1.100:3602</code></td></tr>
                  <tr><td>远程协助</td><td>无人值守被控（Windows 端），需要远程看对方屏幕时用</td></tr>
                </tbody>
              </table>
            </section>

            <section class="help-sec">
              <h3>四、管理台各页做什么</h3>
              <table class="help-table">
                <thead><tr><th style="width:130px">页面</th><th>说明</th></tr></thead>
                <tbody>
                  <tr><td>仪表盘</td><td><b>上手向导</b> + 各类计数总览（用户、群组、消息、文件、好友关系、机器人、入站推送、事件订阅、公钥接入；工作模式下多一张「组织人数」）</td></tr>
                  <tr><td>用户管理</td><td>新建 / 编辑 / 删除用户，改角色、重置密码。<b>工作模式下</b>新建普通用户会自动作为员工加入组织</td></tr>
                  <tr><td>群组管理</td><td>查看群与成员，必要时解散</td></tr>
                  <tr><td>好友关系</td><td>查看好友关系与备注，可解除关系</td></tr>
                  <tr><td>组织机构</td><td>工作模式专用：部门管理（支持父子层级）/ 岗位管理 / 员工管理（含 Excel 粘贴批量导入）。用法见「四之二」</td></tr>
                  <tr><td>考勤管理</td><td>工作模式专用（<b>随工作模式自动启用</b>）：打卡看板 / 统计报表 / 班次与考勤组 / 请假·补卡·外出·加班审批 / 考勤设置。用法见「四之四」</td></tr>
                  <tr><td>文件管理</td><td>查看磁盘占用与上传的文件，可删除</td></tr>
                  <tr><td>消息管理</td><td>按类型 / 关键词检索消息，用于排查与审计</td></tr>
                  <tr><td>集成对接</td><td>入站推送地址、事件订阅、公钥接入（详见第六节）</td></tr>
                  <tr><td>客户端配置</td><td>下发给客户端的配置：服务器地址、功能开关、公告、强制升级；带版本快照与按范围下发</td></tr>
                  <tr><td>动态模块</td><td>客户端首页的功能模块，可开关并指定下发给哪些人</td></tr>
                  <tr><td>系统设置</td><td>公司名称、好友模式（普通 / 工作，见「四之二」）、音视频中继配置、改管理员密码 —— 改完即生效，不用重启</td></tr>
                  <tr><td>系统帮助</td><td>就是本页</td></tr>
                </tbody>
              </table>
            </section>

            <section class="help-sec">
              <h3>四之二、工作模式与组织机构（公司统一开户用这个）</h3>
              <p>两种好友模式，二选一，在「系统设置」里切换：</p>
              <table class="help-table">
                <thead><tr><th style="width:150px">模式</th><th>适合谁 / 行为差异</th></tr></thead>
                <tbody>
                  <tr>
                    <td><b>普通好友模式</b><br /><el-tag size="small">默认</el-tag></td>
                    <td>家人、朋友、小团队。谁都能自助注册；互相搜账号发申请加好友；搜索能看到服务器上的所有人。</td>
                  </tr>
                  <tr>
                    <td><b>工作模式</b></td>
                    <td>
                      公司 / 工厂。关闭自助注册（注册会提示联系管理员）、不再随意加好友（同事关系由组织决定），
                      搜索只能搜到<b>同组织</b>的同事，避免把全员通讯录暴露给每个账号。<br />
                      人员由管理员在「组织机构」统一录入：<b>工号就是登录账号，初始密码 = 工号</b>，录入后自动与同事互为好友。
                    </td>
                  </tr>
                </tbody>
              </table>

              <p><b>开启工作模式后的三步</b></p>
              <el-steps :active="3" align-center style="margin:6px 0 14px">
                <el-step title="系统设置" description="切到工作模式" />
                <el-step title="组织机构" description="创建组织" />
                <el-step title="员工管理" description="录入 / 批量导入" />
              </el-steps>

              <p><b>批量导入员工（几百人的厂用这个，别一个个加）</b></p>
              <ol>
                <li>在 Excel 里排成四列：<code class="mono">工号 | 姓名 | 部门 | 岗位</code>（只有工号必填，其余可留空）。</li>
                <li>选中这些单元格 → <b>Ctrl + C</b> → 打开「组织机构 → 员工管理 → 批量导入」→ 直接 <b>Ctrl + V</b> 粘进输入框（也支持选 CSV 文件）。</li>
                <li>看一眼解析预览没问题，点「导入」。<b>部门 / 岗位不存在会自动创建</b>，同一批里同名的只建一次。</li>
                <li>结果弹窗会写清：新建多少人、自动建了哪些部门岗位、哪些行被跳过及原因（工号格式错 / 已在组织中）。<b>坏行不影响其它行</b>。</li>
              </ol>

              <el-alert type="warning" :closable="false" style="margin:10px 0">
                <template #title>
                  员工登录后，请提醒他到「个人信息 → 账号 → 修改密码」把初始密码改掉 —— 工号当密码只是方便第一次登录。
                  <b>忘记密码由管理员在「用户管理」里重置</b>，员工自己改不了别人的。
                </template>
              </el-alert>

              <p><b>从普通模式切到工作模式，已有的账号怎么办？</b></p>
              <ul>
                <li>已建立的好友关系<b>不受影响</b>，照常聊天。</li>
                <li>但这些账号如果没进组织，在工作模式下<b>搜不到任何人</b>（搜索被限定为同组织）。</li>
                <li>把它们<b>收编进组织</b>就行：在「员工管理」把账号本身当工号录入，系统识别出这是已有账号，
                  <b>只并入组织、不改密码</b>，随即与同事互为好友。批量导入同样支持（结果里显示「老账号归队 N 人」）。</li>
              </ul>
              <p class="help-tip">
                「移除员工」是离职语义：<b>账号保留</b>，仅退出组织、清掉部门岗位、解除与同事的好友关系。
                想让他回来，重新录入同一个工号即可，原密码依然有效。
              </p>
            </section>

            <section class="help-sec">
              <h3>四之三、客户端首次安装：怎么找到服务器</h3>
              <p>服务器地址只需配一次，三种方式任选：</p>
              <ol>
                <li><b>自动扫描（推荐）</b>：首次启动，或在「服务器设置」里点<b>「扫描内网服务器」</b>。
                  客户端向局域网广播探测，服务器应答后把结果列出来（带公司名，一眼认出自家），点一下即填入。</li>
                <li><b>手动填写</b>：在「服务器设置 → 内网地址」填 <code class="mono">http://服务器IP:3602</code>，
                  例如 <code class="mono">http://192.168.1.100:3602</code>。</li>
                <li><b>服务端下发</b>：连上服务器后客户端会自动拉取服务端配置（公司名、功能开关、公告、升级地址），不需要手工配。</li>
              </ol>
              <p class="help-tip">
                扫描依赖服务端 UDP <code class="mono">3616</code> 端口可达：Docker 部署时端口映射要有
                <code class="mono">3616:3616/udp</code>。<b>扫不到也不影响使用</b>，手填地址一样能连上。
              </p>
            </section>

            <section class="help-sec">
              <h3>四之四、考勤打卡（开启工作模式后自动启用）</h3>
              <p>
                <b>不用额外开启</b>：切到工作模式、建好组织并录入员工后，考勤即生效 ——
                员工端工作台出现「考勤打卡」，管理台出现「考勤管理」。
                默认班次 <code class="mono">08:00-17:00</code>、休息 <code class="mono">12:00-13:00</code>、
                工作日为周一至周五，不改也能用。
              </p>
              <p>
                <b>两类人看到的工作台不一样，这是有意的</b>：员工看到「考勤打卡 / 我的申请」（自己打卡、自己提申请）；
                管理员不参与考勤，看到的是「<b>考勤记录</b>」—— 手机上直接看<b>今天谁出勤、谁缺哪张卡</b>，
                谁漏打卡就在那一行点「补卡」代为补录。管理员的完整能力（报表 / 班次 / 考勤组 / 审批）在管理台「考勤管理」。
              </p>

              <p><b>1. 一天打几次卡：2 次 还是 4 次</b></p>
              <p>
                由班次里<b>有没有填休息开始/结束</b>决定，员工端与管理台都会跟着变，不用手工配第二遍：
              </p>
              <table class="help-table">
                <thead><tr><th style="width:120px">休息时段</th><th style="width:90px">一天几次卡</th><th>怎么打</th></tr></thead>
                <tbody>
                  <tr>
                    <td>两个都填</td><td><b>4 次</b></td>
                    <td>上班 → 下班 → 上班 → 下班（<b>四张卡名字一样，靠应打时刻区分是哪一段</b>）。两个在岗段<b>各算各的</b>：<br />
                      08:00-12:00 与 13:00-17:00 就是上午 4 小时 + 下午 4 小时 = 在岗 <b>8 小时</b>。</td>
                  </tr>
                  <tr><td>两个都空</td><td>2 次</td><td>传统的上班 / 下班。</td></tr>
                  <tr><td>只填一个</td><td colspan="2"><b>会被拒绝</b>。只填一个没法判断该打几次，静默忽略等于"我配了但它没生效"。</td></tr>
                </tbody>
              </table>
              <ul>
                <li>休息时段必须<b>严格落在上班与下班之间</b>（上班 &lt; 休息开始 &lt; 休息结束 &lt; 下班）。</li>
                <li><b>跨天夜班不支持休息时段</b>：凌晨那顿休息跨了日期，算不出正确的在岗时长，与其算错不如明确拒绝。</li>
                <li>同一个组织里<b>2 次卡与 4 次卡的人可以共存</b> —— 取决于各自命中的班次。</li>
                <li>4 次卡下第 1 段结束与收工是<b>两张不同的卡</b>（名字都叫"下班"，靠应打时刻区分）：
                  休息前打的那次不会把收工卡覆盖掉，补卡时也必须指明补<b>第几次</b>卡。</li>
              </ul>

              <p><b>2. 打卡怎么算</b></p>
              <ul>
                <li>每张卡各判各的：第 1 段的上班卡取当天最早，其余三张各取对应那一段的记录；
                  员工重复点同一张卡是<b>更新</b>那张卡（旧流水仍保留，管理台可查）。</li>
                <li>打卡时刻一律按<b>服务器时钟</b>记录，客户端改本机时间无效（否则考勤数据没有意义）。</li>
                <li>迟到 = 上班时间 + 弹性 + 迟到宽限之后才算；早退 = 下班时间 − 可提前打卡之前才算。
                  <b>弹性只作用于当天第一次上班卡</b> —— 下午那次若也给弹性，"晚到两小时"就变成合法了。</li>
                <li><b>在岗时长</b> = 两个在岗段之和（打完的段才算），班次上的"应出勤"是标准的 8 小时；
                  班次里填了休息时段后，「休息时长」那个数字不再参与计算。</li>
              </ul>

              <p><b>3. 每天的状态含义</b></p>
              <table class="help-table">
                <thead><tr><th style="width:110px">状态</th><th>含义</th></tr></thead>
                <tbody>
                  <tr><td>正常</td><td>该打的卡都在允许的时间范围内</td></tr>
                  <tr><td>迟到 / 早退</td><td>超出弹性与宽限；并给出分钟数。4 次卡会指明是哪一次卡迟到/早退</td></tr>
                  <tr><td>缺卡</td><td>有卡没打 —— 会<b>点名</b>缺的是哪张（如"缺 13:00 上班、17:00 下班"）；
                    该到点但没到点的不判缺卡，显示「进行中」</td></tr>
                  <tr><td>缺勤</td><td>当天一张卡都没打、也没有请假/外出覆盖</td></tr>
                  <tr><td>请假 / 外出</td><td>当天有审批通过的请假或外出申请，不再判缺勤。
                    半天假只豁免对应那半天的卡（上午假 → 免第 1 段那两张卡）</td></tr>
                  <tr><td>休息</td><td>该星期不在「工作日」里（可在考勤设置里改），不判缺勤</td></tr>
                  <tr><td>进行中</td><td>今天还有卡没到点，尚未发生的事不预先判异常（所以上午打开不会满屏"缺卡"）</td></tr>
                </tbody>
              </table>

              <p><b>4. 班次与考勤组（不同人群不同作息时用）</b></p>
              <ul>
                <li><b>班次</b>：几点上下班、休息时段、弹性打卡、迟到宽限、可提前打卡。
                  <b>下班时间早于或等于上班时间即视为跨天夜班</b>（如 22:00-06:00），次日凌晨打的下班卡会正确算进前一天。</li>
                <li><b>考勤组</b>：把某些人归到某个班次。成员可以<b>按部门</b>纳入（含子部门，新员工入职自动进组），也可以<b>点名到人</b>。</li>
                <li>一个人同时命中多个组时：<b>点名优先</b>，其次按考勤组创建顺序取第一个。<b>不在任何组的人</b>按组织默认班次打卡。</li>
              </ul>

              <p><b>5. 请假 / 补卡 / 外出 / 加班</b></p>
              <ul>
                <li>员工在客户端「我的申请」提交，管理台「考勤管理 → 申请审批」里通过或驳回（驳回需填原因）。</li>
                <li><b>补卡</b>通过后立即写入当天对应打卡记录（来源标记为"补卡审批"），当天状态随之修正。
                  4 次卡下补卡要指明补<b>第几次</b>（员工端与管理端都是点"上班 13:00"这种带时刻的按钮）——
                  只给类型的话，卡会补到错误的段上，看着补了、报表上那天依旧缺卡。</li>
                <li><b>请假</b>支持单日半天（上午/下午）；多日请假按整天计，单次最多 30 天。</li>
                <li><b>外出</b>覆盖其时段碰到的那张卡（上午外出就不判缺上班卡）；<b>加班</b>计入统计的加班时长。</li>
              </ul>

              <p><b>6. 员工漏打卡怎么办</b></p>
              <ol>
                <li>让员工自己提交<b>补卡</b>申请（客户端 → 我的申请 → 补卡），管理员审批通过即修正 —— 推荐，留痕清楚。</li>
                <li>或管理员在客户端<b>工作台 →「考勤记录」</b>里找到那个人点「补卡」——手机上就能办，不用开电脑。</li>
                <li>或在管理台「打卡看板」那行点<b>「补卡」</b>直接补录：弹窗会默认选中<b>缺的那张卡</b>，也可以换（来源标记为"管理员补录"）。</li>
                <li>点<b>「明细」</b>可看某人当天的全部打卡流水（含被更新掉的旧流水），必要时删除某条。</li>
              </ol>

              <p class="help-tip">
                统计报表选部门会<b>连子部门一起算</b>；点人员行首的展开箭头可看该人每天的明细（每张卡一个标签）。
                报表上的「漏打卡」按<b>张</b>统计 —— 4 次卡下一天缺 3 张也只算 1 天「缺卡」，
                按张看才知道谁没打满。停用考勤（考勤设置里）只是让员工端入口消失，<b>历史打卡与申请记录都保留</b>。
              </p>
            </section>

            <section class="help-sec">
              <h3>五、音视频通话与网络穿透（外网通话不通先看这里）</h3>
              <p>通话建立分两步：</p>
              <ol>
                <li><b>优先 P2P 直连</b> —— 两端直接连，延迟最低。靠 <b>STUN</b> 问出各自的公网地址后互相打洞。</li>
                <li><b>打不通就走中继</b> —— 手机 4G/5G、公司网络这类<b>对称 NAT</b> 环境打洞必失败，必须由 <b>TURN</b> 服务器转发媒体。</li>
              </ol>
              <el-alert type="info" :closable="false" style="margin:10px 0">
                <template #title>
                  本系统的 STUN / TURN 配置由<b>服务端下发</b>（<code class="mono">GET /api/call/ice</code>），
                  客户端每 5 分钟拉一次。所以<b>换中继地址只需改服务端 .env 重启，不用重新发客户端</b>。
                </template>
              </el-alert>
              <p>中继有两种来源，配其一即可，都配就是双保险：</p>
              <table class="help-table">
                <thead><tr><th style="width:170px">方案</th><th>说明 / 配置</th></tr></thead>
                <tbody>
                  <tr>
                    <td><b>Cloudflare TURN</b><br /><el-tag size="small" type="success">推荐</el-tag></td>
                    <td>
                      <b>不需要任何端口映射</b>，只用出站连接，走 443/TLS，任何网络都出得去。
                      免费额度 <b>1TB / 月</b>。<br />
                      .env 填 <code class="mono">CF_TURN_KEY_ID</code> 与
                      <code class="mono">CF_TURN_API_TOKEN</code>（scope 选 Calls: Edit）。
                    </td>
                  </tr>
                  <tr>
                    <td><b>自建 coturn</b><br /><span class="hint">飞牛上已部署</span></td>
                    <td>
                      延迟更低，但<b>必须让公网能打进家里的 UDP/TCP 端口</b>：
                      ① 真公网 IP + 路由器映射 <code class="mono">3478/udp</code>、<code class="mono">3478/tcp</code>、
                      <code class="mono">49160-49200/udp</code>；或 ② 用支持 TCP/UDP 的隧道服务。<br />
                      免费版 ZeroNews <b>不支持</b> TCP/UDP 隧道，单靠它无法承载中继。
                    </td>
                  </tr>
                </tbody>
              </table>
              <p class="help-tip">
                排障顺序：先看「系统设置」里有没有下发 TURN → 再用<b>手机流量</b>实测一次真实跨网通话。
                两台都在同一个 Wi-Fi 下测不出问题。
              </p>
            </section>

            <section class="help-sec">
              <h3>五之二、从零申请 Cloudflare TURN（推荐方案，全程免费、无需信用卡）</h3>
              <el-alert type="warning" :closable="false" style="margin-bottom:12px">
                <template #title>
                  先明确一件事：<b>Cloudflare TURN 不需要信用卡、不需要绑付款方式</b>。
                  建 key 那一步没有任何付款环节，免费额度 1000 GB / 月（仅 TURN 用量），
                  家用 1 对 1 通话根本用不完。
                </template>
              </el-alert>

              <p><b>第一步：登录控制台，找到正确的页面</b></p>
              <ol>
                <li>浏览器打开 <code class="mono">dash.cloudflare.com</code> 并登录（没有账号就免费注册一个）。</li>
                <li>
                  看<b>左侧菜单</b>，找 <b>「媒体」</b>（英文 Media）→ 点开 <b>「Realtime」</b> →
                  再点 <b>「TURN 服务器」</b>（英文 TURN Server）。
                </li>
                <li>
                  <b>找不到菜单就用直达网址</b>（最省事）：
                  <div class="mono" style="margin:6px 0;padding:8px 10px;background:var(--el-fill-color-light);border-radius:6px;user-select:all">
                    https://dash.cloudflare.com/?to=/:account/realtime/turn
                  </div>
                </li>
              </ol>
              <el-alert type="error" :closable="false" style="margin:10px 0">
                <template #title>
                  <b>别走错页面</b>：左侧「管理账户 → 账户 API 令牌」那个页面是配 Workers / DNS / R2 用的<b>通用令牌</b>，
                  在那里怎么点都<b>拿不到 TURN key</b>，只会白建一个用不上的令牌。
                </template>
              </el-alert>

              <p><b>第二步：创建 TURN 应用，拿到两个值</b></p>
              <ol>
                <li>在 TURN 页面点 <b>「创建」/「创建 TURN 服务器应用」</b>（英文 Create TURN app）。</li>
                <li>名称随便填，例如 <code class="mono">xiaozhi-im</code>，确认创建。</li>
                <li>页面立刻显示两个值，<b>当场复制</b>：</li>
              </ol>
              <table class="help-table">
                <thead><tr><th style="width:190px">页面上的名字</th><th>长什么样 / 填到哪</th></tr></thead>
                <tbody>
                  <tr>
                    <td><b>Turn 令牌 ID</b><br /><span class="hint">Turn Token ID</span></td>
                    <td>32 位十六进制串 → 填 <code class="mono">CF_TURN_KEY_ID</code></td>
                  </tr>
                  <tr>
                    <td><b>API 令牌</b><br /><span class="hint">API Token</span></td>
                    <td>64 位十六进制串 → 填 <code class="mono">CF_TURN_API_TOKEN</code></td>
                  </tr>
                </tbody>
              </table>
              <el-alert type="warning" :closable="false" style="margin:10px 0">
                <template #title>
                  API 令牌<b>只显示这一次</b>（页面会有红字提示）。关掉页面就再也看不到，
                  只能删掉重建一个。<b>先复制到记事本再关页面。</b>
                </template>
              </el-alert>

              <p><b>第三步：写入服务端配置</b></p>
              <p>推荐直接用本页 <b>「系统设置 → 音视频中继配置」</b> 向导，填两个值点保存即可，不用碰命令行。</p>
              <p>若要手工配置，编辑应用目录下的 <code class="mono">docker/.env</code>，填这两行：</p>
              <div class="mono" style="margin:6px 0;padding:8px 10px;background:var(--el-fill-color-light);border-radius:6px;white-space:pre-wrap;user-select:all">CF_TURN_KEY_ID=你的32位令牌ID
CF_TURN_API_TOKEN=你的64位API令牌</div>

              <p><b>第四步：让配置生效（关键，最容易漏）</b></p>
              <el-alert type="error" :closable="false" style="margin:8px 0">
                <template #title>
                  环境变量是容器<b>创建时</b>烘进去的。<code class="mono">docker restart</code> 完全不重读，
                  裸 <code class="mono">docker compose up -d</code> 也常常判定「无变更」而不动 →
                  必须用 <b><code class="mono">--force-recreate</code></b> 重建。
                </template>
              </el-alert>
              <div class="mono" style="margin:6px 0;padding:8px 10px;background:var(--el-fill-color-light);border-radius:6px;white-space:pre-wrap;user-select:all">cd /vol1/@appcenter/xiaozhi-im/docker
docker compose up -d --force-recreate xiaozhi-im</div>

              <p><b>第五步：验证配置真的生效</b></p>
              <ul>
                <li>回到本页「系统设置」，确认显示<b>已下发 TURN</b>（即 <code class="mono">turnConfigured: true</code>）。</li>
                <li>
                  要看<b>中继来源</b>是否包含 <code class="mono">cloudflare</code>（结构化字段
                  <code class="mono">turnSources</code>）。
                  <b>别用「返回体里有没有 cloudflare 字样」判断</b> —— STUN 列表里本来就有
                  <code class="mono">stun.cloudflare.com</code>，那样判断会永远为真。
                </li>
                <li>最后用<b>手机 4G/5G</b>（关掉 Wi-Fi）打给内网设备实测一次跨网通话。</li>
              </ul>
              <p class="help-tip">
                客户端 ICE 配置有 <b>5 分钟缓存</b>。改完服务端后，要么等 5 分钟，
                要么把客户端完全退出重开，否则可能拿的还是旧配置 —— 别误判成「配置没生效」。
              </p>
            </section>


            <section class="help-sec">
              <h3>六、和外部系统对接</h3>
              <p>总入口在「集成对接」页，三种方式：</p>
              <ul>
                <li><b>入站推送</b>：给外部系统一个带令牌的地址，对方 POST 告警 / 日报过来，直接落到指定群里。</li>
                <li><b>事件订阅</b>：把 IM 里发生的事件（新消息、加好友等）回调到你的系统。</li>
                <li><b>公钥接入</b>：用 Ed25519 私钥签名请求体，IM 侧用你登记的公钥验签，比静态令牌更安全。</li>
              </ul>
              <p class="help-tip">典型用法：工厂 / 门店系统的库存预警、每日销售汇总直接推到 IM 群；服务器宕机告警即时到手机。</p>
            </section>

            <section class="help-sec">
              <h3>七、端口与目录速查</h3>
              <table class="help-table">
                <thead><tr><th style="width:200px">项目</th><th>值</th></tr></thead>
                <tbody>
                  <tr><td>服务端端口</td><td><code class="mono">3602</code>（管理台在 <code class="mono">/admin/</code>）</td></tr>
                  <tr><td>局域网发现</td><td><code class="mono">3616/udp</code> —— 客户端「扫描内网服务器」靠它自动找服务器；Docker 端口映射需含 <code class="mono">3616:3616/udp</code></td></tr>
                  <tr><td>自建中继端口</td><td><code class="mono">3478/udp</code>、<code class="mono">3478/tcp</code>、<code class="mono">49160-49200/udp</code>（仅自建 coturn 方案需要放通）</td></tr>
                  <tr><td>应用目录</td><td><code class="mono">/vol1/@appcenter/xiaozhi-im</code></td></tr>
                  <tr><td>配置与数据</td><td><code class="mono">docker/.env</code>（配置）、<code class="mono">data/</code>（数据库与文件）</td></tr>
                  <tr><td>中继自检脚本</td><td><code class="mono">deploy/turn_status.py</code>（只读，一条命令查完中继状态）</td></tr>
                </tbody>
              </table>
            </section>
          </el-card>
        </div>

        <!-- 用户管理 -->
        <div v-else-if="tab === 'users'">
          <el-alert v-if="compSetting.mode === 'work'" type="info" :closable="false" style="margin-bottom:12px">
            <template #title>
              当前是<b>工作模式</b>：这里新建普通用户会<b>自动作为员工加入组织</b>（账号即工号、自动与同事互为好友）。
              要按部门 / 岗位批量录人，用「组织机构」的批量导入更快。
            </template>
          </el-alert>
          <div class="page-bar">
            <el-input v-model="userSearch" placeholder="搜索账号/昵称（服务端搜索全部用户）" clearable style="width:300px" />
            <el-button type="primary" @click="openUserDialog()">新建用户</el-button>
            <el-button @click="loadUsers">刷新</el-button>
            <span class="hint">共 {{ userPager.p.total }} 个用户</span>
          </div>
          <el-table :data="userPager.p.items" border stripe v-loading="userPager.p.loading">
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
                <el-button size="small" type="primary" plain @click="openUserDialog(row)">编辑</el-button>
                <el-button size="small" @click="toggleRole(row)">{{ row.role === 'admin' ? '降为普通' : '设为管理员' }}</el-button>
                <el-button size="small" type="danger" @click="delUser(row)">删除</el-button>
              </template>
            </el-table-column>
            <template #empty>
              <div class="empty-tip">
                <span v-if="userSearch.trim()">没有匹配「{{ userSearch.trim() }}」的用户</span>
                <span v-else>还没有用户</span>
              </div>
            </template>
          </el-table>
          <PagerBar :pager="userPager" />
        </div>

        <!-- 群组管理 -->
        <div v-else-if="tab === 'groups'">
          <div class="page-bar">
            <el-button type="primary" @click="openGroupDialog()">新建群组</el-button>
            <el-button @click="loadGroups">刷新</el-button>
            <span class="hint">共 {{ groupPager.p.total }} 个群（原来这个列表没有上限，群多了会把响应撑大）</span>
          </div>
          <el-table :data="groupPager.p.items" border stripe v-loading="groupPager.p.loading">
            <el-table-column prop="id" label="ID" width="70" />
            <el-table-column prop="name" label="群名" />
            <el-table-column prop="owner_name" label="群主" />
            <el-table-column prop="members" label="成员数" width="90" />
            <el-table-column label="群公告" min-width="160" show-overflow-tooltip>
              <template #default="{ row }">
                <span v-if="row.announcement">{{ row.announcement }}</span>
                <span v-else style="color:#c0c4cc">—</span>
              </template>
            </el-table-column>
            <el-table-column prop="created_at" label="创建时间" width="180">
              <template #default="{ row }">{{ fmtTime(row.created_at) }}</template>
            </el-table-column>
            <el-table-column label="操作" width="200">
              <template #default="{ row }">
                <el-button size="small" type="primary" plain @click="openGroupDialog(row)">编辑</el-button>
                <el-button size="small" type="danger" @click="delGroup(row)">解散</el-button>
              </template>
            </el-table-column>
          </el-table>
          <PagerBar :pager="groupPager" />
        </div>

        <!-- 好友关系：按用户分组的树状结构，方便看"谁的好友" -->
        <div v-else-if="tab === 'friends'">
          <div class="page-bar">
            <el-button @click="loadFriends">刷新</el-button>
            <el-input v-model="friendQ" placeholder="搜用户名 / 好友名 / 状态" clearable size="small"
                      style="width:220px" />
            <span class="hint">共 {{ friendTotal }} 条好友关系，分布在 {{ friendTreeFiltered.length }} 位用户下（默认折叠，点左侧三角展开；搜索时自动展开命中项）</span>
          </div>
          <el-tree :data="friendTreeFiltered" node-key="key" :props="{ label: 'label', children: 'children' }"
                   :expand-on-click-node="false" :default-expanded-keys="friendSearchExpanded"
                   v-loading="friendLoading">
            <template #default="{ data }">
              <div style="display:flex;align-items:center;width:100%">
                <template v-if="data.isUser">
                  <el-icon><User /></el-icon>
                  <strong style="margin-left:6px">{{ data.label }}</strong>
                  <span class="hint" style="margin-left:8px">（{{ data.children?.length || 0 }} 个好友）</span>
                </template>
                <template v-else>
                  <el-tag :type="data.row.status === 'accepted' ? 'success' : 'warning'" size="small" effect="plain">
                    {{ data.row.status }}
                  </el-tag>
                  <span style="margin:0 8px">{{ data.row.friend_name }}</span>
                  <span class="hint">{{ fmtTime(data.row.created_at) }}</span>
                  <el-button size="small" type="danger" link style="margin-left:auto"
                             @click.stop="delFriend(data.row)">删除</el-button>
                </template>
              </div>
            </template>
          </el-tree>
        </div>

        <!-- 文件管理 -->
        <div v-else-if="tab === 'files'">
          <div class="stat-row">
            <div class="stat-box">
              <div class="stat-k">库内总占用</div>
              <div class="stat-v">{{ fmtBytes(fileStorage?.totalBytes) }}</div>
            </div>
            <div class="stat-box">
              <div class="stat-k">文件数</div>
              <div class="stat-v">{{ fileStorage?.totalCount ?? 0 }}</div>
            </div>
            <div class="stat-box" :class="{ 'stat-warn': (fileOrphans.counts?.dbOnly || 0) + (fileOrphans.counts?.diskOnly || 0) > 0 }">
              <div class="stat-k">库盘不一致</div>
              <div class="stat-v">{{ (fileOrphans.counts?.dbOnly || 0) + (fileOrphans.counts?.diskOnly || 0) }}</div>
            </div>
            <div class="stat-box">
              <div class="stat-k">磁盘实际占用</div>
              <div class="stat-v">{{ fmtBytes(fileStorage?.diskBytes) }}</div>
            </div>
          </div>

          <el-collapse class="file-analysis">
            <el-collapse-item name="storage">
              <template #title>
                <b>存储占用分析</b>
                <span class="hint" style="margin-left:10px">谁把磁盘吃满了 —— 按类型分布 / 按上传者 TOP 10</span>
              </template>
              <div class="analysis-grid">
                <div>
                  <div class="analysis-h">按类型</div>
                  <el-table :data="fileStorage?.byType || []" size="small" border>
                    <el-table-column prop="mime" label="类型" show-overflow-tooltip />
                    <el-table-column prop="count" label="个数" width="80" />
                    <el-table-column label="占用" width="100">
                      <template #default="{ row }">{{ fmtBytes(row.bytes) }}</template>
                    </el-table-column>
                  </el-table>
                </div>
                <div>
                  <div class="analysis-h">按上传者（TOP 10）</div>
                  <el-table :data="fileStorage?.byOwner || []" size="small" border>
                    <el-table-column label="上传者" show-overflow-tooltip>
                      <template #default="{ row }">{{ row.username || ('#' + row.owner_id) }}</template>
                    </el-table-column>
                    <el-table-column prop="count" label="个数" width="80" />
                    <el-table-column label="占用" width="100">
                      <template #default="{ row }">{{ fmtBytes(row.bytes) }}</template>
                    </el-table-column>
                  </el-table>
                </div>
              </div>
            </el-collapse-item>
          </el-collapse>

          <el-tabs v-model="fileTab">
            <el-tab-pane label="全部文件" name="all">
              <div class="page-bar wrap">
                <el-radio-group v-model="fileRange" size="small" @change="filePager.reset()">
                  <el-radio-button value="today">今天</el-radio-button>
                  <el-radio-button value="7d">7 天</el-radio-button>
                  <el-radio-button value="30d">30 天</el-radio-button>
                  <el-radio-button value="90d">90 天</el-radio-button>
                  <el-radio-button value="all">全部</el-radio-button>
                  <el-radio-button value="custom">自定义</el-radio-button>
                </el-radio-group>
                <el-date-picker v-if="fileRange === 'custom'" v-model="fileCustom" type="datetimerange"
                  range-separator="至" start-placeholder="开始时间" end-placeholder="结束时间" size="small"
                  style="width:340px" @change="filePager.reset()" />
                <el-select v-model="fileOwnerId" placeholder="全部上传者" clearable filterable style="width:170px" @change="filePager.reset()">
                  <el-option v-for="u in userOptions" :key="u.id" :label="u.nickname || u.username" :value="u.id" />
                </el-select>
                <el-select v-model="fileMime" placeholder="全部类型" clearable style="width:130px" @change="filePager.reset()">
                  <el-option label="图片" value="image" />
                  <el-option label="视频" value="video" />
                  <el-option label="音频" value="audio" />
                  <el-option label="压缩包" value="zip" />
                  <el-option label="文档" value="text" />
                </el-select>
                <el-input v-model="fileQ" placeholder="原始文件名" clearable style="width:180px" @keyup.enter="filePager.reset()" />
                <el-button type="primary" @click="filePager.reset()">搜索</el-button>
                <el-button @click="resetFileFilter">重置</el-button>
                <el-button type="danger" plain @click="openPurge('files')">批量清理</el-button>
              </div>
              <el-table :data="filePager.p.items" border stripe v-loading="filePager.p.loading">
                <el-table-column prop="id" label="ID" width="70" />
                <el-table-column label="预览" width="80">
                  <template #default="{ row }">
                    <el-image v-if="isImage(row.mime)" :src="`/files/${row.path}`" style="width:48px;height:48px;object-fit:cover" fit="cover" :preview-src-list="[`/files/${row.path}`]" hide-on-click-modal />
                    <span v-else style="color:#909399">—</span>
                  </template>
                </el-table-column>
                <el-table-column prop="name" label="原始文件名" show-overflow-tooltip />
                <el-table-column prop="owner" label="上传者" width="110" />
                <el-table-column prop="mime" label="类型" width="150" show-overflow-tooltip />
                <el-table-column prop="size" label="大小" width="100">
                  <template #default="{ row }">{{ fmtBytes(row.size) }}</template>
                </el-table-column>
                <el-table-column label="引用" width="90">
                  <template #default="{ row }">
                    <el-tag v-if="row.refCount > 0" size="small" type="warning">{{ row.refCount }} 条消息</el-tag>
                    <span v-else style="color:#909399">未引用</span>
                  </template>
                </el-table-column>
                <el-table-column prop="created_at" label="上传时间" width="170">
                  <template #default="{ row }">{{ fmtTime(row.created_at) }}</template>
                </el-table-column>
                <el-table-column label="操作" width="150">
                  <template #default="{ row }">
                    <el-button size="small" @click="downloadFile(row)">下载</el-button>
                    <el-button size="small" type="danger" @click="delFile(row)">删除</el-button>
                  </template>
                </el-table-column>
                <template #empty>
                  <div class="empty-tip">
                    <span>当前筛选条件下没有文件</span>
                    <el-button v-if="fileRange !== 'all'" link type="primary" @click="fileRange = 'all'; filePager.reset()">改为「全部时间」再试</el-button>
                  </div>
                </template>
              </el-table>
              <PagerBar :pager="filePager" />
            </el-tab-pane>

            <el-tab-pane label="孤儿巡检" name="orphans">
              <el-alert type="info" :closable="false" style="margin-bottom:12px">
                <template #title>
                  <b>断链</b>（库里有记录、磁盘文件不见了）通常是手动删了文件 / 挂载变了 / 迁移丢文件；
                  <b>残留</b>（磁盘有文件、库里没记录）通常是删库残留或上传中途失败。
                  <span v-if="fileOrphans.truncated">⚠️ 结果已截断（扫描上限 {{ fileOrphans.scanLimit }}），可能还有更多。</span>
                </template>
              </el-alert>
              <div class="page-bar">
                <el-button @click="loadOrphans">重新巡检</el-button>
                <el-button type="danger" plain :disabled="!fileOrphans.counts?.diskOnly" @click="openPurge('orphan')">
                  清理残留文件（{{ fileOrphans.counts?.diskOnly || 0 }} 个，{{ fmtBytes(fileOrphans.counts?.diskOnlyBytes) }}）
                </el-button>
                <span class="hint">残留文件库里本来就没记录，清理风险最低，不涉及任何消息。</span>
              </div>

              <div class="analysis-h">断链：库里有记录，磁盘文件不存在（{{ fileOrphans.counts?.dbOnly || 0 }}）</div>
              <el-table :data="fileOrphans.dbOnly" border stripe size="small" style="margin-bottom:16px">
                <el-table-column prop="id" label="ID" width="70" />
                <el-table-column prop="name" label="文件名" show-overflow-tooltip />
                <el-table-column prop="path" label="磁盘路径" show-overflow-tooltip />
                <el-table-column label="大小" width="100">
                  <template #default="{ row }">{{ fmtBytes(row.size) }}</template>
                </el-table-column>
                <el-table-column label="上传时间" width="170">
                  <template #default="{ row }">{{ fmtTime(row.created_at) }}</template>
                </el-table-column>
                <template #empty><div class="empty-tip">没有断链文件</div></template>
              </el-table>

              <div class="analysis-h">残留：磁盘有文件，库里无记录（{{ fileOrphans.counts?.diskOnly || 0 }}）</div>
              <el-table :data="fileOrphans.diskOnly" border stripe size="small">
                <el-table-column prop="path" label="磁盘文件名" show-overflow-tooltip />
                <el-table-column label="大小" width="110">
                  <template #default="{ row }">{{ fmtBytes(row.size) }}</template>
                </el-table-column>
                <el-table-column label="修改时间" width="180">
                  <template #default="{ row }">{{ fmtTime(row.mtime) }}</template>
                </el-table-column>
                <template #empty><div class="empty-tip">没有残留文件</div></template>
              </el-table>
            </el-tab-pane>
          </el-tabs>
        </div>

        <!-- 消息管理 -->
        <div v-else-if="tab === 'messages'">
          <el-alert v-if="!msgNoTimeLimit" type="info" :closable="false" style="margin-bottom:12px">
            <template #title>
              默认只查<b>最近 30 天</b>（数据不炸的第一道防线）。找更早的消息，把时间范围改成「全部」或自定义。
            </template>
          </el-alert>
          <div class="page-bar wrap">
            <el-radio-group v-model="msgRange" size="small" @change="msgPager.reset()">
              <el-radio-button value="today">今天</el-radio-button>
              <el-radio-button value="7d">7 天</el-radio-button>
              <el-radio-button value="30d">30 天</el-radio-button>
              <el-radio-button value="90d">90 天</el-radio-button>
              <el-radio-button value="all">全部时间</el-radio-button>
              <el-radio-button value="custom">自定义</el-radio-button>
            </el-radio-group>
            <el-date-picker v-if="msgRange === 'custom'" v-model="msgCustom" type="datetimerange"
              range-separator="至" start-placeholder="开始时间" end-placeholder="结束时间" size="small"
              style="width:340px" @change="msgPager.reset()" />
          </div>
          <div class="page-bar wrap">
            <el-select v-model="msgSenderId" placeholder="全部发送者" clearable filterable style="width:170px" @change="msgPager.reset()">
              <el-option v-for="u in userOptions" :key="u.id" :label="u.nickname || u.username" :value="u.id" />
            </el-select>
            <el-select v-model="msgConvId" placeholder="全部会话" clearable filterable style="width:190px" @change="msgPager.reset()">
              <el-option v-for="c in msgConvs" :key="c.id" :label="c.name" :value="c.id" />
            </el-select>
            <el-select v-model="msgKind" placeholder="全部类型" clearable style="width:120px" @change="msgPager.reset()">
              <el-option label="文字" value="text" />
              <el-option label="图片" value="image" />
              <el-option label="文件" value="file" />
              <el-option label="语音" value="audio" />
              <el-option label="卡片" value="card" />
            </el-select>
            <el-input v-model="msgQ" placeholder="搜索消息内容" clearable style="width:190px" @keyup.enter="msgPager.reset()" />
            <el-checkbox v-model="msgMentioned" @change="msgPager.reset()">仅 @提及</el-checkbox>
            <el-button type="primary" @click="msgPager.reset()">搜索</el-button>
            <el-button @click="resetMsgFilter">重置</el-button>
            <el-button type="danger" plain @click="openPurge('messages')">批量清理</el-button>
          </div>
          <el-table :data="msgPager.p.items" border stripe v-loading="msgPager.p.loading">
            <el-table-column prop="id" label="ID" width="70" />
            <el-table-column prop="sender_name" label="发送者" width="110" />
            <el-table-column label="会话" width="150" show-overflow-tooltip>
              <template #default="{ row }">
                <span v-if="row.conversation_name">{{ row.conversation_name }}</span>
                <span v-else style="color:#c0c4cc">#{{ row.conversation_id }}</span>
                <el-tag v-if="row.conversation_type === 'group'" size="small" type="info" style="margin-left:4px">群</el-tag>
              </template>
            </el-table-column>
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
            <el-table-column label="@" width="80">
              <template #default="{ row }">
                <el-tag v-if="row.mentions" size="small" type="success">@提及</el-tag>
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
            <el-table-column prop="created_at" label="发送时间" width="170">
              <template #default="{ row }">{{ fmtTime(row.created_at) }}</template>
            </el-table-column>
            <el-table-column label="操作" width="100">
              <template #default="{ row }">
                <el-button size="small" type="danger" @click="delMessage(row)">删除</el-button>
              </template>
            </el-table-column>
            <template #empty>
              <div class="empty-tip">
                <span>当前筛选条件下没有数据</span>
                <el-button v-if="!msgNoTimeLimit" link type="primary" @click="msgRange = 'all'; msgPager.reset()">改为「全部时间」再试</el-button>
              </div>
            </template>
          </el-table>
          <PagerBar :pager="msgPager" />
          <div class="hint" style="margin-top:10px">
            提示：筛选条件就是「批量清理」的作用范围 —— 不用勾选，按条件执行，服务端会重算条数并要求二次确认。
          </div>
        </div>

        <!-- 集成对接 -->
        <div v-else-if="tab === 'integrations'">
          <el-alert type="success" :closable="false" style="margin-bottom:14px">
            <template #title>
              把「小智 IM」接到其他软件的入口。工厂系统 / OA / 脚本按下面的<b>推送地址</b>发一条 POST，群里立刻收到；
              也可以反过来订阅群里的事件，实时回调到你的系统。对接全程不需要改 IM 代码。
              所有向导建好的东西<b>都能随时回来改</b>（列表里点「编辑」）。
            </template>
          </el-alert>
          <div class="page-bar" style="margin-bottom:14px">
            <el-button type="warning" @click="openTigerDialog()">🧾 泰格 POS 日报对接</el-button>
            <span class="hint">一键建好「泰格日报」机器人和推送地址，并给出对接方（tiger-bridge）的配置说明 —— 已配置过的不会重复建。</span>
          </div>

          <el-tabs v-model="intTab">
            <!-- ===== 机器人 ===== -->
            <el-tab-pane label="机器人" name="bots">
              <div class="page-bar">
                <el-button type="primary" @click="openBotDialog()">新建机器人</el-button>
                <span class="hint">机器人是「系统发言人」：能被拉进群、能发消息，但无法登录，不会冒充真人。</span>
              </div>
              <el-table :data="bots" border stripe>
                <el-table-column prop="id" label="ID" width="70" />
                <el-table-column prop="nickname" label="名称" width="160" />
                <el-table-column prop="username" label="账号" width="200" />
                <el-table-column label="创建时间" width="170">
                  <template #default="{ row }">{{ fmtTime(row.created_at) }}</template>
                </el-table-column>
                <el-table-column label="操作" width="240">
                  <template #default="{ row }">
                    <el-button size="small" @click="openBotDialog(row)">改名</el-button>
                    <el-button size="small" @click="openBotConvDialog(row)">加入会话</el-button>
                    <el-button size="small" type="danger" @click="delBot(row)">删除</el-button>
                  </template>
                </el-table-column>
              </el-table>
              <el-empty v-if="!bots.length" description="还没有机器人，点「新建机器人」开始对接" />
            </el-tab-pane>

            <!-- ===== API 令牌 ===== -->
            <el-tab-pane label="API 令牌" name="tokens">
              <div class="page-bar">
                <el-button type="primary" @click="openTokenDialog()">发放令牌</el-button>
                <span class="hint">令牌是给程序用的长期凭证，按需勾选权限；泄露了随时吊销。</span>
              </div>
              <el-table :data="tokens" border stripe>
                <el-table-column prop="id" label="ID" width="70" />
                <el-table-column prop="name" label="用途" width="150" />
                <el-table-column label="令牌" width="190">
                  <template #default="{ row }">
                    <code class="mono">{{ row.token }}</code>
                  </template>
                </el-table-column>
                <el-table-column label="身份" width="130">
                  <template #default="{ row }">
                    {{ row.user_name || ('#' + row.user_id) }}
                    <el-tag v-if="row.user_is_bot" size="small" type="success" effect="plain">机器人</el-tag>
                  </template>
                </el-table-column>
                <el-table-column label="权限" min-width="220">
                  <template #default="{ row }">
                    <el-tag v-for="s in row.scopes" :key="s" size="small" style="margin:1px 3px 1px 0">{{ s }}</el-tag>
                  </template>
                </el-table-column>
                <el-table-column label="最近使用" width="160">
                  <template #default="{ row }">{{ row.last_used_at ? fmtTime(row.last_used_at) : '未使用' }}</template>
                </el-table-column>
                <el-table-column label="状态" width="90">
                  <template #default="{ row }">
                    <el-tag v-if="row.revoked" size="small" type="danger">已吊销</el-tag>
                    <el-tag v-else-if="row.expires_at && row.expires_at < Date.now()" size="small" type="info">已过期</el-tag>
                    <el-tag v-else size="small" type="success">正常</el-tag>
                  </template>
                </el-table-column>
                <el-table-column label="操作" width="150">
                  <template #default="{ row }">
                    <el-button size="small" @click="toggleToken(row)">{{ row.revoked ? '恢复' : '吊销' }}</el-button>
                    <el-button size="small" type="danger" @click="delToken(row)">删除</el-button>
                  </template>
                </el-table-column>
              </el-table>
            </el-tab-pane>

            <!-- ===== 签名客户端（app_id / app_secret） ===== -->
            <el-tab-pane label="签名客户端" name="clients">
              <div class="page-bar">
                <el-button type="primary" @click="openClientDialog()">发放凭据</el-button>
                <span class="hint">
                  每次请求都要带 <code class="mono">X-App-Id / X-Timestamp / X-Nonce / X-Sign</code>
                  四个头 —— 令牌泄露了能重放到天荒地老，签名只在 ±5 分钟里有效，且用一次作废。
                </span>
              </div>
              <el-table :data="clients" border stripe>
                <el-table-column prop="id" label="ID" width="70" />
                <el-table-column prop="name" label="用途" width="150" />
                <el-table-column label="app_id" width="200">
                  <template #default="{ row }">
                    <code class="mono">{{ row.appId }}</code>
                    <el-button size="small" text type="primary" @click="copy(row.appId)">复制</el-button>
                  </template>
                </el-table-column>
                <el-table-column label="身份" width="130">
                  <template #default="{ row }">{{ row.userId ? ('#' + row.userId) : '—' }}</template>
                </el-table-column>
                <el-table-column label="权限" min-width="200">
                  <template #default="{ row }">
                    <el-tag v-for="s in row.scopes" :key="s" size="small" style="margin:1px 3px 1px 0">{{ s }}</el-tag>
                  </template>
                </el-table-column>
                <el-table-column label="最近使用" width="160">
                  <template #default="{ row }">{{ row.lastUsedAt ? fmtTime(row.lastUsedAt) : '未使用' }}</template>
                </el-table-column>
                <el-table-column label="状态" width="120">
                  <template #default="{ row }">
                    <el-tag v-if="!row.enabled" size="small" type="danger">已停用</el-tag>
                    <el-tag v-else-if="row.prevValidUntil && row.prevValidUntil > Date.now()" size="small" type="warning" effect="plain">轮换宽限中</el-tag>
                    <el-tag v-else size="small" type="success">正常</el-tag>
                  </template>
                </el-table-column>
                <el-table-column label="操作" width="240">
                  <template #default="{ row }">
                    <el-button size="small" @click="toggleClient(row)">{{ row.enabled ? '停用' : '启用' }}</el-button>
                    <el-button size="small" @click="rotateClient(row)">轮换密钥</el-button>
                    <el-button size="small" type="danger" @click="delClient(row)">删除</el-button>
                  </template>
                </el-table-column>
              </el-table>
              <el-empty v-if="!clients.length" description="还没有签名客户端，点「发放凭据」开始对接" />
              <el-collapse style="margin-top:10px">
                <el-collapse-item title="对接方怎么算签名（点开看示例）">
                  <div class="hint" style="margin-bottom:6px">
                    待签串用换行拼：<code class="mono">method \n path \n query \n timestamp \n nonce \n sha256_hex(原始请求体)</code>；
                    密钥是 app_secret，算法 HMAC-SHA256，结果取 hex。timestamp 是 unix <b>秒</b>，与服务端相差不得超过 ±300 秒。
                  </div>
                  <pre class="mono" style="margin:0;padding:10px;background:var(--el-fill-color-light);border-radius:6px;overflow:auto">{{ signSample }}</pre>
                  <div class="hint" style="margin-top:6px">
                    🔴 请求体必须按<b>原始字节</b>算哈希 —— 用 JSON 重新序列化会因为键序/空格不同而永远签不过。
                    上传文件（multipart）这类请求体不算进签名，只有请求头受保护。
                  </div>
                </el-collapse-item>
              </el-collapse>
            </el-tab-pane>

            <!-- ===== 入站 Webhook ===== -->
            <el-tab-pane label="入站推送（外部 → 群）" name="incoming">
              <div class="page-bar">
                <el-button type="primary" @click="openIncomingDialog()">新建推送地址</el-button>
                <span class="hint">把地址复制给对方系统，POST 一条 JSON 就能往群里发消息。</span>
              </div>
              <el-table :data="incoming" border stripe>
                <el-table-column prop="name" label="用途" width="140" />
                <el-table-column label="推送地址" min-width="330">
                  <template #default="{ row }">
                    <code class="mono">{{ fullUrl(row.path) }}</code>
                    <el-button size="small" text type="primary" @click="copy(fullUrl(row.path))">复制</el-button>
                  </template>
                </el-table-column>
                <el-table-column label="机器人" width="120">
                  <template #default="{ row }">{{ row.bot_name || '—' }}</template>
                </el-table-column>
                <el-table-column label="目标会话" width="150">
                  <template #default="{ row }">{{ row.conversation_title || ('#' + row.conversation_id) }}</template>
                </el-table-column>
                <el-table-column label="签名" width="90">
                  <template #default="{ row }">
                    <el-tag size="small" :type="row.signed ? 'success' : 'info'" effect="plain">
                      {{ row.signed ? '已开启' : '未开启' }}
                    </el-tag>
                  </template>
                </el-table-column>
                <el-table-column label="最近使用" width="160">
                  <template #default="{ row }">{{ row.last_used_at ? fmtTime(row.last_used_at) : '未使用' }}</template>
                </el-table-column>
                <el-table-column label="状态" width="90">
                  <template #default="{ row }">
                    <el-tag v-if="row.revoked" size="small" type="danger">已停用</el-tag>
                    <el-tag v-else size="small" type="success">正常</el-tag>
                  </template>
                </el-table-column>
                <el-table-column label="操作" width="290">
                  <template #default="{ row }">
                    <el-button size="small" @click="testIncoming(row)">试推</el-button>
                    <el-button size="small" @click="openIncomingDialog(row)">编辑</el-button>
                    <el-button size="small" @click="toggleIncoming(row)">{{ row.revoked ? '启用' : '停用' }}</el-button>
                    <el-button size="small" type="danger" @click="delIncoming(row)">删除</el-button>
                  </template>
                </el-table-column>
              </el-table>
            </el-tab-pane>

            <!-- ===== 出站 Webhook ===== -->
            <el-tab-pane label="事件订阅（群 → 外部）" name="outgoing">
              <div class="page-bar">
                <el-button type="primary" @click="openOutgoingDialog()">新建订阅</el-button>
                <span class="hint">群里有新消息 / 被 @ / 成员变动时，实时 POST 到你填的地址（带 HMAC 签名）。</span>
              </div>
              <el-table :data="outgoing" border stripe>
                <el-table-column prop="name" label="用途" width="140" />
                <el-table-column prop="url" label="回调地址" min-width="240" show-overflow-tooltip />
                <el-table-column label="订阅事件" min-width="180">
                  <template #default="{ row }">
                    <el-tag v-if="row.events === '*'" size="small" type="warning">全部事件</el-tag>
                    <el-tag v-else v-for="e in row.events.split(',')" :key="e" size="small" style="margin:1px 3px 1px 0">{{ e }}</el-tag>
                  </template>
                </el-table-column>
                <el-table-column label="范围" width="140">
                  <template #default="{ row }">{{ row.conversation_title || (row.conversation_id ? ('#' + row.conversation_id) : '全部会话') }}</template>
                </el-table-column>
                <el-table-column label="启用" width="80">
                  <template #default="{ row }">
                    <el-switch :model-value="row.active" @change="v => toggleOutgoing(row, v)" />
                  </template>
                </el-table-column>
                <el-table-column label="操作" width="310">
                  <template #default="{ row }">
                    <el-button size="small" @click="testOutgoing(row)">发测试事件</el-button>
                    <el-button size="small" @click="openOutgoingDialog(row)">编辑</el-button>
                    <el-button size="small" @click="rotateOutgoing(row)">换密钥</el-button>
                    <el-button size="small" type="danger" @click="delOutgoing(row)">删除</el-button>
                  </template>
                </el-table-column>
              </el-table>
            </el-tab-pane>

            <!-- ===== 投递日志 ===== -->
            <el-tab-pane label="投递日志" name="deliveries">
              <div class="page-bar">
                <el-button @click="loadDeliveries()">刷新</el-button>
                <el-radio-group v-model="delOk" @change="loadDeliveries()">
                  <el-radio-button label="">全部</el-radio-button>
                  <el-radio-button label="0">仅失败</el-radio-button>
                  <el-radio-button label="1">仅成功</el-radio-button>
                </el-radio-group>
                <span class="hint">失败的会自动重试（最多 {{ intMeta.maxAttempts || 4 }} 次），也可以点「重发」立刻再试一次。</span>
              </div>
              <el-table :data="deliveries" border stripe>
                <el-table-column prop="id" label="ID" width="80" />
                <el-table-column prop="hook_name" label="订阅" width="140" />
                <el-table-column prop="event" label="事件" width="160" />
                <el-table-column label="结果" width="130">
                  <template #default="{ row }">
                    <el-tag v-if="row.ok" size="small" type="success">成功 {{ row.status }}</el-tag>
                    <el-tag v-else-if="row.next_retry_at" size="small" type="warning">待重试</el-tag>
                    <el-tag v-else size="small" type="danger">失败</el-tag>
                  </template>
                </el-table-column>
                <el-table-column prop="attempts" label="尝试" width="70" />
                <el-table-column prop="error" label="错误" min-width="180" show-overflow-tooltip />
                <el-table-column label="时间" width="160">
                  <template #default="{ row }">{{ fmtTime(row.created_at) }}</template>
                </el-table-column>
              <el-table-column label="操作" width="90">
                <template #default="{ row }">
                  <el-button size="small" @click="retryDelivery(row)">重发</el-button>
                </template>
              </el-table-column>
            </el-table>
          </el-tab-pane>

          <!-- ===== 公钥接入 ===== -->
          <el-tab-pane label="公钥接入" name="pubkeys">
            <el-alert type="info" :closable="false" style="margin-bottom:12px">
              <template #title>
                外部系统用<b>私钥签名</b>请求，IM 用你提交的公钥验签。比 HMAC 共享密钥更安全：
                私钥不出对方机器，公钥丢了也只影响这一个对接点。
              </template>
            </el-alert>
            <div class="page-bar">
              <el-button type="primary" @click="openPubkeyDialog()">添加公钥</el-button>
              <span class="hint">支持 RSA / 椭圆曲线 P-256。生成命令（RSA 2048 为例）：
                <code class="mono">openssl genrsa -out priv.pem 2048 &amp;&amp; openssl rsa -in priv.pem -pubout -out pub.pem</code>
              </span>
            </div>
            <el-table :data="pubkeys" border stripe>
              <el-table-column prop="id" label="ID" width="70" />
              <el-table-column prop="key_id" label="公钥 ID" width="160">
                <template #default="{ row }">
                  <code class="mono">{{ row.key_id }}</code>
                </template>
              </el-table-column>
              <el-table-column prop="name" label="用途" width="160" />
              <el-table-column prop="algorithm" label="算法" width="140" />
              <el-table-column label="指纹" min-width="280" show-overflow-tooltip>
                <template #default="{ row }"><code class="mono">{{ row.fingerprint }}</code></template>
              </el-table-column>
              <el-table-column label="创建时间" width="170">
                <template #default="{ row }">{{ fmtTime(row.created_at) }}</template>
              </el-table-column>
              <el-table-column label="最近使用" width="160">
                <template #default="{ row }">{{ row.last_used_at ? fmtTime(row.last_used_at) : '未使用' }}</template>
              </el-table-column>
              <el-table-column label="状态" width="90">
                <template #default="{ row }">
                  <el-tag v-if="row.revoked" size="small" type="danger">已停用</el-tag>
                  <el-tag v-else size="small" type="success">正常</el-tag>
                </template>
              </el-table-column>
              <el-table-column label="操作" width="260">
                <template #default="{ row }">
                  <el-button size="small" @click="openPubkeyTestDialog(row)">验签测试</el-button>
                  <el-button size="small" @click="togglePubkey(row)">{{ row.revoked ? '启用' : '停用' }}</el-button>
                  <el-button size="small" type="danger" @click="delPubkey(row)">删除</el-button>
                </template>
              </el-table-column>
            </el-table>
            <el-empty v-if="!pubkeys.length" description="还没有公钥，点「添加公钥」开始对接" />
          </el-tab-pane>
        </el-tabs>
        </div>

        <!-- 客户端配置中心（v0.8.0 第一期） -->
        <div v-else-if="tab === 'clientconfig'">
          <el-row :gutter="16">
            <el-col :span="14">
              <el-card>
                <template #header>
                  <div class="card-hdr">
                    <span>编辑配置（当前线上 v{{ cc.current.version }}）</span>
                    <div>
                      <el-button size="small" @click="loadCc">刷新</el-button>
                      <el-button size="small" type="primary" @click="openCcDiff">发布…</el-button>
                    </div>
                  </div>
                </template>

                <el-alert type="info" :closable="false" style="margin-bottom:14px"
                  title="改完点「发布」生成新版本，客户端启动时/每 30 分钟自动拉取热生效，无需重装 App。" />

                <el-form label-width="130px" label-position="left">
                  <el-form-item>
                    <template #label><span class="cc-label">服务器地址候选</span></template>
                    <div style="width:100%">
                      <div v-for="(a, i) in ccForm.addrs" :key="i" style="display:flex;gap:8px;margin-bottom:6px;align-items:center">
                        <el-select v-model="a.type" style="width:130px">
                          <el-option label="内网 LAN" value="lan" />
                          <el-option label="公网 IPv4" value="ipv4" />
                          <el-option label="公网 IPv6" value="ipv6" />
                          <el-option label="其他/域名" value="other" />
                        </el-select>
                        <el-input v-model="a.url" placeholder="http:// 或 https:// 开头" style="flex:1" />
                        <el-button size="small" text type="danger" @click="ccForm.addrs.splice(i,1)">删除</el-button>
                      </div>
                      <el-button size="small" @click="ccForm.addrs.push({ type: 'lan', url: '' })">+ 加地址</el-button>
                      <div class="hint">客户端未手动改过地址时，按优先级并发探测选可达者（含 IPv4/IPv6）。留空 = 用打包内置地址。改动后**不打断**在线连接，下次重连生效。</div>
                    </div>
                  </el-form-item>

                  <el-form-item>
                    <template #label><span class="cc-label">功能开关</span></template>
                    <div style="width:100%">
                      <div v-for="(f, i) in ccForm.features" :key="i" style="display:flex;gap:8px;margin-bottom:6px;align-items:center">
                        <el-input v-model="f.key" placeholder="功能名，如 groupCall" style="width:220px" />
                        <el-switch v-model="f.on" active-text="开" inactive-text="关" />
                        <el-button size="small" text type="danger" @click="ccForm.features.splice(i,1)">删除</el-button>
                      </div>
                      <el-button size="small" @click="ccForm.features.push({ key: '', on: true })">+ 加开关</el-button>
                      <div class="hint">客户端入口显隐跟随开关；不认识的开关客户端会忽略，不会报错。</div>
                    </div>
                  </el-form-item>

                  <el-form-item>
                    <template #label><span class="cc-label">最低客户端版本</span></template>
                    <div style="width:100%">
                      <el-input v-model="ccForm.minVersion" placeholder="如 0.7.0；留空 = 不限制" style="width:220px" />
                      <div class="hint">低于此版本的客户端会在「关于」里提示并可直接更新。</div>
                    </div>
                  </el-form-item>

                  <el-form-item>
                    <template #label><span class="cc-label">升级说明页网址（可选）</span></template>
                    <div style="width:100%">
                      <el-input v-model="ccForm.upgradeUrl" placeholder="升级说明页网址（https://…，可选；留空 = 客户端不显示该项）" style="margin-bottom:8px" />
                      <div style="display:flex;gap:8px;margin-bottom:6px;align-items:center">
                        <span style="width:96px;color:#606266;font-size:13px">安卓 APK</span>
                        <el-input v-model="ccForm.pkgAndroid" placeholder="上传后自动填，也可手填 /files/xxx 或 https://…" style="flex:1" />
                        <el-button size="small" :loading="pkgUploading && pkgUploadingPlatform==='android'" @click="pkgPick('android')">{{ (ccForm.pkgAndroid||'').includes('/files/') ? '重新上传' : '上传文件' }}</el-button>
                        <el-button v-if="ccForm.pkgAndroid" size="small" text type="danger" @click="ccForm.pkgAndroid = ''">清除</el-button>
                      </div>
                      <div style="display:flex;gap:8px;margin-bottom:6px;align-items:center">
                        <span style="width:96px;color:#606266;font-size:13px">Windows EXE</span>
                        <el-input v-model="ccForm.pkgWindows" placeholder="上传后自动填，也可手填 /files/xxx 或 https://…" style="flex:1" />
                        <el-button size="small" :loading="pkgUploading && pkgUploadingPlatform==='windows'" @click="pkgPick('windows')">{{ (ccForm.pkgWindows||'').includes('/files/') ? '重新上传' : '上传文件' }}</el-button>
                        <el-button v-if="ccForm.pkgWindows" size="small" text type="danger" @click="ccForm.pkgWindows = ''">清除</el-button>
                      </div>
                      <div style="display:flex;gap:8px;margin-bottom:6px;align-items:center">
                        <span style="width:96px;color:#606266;font-size:13px">iOS 链接</span>
                        <el-input v-model="ccForm.pkgIos" placeholder="App Store / TestFlight 链接" style="flex:1" />
                        <el-button v-if="ccForm.pkgIos" size="small" text type="danger" @click="ccForm.pkgIos = ''">清除</el-button>
                      </div>
                      <div class="hint">「升级说明页网址」是可选项：填了之后，客户端「关于」里会多一个打开该网址的入口（适合放更新须知 / 帮助文档）；<b>留空则客户端不显示该项</b>，不影响下面「立即更新」下载安装包。安卓/WIN「关于 → 立即更新」会下载并调起安装；iOS 跳链接。文件走服务端 /files/ 托管（上限 300MB）。</div>
                    </div>
                    <input ref="pkgFileEl" type="file" style="display:none" @change="onPkgFile" />
                  </el-form-item>

                  <el-form-item>
                    <template #label><span class="cc-label">公告</span></template>
                    <div style="width:100%">
                      <div v-for="(a, i) in ccForm.announcements" :key="i" style="display:flex;gap:8px;margin-bottom:6px;align-items:center">
                        <el-select v-model="a.level" style="width:100px">
                          <el-option label="通知" value="info" />
                          <el-option label="警告" value="warn" />
                          <el-option label="严重" value="critical" />
                        </el-select>
                        <el-input v-model="a.text" placeholder="公告内容" />
                        <el-button size="small" text type="danger" @click="ccForm.announcements.splice(i,1)">删除</el-button>
                      </div>
                      <el-button size="small" @click="ccForm.announcements.push({ text: '', level: 'info' })">+ 加公告</el-button>
                    </div>
                  </el-form-item>

                  <el-form-item>
                    <template #label><span class="cc-label">维护公告</span></template>
                    <div style="width:100%">
                      <el-switch v-model="ccForm.maintOn" inactive-text="无" active-text="启用" />
                      <template v-if="ccForm.maintOn">
                        <el-input v-model="ccForm.maintText" type="textarea" :rows="2" placeholder="维护说明，会显示在登录页" style="margin-top:8px" />
                      </template>
                    </div>
                  </el-form-item>
                </el-form>
              </el-card>
            </el-col>

            <el-col :span="10">
              <el-card style="margin-bottom:16px">
                <template #header>历史版本（版本只增不改，回滚 = 以旧内容发新版本）</template>
                <el-table :data="cc.history" size="small" max-height="260">
                  <el-table-column prop="version" label="版本" width="64" />
                  <el-table-column prop="note" label="说明" show-overflow-tooltip />
                  <el-table-column prop="created_by" label="发布人" width="84" />
                  <el-table-column label="发布时间" width="160">
                    <template #default="{ row }">{{ fmtTime(row.created_at) }}</template>
                  </el-table-column>
                  <el-table-column label="操作" width="84">
                    <template #default="{ row }">
                      <el-button v-if="row.version !== cc.current.version" size="small" text type="warning"
                        @click="rollbackCc(row.version)">回滚</el-button>
                      <el-tag v-else size="small" type="success">当前</el-tag>
                    </template>
                  </el-table-column>
                </el-table>
              </el-card>

              <el-card>
                <template #header>
                  <div class="card-hdr">
                    <span>同步状态（设备上报）</span>
                    <el-button size="small" @click="loadCcApplied">刷新</el-button>
                  </div>
                </template>
                <el-alert v-if="!ccApplied.devices.length" type="info" :closable="false"
                  title="还没有设备上报过配置版本（客户端 v0.8.0 起支持）" />
                <el-table v-else :data="ccApplied.devices" size="small" max-height="300">
                  <el-table-column label="设备" min-width="120">
                    <template #default="{ row }">{{ row.device_id }}</template>
                  </el-table-column>
                  <el-table-column label="用户" width="100">
                    <template #default="{ row }">{{ row.nickname || row.username || '—' }}</template>
                  </el-table-column>
                  <el-table-column label="配置版本" width="88">
                    <template #default="{ row }">v{{ row.config_version }}</template>
                  </el-table-column>
                  <el-table-column label="状态" width="88">
                    <template #default="{ row }">
                      <el-tag size="small" :type="row.state === 'latest' ? 'success' : 'warning'">
                        {{ row.state === 'latest' ? '最新' : '待更新' }}
                      </el-tag>
                    </template>
                  </el-table-column>
                  <el-table-column label="上报时间" width="160">
                    <template #default="{ row }">{{ fmtTime(row.applied_at) }}</template>
                  </el-table-column>
                </el-table>
              </el-card>
            </el-col>
          </el-row>

          <!-- 发布前变更对比 -->
          <el-dialog v-model="ccDiffDlg" title="发布确认 — 本次变更" width="560px">
            <div v-for="d in ccDiff" :key="d.key" style="margin-bottom:10px">
              <b>{{ d.key }}</b>
              <div class="hint">旧：{{ d.old }}</div>
              <div style="color:var(--el-color-success)">新：{{ d.neu }}</div>
            </div>
            <el-alert v-if="!ccDiff.length" type="warning" :closable="false" title="内容没有任何变化，无需发布" />
            <el-input v-model="ccNote" placeholder="发布说明（会记录到历史）" style="margin-top:8px" />
            <template #footer>
              <el-button @click="ccDiffDlg = false">取消</el-button>
              <el-button type="primary" :disabled="!ccDiff.length" :loading="ccBusy" @click="publishCc">确认发布</el-button>
            </template>
          </el-dialog>
        </div>

        <!-- 动态模块（v0.9.0 第二期） -->
        <div v-else-if="tab === 'modules'">
          <el-alert type="success" :closable="false" style="margin-bottom:14px"
            title="在这里拼页面 → 保存 → 客户端下拉刷新即可看到入口，无需重装 App。组件只允许 8 种，颜色只允许语义名（自动适配深色主题）。" />

          <!-- 应用中心总览：客户端「工作台」= 内置应用 + 这里的自定义应用。
               放在这一页是因为管理员来这儿就是为了给客户端长功能，得先知道已经有什么。 -->
          <el-card style="margin-bottom:16px">
            <template #header>
              <div class="card-hdr">
                <span>客户端工作台里的应用（内置 {{ (appCatalog.builtin || []).length }} 个 + 自定义 {{ (appCatalog.dynamic || []).length }} 个）</span>
                <el-button size="small" @click="loadAppCatalog">刷新</el-button>
              </div>
            </template>
            <el-table :data="appCatalog.builtin || []" border size="small">
              <el-table-column label="内置应用" width="180">
                <template #default="{ row }">
                  <b>{{ row.effective.title }}</b>
                  <el-tag v-if="row.effective.title !== row.title" size="small" type="warning" effect="plain"
                    style="margin-left:6px" :title="`出厂名：${row.title}`">已改名</el-tag>
                </template>
              </el-table-column>
              <el-table-column prop="desc" label="说明" min-width="220" show-overflow-tooltip />
              <!-- 分组：改完这个应用就换一组显示（组名可在本页下方「工作台版式」里改） -->
              <el-table-column label="分组" width="190">
                <template #default="{ row }">
                  <el-select :model-value="row.effective.group" size="small" style="width:100%"
                    @change="(v) => appMoveGroup(row, v)">
                    <el-option v-for="g in (appCatalog.groups || [])" :key="g.key" :label="g.label"
                      :value="g.key">
                      <span>{{ g.label }}</span>
                      <span style="float:right;color:#909399;font-size:12px">{{ g.usedBy }} 个</span>
                    </el-option>
                  </el-select>
                </template>
              </el-table-column>
              <!-- 排序直接在这里调：客户端工作台从上到下就是这个顺序（小的在前）。
                   ↑↓ = 和相邻那行交换排序号，不用点进「管理」抽屉里填数字。 -->
              <el-table-column label="排序" width="120" align="center">
                <template #default="{ row }">
                  <span class="mono">{{ row.effective.sort }}</span>
                  <el-button size="small" link type="primary" @click="appMove(row, -1)">↑</el-button>
                  <el-button size="small" link type="primary" @click="appMove(row, 1)">↓</el-button>
                </template>
              </el-table-column>
              <el-table-column label="状态" width="150">
                <template #default="{ row }">
                  <el-tag v-if="row.disabled" size="small" type="danger">已停用</el-tag>
                  <el-tag v-else-if="row.changed" size="small" type="warning" effect="plain">
                    已调整 {{ row.changedFields.length }} 项
                  </el-tag>
                  <el-tag v-else size="small" type="info" effect="plain">出厂设置</el-tag>
                  <div v-if="row.disabled" class="hint" style="margin-top:2px">入口已隐藏，接口也已拦</div>
                </template>
              </el-table-column>
              <el-table-column label="对员工是否可见" width="140">
                <template #default="{ row }">
                  <el-tag v-if="!appWhy[row.id]" size="small" effect="plain">—</el-tag>
                  <el-tag v-else :type="appWhy[row.id].visible ? 'success' : 'warning'" size="small" effect="plain">
                    {{ appWhy[row.id].visible ? '可见' : '当前不可见' }}
                  </el-tag>
                </template>
              </el-table-column>
              <el-table-column label="原因 / 说明" min-width="300">
                <template #default="{ row }">
                  <span v-if="appWhy[row.id] && appWhy[row.id].reasons.length" class="hint">
                    {{ appWhy[row.id].reasons.join('；') }}
                  </span>
                  <span v-else class="hint">正常可见</span>
                </template>
              </el-table-column>
              <el-table-column label="操作" width="130" fixed="right">
                <template #default="{ row }">
                  <el-button size="small" type="primary" plain @click="openAppAdmin(row.id, row.effective?.title || row.title)">管理</el-button>
                </template>
              </el-table-column>
            </el-table>
            <div class="hint" style="margin-top:8px">
              内置应用随客户端安装包发布；它们的入口可见性由<b>业务状态</b>决定
              （是否工作模式 / 是否建了组织 / 考勤是否启用），不是开关 —— 所以不会出现"入口在、点进去报错"。
              其中<b>考勤打卡 / 我的申请</b>是员工专属（自己打卡、自己提申请），<b>考勤记录</b>是管理员专属
              （看今日全员出勤与缺卡、代员工补卡）—— 两类人看到的工作台本来就该不一样。
              下面拼出来的自定义模块和它们并列出现在同一个工作台里。
              <br />
              点每行的<b>「管理」</b>可以给内置应用改名 / 换图标 / <b>换分组 / 换配色</b> / 调顺序 / 调参数 / <b>整应用停用</b>
              （停用会同时隐藏入口<b>并拦掉它的后端接口</b>，不是只藏图标）；<b>调顺序直接点排序列的 ↑↓</b> 更快，
              客户端工作台从上到下就是这里的顺序。自定义模块请到下方模块清单里编辑
              —— 两处都能改同一件事迟早对不上。
              <br />
              <b>分组</b>与<b>顶部公告</b>在下方「工作台版式」里统一改 —— 那两样是"整块工作台长什么样"，
              不属于某一个应用。
            </div>
          </el-card>

          <!-- ==================== 工作台版式：分组 + 公告（v0.22.0） ====================
               从上面那张表拆出来单独一块，是因为它管的是**整块版式**而不是某一个应用：
               组名、组序、收起、新增组，以及工作台顶部那条公告。
               钉钉 / 企业微信 / 飞书的工作台都能改这两样，写死在这里就像别人家的默认模板。 -->
          <el-card style="margin-bottom:16px">
            <template #header>
              <div class="card-hdr">
                <span>工作台版式 —— 分组管理（客户端工作台按组分区显示）</span>
                <el-button size="small" @click="loadWorkbenchView">刷新</el-button>
              </div>
            </template>

            <el-alert type="info" :closable="false" show-icon style="margin-bottom:12px"
              title="组名、组序都可以改；「已隐藏」的组整个收起来（组里还有应用时收起等于那些应用一起消失，改前看一眼「组里应用」列）。出厂分组不能删除，自定义组空了才能删。" />

            <!-- 新增分组 -->
            <div style="display:flex;flex-wrap:wrap;gap:8px;align-items:center;margin-bottom:12px">
              <span class="hint">新增分组：</span>
              <el-input v-model="wb.newKey" size="small" placeholder="组 key，如 store（小写字母开头）" style="width:230px" />
              <el-input v-model="wb.newLabel" size="small" :placeholder="`组名，如 门店作业（最多 ${wb.labelMax || 8} 字）`" style="width:170px" />
              <el-input-number v-model="wb.newSort" size="small" :min="0" :max="9999" />
              <el-button size="small" type="primary" :loading="wb.busy" @click="addGroup">添加分组</el-button>
            </div>

            <el-table :data="wb.groups || []" border size="small">
              <el-table-column label="组名" min-width="200">
                <template #default="{ row }">
                  <el-input v-model="row.label" size="small" @change="(v) => wbSaveGroup(row, { label: v })" />
                </template>
              </el-table-column>
              <el-table-column label="key" width="130">
                <template #default="{ row }"><code class="mono">{{ row.key }}</code></template>
              </el-table-column>
              <el-table-column label="排序" width="120" align="center">
                <template #default="{ row }">
                  <el-input-number v-model="row.sort" size="small" :min="0" :max="9999"
                    @change="(v) => wbSaveGroup(row, { sort: v })" />
                </template>
              </el-table-column>
              <el-table-column label="组里应用" width="110" align="center">
                <template #default="{ row }">
                  <span :style="row.usedBy ? '' : 'color:#c0c4cc'">{{ row.usedBy }}</span>
                </template>
              </el-table-column>
              <el-table-column label="显示" width="100" align="center">
                <template #default="{ row }">
                  <el-switch :model-value="!row.hidden" @change="(v) => wbSaveGroup(row, { hidden: !v })" />
                </template>
              </el-table-column>
              <el-table-column label="操作" width="110" align="center">
                <template #default="{ row }">
                  <el-button size="small" link type="danger" :disabled="!row.custom"
                    @click="wbDelGroup(row)">删除</el-button>
                </template>
              </el-table-column>
            </el-table>
            <div class="hint" style="margin-top:8px">
              「显示」关掉 = 这个组整体收起（key 还留着，随时能放回来）；出厂分组没有删除按钮 ——
              删掉会让挂在上面的应用集体消失，那是最难查的一类问题。
            </div>
          </el-card>

          <!-- ==================== 工作台公告 ==================== -->
          <el-card style="margin-bottom:16px">
            <template #header>
              <div class="card-hdr">
                <span>工作台顶部公告（客户端打开工作台第一眼看到）</span>
                <el-button size="small" @click="purgeNotices">清理已停用</el-button>
                <el-button size="small" @click="loadWorkbenchView">刷新</el-button>
              </div>
            </template>

            <el-alert type="warning" :closable="false" show-icon style="margin-bottom:12px"
              :title="`公告最多 ${wb.textMax || 60} 个字，最多同时显示 ${wb.maxDownload || 3} 条（多了会把应用区顶下去）。停用的公告立刻从手机上消失，但列表里还留着 —— 想彻底清掉请用下面的「清理已停用」。`" />

            <div style="display:flex;flex-wrap:wrap;gap:8px;align-items:center;margin-bottom:12px">
              <el-input v-model="wb.newNotice" size="small" :maxlength="wb.textMax || 60"
                placeholder="要所有人看见的一句话，例如：明天盘点，全店 9 点前把货架归位" style="width:420px" />
              <el-input-number v-model="wb.newNoticeSort" size="small" :min="0" :max="9999" />
              <el-button size="small" type="primary" :loading="wb.busy" @click="addNotice">发布</el-button>
              <el-button size="small" @click="wbBgTarget = 'new'; wbBgEl?.click()">背景图</el-button>
              <img v-if="wb.newNoticeBgUrl" :src="wb.newNoticeBgUrl" style="height:34px;border-radius:4px;object-fit:cover" />
              <el-button v-if="wb.newNoticeBgUrl" size="small" text type="danger" @click="clearWbBg">清除</el-button>
              <input ref="wbBgEl" type="file" accept="image/*" style="display:none" @change="onWbBg" />
            </div>
            <div style="margin-bottom:12px;max-width:540px">
              <div class="hint" style="margin-bottom:4px">正文（点开公告横幅看得到，可不填；最多 {{ wb.contentMax || 2000 }} 字）</div>
              <el-input v-model="wb.newNoticeContent" type="textarea" :rows="3" :maxlength="wb.contentMax || 2000"
                show-word-limit
                placeholder="想多说几句就写这儿，例如活动细则、注意事项……手机端点击工作台公告横幅即可展开看详情。" />
            </div>

            <!-- 宽屏 / 窄屏预览：先在管理台看清楚客户端实际效果再发布 -->
            <div style="display:flex;gap:18px;margin-bottom:14px;flex-wrap:wrap">
              <div>
                <div class="hint" style="margin-bottom:4px">宽屏预览（桌面端工作台）</div>
                <div :style="wbPreviewStyle" style="position:relative;display:flex;align-items:center;gap:8px;width:440px;height:78px;padding:0 14px;border-radius:8px;border:1px solid var(--el-border-color);overflow:hidden;color:#fff;box-sizing:border-box">
                  <div style="position:absolute;inset:0;background:rgba(0,0,0,.38)"></div>
                  <el-icon style="position:relative;z-index:1"><Bell /></el-icon>
                  <span style="position:relative;z-index:1;font-size:13.5px;line-height:1.5;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">{{ wb.newNotice || '（公告内容预览）' }}</span>
                </div>
              </div>
              <div>
                <div class="hint" style="margin-bottom:4px">窄屏预览（手机端工作台）</div>
                <div :style="wbPreviewStyle" style="position:relative;display:flex;align-items:center;gap:8px;width:240px;height:78px;padding:0 14px;border-radius:8px;border:1px solid var(--el-border-color);overflow:hidden;color:#fff;box-sizing:border-box">
                  <div style="position:absolute;inset:0;background:rgba(0,0,0,.38)"></div>
                  <el-icon style="position:relative;z-index:1"><Bell /></el-icon>
                  <span style="position:relative;z-index:1;font-size:13.5px;line-height:1.5;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">{{ wb.newNotice || '（公告内容预览）' }}</span>
                </div>
              </div>
            </div>

            <el-table :data="wb.notices || []" border size="small">
              <el-table-column label="标题" min-width="280">
                <template #default="{ row }">
                  <el-input v-model="row.text" size="small" :maxlength="wb.textMax || 60" @change="(v) => wbSaveNotice(row, { text: v })" />
                </template>
              </el-table-column>
              <el-table-column label="正文" min-width="280">
                <template #default="{ row }">
                  <el-input v-model="row.content" type="textarea" :rows="2" :maxlength="wb.contentMax || 2000"
                    @change="(v) => wbSaveNotice(row, { content: v })" placeholder="（空）点开公告可见" />
                </template>
              </el-table-column>
              <el-table-column label="排序" width="120" align="center">
                <template #default="{ row }">
                  <el-input-number v-model="row.sort" size="small" :min="0" :max="9999"
                    @change="(v) => wbSaveNotice(row, { sort: v })" />
                </template>
              </el-table-column>
              <el-table-column label="状态" width="100" align="center">
                <template #default="{ row }">
                  <el-tag :type="row.enabled ? 'success' : 'info'" size="small" effect="plain">
                    {{ row.enabled ? '生效中' : '已停用' }}
                  </el-tag>
                </template>
              </el-table-column>
              <el-table-column label="启用" width="90" align="center">
                <template #default="{ row }">
                  <el-switch :model-value="row.enabled" @change="(v) => wbSaveNotice(row, { enabled: v })" />
                </template>
              </el-table-column>
              <el-table-column label="背景图" width="120">
                <template #default="{ row }">
                  <div style="display:flex;align-items:center;gap:6px">
                    <img v-if="row.bgUrl" :src="row.bgUrl" style="height:26px;width:26px;object-fit:cover;border-radius:4px" />
                    <span v-else class="hint">无</span>
                    <el-button size="small" link type="primary" @click="wbBgTarget = { row }; wbBgEl?.click()">换</el-button>
                    <el-button v-if="row.bgUrl" size="small" link type="danger" @click="clearWbRowBg(row)">清</el-button>
                  </div>
                </template>
              </el-table-column>
              <el-table-column label="操作" width="90" align="center">
                <template #default="{ row }">
                  <el-button size="small" link type="danger" @click="delNotice(row)">删除</el-button>
                </template>
              </el-table-column>
            </el-table>
            <div class="hint" style="margin-top:8px">
              这是"必须读到"的位置，不是群消息的副本 —— 群消息员工可以压根不看，
              公告在他打开工作台的第一眼就在那儿。横幅上那句话之外，可填「正文」，
              手机端点击公告横幅会弹开应用内详情（标题 + 正文 + 背景图），不用再发群消息。
            </div>
          </el-card>

          <!-- 应用管理抽屉：一个内置应用的全部可调项都在这里。
               刻意做成"出厂值 / 当前值 / 差异"三列可见 —— 管理员最需要回答的问题是
               "这一版和出厂差在哪"，只给当前值他答不出来。 -->
          <el-drawer v-model="appAdm.open" size="70%" :title="appAdm.title">
            <div v-if="appAdm.loading" style="padding:20px"><el-skeleton :rows="6" animated /></div>
            <div v-else-if="appAdm.error">
              <el-alert type="error" :closable="false" :title="appAdm.error" />
            </div>
            <div v-else>
              <el-alert v-if="appAdm.data?.app?.effective?.disabled" type="error" :closable="false"
                style="margin-bottom:12px" show-icon
                title="这个应用当前已停用：客户端看不到入口，它的后端接口一律回 403（app_disabled）。" />
              <el-alert v-if="appAdm.data?.data?.localOnly" type="info" :closable="false" show-icon
                style="margin-bottom:12px" :title="appAdm.data.data.localOnlyNote" />

              <el-tabs v-model="appAdm.tab">
                <!-- ============ 基本信息 ============ -->
                <el-tab-pane label="基本信息" name="basic">
                  <el-form label-width="130px" label-position="left" style="max-width:640px">
                    <el-form-item :label="`名称（出厂：${appAdm.data?.app?.factory?.title}）`">
                      <el-input v-model="appAdm.form.title" maxlength="12" show-word-limit
                        :placeholder="appAdm.data?.app?.factory?.title" />
                    </el-form-item>
                    <el-form-item :label="`图标（出厂：${appAdm.data?.app?.factory?.icon}）`">
                      <el-select v-model="appAdm.form.icon" clearable filterable
                        :placeholder="appAdm.data?.app?.factory?.icon" style="width:100%">
                        <el-option v-for="ic in (appAdm.data?.icons || [])" :key="ic" :label="ic" :value="ic" />
                      </el-select>
                    </el-form-item>
                    <el-form-item label="分组">
                      <el-select v-model="appAdm.form.group" clearable filterable
                        placeholder="留在当前分组" style="width:100%">
                        <el-option v-for="g in (appCatalog.groups || [])" :key="g.key" :label="g.label"
                          :value="g.key">
                          <span>{{ g.label }}</span>
                          <span style="float:right;color:#909399;font-size:12px">{{ g.usedBy }} 个</span>
                        </el-option>
                      </el-select>
                      <span class="hint" style="margin-left:10px">
                        出厂分组是 <code class="mono">{{ appAdm.data?.app?.factory?.group }}</code>；
                        想换到别的组，得先在下方「工作台版式」里建好那个组
                      </span>
                    </el-form-item>
                    <el-form-item :label="`图标底色（出厂：${appAdm.data?.app?.factory?.color || '无'}）`">
                      <div style="display:flex;gap:10px;align-items:center">
                        <el-color-picker v-model="appAdm.form.color" :predefine="WB_COLORS"
                          :disabled="!appAdm.form.color" />
                        <el-button v-if="appAdm.form.color" size="small" link @click="appAdm.form.color = ''">用出厂色</el-button>
                        <span class="hint">客户端工作台的图标底色（#RRGGBB）。</span>
                      </div>
                    </el-form-item>
                    <el-form-item label="排序号（越小越靠前）">
                      <el-input-number v-model="appAdm.form.sort" :min="0" :max="9999" :step="5" />
                      <span class="hint" style="margin-left:10px">
                        出厂顺序号是 {{ appAdm.data?.app?.factory?.sort ?? '—' }}；留空 = 用出厂顺序
                      </span>
                    </el-form-item>
                    <el-form-item>
                      <el-button type="primary" :loading="appAdm.saving" @click="saveAppAdm">保存</el-button>
                      <el-button :disabled="!appAdm.data?.app?.changed" @click="resetAppAdm">恢复出厂设置</el-button>
                    </el-form-item>
                  </el-form>
                  <el-divider content-position="left">与出厂的差异</el-divider>
                  <el-table v-if="(appAdm.data?.app?.changedFields || []).length" :data="appAdm.data.app.changedFields"
                    border size="small">
                    <el-table-column prop="label" label="项目" width="140" />
                    <el-table-column label="出厂" min-width="150">
                      <template #default="{ row }">{{ row.from === null ? '（无）' : row.from }}</template>
                    </el-table-column>
                    <el-table-column label="当前" min-width="150">
                      <template #default="{ row }">{{ row.to === true ? '是' : (row.to === false ? '否' : row.to) }}</template>
                    </el-table-column>
                  </el-table>
                  <div v-else class="hint">当前和出厂完全一致。</div>
                  <el-divider content-position="left">出厂定义（只读）</el-divider>
                  <div class="hint">
                    说明：{{ appAdm.data?.app?.factory?.desc }}<br />
                    <code class="mono">{{ appAdm.data?.app?.id }}</code>
                    · 分组 {{ appAdm.data?.app?.factory?.group }}
                    · 分组内不再有可覆盖项 —— <b>「什么时候该出现」由业务状态决定，不可覆盖</b>：
                    {{ needText(appAdm.data?.app?.factory?.need) }}
                  </div>
                </el-tab-pane>

                <!-- ============ 功能设置 ============ -->
                <el-tab-pane label="功能设置" name="params">
                  <div class="hint" style="margin-bottom:10px">
                    参数的取值由<b>服务端保存并下发</b>；标注「服务端」的改完立刻生效，
                    标注「客户端」的下发到手机后由客户端读取（需要客户端版本支持）。
                  </div>
                  <el-table :data="appAdm.data?.app?.params || []" border size="small">
                    <el-table-column prop="label" label="参数" width="170">
                      <template #default="{ row }">
                        <div>{{ row.label }}</div>
                        <el-tag size="small" :type="row.enforced === 'server' ? 'success' : 'warning'" effect="plain">
                          {{ row.enforced === 'server' ? '服务端' : '客户端' }}
                        </el-tag>
                      </template>
                    </el-table-column>
                    <el-table-column label="取值" width="200">
                      <template #default="{ row }">
                        <el-switch v-if="row.type === 'bool'" :model-value="row.value"
                          @change="(v) => setAppParam(row.key, v)" />
                        <el-input v-else :model-value="row.value" :placeholder="row.type === 'version' ? '留空 = 不限' : ''"
                          @change="(v) => setAppParam(row.key, v)" />
                      </template>
                    </el-table-column>
                    <el-table-column prop="desc" label="说明" min-width="280" />
                    <el-table-column label="状态" width="110">
                      <template #default="{ row }">
                        <el-tag v-if="row.overridden" size="small" type="warning" effect="plain">已改</el-tag>
                        <el-tag v-else size="small" type="info" effect="plain">默认</el-tag>
                        <el-button v-if="row.overridden" link size="small" style="margin-left:4px"
                          @click="setAppParam(row.key, row.def)">还原</el-button>
                      </template>
                    </el-table-column>
                  </el-table>
                </el-tab-pane>

                <!-- ============ 数据 ============ -->
                <el-tab-pane label="数据" name="data">
                  <div v-if="!(appAdm.data?.data?.sources || []).length" class="hint" style="padding:10px 0">
                    <span v-if="appAdm.data?.data?.localOnly">{{ appAdm.data.data.localOnlyNote }}</span>
                    <span v-else>这个应用暂无可查看的数据源。</span>
                  </div>
                  <template v-else>
                    <div class="hint" style="margin-bottom:10px">{{ appAdm.data?.data?.overviewNote }}</div>
                    <div v-if="(appAdm.data?.data?.warnings || []).length" style="margin-bottom:10px">
                      <el-alert v-for="(w, i) in appAdm.data.data.warnings" :key="i" type="warning"
                        :closable="false" :title="w" style="margin-bottom:4px" />
                    </div>

                    <div class="mtiles">
                      <div v-for="m in (appAdm.data?.data?.metrics || [])" :key="m.key" class="mtile">
                        <div class="mtile-k">{{ m.label }}</div>
                        <div class="mtile-v">
                          {{ m.value }}<span v-if="m.unit" style="font-size:13px;font-weight:500;margin-left:2px">{{ m.unit }}</span>
                        </div>
                      </div>
                    </div>

                    <div class="card-hdr" style="margin:14px 0 8px">
                      <div style="display:flex;gap:8px;flex-wrap:wrap;align-items:center">
                        <el-select v-model="appAdm.src" style="width:190px" @change="loadAppRows">
                          <el-option v-for="s in appAdm.data.data.sources" :key="s.key" :label="s.name" :value="s.key" />
                        </el-select>
                        <el-input v-model="appAdm.q" placeholder="搜索" clearable style="width:170px"
                          @keyup.enter="loadAppRows" @clear="loadAppRows" />
                        <el-date-picker v-model="appAdm.range" type="daterange" unlink-panels
                          range-separator="~" start-placeholder="开始" end-placeholder="结束"
                          value-format="YYYY-MM-DD" style="width:240px" @change="loadAppRows" />
                        <el-checkbox v-model="appAdm.allTime" @change="loadAppRows">全部时间</el-checkbox>
                        <el-button size="small" :loading="appAdm.rowsLoading" @click="loadAppRows">查询</el-button>
                        <el-button size="small" type="primary" plain @click="exportAppRows">导出 CSV</el-button>
                      </div>
                    </div>
                    <div v-if="appAdm.srcTimeFiltered === false" class="hint" style="margin-bottom:6px">
                      该数据源没有时间维度，时间筛选对它不生效。
                    </div>

                    <el-table :data="appAdm.rows" border size="small" v-loading="appAdm.rowsLoading" max-height="420">
                      <el-table-column v-for="c in appAdm.cols" :key="c.key" :prop="c.key" :label="c.label"
                        :width="c.width" show-overflow-tooltip />
                    </el-table>
                    <div style="margin-top:10px;display:flex;justify-content:flex-end">
                      <el-pagination small background layout="total, prev, pager, next, sizes"
                        :total="appAdm.total" :current-page="appAdm.page" :page-size="appAdm.pageSize"
                        :page-sizes="[20, 50, 100, 200]"
                        @current-change="(p) => { appAdm.page = p; loadAppRows(); }"
                        @size-change="(s) => { appAdm.pageSize = s; appAdm.page = 1; loadAppRows(); }" />
                    </div>
                  </template>
                </el-tab-pane>

                <!-- ============ 停用与清理 ============ -->
                <el-tab-pane label="停用与清理" name="danger">
                  <el-divider content-position="left">整应用停用</el-divider>
                  <div class="hint" style="margin-bottom:10px">
                    停用 = <b>隐藏入口 + 后端每条接口都拦</b>（回 403 / app_disabled）。只藏入口是不够的：
                    老客户端、缓存页面照样能打卡、能上传，而你以为已经停用了。
                  </div>
                  <el-switch :model-value="appAdm.data?.app?.effective?.disabled" active-text="停用这个应用"
                    @change="toggleAppDisabled" />
                  <div style="margin-top:12px">
                    <div class="hint" style="margin-bottom:6px">
                      停用后会关掉这些接口（{{ appAdm.data?.guard?.note }}）：
                    </div>
                    <el-table v-if="(appAdm.data?.guard?.items || []).length" :data="appAdm.data.guard.items"
                      border size="small">
                      <el-table-column prop="scope" label="范围" width="200" />
                      <el-table-column label="接口" min-width="320">
                        <template #default="{ row }">
                          <code v-for="p in row.paths" :key="p" class="mono" style="display:block">{{ p }}</code>
                        </template>
                      </el-table-column>
                      <el-table-column label="管理台" width="130">
                        <template #default="{ row }">
                          <el-tag v-if="row.consoleOnly" size="small" type="success" effect="plain">不受影响</el-tag>
                          <span v-else class="hint">一并停用</span>
                        </template>
                      </el-table-column>
                    </el-table>
                    <div v-else class="hint">{{ appAdm.data?.guard?.localOnly ? '这个应用没有服务端接口（见上方说明）。' : '没有登记到接口。' }}</div>
                  </div>
                  <div v-if="appAdm.data?.data?.shared" class="hint" style="margin-top:10px">
                    <b>共用接口不随停用而关闭：</b>
                    <div v-for="(v, k) in appAdm.data.data.shared" :key="k">· <code class="mono">{{ k }}</code> — {{ v }}</div>
                  </div>

                  <el-divider content-position="left">数据清理</el-divider>
                  <template v-if="(appAdm.data?.data?.purgeables || []).length">
                    <el-alert type="warning" :closable="false" show-icon style="margin-bottom:10px"
                      title="清理不可逆。流程是：先预览命中条数 → 确认后手输条数 → 服务端重算比对一致才执行，并先落一份备份。" />
                    <div style="display:flex;gap:8px;flex-wrap:wrap;align-items:center;margin-bottom:10px">
                      <el-select v-model="appAdm.purgeSrc" style="width:190px">
                        <el-option v-for="p in appAdm.data.data.purgeables" :key="p.key" :label="p.label" :value="p.key" />
                      </el-select>
                      <el-date-picker v-model="appAdm.range" type="daterange" unlink-panels
                        range-separator="~" start-placeholder="开始" end-placeholder="结束"
                        value-format="YYYY-MM-DD" style="width:240px" />
                      <el-checkbox v-model="appAdm.allTime">全部时间</el-checkbox>
                      <el-button type="warning" plain :loading="appAdm.purgeBusy" @click="appPurgePreview">预览要清理什么</el-button>
                    </div>
                    <div v-if="appAdm.purgePrev">
                      <el-alert :type="appAdm.purgePrev.count ? 'error' : 'success'" :closable="false" show-icon
                        :title="appAdm.purgePrev.count
                          ? `将删除 ${appAdm.purgePrev.count} 条「${appAdm.purgePrev.label}」。下面是最新的若干条样例：`
                          : '当前条件下没有可清理的数据。'" />
                      <!-- 样例的形状是"每行一个 {key,label,value} 数组"（服务端按数据源
                           自己那套列定义生成的），所以列头取自 sample[0]，单元格取 row[key].value -->
                      <el-table v-if="appAdm.purgePrev.count" :data="appAdm.purgePrev.sample" border size="small"
                        max-height="260" style="margin-top:8px">
                        <el-table-column v-for="c in (appAdm.purgePrev.sample[0] || [])" :key="c.key" :label="c.label"
                          show-overflow-tooltip>
                          <template #default="{ row }">{{ row[c.key]?.value }}</template>
                        </el-table-column>
                      </el-table>
                      <div v-if="appAdm.purgePrev.count" style="margin-top:10px;display:flex;gap:8px;align-items:center">
                        <span class="hint">请输入上面的条数以确认：</span>
                        <el-input-number v-model="appAdm.purgeConfirm" :min="0" />
                        <el-button type="danger" :disabled="appAdm.purgeConfirm !== appAdm.purgePrev.count"
                          :loading="appAdm.purgeBusy" @click="appPurgeRun">确认清理</el-button>
                      </div>
                    </div>
                  </template>
                  <div v-else class="hint">{{ appAdm.data?.data?.readOnlyReason || '这个应用的数据不支持清理。' }}</div>
                </el-tab-pane>
              </el-tabs>
            </div>
          </el-drawer>

          <el-row :gutter="16">
            <el-col :span="8">
              <el-card>
                <template #header>
                  <div class="card-hdr">
                    <span>模块清单（{{ mm.modules.length }}）</span>
                    <div>
                      <el-button size="small" @click="loadMm">刷新</el-button>
                      <el-button size="small" type="primary" @click="newModule">新建</el-button>
                    </div>
                  </div>
                </template>

                <el-alert v-if="!mm.modules.length" type="info" :closable="false"
                  title="还没有模块。可以从下面的「模板库」一键建一个开始。" />

                <div v-for="m in mm.modules" :key="m.moduleId" class="mm-item"
                  :class="{ 'mm-item-on': m.moduleId === mmSel }" @click="selectModule(m)">
                  <div style="display:flex;align-items:center;gap:8px">
                    <b>{{ m.title }}</b>
                    <el-tag v-if="!m.enabled" size="small" type="info">已停用</el-tag>
                    <el-tag v-if="m.minClientVersion" size="small" type="warning">需 {{ m.minClientVersion }}</el-tag>
                  </div>
                  <div class="hint">
                    <code class="mono">{{ m.moduleId }}</code>
                    · {{ (m.body || []).length }} 个内容块
                    · {{ visibleLabel(m) }}
                  </div>
                </div>

                <el-divider content-position="left">模板库</el-divider>
                <div class="hint" style="margin-bottom:8px">
                  一键载入一份可用的起始内容（模板定义在服务端，与校验规则同源，不会出现
                  "模板本身不合法"的情况）。载入后确认无误再点保存。
                </div>
                <el-button v-for="t in mm.capability.templates" :key="t.id" size="small"
                  style="margin:0 6px 6px 0" :title="t.desc"
                  @click="applyTemplate(t)">{{ t.name }}</el-button>
              </el-card>
            </el-col>

            <el-col :span="16">
              <el-card>
                <template #header>
                  <div class="card-hdr">
                    <span>{{ mmSel ? '编辑模块' : '新建模块' }}</span>
                    <div>
                      <el-button size="small" @click="mmJsonDlg = true" :disabled="!mmForm.moduleId">预览 JSON</el-button>
                      <el-button size="small" :disabled="!mmSel" @click="openSubs(mmSel)">提交记录</el-button>
                      <el-button size="small" :disabled="!mmSel" type="danger" plain @click="deleteModule(mmSel)">删除</el-button>
                      <el-button size="small" type="primary" :loading="mmBusy" @click="saveModule">保存</el-button>
                    </div>
                  </div>
                </template>

                <el-form label-width="120px" label-position="left">
                  <el-row :gutter="12">
                    <el-col :span="12">
                      <el-form-item label="模块 ID">
                        <el-input v-model="mmForm.moduleId" :disabled="!!mmSel"
                          placeholder="小写字母/数字/下划线，如 device_repair" />
                      </el-form-item>
                    </el-col>
                    <el-col :span="12">
                      <el-form-item label="标题">
                        <el-input v-model="mmForm.title" placeholder="显示在应用列表里" />
                      </el-form-item>
                    </el-col>
                  </el-row>
                  <el-row :gutter="12">
                    <el-col :span="12">
                      <el-form-item label="图标">
                        <el-select v-model="mmForm.icon" style="width:100%">
                          <el-option v-for="i in mm.capability.icons" :key="i" :label="i" :value="i" />
                        </el-select>
                      </el-form-item>
                    </el-col>
                    <el-col :span="12">
                      <el-form-item label="排序">
                        <el-input-number v-model="mmForm.sort" :min="0" :max="9999" />
                        <span class="hint" style="margin-left:8px">数字小的排前面</span>
                      </el-form-item>
                    </el-col>
                  </el-row>
                  <el-row :gutter="12">
                    <el-col :span="12">
                      <el-form-item label="最低客户端版本">
                        <el-input v-model="mmForm.minClientVersion" placeholder="如 0.9.0；留空 = 不限制" />
                      </el-form-item>
                    </el-col>
                    <el-col :span="12">
                      <el-form-item label="启用">
                        <el-switch v-model="mmForm.enabled" active-text="下发" inactive-text="停用" />
                      </el-form-item>
                    </el-col>
                  </el-row>
                  <el-form-item label="可见范围">
                    <div style="width:100%">
                      <el-select v-model="mmForm.roles" multiple placeholder="按角色（留空 = 不限）" style="width:100%;margin-bottom:6px">
                        <el-option label="管理员 admin" value="admin" />
                        <el-option label="普通用户 user" value="user" />
                      </el-select>
                      <el-select v-model="mmForm.userIds" multiple filterable placeholder="按用户（留空 = 不限）" style="width:100%">
                        <el-option v-for="u in userOptions" :key="u.id"
                          :label="(u.nickname || u.username) + ' #' + u.id" :value="u.id" />
                      </el-select>
                      <div class="hint">
                        角色和用户都留空 = 所有人可见（会写进免鉴权的 bootstrap）；只要填了任一项，就变成需登录才下发。
                      </div>
                    </div>
                  </el-form-item>

                  <el-divider content-position="left">页面内容（{{ mmForm.body.length }} / {{ mm.capability.maxComponents }}）</el-divider>

                  <div v-for="(c, i) in mmForm.body" :key="i" class="mm-comp">
                    <div class="mm-comp-hdr">
                      <el-tag size="small">{{ compLabel(c.component) }}</el-tag>
                      <div>
                        <el-button size="small" text :disabled="i === 0" @click="moveComp(i, -1)">上移</el-button>
                        <el-button size="small" text :disabled="i === mmForm.body.length - 1" @click="moveComp(i, 1)">下移</el-button>
                        <el-button size="small" text type="danger" @click="mmForm.body.splice(i, 1)">删除</el-button>
                      </div>
                    </div>

                    <!-- text -->
                    <template v-if="c.component === 'text'">
                      <el-input v-model="c.text" type="textarea" :rows="2" placeholder="要显示的文字" />
                      <div style="display:flex;gap:8px;margin-top:6px;align-items:center">
                        <el-input-number v-model="c.size" :min="8" :max="40" />
                        <el-select v-model="c.color" style="width:130px">
                          <el-option v-for="x in mm.capability.colors" :key="x" :label="x" :value="x" />
                        </el-select>
                        <el-select v-model="c.align" style="width:110px">
                          <el-option label="左" value="left" />
                          <el-option label="中" value="center" />
                          <el-option label="右" value="right" />
                        </el-select>
                      </div>
                    </template>

                    <!-- card -->
                    <template v-else-if="c.component === 'card'">
                      <div style="display:flex;gap:8px">
                        <el-input v-model="c.title" placeholder="卡片标题" />
                        <el-input v-model="c.subtitle" placeholder="副标题" />
                        <el-select v-model="c.accent" style="width:140px">
                          <el-option v-for="x in mm.capability.colors" :key="x" :label="x" :value="x" />
                        </el-select>
                      </div>
                      <div class="hint" style="margin:8px 0 4px">卡内组件（{{ (c.children || []).length }}）</div>
                      <div v-for="(cc, ci) in c.children" :key="ci" class="mm-comp" style="margin-bottom:6px">
                        <div class="mm-comp-hdr">
                          <el-tag size="small" type="info">{{ compLabel(cc.component) }}</el-tag>
                          <el-button size="small" text type="danger" @click="c.children.splice(ci, 1)">删除</el-button>
                        </div>
                        <template v-if="cc.component === 'text'">
                          <el-input v-model="cc.text" type="textarea" :rows="2" />
                          <el-select v-model="cc.color" style="width:140px;margin-top:6px">
                            <el-option v-for="x in mm.capability.colors" :key="x" :label="x" :value="x" />
                          </el-select>
                        </template>
                        <template v-else-if="cc.component === 'list'">
                          <el-input v-model="cc.dataPath" placeholder="数据路径，如 data.items" style="margin-bottom:6px" />
                          <el-input v-model="cc.itemTemplate.title" placeholder="标题模板，如 {{name}}" style="margin-bottom:6px" />
                          <el-input v-model="cc.itemTemplate.subtitle" placeholder="副标题模板" style="margin-bottom:6px" />
                          <el-input v-model="cc.itemTemplate.trailing" placeholder="右侧文字模板" />
                        </template>
                        <template v-else-if="cc.component === 'table'">
                          <el-input v-model="cc.dataPath" placeholder="数据路径，如 data.rows" style="margin-bottom:6px" />
                          <div v-for="(col, xi) in cc.columns" :key="xi" style="display:flex;gap:6px;margin-bottom:6px">
                            <el-input v-model="col.key" placeholder="字段名" />
                            <el-input v-model="col.label" placeholder="表头文字" />
                            <el-button size="small" text type="danger" @click="cc.columns.splice(xi, 1)">删</el-button>
                          </div>
                          <el-button size="small" @click="cc.columns.push({ key: '', label: '' })">+ 加一列</el-button>
                        </template>
                        <template v-else-if="cc.component === 'chart'">
                          <el-input v-model="cc.dataPath" placeholder="数据路径" style="margin-bottom:6px" />
                          <div style="display:flex;gap:6px">
                            <el-input v-model="cc.xKey" placeholder="X 字段" />
                            <el-input v-model="cc.yKey" placeholder="Y 字段" />
                            <el-select v-model="cc.kind" style="width:120px">
                              <el-option v-for="k in mm.capability.chartKinds" :key="k" :label="k" :value="k" />
                            </el-select>
                          </div>
                        </template>
                        <template v-else-if="cc.component === 'action'">
                          <el-input v-model="cc.label" placeholder="按钮文字" style="margin-bottom:6px" />
                          <div class="mm-act">
                            <el-select v-model="cc.onTap.action" style="width:220px">
                              <el-option v-for="a in mmActionTypes" :key="a.value" :label="a.label" :value="a.value" />
                            </el-select>
                            <template v-if="cc.onTap.action === 'api' || cc.onTap.action === 'submit'">
                              <el-input v-model="cc.onTap.path" placeholder="/api/hooks/xxx（只允许这个前缀）" />
                              <el-select v-model="cc.onTap.method" style="width:100px">
                                <el-option label="GET" value="GET" />
                                <el-option label="POST" value="POST" />
                              </el-select>
                            </template>
                            <el-select v-else-if="cc.onTap.action === 'navigate'" v-model="cc.onTap.page" style="width:180px">
                              <el-option v-for="p in mm.capability.navPages" :key="p" :label="p" :value="p" />
                            </el-select>
                            <el-input v-else-if="cc.onTap.action === 'copy'" v-model="cc.onTap.text" placeholder="要复制的文字" />
                            <el-input v-else v-model="cc.onTap.url" placeholder="https://…（只允许 https）" />
                          </div>
                        </template>
                        <template v-else-if="cc.component === 'form'">
                          <div class="hint">表单请放在最外层（卡内表单在客户端也能渲染，但管理台暂不提供编辑，避免嵌套过深）。</div>
                        </template>
                        <template v-else-if="cc.component === 'divider'">
                          <div class="hint">分隔线，无需配置</div>
                        </template>
                      </div>
                      <el-button size="small" @click="addChild(c)">+ 加卡内组件</el-button>
                    </template>

                    <!-- list -->
                    <template v-else-if="c.component === 'list'">
                      <el-input v-model="c.dataPath" placeholder="数据路径，如 data.items（服务端算好）" style="margin-bottom:6px" />
                      <el-input v-model="c.itemTemplate.title" placeholder="标题模板，如 {{name}}" style="margin-bottom:6px" />
                      <el-input v-model="c.itemTemplate.subtitle" placeholder="副标题模板" style="margin-bottom:6px" />
                      <el-input v-model="c.itemTemplate.trailing" placeholder="右侧文字模板" />
                      <div class="hint">模板里用「双大括号 + 字段名」写占位符，服务端数据里的同名字段会被替换进来。</div>
                    </template>

                    <!-- table -->
                    <template v-else-if="c.component === 'table'">
                      <el-input v-model="c.dataPath" placeholder="数据路径，如 data.rows" style="margin-bottom:6px" />
                      <div v-for="(col, xi) in c.columns" :key="xi" style="display:flex;gap:6px;margin-bottom:6px">
                        <el-input v-model="col.key" placeholder="字段名" />
                        <el-input v-model="col.label" placeholder="表头文字" />
                        <el-input-number v-model="col.width" :min="40" :max="400" placeholder="宽" />
                        <el-button size="small" text type="danger" @click="c.columns.splice(xi, 1)">删</el-button>
                      </div>
                      <el-button size="small" @click="c.columns.push({ key: '', label: '' })">+ 加一列</el-button>
                    </template>

                    <!-- chart -->
                    <template v-else-if="c.component === 'chart'">
                      <el-input v-model="c.dataPath" placeholder="数据路径，如 data.rows" style="margin-bottom:6px" />
                      <div style="display:flex;gap:6px">
                        <el-input v-model="c.xKey" placeholder="X 轴字段" />
                        <el-input v-model="c.yKey" placeholder="Y 轴字段" />
                        <el-select v-model="c.kind" style="width:140px">
                          <el-option v-for="k in mm.capability.chartKinds" :key="k" :label="k === 'bar' ? '柱状 bar' : '折线 line'" :value="k" />
                        </el-select>
                      </div>
                    </template>

                    <!-- action -->
                    <template v-else-if="c.component === 'action'">
                      <el-input v-model="c.label" placeholder="按钮文字" style="margin-bottom:6px" />
                      <div class="mm-act">
                        <el-select v-model="c.onTap.action" style="width:220px">
                          <el-option v-for="a in mmActionTypes" :key="a.value" :label="a.label" :value="a.value" />
                        </el-select>
                        <template v-if="c.onTap.action === 'api' || c.onTap.action === 'submit'">
                          <el-input v-model="c.onTap.path" placeholder="/api/hooks/xxx（只允许这个前缀）" />
                          <el-select v-model="c.onTap.method" style="width:100px">
                            <el-option label="GET" value="GET" />
                            <el-option label="POST" value="POST" />
                          </el-select>
                        </template>
                        <el-select v-else-if="c.onTap.action === 'navigate'" v-model="c.onTap.page" style="width:180px">
                          <el-option v-for="p in mm.capability.navPages" :key="p" :label="p" :value="p" />
                        </el-select>
                        <el-input v-else-if="c.onTap.action === 'copy'" v-model="c.onTap.text" placeholder="要复制的文字" />
                        <el-input v-else v-model="c.onTap.url" placeholder="https://…（只允许 https）" />
                      </div>
                      <div class="hint">
                        接口路径必须以 <code class="mono">/api/hooks/</code> 开头；
                        上游的真实地址在「<b>上游接口</b>」里登记，这里只填
                        <code class="mono">{{ us.pathPrefix }}&lt;接口名&gt;/&lt;子路径&gt;</code>。
                        填之前先去那一页「试跑」一下，按真实返回的字段拼数据路径，比猜快。
                      </div>
                    </template>

                    <!-- form -->
                    <template v-else-if="c.component === 'form'">
                      <div v-for="(f, fi) in c.fields" :key="fi" class="mm-field">
                        <div style="display:flex;gap:6px;margin-bottom:6px">
                          <el-input v-model="f.key" placeholder="字段名（英文，如 device）" />
                          <el-input v-model="f.label" placeholder="显示名称" />
                          <el-select v-model="f.type" style="width:140px">
                            <el-option v-for="t in mm.capability.fieldTypes" :key="t" :label="t" :value="t" />
                          </el-select>
                          <el-checkbox v-model="f.required">必填</el-checkbox>
                          <el-button size="small" text type="danger" @click="c.fields.splice(fi, 1)">删除</el-button>
                        </div>
                        <template v-if="f.type === 'select'">
                          <div v-for="(o, oi) in f.options" :key="oi" style="display:flex;gap:6px;margin-bottom:6px">
                            <el-input v-model="o.label" placeholder="选项文字" />
                            <el-input v-model="o.value" placeholder="提交值" />
                            <el-button size="small" text type="danger" @click="f.options.splice(oi, 1)">删</el-button>
                          </div>
                          <el-button size="small" @click="f.options.push({ label: '', value: '' })">+ 加选项</el-button>
                        </template>
                        <el-input v-else v-model="f.placeholder" placeholder="输入提示（可空）" />
                      </div>
                      <el-button size="small" @click="c.fields.push({ key: '', label: '', type: 'text', required: false, options: [] })">
                        + 加字段
                      </el-button>
                      <div class="hint">
                        提交的数据会先由服务端按这里的字段清单清洗 —— 客户端多传的字段一律丢弃。
                      </div>
                    </template>

                    <template v-else-if="c.component === 'divider'">
                      <div class="hint">分隔线，无需配置</div>
                    </template>

                    <template v-else>
                      <el-alert type="error" :closable="false" title="未知组件类型，保存会被服务端拒绝" />
                    </template>
                  </div>

                  <div style="margin-top:12px">
                    <span class="hint" style="margin-right:8px">添加组件：</span>
                    <el-button v-for="k in mm.capability.components" :key="k" size="small"
                      @click="addComp(k)">{{ compLabel(k) }}</el-button>
                  </div>
                </el-form>
              </el-card>
            </el-col>
          </el-row>

          <el-dialog v-model="mmJsonDlg" title="模块定义 JSON（这就是客户端会收到的内容）" width="720px">
            <pre class="mm-json">{{ mmJson }}</pre>
          </el-dialog>

          <el-dialog v-model="mmSubsDlg" title="提交记录" width="760px">
            <el-table :data="mmSubs" size="small" max-height="420">
              <el-table-column prop="nickname" label="提交人" width="120" />
              <el-table-column label="提交内容" min-width="300">
                <template #default="{ row }"><code class="mono">{{ JSON.stringify(row.data) }}</code></template>
              </el-table-column>
              <el-table-column label="时间" width="160">
                <template #default="{ row }">{{ fmtTime(row.created_at) }}</template>
              </el-table-column>
            </el-table>
            <el-alert v-if="!mmSubs.length" type="info" :closable="false"
              title="还没有提交记录。客户端提交后这里会出现（字段已由服务端按 schema 白名单清洗）。" />
          </el-dialog>
        </div>

        <!-- 系统设置 -->
        <!-- 组织机构（套用工厂 V2 人事模型：部门 → 岗位 → 员工 + 批量导入） -->
        <div v-else-if="tab === 'orgs'">
          <el-alert v-if="!orgWorkMode" type="warning" :closable="false" style="margin-bottom:14px">
            <template #title>
              当前是普通好友模式：组织信息可查看，创建组织 / 录入员工前请先到「系统设置」开启工作模式。
            </template>
          </el-alert>

          <el-card v-if="!orgData.org">
            <template #header>创建组织（一个服务器一个组织）</template>
            <el-form inline label-width="80px" style="max-width:560px">
              <el-form-item label="组织名">
                <el-input v-model="orgNewName" maxlength="30" placeholder="2-30 个字，如：盛京食品厂" style="width:260px" />
              </el-form-item>
              <el-form-item>
                <el-button type="primary" :loading="orgBusy" @click="createOrg">创建组织</el-button>
              </el-form-item>
            </el-form>
          </el-card>

          <el-card v-else>
            <template #header>
              <div class="card-hdr">
                <span>组织机构：{{ orgData.org.name }}（{{ orgData.members.length }} 人）</span>
                <el-button size="small" @click="loadOrgs">刷新</el-button>
              </div>
            </template>

            <el-tabs v-model="orgTab">
              <!-- ======== 部门管理 ======== -->
              <el-tab-pane label="部门管理" name="depts">
                <div style="margin-bottom:12px">
                  <el-button size="small" type="primary" @click="openDeptDlg()">新增部门</el-button>
                </div>
                <el-table :data="orgData.depts || []" border stripe row-key="id">
                  <el-table-column prop="id" label="ID" width="70" />
                  <el-table-column prop="name" label="部门名称" min-width="160" />
                  <el-table-column label="上级部门" min-width="140">
                    <template #default="{ row }">{{ deptName(row.parent_id) || '—（顶级）' }}</template>
                  </el-table-column>
                  <el-table-column prop="sort" label="排序" width="80" />
                  <el-table-column label="操作" width="150">
                    <template #default="{ row }">
                      <el-button size="small" type="primary" plain @click="openDeptDlg(row)">编辑</el-button>
                      <el-button size="small" type="danger" @click="removeDept(row)">删除</el-button>
                    </template>
                  </el-table-column>
                </el-table>
              </el-tab-pane>

              <!-- ======== 岗位管理 ======== -->
              <el-tab-pane label="岗位管理" name="positions">
                <div style="margin-bottom:12px">
                  <el-button size="small" type="primary" @click="openPosDlg()">新增岗位</el-button>
                </div>
                <el-table :data="orgData.positions || []" border stripe>
                  <el-table-column prop="id" label="ID" width="70" />
                  <el-table-column prop="name" label="岗位名称" min-width="160" />
                  <el-table-column label="所属部门" min-width="140">
                    <template #default="{ row }">{{ row.dept_name || '—（通用）' }}</template>
                  </el-table-column>
                  <el-table-column prop="sort" label="排序" width="80" />
                  <el-table-column label="操作" width="150">
                    <template #default="{ row }">
                      <el-button size="small" type="primary" plain @click="openPosDlg(row)">编辑</el-button>
                      <el-button size="small" type="danger" @click="removePos(row)">删除</el-button>
                    </template>
                  </el-table-column>
                </el-table>
              </el-tab-pane>

              <!-- ======== 员工管理 ======== -->
              <el-tab-pane :label="`员工管理（${orgData.members.length}）`" name="members">
                <div style="margin-bottom:12px">
                  <el-button size="small" type="success" @click="orgImportDlg = true">批量导入</el-button>
                  <el-button size="small" type="primary" @click="orgDlg = true">录入员工</el-button>
                </div>
                <el-table :data="orgData.members" border stripe>
                  <el-table-column prop="id" label="ID" width="70" />
                  <el-table-column prop="employee_no" label="工号" width="110">
                    <template #default="{ row }">{{ row.employee_no || '—' }}</template>
                  </el-table-column>
                  <el-table-column prop="username" label="账号" width="110" />
                  <el-table-column prop="nickname" label="昵称" min-width="110" />
                  <el-table-column label="部门" min-width="120">
                    <template #default="{ row }">{{ row.dept_name || '—' }}</template>
                  </el-table-column>
                  <el-table-column label="岗位" min-width="120">
                    <template #default="{ row }">{{ row.position_name || '—' }}</template>
                  </el-table-column>
                  <el-table-column label="操作" width="150">
                    <template #default="{ row }">
                      <el-button size="small" type="primary" plain @click="openMemberDlg(row)">编辑</el-button>
                      <el-button size="small" type="danger" @click="removeMember(row)">移除</el-button>
                    </template>
                  </el-table-column>
                </el-table>
              </el-tab-pane>
            </el-tabs>
          </el-card>

          <!-- 录入员工 -->
          <el-dialog v-model="orgDlg" title="录入员工" width="460px">
            <el-alert type="info" :closable="false" style="margin-bottom:14px">
              <template #title>工号即登录账号，初始密码 = 工号；录入后自动与全员互为好友。</template>
            </el-alert>
            <el-form label-width="70px">
              <el-form-item label="工号">
                <el-input v-model="orgEmp.no" maxlength="20" placeholder="3-20 位字母/数字/下划线，如 001 或 emp001" />
              </el-form-item>
              <el-form-item label="昵称">
                <el-input v-model="orgEmp.name" maxlength="24" placeholder="可选，默认同工号" />
              </el-form-item>
              <el-form-item label="部门">
                <el-select v-model="orgEmp.deptId" clearable placeholder="可选" style="width:100%">
                  <el-option v-for="d in orgData.depts || []" :key="d.id" :label="deptName(d.parent_id) ? deptName(d.parent_id) + ' / ' + d.name : d.name" :value="d.id" />
                </el-select>
              </el-form-item>
              <el-form-item label="岗位">
                <el-select v-model="orgEmp.positionId" clearable placeholder="可选" style="width:100%">
                  <el-option v-for="p in orgData.positions || []" :key="p.id" :label="p.name" :value="p.id" />
                </el-select>
              </el-form-item>
            </el-form>
            <template #footer>
              <el-button @click="orgDlg = false">取消</el-button>
              <el-button type="primary" :loading="orgBusy" @click="addMember">录入</el-button>
            </template>
          </el-dialog>

          <!-- 部门 新增/编辑 -->
          <el-dialog v-model="deptDlg" :title="deptForm.id ? '编辑部门' : '新增部门'" width="440px">
            <el-form label-width="80px">
              <el-form-item label="部门名称">
                <el-input v-model="deptForm.name" maxlength="30" placeholder="如：生产部 / 包装车间" />
              </el-form-item>
              <el-form-item label="上级部门">
                <el-select v-model="deptForm.parentId" clearable placeholder="不选 = 顶级部门" style="width:100%">
                  <el-option v-for="d in (orgData.depts || []).filter((x) => x.id !== deptForm.id)" :key="d.id" :label="d.name" :value="d.id" />
                </el-select>
              </el-form-item>
              <el-form-item label="排序">
                <el-input-number v-model="deptForm.sort" :min="0" :max="999" />
              </el-form-item>
            </el-form>
            <template #footer>
              <el-button @click="deptDlg = false">取消</el-button>
              <el-button type="primary" :loading="orgBusy" @click="saveDept">保存</el-button>
            </template>
          </el-dialog>

          <!-- 岗位 新增/编辑 -->
          <el-dialog v-model="posDlg" :title="posForm.id ? '编辑岗位' : '新增岗位'" width="440px">
            <el-form label-width="80px">
              <el-form-item label="岗位名称">
                <el-input v-model="posForm.name" maxlength="30" placeholder="如：包装工 / 质检员 / 组长" />
              </el-form-item>
              <el-form-item label="所属部门">
                <el-select v-model="posForm.deptId" clearable placeholder="不选 = 全厂通用岗位" style="width:100%">
                  <el-option v-for="d in orgData.depts || []" :key="d.id" :label="d.name" :value="d.id" />
                </el-select>
              </el-form-item>
              <el-form-item label="排序">
                <el-input-number v-model="posForm.sort" :min="0" :max="999" />
              </el-form-item>
            </el-form>
            <template #footer>
              <el-button @click="posDlg = false">取消</el-button>
              <el-button type="primary" :loading="orgBusy" @click="savePos">保存</el-button>
            </template>
          </el-dialog>

          <!-- 编辑员工 -->
          <el-dialog v-model="memberDlg" :title="`编辑员工：${memberForm.username || ''}`" width="440px">
            <el-form label-width="80px">
              <el-form-item label="昵称">
                <el-input v-model="memberForm.nickname" maxlength="24" />
              </el-form-item>
              <el-form-item label="部门">
                <el-select v-model="memberForm.deptId" clearable placeholder="未分配" style="width:100%">
                  <el-option v-for="d in orgData.depts || []" :key="d.id" :label="d.name" :value="d.id" />
                </el-select>
              </el-form-item>
              <el-form-item label="岗位">
                <el-select v-model="memberForm.positionId" clearable placeholder="未分配" style="width:100%">
                  <el-option v-for="p in orgData.positions || []" :key="p.id" :label="p.name" :value="p.id" />
                </el-select>
              </el-form-item>
            </el-form>
            <template #footer>
              <el-button @click="memberDlg = false">取消</el-button>
              <el-button type="primary" :loading="orgBusy" @click="saveMember">保存</el-button>
            </template>
          </el-dialog>

          <!-- 批量导入 -->
          <el-dialog v-model="orgImportDlg" title="批量导入员工" width="680px" top="6vh">
            <el-alert type="info" :closable="false" style="margin-bottom:12px">
              <template #title>
                在 Excel 里按「工号、姓名、部门、岗位」四列排好 → 选中区域复制 → 直接粘贴到下面（也支持 CSV 文本）。
                部门 / 岗位不存在会自动创建；工号重复或已录入的行自动跳过。
              </template>
            </el-alert>
            <el-input
              v-model="importText" type="textarea" :rows="9"
              placeholder="emp010	王十	生产部	包装工&#10;emp011	王十一	生产部	包装工&#10;emp012	赵十二	销售部	业务员"
              style="font-family:monospace" />
            <div style="margin-top:8px;display:flex;gap:10px;align-items:center">
              <input type="file" accept=".csv,.txt,.tsv" @change="onImportFile"
                style="font-size:12px" />
              <span style="font-size:12px;color:#909399">
                解析出 {{ importRows.length }} 行有效数据（列不够按「工号、姓名」处理）
              </span>
            </div>
            <el-table v-if="importRows.length" :data="importRows.slice(0, 8)" border size="small" style="margin-top:10px">
              <el-table-column prop="employeeNo" label="工号" width="130" />
              <el-table-column prop="nickname" label="姓名" width="130" />
              <el-table-column prop="dept" label="部门" />
              <el-table-column prop="position" label="岗位" />
              <el-table-column label="校验" width="150">
                <template #default="{ row }">
                  <span v-if="row._bad" style="color:#f56c6c">{{ row._bad }}</span>
                  <span v-else style="color:#67c23a">✓</span>
                </template>
              </el-table-column>
            </el-table>
            <div v-if="importRows.length > 8" style="font-size:12px;color:#909399;margin-top:4px">
              仅预览前 8 行，共 {{ importRows.length }} 行
            </div>
            <template #footer>
              <el-button @click="orgImportDlg = false">取消</el-button>
              <el-button type="primary" :loading="orgBusy" :disabled="!importRows.length" @click="doImport">
                导入 {{ importRows.length }} 行
              </el-button>
            </template>
          </el-dialog>

          <!-- 导入结果 -->
          <el-dialog v-model="importResultDlg" title="导入结果" width="560px">
            <el-result v-if="importResult"
              :icon="(importResult.created || importResult.adopted?.length) ? 'success' : 'warning'"
              :title="importResult.message">
              <template #sub-title>
                <div style="text-align:left;font-size:13px">
                  <div v-if="importResult.adopted?.length">
                    老账号归队 {{ importResult.adopted.length }} 人（沿用原密码）：
                    {{ importResult.adopted.slice(0, 10).join('、') }}{{ importResult.adopted.length > 10 ? ' 等' : '' }}
                  </div>
                  <div v-if="importResult.newDepts?.length">自动创建部门：{{ importResult.newDepts.join('、') }}</div>
                  <div v-if="importResult.newPositions?.length">自动创建岗位：{{ importResult.newPositions.join('、') }}</div>
                  <div v-if="importResult.skipped?.length" style="margin-top:8px">
                    <b>跳过 {{ importResult.skipped.length }} 行：</b>
                    <div v-for="s in importResult.skipped.slice(0, 20)" :key="s.employeeNo" style="color:#e6a23c">
                      {{ s.employeeNo || '（空工号）' }} —— {{ s.reason }}
                    </div>
                  </div>
                </div>
              </template>
            </el-result>
            <template #footer>
              <el-button type="primary" @click="importResultDlg = false">好的</el-button>
            </template>
          </el-dialog>
        </div>

        <!-- 考勤管理（工作模式下随工作模式一起启用） -->
        <div v-else-if="tab === 'attendance'">
          <el-alert v-if="compSetting.mode !== 'work'" type="warning" :closable="false" style="margin-bottom:14px">
            <template #title>
              当前是普通好友模式，考勤未启用。考勤随<b>工作模式</b>一起启用：请到「系统设置」把好友模式切换为工作模式。
            </template>
          </el-alert>
          <el-alert v-else-if="!orgData.org" type="warning" :closable="false" style="margin-bottom:14px">
            <template #title>
              还没有组织机构：考勤的对象是组织员工。请先到「组织机构」创建组织并录入员工。
            </template>
          </el-alert>

          <el-card>
            <template #header>
              <div class="card-hdr">
                <span>考勤管理{{ orgData.org ? ' · ' + orgData.org.name : '' }}</span>
                <div style="display:flex;align-items:center;gap:6px">
                  <el-tag :type="attConfig.enabled ? 'success' : 'info'" size="small" effect="plain">
                    {{ attConfig.enabled ? '考勤已启用' : '考勤已停用' }}
                  </el-tag>
                  <el-tooltip content="打卡时间一律以服务器时钟为准。若员工打的卡时间不对，先核对这里" placement="bottom">
                    <el-tag size="small" effect="plain" type="warning">
                      服务器时间 {{ attFmtTs(attConfig.serverTime) }}
                    </el-tag>
                  </el-tooltip>
                  <el-button size="small" @click="loadAttendance">刷新</el-button>
                </div>
              </div>
            </template>

            <el-tabs v-model="attTab" @tab-change="loadAttTab">
              <!-- ======== 打卡看板 ======== -->
              <el-tab-pane label="打卡看板" name="today">
                <div style="margin-bottom:12px;display:flex;align-items:center;gap:10px;flex-wrap:wrap">
                  <el-date-picker v-model="attDay" type="date" value-format="YYYY-MM-DD" :clearable="false"
                                  style="width:150px" @change="loadAttOverview" />
                  <el-tag v-if="attOverview.isWorkday === false" type="info" size="small" effect="plain">所选日期是休息日</el-tag>
                  <span class="hint">没打卡的人也在表里 —— 管理者真正要看的恰恰是"谁没来"。</span>
                </div>
                <el-row :gutter="10" style="margin-bottom:14px">
                  <el-col :span="3" v-for="c in attOvCards" :key="c.k">
                    <el-card shadow="never" class="stat">
                      <div class="stat-num">{{ attOverview.stats ? (attOverview.stats[c.k] ?? 0) : '—' }}</div>
                      <div class="stat-label">{{ c.label }}</div>
                    </el-card>
                  </el-col>
                </el-row>
                <el-table :data="attOverview.items || []" border stripe size="small" max-height="560">
                  <el-table-column label="工号" width="95">
                    <template #default="{ row }">{{ row.employeeNo || '—' }}</template>
                  </el-table-column>
                  <el-table-column prop="nickname" label="姓名" min-width="95" />
                  <el-table-column label="部门" min-width="105">
                    <template #default="{ row }">{{ row.deptName || '—' }}</template>
                  </el-table-column>
                  <el-table-column label="班次" min-width="200">
                    <template #default="{ row }">
                      {{ row.shiftName || '默认班次' }}
                      <span v-if="row.shift" class="hint">
                        （{{ row.shift.workStart }}-{{ row.shift.workEnd }}<template
                          v-if="row.shift.restStart">，休息 {{ row.shift.restStart }}-{{ row.shift.restEnd }}</template>）
                      </span>
                      <el-tag v-if="(row.shift?.punchesPerDay || 0) >= 4" size="small" effect="plain" type="success">4次卡</el-tag>
                    </template>
                  </el-table-column>
                  <!-- 逐张卡展示：4 次卡的卡名都叫"上班/下班"，靠应打时刻才看得出缺的是哪一段；
                       只给最早的上班和最晚的下班是看不出来的 -->
                  <el-table-column label="今日打卡" min-width="252">
                    <template #default="{ row }">
                      <template v-if="(row.punches || []).length">
                        <el-tag v-for="p in row.punches" :key="p.key" size="small" effect="plain"
                                :type="attPunchTagType(p)" style="margin:1px 3px 1px 0">
                          {{ p.label }} {{ attPunchText(p) }}
                        </el-tag>
                        <span class="hint" style="margin-left:4px">{{ attPunchCount(row) }} 张</span>
                      </template>
                      <span v-else>—</span>
                    </template>
                  </el-table-column>
                  <el-table-column label="在岗" width="82" align="center">
                    <template #default="{ row }">
                      <span :class="{ 'att-bad': (row.workedMinutes || 0) > 0 && row.workedMinutes < (row.expectedWorkMinutes || 0) }">
                        {{ attHours(row.workedMinutes) }}
                      </span>
                      <span v-if="row.expectedWorkMinutes" class="hint">/{{ attHours(row.expectedWorkMinutes) }}</span>
                    </template>
                  </el-table-column>
                  <el-table-column label="状态" width="92">
                    <template #default="{ row }">
                      <el-tag size="small" :type="attStatusType(row.status)" effect="plain">{{ row.statusLabel }}</el-tag>
                    </template>
                  </el-table-column>
                  <el-table-column prop="note" label="说明" min-width="130" />
                  <el-table-column label="打卡地点" min-width="140">
                    <template #default="{ row }">{{ row.address || '—' }}</template>
                  </el-table-column>
                  <el-table-column label="定位校验" width="118" align="center">
                    <template #default="{ row }">
                      <template v-if="row.locAnomaly">
                        <el-tag size="small" type="danger" effect="dark">{{ attLocStatusLabel(row.locStatus) }}</el-tag>
                      </template>
                      <template v-else-if="row.locStatus === 'ok'">
                        <el-tag size="small" type="success" effect="plain">围栏内</el-tag>
                      </template>
                      <span v-else class="hint">—</span>
                    </template>
                  </el-table-column>
                  <el-table-column label="操作" width="132" fixed="right">
                    <template #default="{ row }">
                      <el-button size="small" @click="openAttRecordDlg(row)">补卡</el-button>
                      <el-button size="small" @click="openAttDetail(row)">明细</el-button>
                    </template>
                  </el-table-column>
                </el-table>
              </el-tab-pane>

              <!-- ======== 统计报表 ======== -->
              <el-tab-pane label="统计报表" name="report">
                <div style="margin-bottom:12px;display:flex;gap:8px;align-items:center;flex-wrap:wrap">
                  <el-date-picker v-model="attRange" type="daterange" value-format="YYYY-MM-DD" :clearable="false"
                                  start-placeholder="开始日期" end-placeholder="结束日期"
                                  style="width:250px" @change="loadAttReport" />
                  <el-select v-model="attDeptId" placeholder="全部部门" clearable style="width:170px" @change="loadAttReport">
                    <el-option v-for="d in orgData.depts || []" :key="d.id" :label="d.name" :value="d.id" />
                  </el-select>
                  <el-button size="small" @click="loadAttReport">查询</el-button>
                  <span class="hint">选部门会连子部门一起算；点行首箭头展开可看每天明细。</span>
                </div>
                <el-row :gutter="10" style="margin-bottom:14px">
                  <el-col :span="3" v-for="c in attRepCards" :key="c.k">
                    <el-card shadow="never" class="stat">
                      <div class="stat-num">{{ attCardVal(attReport.totals, c) }}</div>
                      <div class="stat-label">{{ c.label }}</div>
                    </el-card>
                  </el-col>
                </el-row>
                <el-table :data="attReport.users || []" border stripe size="small" row-key="userId">
                  <el-table-column type="expand">
                    <template #default="{ row }">
                      <div style="padding:8px 14px 14px">
                        <div class="hint" style="margin-bottom:6px">
                          班次：{{ row.shiftName }}（{{ row.shift.workStart }}-{{ row.shift.workEnd }}<template
                            v-if="row.shift.restStart">，休息 {{ row.shift.restStart }}-{{ row.shift.restEnd }}</template>）·
                          一天 {{ row.shift.punchesPerDay || 2 }} 次卡 ·
                          来源：{{ row.shiftSource === 'group' ? '考勤组点名' : (row.shiftSource === 'dept' ? '考勤组（部门）' : '组织默认班次') }}
                          {{ row.groupName ? '· 考勤组「' + row.groupName + '」' : '' }}
                        </div>
                        <el-table :data="row.days" border size="small" max-height="320">
                          <el-table-column prop="day" label="日期" width="110" />
                          <el-table-column label="星期" width="70">
                            <template #default="{ row: d }">{{ attWeekName(d.weekday) }}</template>
                          </el-table-column>
                          <!-- 4 次卡与 2 次卡共用这一列：几张卡就渲染几个标签 -->
                          <el-table-column label="打卡明细" min-width="268">
                            <template #default="{ row: d }">
                              <template v-if="(d.punches || []).length">
                                <el-tag v-for="p in d.punches" :key="p.key" size="small" effect="plain"
                                        :type="attPunchTagType(p)" style="margin:1px 3px 1px 0">
                                  {{ p.label }} {{ attPunchText(p) }}
                                </el-tag>
                              </template>
                              <span v-else>—</span>
                            </template>
                          </el-table-column>
                          <el-table-column label="在岗" width="76" align="center">
                            <template #default="{ row: d }">
                              <span :class="{ 'att-bad': (d.workedMinutes || 0) < (d.expectedWorkMinutes || 0) }">
                                {{ attHours(d.workedMinutes) }}
                              </span>
                            </template>
                          </el-table-column>
                          <el-table-column label="状态" width="95">
                            <template #default="{ row: d }">
                              <el-tag size="small" :type="attStatusType(d.status)" effect="plain">{{ d.statusLabel }}</el-tag>
                            </template>
                          </el-table-column>
                          <el-table-column prop="note" label="说明" min-width="180" />
                        </el-table>
                      </div>
                    </template>
                  </el-table-column>
                  <el-table-column prop="nickname" label="姓名" min-width="95" />
                  <el-table-column label="工号" width="88">
                    <template #default="{ row }">{{ row.employeeNo || '—' }}</template>
                  </el-table-column>
                  <el-table-column label="部门" min-width="100">
                    <template #default="{ row }">{{ row.deptName || '—' }}</template>
                  </el-table-column>
                  <el-table-column label="应出勤" width="78" align="center">
                    <template #default="{ row }">{{ row.summary.workdays }}</template>
                  </el-table-column>
                  <el-table-column label="出勤天" width="78" align="center">
                    <template #default="{ row }">{{ row.summary.present }}</template>
                  </el-table-column>
                  <el-table-column label="迟到" width="70" align="center">
                    <template #default="{ row }">
                      <span :class="{ 'att-bad': row.summary.late > 0 }">{{ row.summary.late }}</span>
                      <span v-if="row.summary.lateMinutes" class="hint">/{{ row.summary.lateMinutes }}分</span>
                    </template>
                  </el-table-column>
                  <el-table-column label="早退" width="70" align="center">
                    <template #default="{ row }">
                      <span :class="{ 'att-bad': row.summary.early > 0 }">{{ row.summary.early }}</span>
                    </template>
                  </el-table-column>
                  <!-- 4 次卡下"缺卡(天)"会掩盖问题：一天缺 3 张也只算 1 天，
                       所以按**张**统计漏打卡，与"在岗时长"一起才看得出谁没打满 -->
                  <el-table-column label="漏打卡" width="72" align="center">
                    <template #default="{ row }">
                      <span :class="{ 'att-bad': row.summary.missingPunches > 0 }"
                            :title="'缺卡' + row.summary.missing + ' 天 / 漏打 ' + row.summary.missingPunches + ' 张'">
                        {{ row.summary.missingPunches }}张
                      </span>
                    </template>
                  </el-table-column>
                  <el-table-column label="在岗/应出勤" width="112" align="center">
                    <template #default="{ row }">
                      <span :class="{ 'att-bad': row.summary.workedMinutes < row.summary.expectedWorkMinutes }">
                        {{ attHours(row.summary.workedMinutes) }}
                      </span>
                      <span class="hint">/{{ attHours(row.summary.expectedWorkMinutes) }}</span>
                    </template>
                  </el-table-column>
                  <el-table-column label="缺勤" width="66" align="center">
                    <template #default="{ row }"><span :class="{ 'att-bad': row.summary.absent > 0 }">{{ row.summary.absent }}</span></template>
                  </el-table-column>
                  <el-table-column label="请假" width="66" align="center">
                    <template #default="{ row }">{{ row.summary.leave }}</template>
                  </el-table-column>
                  <el-table-column label="加班" width="76" align="center">
                    <template #default="{ row }">
                      {{ Math.round(row.summary.overtimeMinutes / 6) / 10 }}h
                    </template>
                  </el-table-column>
                </el-table>
              </el-tab-pane>

              <!-- ======== 班次与考勤组 ======== -->
              <el-tab-pane label="班次与考勤组" name="shift">
                <div class="card-hdr" style="margin-bottom:8px">
                  <span><b>班次</b> —— 几点上下班、弹性与宽限</span>
                  <el-button size="small" type="primary" @click="openShiftDlg()">新增班次</el-button>
                </div>
                <div class="hint" style="margin-bottom:10px">
                  不建班次也能用：没被任何考勤组纳入的员工按「组织默认班次」
                  （{{ attConfig.defaultShift ? attConfig.defaultShift.workStart + '-' + attConfig.defaultShift.workEnd : '08:00-17:00' }}<template
                    v-if="attConfig.defaultShift && attConfig.defaultShift.restStart">，休息 {{ attConfig.defaultShift.restStart }}-{{ attConfig.defaultShift.restEnd }}</template>）打卡。
                  班次是精细化，不是使用前提。<br />
                  <b>休息开始 / 结束都填上 = 一天 4 次卡</b>（上班 → 下班 → 上班 → 下班，
                  两个在岗段各算各的）；两个都空 = 传统的一天 2 次卡。只填一个会被拒绝。
                </div>
                <el-table :data="attShifts" border stripe size="small" style="margin-bottom:22px">
                  <el-table-column prop="name" label="班次名称" min-width="120" />
                  <el-table-column label="上下班" width="130">
                    <template #default="{ row }">{{ row.workStart }} - {{ row.workEnd }}</template>
                  </el-table-column>
                  <el-table-column label="跨天" width="70">
                    <template #default="{ row }">
                      <el-tag v-if="row.crossDay" size="small" type="warning" effect="plain">夜班</el-tag>
                      <span v-else>—</span>
                    </template>
                  </el-table-column>
                  <el-table-column label="一天几次卡" width="98" align="center">
                    <template #default="{ row }">
                      <el-tag size="small" effect="plain" :type="row.punchesPerDay >= 4 ? 'success' : 'info'">
                        {{ row.punchesPerDay || 2 }} 次
                      </el-tag>
                    </template>
                  </el-table-column>
                  <el-table-column label="休息" width="128">
                    <template #default="{ row }">
                      <span v-if="row.restStart">{{ row.restStart }} - {{ row.restEnd }}</span>
                      <span v-else class="hint">未设置</span>
                    </template>
                  </el-table-column>
                  <el-table-column label="在岗时长" width="88" align="center">
                    <template #default="{ row }">{{ attHours(row.expectedWorkMinutes) }}</template>
                  </el-table-column>
                  <el-table-column label="弹性打卡" width="88">
                    <template #default="{ row }">{{ row.flexMinutes }} 分</template>
                  </el-table-column>
                  <el-table-column label="迟到宽限" width="88">
                    <template #default="{ row }">{{ row.lateGrace }} 分</template>
                  </el-table-column>
                  <el-table-column label="可提前打卡" width="98">
                    <template #default="{ row }">{{ row.earlyGrace }} 分</template>
                  </el-table-column>
                  <el-table-column label="操作" width="140">
                    <template #default="{ row }">
                      <el-button size="small" type="primary" plain @click="openShiftDlg(row)">编辑</el-button>
                      <el-button size="small" type="danger" @click="removeShift(row)">删除</el-button>
                    </template>
                  </el-table-column>
                </el-table>

                <div class="card-hdr" style="margin-bottom:8px">
                  <span><b>考勤组</b> —— 不同人群用不同班次</span>
                  <el-button size="small" type="primary" @click="openGroupDlg()">新增考勤组</el-button>
                </div>
                <div class="hint" style="margin-bottom:10px">
                  成员可以按<b>部门</b>纳入（含子部门，新员工自动进组，人事少做一件事），也可以<b>点名到人</b>；同一人同时命中多个组时，点名优先，其次按创建顺序取第一个。
                </div>
                <el-table :data="attGroups" border stripe size="small">
                  <el-table-column prop="name" label="考勤组" min-width="130" />
                  <el-table-column label="班次" width="130">
                    <template #default="{ row }">
                      {{ row.shiftName }}
                      <span v-if="row.shift" class="hint">（{{ row.shift.workStart }}-{{ row.shift.workEnd }}）</span>
                    </template>
                  </el-table-column>
                  <el-table-column label="定位要求" min-width="150">
                    <template #default="{ row }">
                      {{ attLocLabel(row.locationMode) }}
                      <div v-if="row.locationIds && row.locationIds.length" class="hint">
                        围栏：{{ row.locationIds.map((id) => attLocName(id)).join('、') }}
                      </div>
                    </template>
                  </el-table-column>
                  <el-table-column label="纳入部门" min-width="150">
                    <template #default="{ row }">
                      <template v-if="row.deptIds && row.deptIds.length">
                        <el-tag v-for="d in row.deptIds" :key="d" size="small" effect="plain" style="margin-right:4px">
                          {{ deptName(d) }}
                        </el-tag>
                      </template>
                      <span v-else class="hint">—</span>
                    </template>
                  </el-table-column>
                  <el-table-column label="人数" width="76" align="center">
                    <template #default="{ row }">{{ row.memberCount }}</template>
                  </el-table-column>
                  <el-table-column label="操作" width="140">
                    <template #default="{ row }">
                      <el-button size="small" type="primary" plain @click="openGroupDlg(row)">编辑</el-button>
                      <el-button size="small" type="danger" @click="removeGroup(row)">删除</el-button>
                    </template>
                  </el-table-column>
                </el-table>
              </el-tab-pane>

              <!-- ======== 申请审批 ======== -->
              <el-tab-pane :label="`申请审批（${attReqCounts.pending || 0}）`" name="review">
                <div style="margin-bottom:12px;display:flex;gap:10px;align-items:center;flex-wrap:wrap">
                  <el-radio-group v-model="attReqStatus" size="small" @change="loadAttRequests">
                    <el-radio-button label="pending">待审批</el-radio-button>
                    <el-radio-button label="approved">已通过</el-radio-button>
                    <el-radio-button label="rejected">已驳回</el-radio-button>
                    <el-radio-button label="all">全部</el-radio-button>
                  </el-radio-group>
                  <el-select v-model="attReqKind" clearable placeholder="全部类型" size="small"
                             style="width:130px" @change="loadAttRequests">
                    <el-option label="请假" value="leave" />
                    <el-option label="补卡" value="makeup" />
                    <el-option label="外出" value="outing" />
                    <el-option label="加班" value="overtime" />
                  </el-select>
                  <span class="hint">补卡通过后立即写入考勤记录；请假/外出通过后当天不再判缺勤。</span>
                </div>
                <el-table :data="attRequests" border stripe size="small">
                  <el-table-column prop="nickname" label="申请人" min-width="95" />
                  <el-table-column label="工号" width="90">
                    <template #default="{ row }">{{ row.employeeNo || '—' }}</template>
                  </el-table-column>
                  <el-table-column label="类型" width="76">
                    <template #default="{ row }">
                      <el-tag size="small" effect="plain">{{ row.kindLabel }}</el-tag>
                    </template>
                  </el-table-column>
                  <el-table-column prop="desc" label="内容" min-width="200" />
                  <el-table-column prop="reason" label="事由" min-width="140" />
                  <el-table-column label="提交时间" width="150">
                    <template #default="{ row }">{{ attFmtTs(row.createdAt) }}</template>
                  </el-table-column>
                  <el-table-column label="状态" width="86">
                    <template #default="{ row }">
                      <el-tag size="small" :type="row.status === 'approved' ? 'success' : (row.status === 'rejected' ? 'danger' : (row.status === 'pending' ? 'warning' : 'info'))" effect="plain">
                        {{ row.statusLabel }}
                      </el-tag>
                    </template>
                  </el-table-column>
                  <el-table-column label="审批意见" min-width="120">
                    <template #default="{ row }">{{ row.reviewNote || '—' }}</template>
                  </el-table-column>
                  <el-table-column label="操作" width="140" fixed="right">
                    <template #default="{ row }">
                      <template v-if="row.status === 'pending'">
                        <el-button size="small" type="success" @click="reviewAtt(row, true)">通过</el-button>
                        <el-button size="small" type="danger" @click="reviewAtt(row, false)">驳回</el-button>
                      </template>
                      <span v-else class="hint">已处理</span>
                    </template>
                  </el-table-column>
                </el-table>
              </el-tab-pane>

              <!-- ======== 考勤设置 ======== -->
              <el-tab-pane label="考勤设置" name="config">
                <el-form label-width="150px" style="max-width:700px">
                  <el-form-item label="启用考勤">
                    <el-switch v-model="attConfig.enabled" />
                    <el-tag size="small" :type="attConfig.enabled ? 'success' : 'info'" effect="plain" style="margin-left:10px">
                      {{ attConfig.enabled ? '员工端可见「考勤打卡」' : '员工端入口整体消失' }}
                    </el-tag>
                    <div class="hint">工作模式下默认开启。停用只是隐藏入口，历史打卡与申请记录都保留。</div>
                  </el-form-item>
                  <el-form-item label="默认班次 上班 / 下班">
                    <el-input v-model="attConfig.defaultShift.workStart" style="width:100px" placeholder="09:00" />
                    <span style="margin:0 8px">—</span>
                    <el-input v-model="attConfig.defaultShift.workEnd" style="width:100px" placeholder="18:00" />
                    <div class="hint">下班时间<b>早于或等于</b>上班时间即视为跨天夜班（如 22:00 - 06:00），下班卡会算到次日凌晨。</div>
                  </el-form-item>
                  <el-form-item label="默认班次 休息">
                    <el-input v-model="attConfig.defaultShift.restStart" style="width:100px" placeholder="12:00" />
                    <span style="margin:0 8px">—</span>
                    <el-input v-model="attConfig.defaultShift.restEnd" style="width:100px" placeholder="13:00" />
                    <el-button size="small" style="margin-left:10px"
                               @click="attConfig.defaultShift.restStart = ''; attConfig.defaultShift.restEnd = ''">
                      清空（改回 2 次卡）
                    </el-button>
                    <div class="hint">
                      两个都填 = <b>一天 4 次卡</b>：上班 → 下班 → 上班 → 下班，两个在岗段各算各的
                      （08:00-12:00 / 13:00-17:00 就是各 4 小时、合计 8 小时）；两个都空 = 传统 2 次卡；<b>只填一个会被拒绝</b>。<br />
                      休息时段必须严格落在上班与下班之间，且跨天夜班不支持休息（凌晨那顿休息跨了日期，算不清）。
                    </div>
                  </el-form-item>
                  <el-form-item label="弹性打卡 / 迟到宽限">
                    <el-input-number v-model="attConfig.defaultShift.flexMinutes" :min="0" :max="240" :step="5" />
                    <el-input-number v-model="attConfig.defaultShift.lateGrace" :min="0" :max="120" :step="5" style="margin-left:10px" />
                    <span class="hint" style="margin-left:8px">分钟。弹性 = 允许晚到多久仍不算缺勤；宽限 = 迟到判定的缓冲（前者影响"该不该来"，后者只影响"算不算迟到"）</span>
                  </el-form-item>
                  <el-form-item label="可提前打卡">
                    <el-input-number v-model="attConfig.defaultShift.earlyGrace" :min="0" :max="240" :step="5" />
                    <span class="hint" style="margin-left:8px">分钟：下班前这么多分钟内打卡不算早退（设 10 就是 17:50 打下班卡也正常）</span>
                  </el-form-item>
                  <el-form-item label="休息时长">
                    <!-- 填了休息时段后，在岗时长按时段算，这个数字就没用了。
                         让两个地方都能"设定休息多久"只会有一天对不上，所以直接禁掉 -->
                    <el-input-number v-model="attConfig.defaultShift.restMinutes" :min="0" :max="480" :step="15"
                                     :disabled="!!attConfig.defaultShift.restStart" />
                    <span class="hint" style="margin-left:8px">
                      {{ attConfig.defaultShift.restStart
                        ? '已按上面的休息时段计算在岗时长，这里不用管'
                        : '分钟，仅作展示，不参与迟到早退判定' }}
                    </span>
                  </el-form-item>
                  <el-form-item label="工作日">
                    <el-checkbox-group v-model="attConfig.workdays">
                      <el-checkbox v-for="d in attWeekLabels" :key="d.v" :label="d.v">{{ d.t }}</el-checkbox>
                    </el-checkbox-group>
                    <div class="hint">只有勾选的星期计「应出勤」；未勾选的日期不判缺勤（休息日来上班，让员工提交加班申请即可）。</div>
                  </el-form-item>
                  <el-form-item label="定位精度阈值">
                    <el-input-number v-model="attConfig.fenceAccuracyMax" :min="10" :max="2000" :step="10" />
                    <span class="hint" style="margin-left:8px">米（默认 200）</span>
                    <div class="hint">
                      手机打卡时会自报一个「定位精度」：<b>数字越大说明这次定位越糊</b>。
                      精度差于这个阈值的打卡，在定位要求为「必须提供」的考勤组里会被<b>直接拒绝</b>，
                      只做标记的组则照常记录、但在看板里标成「定位可疑」。<br />
                      <b>怎么调：</b>调小 = 更严（要求定位更准），但室内、高楼密集处常常拿不到那么准的 GPS，
                      会出现「人就在店里却打不上卡」；调大 = 更松，大到一定程度等于放弃这项防伪。
                      建议先用默认的 200 米跑几天，看看看板里「定位可疑」多不多再决定。
                    </div>
                  </el-form-item>
                  <el-form-item label="服务器时间 / 时区">
                    <el-tag size="small" effect="plain" type="warning">{{ attFmtTs(attConfig.serverTime) }}</el-tag>
                    <el-tag size="small" effect="plain" style="margin-left:8px">{{ attConfig.timezone }}</el-tag>
                    <div class="hint">打卡时刻一律按服务器时钟记录，客户端改本地时间无效。</div>
                  </el-form-item>
                  <el-form-item>
                    <el-button type="primary" :loading="attBusy" @click="saveAttConfig">保存设置</el-button>
                  </el-form-item>
                </el-form>
              </el-tab-pane>

              <!-- ======== 打卡点位（地理围栏） ======== -->
              <el-tab-pane label="打卡点位" name="locations">
                <div class="card-hdr" style="margin-bottom:8px">
                  <span><b>打卡点位</b> —— 组织统一维护，考勤组从中勾选可用子集</span>
                  <el-button size="small" type="primary" @click="openLocDlg()">新增点位</el-button>
                </div>
                <div class="hint" style="margin-bottom:10px">
                  打卡点位就是「允许在哪里打卡」的地理围栏：填好<b>经纬度</b>和<b>围栏半径（米）</b>，
                  对应考勤组把定位要求设为「必须提供」后，员工只有落在某个点位半径内才能打卡；
                  超出围栏、定位精度过低或检测到<b>模拟定位</b>都会被直接拒绝。点位只需建一次，多个考勤组共用。
                </div>
                <el-table :data="attLocations" border stripe size="small" empty-text="还没有打卡点位，点右上角「新增点位」">
                  <el-table-column prop="name" label="点位名称" min-width="140" />
                  <el-table-column label="纬度" width="120">
                    <template #default="{ row }">{{ Number(row.lat).toFixed(6) }}</template>
                  </el-table-column>
                  <el-table-column label="经度" width="120">
                    <template #default="{ row }">{{ Number(row.lng).toFixed(6) }}</template>
                  </el-table-column>
                  <el-table-column label="围栏半径" width="110" align="center">
                    <template #default="{ row }">{{ row.radius }} 米</template>
                  </el-table-column>
                  <el-table-column label="被引用" width="100" align="center">
                    <template #default="{ row }">{{ attGroupRefCount(row.id) }}</template>
                  </el-table-column>
                  <el-table-column label="操作" width="140">
                    <template #default="{ row }">
                      <el-button size="small" type="primary" plain @click="openLocDlg(row)">编辑</el-button>
                      <el-button size="small" type="danger" @click="removeLoc(row)">删除</el-button>
                    </template>
                  </el-table-column>
                </el-table>
              </el-tab-pane>

              <!-- ======== 智能薪酬（复刻钉钉） ======== -->
              <el-tab-pane label="智能薪酬" name="salary">
                <div class="hint" style="margin-bottom:10px">
                  按<b>考勤结果 + 这里的规则</b>算每个人每月的扣款与奖励：迟到分档扣、缺卡按次扣、
                  旷工按天扣日工资、请假按比例扣、全勤发奖、审批过的加班按时长算加班费。
                  日工资 = 月薪基数 ÷ 计薪天数。报表<b>每次现算</b>——改了打卡记录、审批了请假，
                  重新打开就是对的，没有"重算"按钮也没有旧快照。
                </div>

                <!-- 规则 -->
                <el-card shadow="never" style="margin-bottom:14px">
                  <template #header><b>扣款 / 奖励规则</b>
                    <el-tag v-if="salConfig.customized" size="small" type="success" style="margin-left:8px">已自定义</el-tag>
                    <el-tag v-else size="small" type="info" effect="plain" style="margin-left:8px">出厂默认</el-tag>
                  </template>
                  <el-form label-width="150px" size="small">
                    <el-form-item label="迟到扣款（分档）">
                      <div v-for="(t, i) in salConfig.lateTiers" :key="i" style="margin-bottom:4px">
                        ≤ <el-input-number v-model="t.upTo" :min="1" :max="1440" size="small" controls-position="right" style="width:100px" /> 分钟
                        扣 <el-input-number v-model="t.amount" :min="0" :max="100000" size="small" controls-position="right" style="width:110px" /> 元
                        <el-button size="small" text type="danger" @click="salConfig.lateTiers.splice(i, 1)"
                                   :disabled="salConfig.lateTiers.length <= 1">删</el-button>
                      </div>
                      <div>
                        <el-button size="small" @click="salConfig.lateTiers.push({ upTo: (salConfig.lateTiers.at(-1)?.upTo || 0) + 30, amount: 50 })"
                                   :disabled="salConfig.lateTiers.length >= 4">加一档</el-button>
                        <span class="hint" style="margin-left:8px">
                          超出最后一档的部分按下面"每分钟"单价算；档位分钟数必须逐档递增。
                        </span>
                      </div>
                    </el-form-item>
                    <el-form-item label="超出档每分钟扣">
                      <el-input-number v-model="salConfig.latePerMinute" :min="0" :max="1000" :step="0.5" />
                      <span class="hint" style="margin-left:8px">元 / 分钟（迟到超过最后一档时按分钟计）</span>
                    </el-form-item>
                    <el-form-item label="缺卡每次扣">
                      <el-input-number v-model="salConfig.missingCardDeduct" :min="0" :max="100000" />
                      <span class="hint" style="margin-left:8px">元（旷工的天<b>不重复</b>扣缺卡）</span>
                    </el-form-item>
                    <el-form-item label="旷工扣款比例">
                      <el-input-number v-model="salConfig.absentDayDeductPct" :min="0" :max="300" />
                      <span class="hint" style="margin-left:8px">% 日工资 / 天</span>
                    </el-form-item>
                    <el-form-item label="请假扣款比例">
                      <el-input-number v-model="salConfig.leaveDeductPct" :min="0" :max="300" />
                      <span class="hint" style="margin-left:8px">% 日工资 / 天（半天按 0.5 天）</span>
                    </el-form-item>
                    <el-form-item label="全勤奖">
                      <el-input-number v-model="salConfig.fullAttendanceBonus" :min="0" :max="100000" />
                      <span class="hint" style="margin-left:8px">元（当月无迟到/早退/缺卡/旷工/请假才发）</span>
                    </el-form-item>
                    <el-form-item label="加班费时薪">
                      <el-input-number v-model="salConfig.overtimePerHour" :min="0" :max="100000" />
                      <span class="hint" style="margin-left:8px">
                        元 / 小时（0 = 不计加班费）。时长只认<b>审批通过的加班申请</b>，休息日来打卡不算。
                      </span>
                    </el-form-item>
                    <el-form-item label="计薪天数">
                      <el-input-number v-model="salConfig.dayDivisor" :min="1" :max="31" :step="0.01" />
                      <span class="hint" style="margin-left:8px">天 / 月（法定口径 21.75）</span>
                    </el-form-item>
                    <el-form-item>
                      <el-button type="primary" :loading="salBusy" @click="saveSalConfig">保存规则并重算</el-button>
                    </el-form-item>
                  </el-form>
                </el-card>

                <!-- 基数 -->
                <el-card shadow="never" style="margin-bottom:14px">
                  <template #header><b>员工月薪基数</b>
                    <el-button size="small" type="primary" :loading="salBusy" style="float:right" @click="saveSalBases">保存基数</el-button>
                  </template>
                  <el-table :data="salBases" border stripe size="small" max-height="320"
                            empty-text="还没有员工 —— 先在「组织机构」里录员工">
                    <el-table-column prop="username" label="工号" width="120" />
                    <el-table-column prop="nickname" label="姓名" min-width="120" />
                    <el-table-column label="月薪基数（元）" width="220">
                      <template #default="{ row }">
                        <el-input-number v-model="row.monthBase" :min="0" :max="10000000" :step="100"
                                         controls-position="right" style="width:180px" />
                      </template>
                    </el-table-column>
                    <el-table-column :label="'日工资（按 ' + salConfig.dayDivisor + ' 天）'" min-width="140">
                      <template #default="{ row }">{{ ((Number(row.monthBase) || 0) / (salConfig.dayDivisor || 21.75)).toFixed(2) }} 元</template>
                    </el-table-column>
                  </el-table>
                </el-card>

                <!-- 报表 -->
                <el-card shadow="never">
                  <template #header>
                    <b>月度工资表</b>
                    <el-date-picker v-model="salMonth" type="month" value-format="YYYY-MM" :clearable="false"
                                    style="width:130px;margin:0 10px" @change="loadSalReport" />
                    <el-tag size="small" type="warning" effect="plain">全员应发合计：¥{{ salReport.totalNet }}</el-tag>
                    <el-button size="small" style="float:right" @click="exportSalCsv">导出 CSV</el-button>
                  </template>
                  <el-table :data="salReport.items" border stripe size="small" max-height="420"
                            empty-text="这个月还没有数据">
                    <el-table-column prop="username" label="工号" width="100" />
                    <el-table-column prop="nickname" label="姓名" width="100" />
                    <el-table-column prop="base" label="基数" width="90" align="right" />
                    <el-table-column label="考勤概况" min-width="230">
                      <template #default="{ row }">
                        迟到 {{ row.stats.lateCount }} 次({{ row.stats.lateMinutes }}分) ·
                        缺卡 {{ row.stats.missingCount }} ·
                        旷工 {{ row.stats.absentDays }} 天 ·
                        请假 {{ row.stats.leaveDays }} 天
                        <template v-if="row.stats.overtimeMinutes > 0"> · 加班 {{ row.stats.overtimeMinutes }} 分</template>
                      </template>
                    </el-table-column>
                    <el-table-column label="明细" min-width="300">
                      <template #default="{ row }">
                        <div v-for="x in row.items" :key="x.key" :style="{ color: x.amount < 0 ? '#c0392b' : '#1e8e3e' }">
                          {{ x.label }} {{ x.amount >= 0 ? '+' : '' }}{{ x.amount }}
                          <span class="hint">{{ x.note }}</span>
                        </div>
                        <span v-if="!row.items.length" class="hint">没配基数，也无法判定（无出勤记录）</span>
                      </template>
                    </el-table-column>
                    <el-table-column prop="deductions" label="扣款合计" width="100" align="right" />
                    <el-table-column prop="bonus" label="奖励合计" width="100" align="right" />
                    <el-table-column label="应发" width="110" align="right">
                      <template #default="{ row }"><b>¥{{ row.net }}</b></template>
                    </el-table-column>
                  </el-table>
                </el-card>
              </el-tab-pane>
            </el-tabs>
          </el-card>

          <!-- 班次编辑 -->
          <el-dialog v-model="attShiftDlg" :title="attShiftForm.id ? '编辑班次' : '新增班次'" width="520px">
            <el-form label-width="120px">
              <el-form-item label="班次名称">
                <el-input v-model="attShiftForm.name" maxlength="20" placeholder="如：白班 / 夜班 / 早班" />
              </el-form-item>
              <el-form-item label="上班 / 下班">
                <el-input v-model="attShiftForm.workStart" style="width:100px" placeholder="09:00" />
                <span style="margin:0 8px">—</span>
                <el-input v-model="attShiftForm.workEnd" style="width:100px" placeholder="18:00" />
              </el-form-item>
              <el-form-item label="休息开始 / 结束">
                <el-input v-model="attShiftForm.restStart" style="width:100px" placeholder="12:00" />
                <span style="margin:0 8px">—</span>
                <el-input v-model="attShiftForm.restEnd" style="width:100px" placeholder="13:00" />
                <div class="hint">
                  两个都填 = 这个班次一天打 <b>4 次</b>卡（上班 / 下班 / 上班 / 下班，四张卡按应打时刻区分）；
                  两个都空 = 一天 2 次卡。必须落在上班与下班之间，跨天夜班不支持。
                </div>
              </el-form-item>
              <el-form-item label="休息时长">
                <el-input-number v-model="attShiftForm.restMinutes" :min="0" :max="480" :step="15"
                                 :disabled="!!attShiftForm.restStart" />
                <span class="hint" style="margin-left:8px">
                  {{ attShiftForm.restStart ? '已由休息时段决定' : '分钟（仅作展示）' }}
                </span>
              </el-form-item>
              <el-form-item label="弹性打卡">
                <el-input-number v-model="attShiftForm.flexMinutes" :min="0" :max="240" :step="5" />
                <span class="hint" style="margin-left:8px">分钟</span>
              </el-form-item>
              <el-form-item label="迟到宽限">
                <el-input-number v-model="attShiftForm.lateGrace" :min="0" :max="120" :step="5" />
                <span class="hint" style="margin-left:8px">分钟</span>
              </el-form-item>
              <el-form-item label="可提前打卡">
                <el-input-number v-model="attShiftForm.earlyGrace" :min="0" :max="240" :step="5" />
                <span class="hint" style="margin-left:8px">分钟</span>
              </el-form-item>
            </el-form>
            <template #footer>
              <el-button @click="attShiftDlg = false">取消</el-button>
              <el-button type="primary" :loading="attBusy" @click="saveShift">保存</el-button>
            </template>
          </el-dialog>

          <!-- 考勤组编辑 -->
          <el-dialog v-model="attGroupDlg" :title="attGroupForm.id ? '编辑考勤组' : '新增考勤组'" width="620px">
            <el-form label-width="110px">
              <el-form-item label="考勤组名称">
                <el-input v-model="attGroupForm.name" maxlength="20" placeholder="如：生产部白班" />
              </el-form-item>
              <el-form-item label="使用班次">
                <el-select v-model="attGroupForm.shiftId" clearable placeholder="不选 = 组织默认班次" style="width:100%">
                  <el-option v-for="s in attShifts" :key="s.id" :label="`${s.name}（${s.workStart}-${s.workEnd}）`" :value="s.id" />
                </el-select>
              </el-form-item>
              <el-form-item label="定位要求">
                <el-radio-group v-model="attGroupForm.locationMode">
                  <el-radio label="off">不校验</el-radio>
                  <el-radio label="optional">有就记录</el-radio>
                  <el-radio label="required">必须提供（围栏）</el-radio>
                </el-radio-group>
                <div class="hint">「必须提供」= 员工打卡必须带定位且命中围栏，否则直接拒绝（挡代打卡/虚拟定位）；「有就记录」= 不拒绝，但异常定位会标红进报表。</div>
              </el-form-item>
              <el-form-item v-if="attGroupForm.locationMode !== 'off'" label="允许打卡点位">
                <el-select v-model="attGroupForm.locationIds" multiple clearable placeholder="勾选本组可用的打卡点位（不选 = 只校验有定位，不按距离拒）"
                           style="width:100%">
                  <el-option v-for="l in attLocations" :key="l.id" :label="`${l.name}（半径 ${l.radius} 米）`" :value="l.id" />
                </el-select>
                <div class="hint">勾选后，本组员工只有落在某个点位半径内才能打卡（地理围栏）。点位在「打卡点位」页统一维护。</div>
              </el-form-item>
              <el-form-item label="纳入部门">
                <el-select v-model="attGroupForm.deptIds" multiple clearable placeholder="选部门（含其子部门）"
                           style="width:100%">
                  <el-option v-for="d in orgData.depts || []" :key="d.id" :label="d.name" :value="d.id" />
                </el-select>
                <div class="hint">新员工入职即自动进组 —— 这是比"逐个点名"更省事的方式。</div>
              </el-form-item>
              <el-form-item label="点名成员">
                <el-select v-model="attGroupForm.memberIds" multiple clearable filterable placeholder="额外指定到人（优先级最高）"
                           style="width:100%">
                  <el-option v-for="m in orgData.members || []" :key="m.id" :value="m.id"
                             :label="`${m.nickname || m.username}${m.employee_no ? '（' + m.employee_no + '）' : ''}`" />
                </el-select>
              </el-form-item>
            </el-form>
            <template #footer>
              <el-button @click="attGroupDlg = false">取消</el-button>
              <el-button type="primary" :loading="attBusy" @click="saveAttGroup">保存</el-button>
            </template>
          </el-dialog>

          <!-- 打卡点位编辑 -->
          <el-dialog v-model="attLocDlg" :title="attLocForm.id ? '编辑打卡点位' : '新增打卡点位'" width="520px">
            <el-form label-width="110px">
              <el-form-item label="点位名称">
                <el-input v-model="attLocForm.name" maxlength="30" placeholder="如：门店总部 / 二号仓" />
              </el-form-item>
              <el-form-item label="纬度">
                <el-input v-model="attLocForm.lat" style="width:200px" placeholder="如：31.230416" />
                <div class="hint">WGS-84 十进制，手机 GPS 读数直接填（与员工端同一基准）。</div>
              </el-form-item>
              <el-form-item label="经度">
                <el-input v-model="attLocForm.lng" style="width:200px" placeholder="如：121.473701" />
              </el-form-item>
              <el-form-item label="围栏半径">
                <el-input-number v-model="attLocForm.radius" :min="10" :max="5000" :step="10" />
                <span class="hint" style="margin-left:8px">米：在此范围内打卡算"到位"。</span>
              </el-form-item>
            </el-form>
            <template #footer>
              <el-button @click="attLocDlg = false">取消</el-button>
              <el-button type="primary" :loading="attBusy" @click="saveLoc">保存</el-button>
            </template>
          </el-dialog>

          <!-- 管理员补卡 / 修正 -->
          <el-dialog v-model="attRecDlg" title="补卡 / 修正打卡" width="480px">
            <el-alert type="info" :closable="false" style="margin-bottom:12px">
              <template #title>
                以管理员身份直接写入打卡记录（来源标记为 admin，可追溯）。同一天同一张卡已有记录时会被覆盖。
              </template>
            </el-alert>
            <el-form label-width="90px">
              <el-form-item label="员工">
                <span>{{ attRecForm.nickname }}（{{ attRecForm.employeeNo || attRecForm.userId }}）</span>
              </el-form-item>
              <el-form-item label="日期">
                <el-date-picker v-model="attRecForm.day" type="date" value-format="YYYY-MM-DD" :clearable="false" style="width:160px" />
              </el-form-item>
              <el-form-item label="补哪张卡">
                <!-- 选项照该员工的打卡计划来：2 次卡两项、4 次卡四项。
                     必须带 slot —— 4 次卡里第 1 段结束与收工都是 out，
                     只填类型会把卡补到错误的段上（看着补了，报表上还是缺卡） -->
                <el-radio-group v-model="attRecForm.key" @change="onAttRecPick">
                  <el-radio v-for="p in (attRecForm.options || [])" :key="p.key" :label="p.key">
                    {{ p.expectTime ? p.label + ' ' + p.expectTime : p.label }}
                  </el-radio>
                </el-radio-group>
              </el-form-item>
              <el-form-item label="时间">
                <el-input v-model="attRecForm.time" style="width:110px" placeholder="HH:MM" />
                <span class="hint" style="margin-left:8px">如 08:55</span>
              </el-form-item>
            </el-form>
            <template #footer>
              <el-button @click="attRecDlg = false">取消</el-button>
              <el-button type="primary" :loading="attBusy" @click="saveAttRecord">保存</el-button>
            </template>
          </el-dialog>

          <!-- 打卡明细 -->
          <el-dialog v-model="attDetailDlg" :title="`打卡明细 · ${attDetail.nickname || ''} · ${attDetail.day}`" width="620px">
            <el-table :data="attDetail.items" border size="small">
              <el-table-column label="卡" width="104">
                <template #default="{ row }">
                  <el-tag size="small" :type="row.type === 'in' ? 'success' : 'info'" effect="plain">
                    {{ row.punchLabel || (row.type === 'in' ? '上班卡' : '下班卡') }}
                  </el-tag>
                </template>
              </el-table-column>
              <el-table-column prop="time" label="时刻" width="90" />
              <el-table-column label="来源" width="110">
                <template #default="{ row }">{{ attSourceLabel(row.source) }}</template>
              </el-table-column>
              <el-table-column prop="address" label="地点" min-width="140">
                <template #default="{ row }">{{ row.address || '—' }}</template>
              </el-table-column>
              <el-table-column prop="device" label="设备" min-width="120">
                <template #default="{ row }">{{ row.device || '—' }}</template>
              </el-table-column>
              <el-table-column label="操作" width="80">
                <template #default="{ row }">
                  <el-button size="small" type="danger" @click="deleteAttRecord(row)">删除</el-button>
                </template>
              </el-table-column>
            </el-table>
            <div class="hint" style="margin-top:8px">
              同一天同一类型可以有多条流水（员工"更新打卡"会保留历史），统计只取上班最早、下班最晚。
            </div>
          </el-dialog>
        </div>

        <div v-else-if="tab === 'upstreams'">
          <el-alert type="success" :closable="false" style="margin-bottom:14px">
            <template #title>
              把内网系统的数据<b>接到客户端里</b>。在这里登记一次地址，「动态模块」的列表 / 表格 / 图表
              就能取到真数据 —— 员工在小智里<b>点进去看</b>，不用把数字推到群里刷屏。
              客户端只提交一个<b>名字</b>，真实地址和凭据都在服务端，所以猜不到别的地址、也拿不到凭据。
            </template>
          </el-alert>

          <div class="page-bar">
            <el-button type="primary" @click="openUsDialog()">登记上游接口</el-button>
            <span class="hint">
              只允许 GET / POST；子路径跳不出填的地址（<code class="mono">..</code> /
              完整 URL / <code class="mono">//</code> 一律拒绝）。
            </span>
          </div>

          <!-- 列宽是**算出来的**，不是随手填的：这块表要能塞进 1366 宽的笔记本屏，
               否则最右边的「删除」会被挤到视口外，而表格看着"挺正常"，
               人只会以为这个功能没做。当前合计 ≈1315。 -->
          <el-table :data="us.list" border stripe>
            <el-table-column label="接口名 / 说明" width="145">
              <template #default="{ row }">
                <code class="mono">{{ row.name }}</code>
                <div v-if="row.label" class="hint">{{ row.label }}</div>
              </template>
            </el-table-column>
            <el-table-column label="上游地址" width="175">
              <template #default="{ row }">
                <span class="mono" :title="row.baseUrl">{{ row.baseUrl }}</span>
              </template>
            </el-table-column>
            <el-table-column label="客户端调用的路径" width="195">
              <template #default="{ row }">
                <code class="mono">{{ us.pathPrefix + row.name }}/…</code>
                <el-button size="small" text type="primary"
                  @click="copy(us.pathPrefix + row.name + '/')">复制</el-button>
              </template>
            </el-table-column>
            <el-table-column label="凭据" width="68">
              <template #default="{ row }">
                <el-tag size="small" :type="row.hasAuth ? 'success' : 'info'" effect="plain">
                  {{ row.hasAuth ? '已配置' : '无' }}
                </el-tag>
              </template>
            </el-table-column>
            <el-table-column label="超时" width="92">
              <template #default="{ row }">{{ row.timeoutMs }}ms</template>
            </el-table-column>
            <el-table-column label="允许的角色" width="108">
              <template #default="{ row }">
                <el-tag v-if="!row.allowRoles.length" size="small" effect="plain">全部登录用户</el-tag>
                <el-tag v-for="r in row.allowRoles" v-else :key="r" size="small" style="margin-right:3px">{{ r }}</el-tag>
              </template>
            </el-table-column>
            <el-table-column label="状态" width="68">
              <template #default="{ row }">
                <el-tag size="small" :type="row.enabled ? 'success' : 'danger'">
                  {{ row.enabled ? '启用' : '已停用' }}
                </el-tag>
              </template>
            </el-table-column>
            <el-table-column label="最后修改" width="115">
              <template #default="{ row }">
                <div>{{ fmtTime(row.updatedAt) }}</div>
                <div class="hint">{{ row.updatedBy }}</div>
              </template>
            </el-table-column>
            <el-table-column label="操作" width="340">
              <template #default="{ row }">
                <el-button size="small" :loading="usProbing === row.id" @click="probeUs(row)">探活</el-button>
                <el-button size="small" @click="openUsTest(row)">试跑</el-button>
                <el-button size="small" type="primary" plain @click="openUsDialog(row)">编辑</el-button>
                <el-button size="small" @click="toggleUs(row)">{{ row.enabled ? '停用' : '启用' }}</el-button>
                <el-button size="small" type="danger" @click="delUs(row)">删除</el-button>
              </template>
            </el-table-column>
          </el-table>
          <el-empty v-if="!us.list.length" description="还没有上游。点「登记上游接口」把内网系统的地址填进来" />

          <div class="hint" style="margin-top:12px">
            <b>怎么用</b>：登记完回到「动态模块」，新建一个 <code class="mono">table</code> 或
            <code class="mono">chart</code>，把「数据来源」填成上表里那条路径（例如
            <code class="mono">/api/hooks/up/tiger/report/daily?day=…</code>），再按试跑返回的字段拼列/轴。
            员工端<b>下拉刷新</b>就能看到，不用重装 App。
          </div>
        <!-- ===== 上游接口（动态模块第三期：让列表/表格/图表取到真数据） ===== -->
        <el-dialog v-model="usDlg" :title="usSel ? `编辑上游「${usSel}」` : '登记上游接口'" width="640px">
          <el-form label-width="130px" label-position="left">
            <el-form-item label="接口名">
              <el-input v-model="usForm.name" :disabled="!!usSel"
                placeholder="小写字母开头，如 tiger / factory / pos" />
              <div class="hint">
                这个名字会出现在路径里（客户端只认名字，不认地址）—— 改名字等于换一条接口，
                所以登记后不能改名，要改就删掉重建。
              </div>
            </el-form-item>
            <el-form-item label="说明">
              <el-input v-model="usForm.label" placeholder="如：门店日报数据源（给自己看的）" />
            </el-form-item>
            <el-form-item label="上游地址">
              <el-input v-model="usForm.baseUrl" placeholder="http://192.168.1.100:3666（写到端口即可，不要带子路径）" />
              <div class="hint">
                必须是服务端**能访问到**的地址。填 127.0.0.1 时注意：跑的是容器/服务器上的本机，
                不是你自己电脑。
              </div>
            </el-form-item>
            <el-form-item label="凭据（Authorization）">
              <el-input v-model="usForm.authHeader" type="password" show-password
                :placeholder="usEditingHasAuth ? '已配置（留空 = 不改动）' : '如 Bearer xxxxx（留空 = 不带凭据）'" />
              <div class="hint">
                <template v-if="usEditingHasAuth">
                  出于安全考虑这里<b>不回显</b>已存的凭据。留空提交 = 保持原值；
                  要换就整条重填，要清掉请勾下面。
                </template>
                <template v-else>
                  由服务端在转发时注入，客户端拿不到也不需要知道。
                </template>
                <div v-if="usEditingHasAuth" style="margin-top:6px">
                  <el-checkbox v-model="usForm.clearAuth">清空已存凭据</el-checkbox>
                </div>
              </div>
            </el-form-item>
            <el-form-item label="超时">
              <el-input-number v-model="usForm.timeoutMs" :min="us.capability.minTimeout || 1000"
                :max="us.capability.maxTimeout || 30000" :step="1000" />
              <span class="hint" style="margin-left:8px">
                毫秒。上游常是内网小机器，给太短会误报超时。
              </span>
            </el-form-item>
            <el-form-item label="允许的角色">
              <el-select v-model="usForm.allowRoles" multiple allow-create filterable
                placeholder="留空 = 所有登录用户" style="width:100%">
                <el-option label="管理员 admin" value="admin" />
                <el-option label="普通用户 user" value="user" />
              </el-select>
              <div class="hint">
                留空 = 任何登录用户都能取到数（适合门店日报这类人人可看的）。
                填了就<b>只</b>放这些角色 —— 注意 admin 不在列表里也没权限，规则只有一套，
                免得"设了白名单管理员却能绕过"当惊喜。
              </div>
            </el-form-item>
            <el-form-item label="启用">
              <el-switch v-model="usForm.enabled" active-text="启用" inactive-text="停用" />
              <span class="hint" style="margin-left:8px">停用 = 该接口对所有角色关闸，不用删配置就能临时关掉。</span>
            </el-form-item>
          </el-form>
          <template #footer>
            <el-button @click="usDlg = false">取消</el-button>
            <el-button type="primary" :loading="usBusy" @click="saveUs">保存</el-button>
          </template>
        </el-dialog>

        <el-dialog v-model="usTestDlg" :title="`试跑上游「${usTestName}」`" width="760px">
          <div class="hint" style="margin-bottom:10px">
            这里直接按服务端转发一次，下面显示的是<b>客户端会拿到的那一整包</b>（包含
            <code class="mono">data</code> 外壳、耗时、真实 URL）。
            所以填 <code class="mono">dataPath</code> 时要带上前缀，写成
            <code class="mono">data.字段名</code> —— 只写字段名在客户端取不到值，表格会是空的。
          </div>
          <el-input v-model="usTestSub" placeholder="子路径，如 report/daily 或 report/daily/2026-09-16">
            <template #prepend>{{ us.pathPrefix + usTestName }}/</template>
            <template #append>
              <el-button :loading="usTestBusy" @click="runUsTest">试跑</el-button>
            </template>
          </el-input>
          <el-alert v-if="usTestErr" type="error" :closable="false" style="margin-top:12px"
            :title="usTestErr" />
          <div v-if="usTestMeta" class="hint" style="margin-top:10px">{{ usTestMeta }}</div>
          <pre v-if="usTestOut" class="mm-json" style="margin-top:10px">{{ usTestOut }}</pre>
        </el-dialog>

        </div>

        <div v-else-if="tab === 'master'">
          <el-alert type="success" :closable="false" style="margin-bottom:14px">
            <template #title>
              商品档案（商档）是<b>盘点的底表</b>：手机在盘点页点「同步商品档案」，
              就把这里的<b>条码 / 名称 / 规格 / 单位 / 进价 / 售价 / 会员价 / 特价 / 库存</b>整份拉到手机上，
              断网也能盘 ——
              扫出来的每一行靠它显示成人看得懂的名字，差异表靠它算金额。
              以前这份数据只能从泰格上游拉 —— 那台机器一关机、IP 一漂就断。
              现在存在自家服务端：<b>一次导入，全员拉同一份</b>。
              <br />
              <b>注意：盘点差异不是拿实盘数和「账面数」比</b>。门店的系统里没有可用的
              库存账面（泰格库所有库存表都是空的），拿它当基准会得到"差异集 = 全部商品"，
              三遍制就退化成把同一个货架扫三遍。实际口径是<b>三遍平行互比</b>：
              复盘比初盘、抽盘比复盘，对不上的才进差异集（含上一遍盘过、这一遍没扫到的"漏盘"）。
              下面的「账面数」只作参考列。
            </template>
          </el-alert>

          <div class="page-bar">
            <el-button type="primary" :loading="masterImport.running" @click="pickMasterFile">导入 CSV</el-button>
            <span class="hint" style="margin-left:8px">
              标准格式（十列，<b>必须带表头</b>，供应商可选）：条码，名称，规格，单位，进价，售价，会员价，特价，库存，供应商
              （会员价/特价没有可缺省，其余列必带）
            </span>
            <el-button :disabled="!master.total || masterImport.running" @click="clearMaster">清空</el-button>
            <span class="hint">
              格式：<code class="mono">序号,条码,商品名字,数量</code> —— 和扫码枪同一份模板，
              可不带表头；<b>数量列落到「账面数」，只作参考</b>（差异是拿三遍实盘互比算的，
              不是拿它比）。
              <code class="mono">.txt</code> 用 Tab 分隔也能读，GBK / UTF-8 都行。
            </span>
            <input ref="masterFileEl" type="file" accept=".csv,.txt,.tsv" style="display:none" @change="onMasterFile" />
          </div>

          <div v-if="masterImport.running" style="margin:12px 0">
            <el-progress :percentage="masterImport.total
              ? Math.floor(masterImport.done / masterImport.total * 100) : 0" />
            <div class="hint">
              已传 {{ masterImport.done }} / {{ masterImport.total }} 行
              <span v-if="masterImport.rejected">（跳过 {{ masterImport.rejected }} 行不合法条码）</span>
              —— <b>全部传完才会替换旧档案</b>，中途关掉页面旧数据不受影响。
            </div>
          </div>

          <el-descriptions border :column="3" style="margin-bottom:14px">
            <el-descriptions-item label="商品总数">{{ master.total }}</el-descriptions-item>
            <el-descriptions-item label="最后更新">
              {{ master.updated_at ? fmtTime(master.updated_at) : '—' }}
            </el-descriptions-item>
            <el-descriptions-item label="手机同步方式">
              盘点页右上角 <code class="mono">同步商品档案</code>
            </el-descriptions-item>
          </el-descriptions>

          <el-table :data="master.list" border stripe>
            <el-table-column label="条码" width="180">
              <template #default="{ row }"><code class="mono">{{ row.barcode }}</code></template>
            </el-table-column>
            <el-table-column label="商品名" min-width="220">
              <template #default="{ row }">{{ row.name || '—' }}</template>
            </el-table-column>
            <el-table-column label="规格" width="120">
              <template #default="{ row }">{{ row.spec || '—' }}</template>
            </el-table-column>
            <el-table-column label="单位" width="80">
              <template #default="{ row }">{{ row.unit || '—' }}</template>
            </el-table-column>
            <el-table-column label="进价" width="100">
              <template #default="{ row }">{{ row.purchase_price == null ? '—' : row.purchase_price }}</template>
            </el-table-column>
            <el-table-column label="售价" width="100">
              <template #default="{ row }">{{ row.unit_price == null ? '—' : row.unit_price }}</template>
            </el-table-column>
            <el-table-column label="会员价" width="100">
              <template #default="{ row }">{{ row.member_price == null ? '—' : row.member_price }}</template>
            </el-table-column>
            <el-table-column label="特价" width="100">
              <template #default="{ row }">{{ row.special_price == null ? '—' : row.special_price }}</template>
            </el-table-column>
            <el-table-column label="账面数（库存参考）" width="150">
              <template #default="{ row }">
                <b>{{ row.account_qty == null ? '—' : row.account_qty }}</b>
              </template>
            </el-table-column>
            <el-table-column label="供应商" min-width="160">
              <template #default="{ row }">{{ row.supplier || '—' }}</template>
            </el-table-column>
          </el-table>
          <el-empty v-if="!master.list.length && !masterImport.running"
            description="还没有商品档案。点「导入 CSV」把门店的商品表导进来，手机盘点才认得出商品名、差异表才算得出金额" />
          <div v-if="master.list.length" class="page-bar" style="margin-top:10px">
            <el-button size="small" :disabled="master.page <= 1" @click="loadMasterPage(master.page - 1)">上一页</el-button>
            <span class="hint">第 {{ master.page }} 页</span>
            <el-button size="small" :disabled="master.list.length < master.pageSize"
              @click="loadMasterPage(master.page + 1)">下一页</el-button>
          </div>
        </div>

        <!-- ===== 库房减货（对账） ===== -->
        <div v-else-if="tab === 'deduct'">
          <el-alert type="success" :closable="false" style="margin-bottom:14px">
            <template #title>
              手机上的「库房减货」提交后点<b>上传管理台</b>，数据就到这里。
              <b>按商品对账</b>把这段时间所有单<b>累加</b>起来 —— 回答"这个品一共减了多少、
              分几次减的"；<b>减货单</b>回答"谁、什么时候、减了一单"。
              <br />
              <b>传上来的数改不了</b>：服务端默认拒绝覆盖已经上传过的单（手机要显式重传才行），
              所以这里的数就是当时传上来的原样 —— 这也是"能对账"的前提。
            </template>
          </el-alert>

          <div class="page-bar">
            <el-date-picker v-model="deductRange" type="daterange" size="small"
              range-separator="至" start-placeholder="开始日期" end-placeholder="结束日期"
              value-format="x" style="width:250px" @change="reloadDeduct" />
            <el-button size="small" :disabled="!deductRange" @click="deductRange = null; reloadDeduct()">全部时间</el-button>
            <el-input v-model="deduct.q" size="small" placeholder="搜条码或商品名" clearable
              style="width:200px;margin-left:8px" @keyup.enter="reloadDeduct" @clear="reloadDeduct" />
            <el-button size="small" type="primary" style="margin-left:8px" @click="reloadDeduct">查询</el-button>
            <span class="hint">减货不挂盘点位、不分阶段，只看时间和商品</span>
          </div>

          <el-descriptions border :column="4" style="margin:14px 0">
            <el-descriptions-item label="减货单">{{ deduct.overall.sheets ?? 0 }} 张</el-descriptions-item>
            <el-descriptions-item label="明细行">{{ deduct.overall.rows_count ?? 0 }}</el-descriptions-item>
            <el-descriptions-item label="减货总数量"><b>{{ deduct.overall.total_qty ?? 0 }}</b></el-descriptions-item>
            <el-descriptions-item label="统计范围">{{ deductRangeLabel }}</el-descriptions-item>
          </el-descriptions>

          <el-tabs v-model="deductTab">
            <el-tab-pane label="按商品对账" name="reconcile">
              <el-table :data="deduct.rec" border stripe v-loading="deduct.loading">
                <el-table-column label="条码" width="170">
                  <template #default="{ row }"><code class="mono">{{ row.barcode }}</code></template>
                </el-table-column>
                <el-table-column label="商品名" min-width="200">
                  <template #default="{ row }">{{ row.name || '—' }}</template>
                </el-table-column>
                <el-table-column label="规格" width="110">
                  <template #default="{ row }">{{ row.spec || '—' }}</template>
                </el-table-column>
                <el-table-column label="单位" width="70">
                  <template #default="{ row }">{{ row.unit || '—' }}</template>
                </el-table-column>
                <el-table-column label="减货总量" width="110">
                  <template #default="{ row }"><b>{{ row.total_qty }}</b></template>
                </el-table-column>
                <el-table-column label="涉及单数" width="90">
                  <template #default="{ row }">{{ row.sheets_count }}</template>
                </el-table-column>
                <el-table-column label="最后减货时间" width="160">
                  <template #default="{ row }">{{ fmtTime(row.last_at) }}</template>
                </el-table-column>
              </el-table>
              <el-empty v-if="!deduct.rec.length && !deduct.loading"
                description="这段时间还没有减货记录。手机上的减货单要「提交」之后再点「上传管理台」才会到这里" />
              <div v-if="deduct.rec.length" class="page-bar" style="margin-top:10px">
                <el-button size="small" :disabled="deduct.recPage <= 1" @click="loadDeductRec(deduct.recPage - 1)">上一页</el-button>
                <span class="hint">第 {{ deduct.recPage }} 页 · 共 {{ deduct.recTotal }} 个品</span>
                <el-button size="small" :disabled="deduct.rec.length < 100"
                  @click="loadDeductRec(deduct.recPage + 1)">下一页</el-button>
              </div>
            </el-tab-pane>

            <el-tab-pane label="减货单" name="sheets">
              <el-table :data="deduct.sheets" border stripe v-loading="deduct.loading">
                <el-table-column label="单号" width="200">
                  <template #default="{ row }">
                    <a class="link" @click="openDeductSheet(row.sheet_no)"><code class="mono">{{ row.sheet_no }}</code></a>
                  </template>
                </el-table-column>
                <el-table-column label="操作人" width="120">
                  <template #default="{ row }">{{ row.operator || '—' }}</template>
                </el-table-column>
                <el-table-column label="开单时间" width="160">
                  <template #default="{ row }">{{ fmtTime(row.started_at) }}</template>
                </el-table-column>
                <el-table-column label="上传时间" width="160">
                  <template #default="{ row }">{{ row.uploaded_at ? fmtTime(row.uploaded_at) : '—' }}</template>
                </el-table-column>
                <el-table-column label="品种数" width="90">
                  <template #default="{ row }">{{ row.rows_count ?? 0 }}</template>
                </el-table-column>
                <el-table-column label="数量" width="100">
                  <template #default="{ row }"><b>{{ row.total_qty ?? 0 }}</b></template>
                </el-table-column>
                <el-table-column label="设备" width="130">
                  <template #default="{ row }">{{ row.device_id || '—' }}</template>
                </el-table-column>
              </el-table>
              <el-empty v-if="!deduct.sheets.length && !deduct.loading" description="还没有减货单" />
              <div v-if="deduct.sheets.length" class="page-bar" style="margin-top:10px">
                <el-button size="small" :disabled="deduct.sheetsPage <= 1" @click="loadDeductSheets(deduct.sheetsPage - 1)">上一页</el-button>
                <span class="hint">第 {{ deduct.sheetsPage }} 页 · 共 {{ deduct.sheetsTotal }} 张</span>
                <el-button size="small" :disabled="deduct.sheets.length < 50"
                  @click="loadDeductSheets(deduct.sheetsPage + 1)">下一页</el-button>
              </div>
            </el-tab-pane>
          </el-tabs>

          <el-dialog v-model="deduct.dlg" :title="`减货单 ${deduct.cur || ''}`" width="860px">
            <el-table :data="deduct.detail" border stripe max-height="440">
              <el-table-column label="条码" width="170">
                <template #default="{ row }"><code class="mono">{{ row.barcode }}</code></template>
              </el-table-column>
              <el-table-column label="商品名" min-width="200">
                <template #default="{ row }">{{ row.name || '—' }}</template>
              </el-table-column>
              <el-table-column label="规格" width="110">
                <template #default="{ row }">{{ row.spec || '—' }}</template>
              </el-table-column>
              <el-table-column label="减货数量" width="110">
                <template #default="{ row }"><b>{{ row.qty }}</b></template>
              </el-table-column>
              <el-table-column label="扫码时间" width="170">
                <template #default="{ row }">{{ fmtTime(row.scanned_at) }}</template>
              </el-table-column>
            </el-table>
          </el-dialog>
        </div>

        <!-- ===== 培训中心 ===== -->
        <!-- 名字就叫「培训中心」：与客户端应用台入口、服务端模块名三处一致 -->
        <div v-else-if="tab === 'training'">
          <el-tabs v-model="trTab">
            <!-- ---------------- 课程 ---------------- -->
            <el-tab-pane label="课程" name="courses">
              <el-alert type="info" :closable="false" style="margin-bottom:12px">
                <template #title>结构在这里维护，大视频走导入器（别用浏览器传）</template>
                <template #default>
                  200+ 视频课件在 <code class="mono">Y:\培训资料</code>，让导入器按目录层级自动建成课程：
                  <code class="mono">node server/tools/import_training.js --dir "Y:\培训资料"</code>
                  默认只预览不写库；加 <code class="mono">--apply --copy</code> 才真导入
                  （<b>重复导入是幂等的</b>，不会建出第二份）。小文件（讲义 PDF）可以直接在下面「+ 课时」时上传。
                </template>
              </el-alert>

              <div class="page-bar wrap">
                <el-button type="primary" @click="openTrCourse(null)">新建课程</el-button>
                <el-button @click="loadTrCourses()">刷新</el-button>
                <span class="hint">
                  未发布的课是<b>草稿</b>：管理端看得见、学员侧看不见。建好结构再点「发布」。
                </span>
              </div>

              <el-table :data="tr.courses" v-loading="tr.loading" border stripe>
                <el-table-column prop="id" label="ID" width="70" />
                <el-table-column prop="title" label="课程名称" min-width="200" />
                <el-table-column label="分类" width="120">
                  <template #default="{ row }">{{ row.category || '—' }}</template>
                </el-table-column>
                <el-table-column label="必修" width="70">
                  <template #default="{ row }">
                    <el-tag v-if="row.required" type="danger" size="small">必修</el-tag>
                    <span v-else class="hint">选修</span>
                  </template>
                </el-table-column>
                <el-table-column label="状态" width="90">
                  <template #default="{ row }">
                    <el-tag :type="row.published ? 'success' : 'info'" size="small">
                      {{ row.published ? '已发布' : '草稿' }}
                    </el-tag>
                  </template>
                </el-table-column>
                <el-table-column label="章节 / 课时 / 考试" width="150">
                  <template #default="{ row }">
                    {{ row.chapter_count }} / {{ row.lesson_count }} / {{ row.exam_count }}
                  </template>
                </el-table-column>
                <el-table-column label="报名人数" width="90">
                  <template #default="{ row }">{{ row.enroll_count }}</template>
                </el-table-column>
                <el-table-column label="操作" width="290">
                  <template #default="{ row }">
                    <el-button size="small" @click="openTrStruct(row)">结构</el-button>
                    <el-button size="small" @click="openTrCourse(row)">改</el-button>
                    <el-button size="small" :type="row.published ? 'warning' : 'success'"
                      @click="toggleTrPublish(row)">{{ row.published ? '下线' : '发布' }}</el-button>
                    <el-button size="small" type="danger" @click="delTrCourse(row)">删</el-button>
                  </template>
                </el-table-column>
              </el-table>
              <el-empty v-if="!tr.loading && !tr.courses.length"
                description="还没有课程。先「新建课程」，或用导入器把 Y:\培训资料 扫进来。" />
            </el-tab-pane>

            <!-- ---------------- 成绩 ---------------- -->
            <el-tab-pane label="成绩" name="sheets">
              <!--
                这张表才是培训中心的意义所在：**谁学了、考了多少、过没过**。
                没有它，前面做得再漂亮也只是个视频播放器。
              -->
              <div class="page-bar wrap">
                <el-select v-model="tr.sheetCourse" placeholder="全部课程" clearable style="width:220px"
                  @change="tr.sheetPage = 1; loadTrSheets()">
                  <el-option v-for="c in tr.courses" :key="c.id" :label="c.title" :value="c.id" />
                </el-select>
                <el-checkbox v-model="tr.onlyPassed" @change="tr.sheetPage = 1; loadTrSheets()">只看及格</el-checkbox>
                <el-button @click="loadTrSheets()">刷新</el-button>
                <span class="hint">共 {{ tr.sheetTotal }} 条记录（<b>不限时间</b>，去年的成绩也查得到）</span>
              </div>
              <el-table :data="tr.sheets" v-loading="tr.sheetLoading" border stripe>
                <el-table-column label="学员" width="150">
                  <template #default="{ row }">
                    {{ row.nickname || row.username || ('#' + row.user_id) }}
                  </template>
                </el-table-column>
                <el-table-column label="课程" min-width="170">
                  <template #default="{ row }">{{ row.course_title || '—' }}</template>
                </el-table-column>
                <el-table-column label="章节考试" min-width="150">
                  <template #default="{ row }">{{ row.exam_title || '—' }}</template>
                </el-table-column>
                <el-table-column label="第几次" width="80">
                  <template #default="{ row }">{{ row.attempt_no }}</template>
                </el-table-column>
                <el-table-column label="分数" width="120">
                  <template #default="{ row }">
                    <span :style="{ color: row.pass ? '#67c23a' : '#f56c6c' }">{{ row.score }}</span>
                    <span class="hint"> / 及格 {{ row.pass_score }}</span>
                  </template>
                </el-table-column>
                <el-table-column label="结果" width="90">
                  <template #default="{ row }">
                    <el-tag v-if="!row.submitted_at" type="warning" size="small">未交卷</el-tag>
                    <el-tag v-else :type="row.pass ? 'success' : 'danger'" size="small">
                      {{ row.pass ? '及格' : '不及格' }}
                    </el-tag>
                  </template>
                </el-table-column>
                <el-table-column label="开始时间" width="170">
                  <template #default="{ row }">{{ fmtTime(row.started_at) }}</template>
                </el-table-column>
                <el-table-column label="交卷时间" width="170">
                  <template #default="{ row }">{{ row.submitted_at ? fmtTime(row.submitted_at) : '—' }}</template>
                </el-table-column>
              </el-table>
              <div class="page-bar" style="margin-top:10px">
                <el-button :disabled="tr.sheetPage <= 1" @click="tr.sheetPage--; loadTrSheets()">上一页</el-button>
                <span class="hint">第 {{ tr.sheetPage }} 页</span>
                <el-button :disabled="tr.sheets.length < tr.sheetSize" @click="tr.sheetPage++; loadTrSheets()">下一页</el-button>
              </div>
            </el-tab-pane>

            <!-- ---------------- 培训文件 ---------------- -->
            <el-tab-pane label="培训文件" name="files">
              <el-alert type="info" :closable="false" style="margin-bottom:12px">
                <template #title>这里只列出"被培训课程/课时引用过"的文件</template>
                <template #default>
                  课件 PDF、视频、课程封面图都归到这里统一管理，不用再去通用文件管理里翻。
                  被引用的文件不能删（先去课程结构里解绑）；没被引用的可以清理掉。
                </template>
              </el-alert>
              <div class="page-bar wrap">
                <el-button @click="loadTrFiles()">刷新</el-button>
                <span class="hint">共 {{ tr.files.length }} 个培训文件</span>
              </div>
              <el-table :data="tr.files" v-loading="tr.filesLoading" border stripe>
                <el-table-column label="文件" min-width="240">
                  <template #default="{ row }">
                    <div style="display:flex;align-items:center;gap:8px">
                      <img v-if="isImage(row.mime)" :src="'/files/' + row.path" style="height:28px;width:28px;object-fit:cover;border-radius:4px" />
                      <el-icon v-else><Document /></el-icon>
                      <span>{{ row.name }}</span>
                    </div>
                  </template>
                </el-table-column>
                <el-table-column label="类型" width="120">
                  <template #default="{ row }">{{ row.mime || '—' }}</template>
                </el-table-column>
                <el-table-column label="大小" width="110">
                  <template #default="{ row }">{{ fmtBytes(row.size) }}</template>
                </el-table-column>
                <el-table-column label="引用" width="120" align="center">
                  <template #default="{ row }">
                    <el-tag size="small" :type="row.refs > 0 ? 'warning' : 'info'">{{ row.refs }} 处</el-tag>
                    <div class="hint" style="line-height:1.2">
                      课时 {{ row.lessonRefs }} · 封面 {{ row.coverRefs }}
                    </div>
                  </template>
                </el-table-column>
                <el-table-column label="上传时间" width="170">
                  <template #default="{ row }">{{ fmtTime(row.createdAt) }}</template>
                </el-table-column>
                <el-table-column label="操作" width="140">
                  <template #default="{ row }">
                    <el-button size="small" link type="primary" @click="trFileOpen(row)">下载</el-button>
                    <el-button size="small" link type="danger" :disabled="row.refs > 0"
                      @click="delTrFile(row)">删除</el-button>
                  </template>
                </el-table-column>
              </el-table>
              <el-empty v-if="!tr.filesLoading && !tr.files.length" description="还没有培训文件。" />
            </el-tab-pane>
          </el-tabs>

          <!-- 课程信息 -->
          <el-dialog v-model="tr.courseDlg" :title="tr.courseForm.id ? '修改课程' : '新建课程'" width="520px">
            <el-form label-width="90px">
              <el-form-item label="课程名称">
                <el-input v-model="tr.courseForm.title" maxlength="120" show-word-limit
                  placeholder="如：生鲜陈列基础" />
              </el-form-item>
              <el-form-item label="分类">
                <el-select v-model="tr.courseForm.category" filterable allow-create default-first-option
                  placeholder="如 店长管理 / 生鲜陈列 / 防损 / 前台收银" style="width:100%">
                  <el-option v-for="c in trCategories" :key="c" :label="c" :value="c" />
                </el-select>
              </el-form-item>
              <el-form-item label="简介">
                <el-input v-model="tr.courseForm.intro" type="textarea" :rows="3" maxlength="2000"
                  placeholder="这门课讲什么、学完能干什么" />
              </el-form-item>
              <el-form-item label="必修">
                <el-switch v-model="tr.courseForm.required" />
                <span class="hint" style="margin-left:10px">必修课不学完，年度培训进度就不满</span>
              </el-form-item>
              <el-form-item label="发布">
                <el-switch v-model="tr.courseForm.published" />
                <span class="hint" style="margin-left:10px">关着 = 草稿，学员侧看不到</span>
              </el-form-item>

              <!-- 🔴 课件：以前这里一个挂课件的入口都没有，得先建课程、再建章节、
                   再建课时、最后逐条挂文件，四步走完人就不想建课了。
                   现在建课当场就能挂（传文件 或 填外链），一起存进去。 -->
              <el-form-item label="课件">
                <div style="width:100%">
                  <div v-for="(w, wi) in tr.courseForm.wares" :key="'ware' + wi" class="tr-ware">
                    <span class="tr-ware-no">{{ wi + 1 }}</span>
                    <el-input v-model="w.title" size="small" placeholder="课件名，如：01 陈列三原则"
                      style="flex:1 1 140px" />
                    <el-select v-model="w.kind" size="small" style="width:86px">
                      <el-option value="video" label="视频" />
                      <el-option value="doc" label="文档" />
                    </el-select>
                    <el-input v-model="w.linkUrl" size="small" placeholder="课件链接（http 开头）"
                      style="flex:1 1 180px" />
                    <el-button size="small" :loading="tr.uploading && tr.wareIdx === wi"
                      @click="pickTrWare(wi)">上传</el-button>
                    <el-button size="small" plain @click="openWare(w)">预览</el-button>
                    <el-button size="small" type="danger" plain @click="tr.courseForm.wares.splice(wi, 1)">删</el-button>
                  </div>
                  <div v-if="!tr.courseForm.wares.length" class="hint" style="margin:2px 0 6px">
                    还没有课件。这里可以直接传文件，也可以只填一个外链（共享盘 / 视频号 / 腾讯文档）——
                    都留空也能先建课，之后在「课程结构」里补。
                  </div>
                  <el-button size="small" @click="tr.courseForm.wares.push({ title: '', kind: 'video', linkUrl: '', fileId: null })">
                    + 加一节课
                  </el-button>
                  <input ref="trWareEl" type="file" style="display:none" @change="onTrWareFile" />
                </div>
              </el-form-item>
            </el-form>
            <template #footer>
              <el-button @click="tr.courseDlg = false">取消</el-button>
              <el-button type="primary" :loading="tr.saving" @click="saveTrCourse()">保存</el-button>
            </template>
          </el-dialog>

          <!-- 课程结构：章节 → 课时 / 考试 -->
          <el-drawer v-model="tr.structDlg" size="66%" :title="tr.structTitle">
            <div class="page-bar wrap">
              <el-button type="primary" size="small" @click="addTrChapter()">+ 章节</el-button>
              <el-button size="small" @click="reloadTrStruct()">刷新</el-button>
              <span class="hint">结构改完不用重新发布 —— 学员下次打开课程就是新的</span>
            </div>

            <div v-for="(ch, ci) in tr.struct" :key="ch.id" class="tr-card">
              <div class="tr-card-head">
                <b>{{ ci + 1 }}. {{ ch.title }}</b>
                <span style="flex:1"></span>
                <el-button size="small" @click="addTrLesson(ch)">+ 课时</el-button>
                <el-button size="small" @click="addTrExam(ch)">+ 考试</el-button>
                <el-button size="small" type="danger" @click="delTrChapter(ch)">删章节</el-button>
              </div>

              <el-table :data="ch.lessons" size="small" border>
                <el-table-column prop="id" label="ID" width="60" />
                <el-table-column prop="title" label="课时" min-width="160" />
                <el-table-column label="类型" width="80">
                  <template #default="{ row }">{{ row.kind === 'doc' ? '文档' : '视频' }}</template>
                </el-table-column>
                <el-table-column label="时长" width="90">
                  <template #default="{ row }">
                    {{ row.duration_sec ? Math.round(row.duration_sec / 60) + ' 分' : '—' }}
                  </template>
                </el-table-column>
                <!-- 课件两列分开写：传了文件 / 填了外链，一眼看得出这节能不能点开。
                     ⚠️ 管理端这里是下划线的原始列名（SELECT *），别写成 fileId。 -->
                <el-table-column label="课件" min-width="170">
                  <template #default="{ row }">
                    <div v-if="row.file_id">已挂 file#{{ row.file_id }}</div>
                    <div v-else-if="row.link_url" style="color:#909399">
                      外链（未传文件）
                    </div>
                    <div v-else style="color:#e6a23c;font-size:12px">未挂课件（学员点开是空的）</div>
                  </template>
                </el-table-column>
                <el-table-column label="链接" min-width="180">
                  <template #default="{ row }">
                    <span v-if="row.link_url" class="hint">{{ row.link_url }}</span>
                    <span v-else style="color:#c0c4cc;font-size:12px">—</span>
                  </template>
                </el-table-column>
                <el-table-column label="操作" width="130">
                  <template #default="{ row }">
                    <el-button size="small" @click="editTrLesson(ch, row)">改</el-button>
                    <el-button size="small" type="danger" @click="delTrLesson(row)">删</el-button>
                  </template>
                </el-table-column>
              </el-table>
              <div v-if="!ch.lessons.length" class="hint" style="margin:6px 0 0 2px">本章还没有课时</div>

              <div v-for="e in ch.exams" :key="'e' + e.id" class="tr-exam">
                <div class="tr-card-head">
                  <b>考试：{{ e.title }}</b>
                  <span class="hint">
                    及格 {{ e.pass_score }} 分 · {{ e.attempt_limit }} 次机会 ·
                    本章进度达 {{ e.min_progress }}% 才放行 · {{ e.questions.length }} 题
                  </span>
                  <span style="flex:1"></span>
                  <el-button size="small" type="danger" @click="delTrExam(e)">删考试</el-button>
                </div>
                <el-table :data="e.questions" size="small" border>
                  <el-table-column prop="id" label="ID" width="60" />
                  <el-table-column label="题型" width="80">
                    <template #default="{ row }">{{ trTypeName(row.type) }}</template>
                  </el-table-column>
                  <el-table-column prop="stem" label="题干" min-width="200" />
                  <el-table-column prop="score" label="分值" width="70" />
                  <el-table-column label="选项（✓ = 正确答案；这份只在管理端显示，学员侧不下发）" min-width="260">
                    <template #default="{ row }">
                      <div v-for="o in row.options" :key="o.id">
                        <span :style="{ color: o.correct ? '#67c23a' : '#606266' }">
                          {{ o.correct ? '✓' : '　' }} {{ o.label }}. {{ o.content }}
                        </span>
                      </div>
                    </template>
                  </el-table-column>
                </el-table>
              </div>
            </div>
            <el-empty v-if="!tr.struct.length" description="还没有章节。先「+ 章节」，再往里加课时。" />
          </el-drawer>

          <!-- 加课时 / 改课时（同一个弹窗：以前只有"加"，挂错课件只能删了重建，
               而重建会让学员的历史进度一起消失） -->
          <el-dialog v-model="tr.lessonDlg" :title="tr.lessonEditId ? '修改课时' : '添加课时'" width="560px">
            <el-form label-width="90px">
              <el-form-item label="课时名称">
                <el-input v-model="tr.lessonForm.title" maxlength="120" placeholder="如：01 陈列三原则" />
              </el-form-item>
              <el-form-item label="类型">
                <el-radio-group v-model="tr.lessonForm.kind">
                  <el-radio value="video">视频</el-radio>
                  <el-radio value="doc">文档（只记"看过"，不计时长）</el-radio>
                </el-radio-group>
              </el-form-item>
              <el-form-item label="时长(秒)">
                <el-input-number v-model="tr.lessonForm.durationSec" :min="0" :max="86400" />
                <span class="hint" style="margin-left:10px">视频填真实时长，进度百分比才算得准</span>
              </el-form-item>
              <el-form-item label="课件文件">
                <div>
                  <input ref="trFileEl" type="file" style="display:none" @change="onTrFile" />
                  <el-button size="small" :loading="tr.uploading" @click="trFileEl?.click()">上传课件</el-button>
                  <span v-if="tr.lessonForm.fileId" class="hint" style="margin-left:10px">
                    已挂 file#{{ tr.lessonForm.fileId }}
                  </span>
                  <div class="hint" style="margin-top:4px">
                    上传适合讲义这类小文件；<b>大视频用导入器</b>（浏览器传几百兆会超时且不报错）。
                  </div>
                </div>
              </el-form-item>
              <!-- 🔴 外链：共享盘 / 视频号 / 腾讯文档这类进不了系统文件的课件走这里。
                   以前整张表只有 file_id，"设置课件链接地址"这个入口根本不存在。 -->
              <el-form-item label="课件链接">
                <div style="width:100%">
                  <el-input v-model="tr.lessonForm.linkUrl" maxlength="2000" clearable
                    placeholder="http 或 https 开头，例如 https://docs.qq.com/doc/xxxx" />
                  <div class="hint" style="margin-top:4px">
                    留空 = 只用上面传的文件；填了 = 学员点这节课直接跳过去。
                    <b>两者可以同时用</b>（点课时会先跳外链，跳不过去再回落到文件）。
                  </div>
                </div>
              </el-form-item>
            </el-form>
            <template #footer>
              <el-button @click="tr.lessonDlg = false">取消</el-button>
              <el-button type="primary" :loading="tr.saving" @click="saveTrLesson()">
                {{ tr.lessonEditId ? '保存修改' : '添加' }}
              </el-button>
            </template>
          </el-dialog>

          <!-- 建考试（题目一次建好：分开建会出现"没有题的考试"） -->
          <el-dialog v-model="tr.examDlg" title="新建章节考试" width="760px" top="6vh">
            <el-form label-width="100px">
              <el-form-item label="考试名称">
                <el-input v-model="tr.examForm.title" maxlength="120" placeholder="如：第一章测验" />
              </el-form-item>
              <el-form-item label="及格分">
                <el-input-number v-model="tr.examForm.passScore" :min="0" :max="1000" />
                <span class="hint" style="margin-left:14px">机会</span>
                <el-input-number v-model="tr.examForm.attemptLimit" :min="1" :max="99" style="margin-left:6px" />
                <span class="hint" style="margin-left:4px">次（默认 1 次，且<b>点开始就消耗</b>）</span>
              </el-form-item>
              <el-form-item label="进度门禁">
                <el-input-number v-model="tr.examForm.minProgress" :min="0" :max="100" />
                <span class="hint" style="margin-left:10px">
                  %：本章进度低于这个百分比不放行考试（100 = 必须看完本章）
                </span>
              </el-form-item>
            </el-form>

            <div class="tr-card-head" style="margin-bottom:6px">
              <b>题目（{{ tr.examForm.questions.length }} 题，共
                {{ tr.examForm.questions.reduce((n, q) => n + (Number(q.score) || 0), 0) }} 分）</b>
              <span style="flex:1"></span>
              <el-button size="small" @click="addTrQuestion()">+ 加题</el-button>
            </div>

            <div v-for="(q, qi) in tr.examForm.questions" :key="qi" class="tr-q">
              <div class="tr-card-head">
                <b>第 {{ qi + 1 }} 题</b>
                <el-select v-model="q.type" size="small" style="width:110px">
                  <el-option label="单选" value="single" />
                  <el-option label="多选" value="multi" />
                  <el-option label="判断" value="judge" />
                </el-select>
                <span class="hint">分值</span>
                <el-input-number v-model="q.score" size="small" :min="1" :max="100" style="width:100px" />
                <span style="flex:1"></span>
                <el-button size="small" type="danger" @click="tr.examForm.questions.splice(qi, 1)">删</el-button>
              </div>
              <el-input v-model="q.stem" size="small" placeholder="题干" style="margin:6px 0" />
              <div v-for="(o, oi) in q.options" :key="oi" style="display:flex;align-items:center;gap:8px;margin-bottom:4px">
                <el-checkbox v-model="o.correct">正确</el-checkbox>
                <el-input v-model="o.content" size="small" :placeholder="'选项 ' + trLabel(oi)" />
                <el-button size="small" text type="danger"
                  :disabled="q.options.length <= 2" @click="q.options.splice(oi, 1)">×</el-button>
              </div>
              <el-button size="small" text @click="q.options.push({ content: '', correct: false })">+ 选项</el-button>
            </div>

            <template #footer>
              <el-button @click="tr.examDlg = false">取消</el-button>
              <el-button type="primary" :loading="tr.saving" @click="saveTrExam()">建考试</el-button>
            </template>
          </el-dialog>
        </div>

        <!-- ===== 消息推送（APNs） ===== -->
        <div v-else-if="tab === 'push'">
          <el-alert type="info" :closable="false" style="margin-bottom:14px">
            <template #title>
              手机锁屏时要有消息提醒，只能靠 Apple 的推送通道（APNs）——
              App 自己连着 WebSocket，但**退到后台就被系统挂起**了。
              这里配的是服务端的 APNs 凭据：配好之后服务端直接把提醒推给 Apple，
              由 Apple 送到手机。
              <br />
              <b>四样东西缺一不可</b>：Key ID / Team ID / Bundle ID（App 的标识）/
              .p8 私钥（在 Apple 开发者后台「Keys」里下载，<b>只能下一次</b>）。
            </template>
          </el-alert>

          <el-descriptions border :column="4" style="margin-bottom:14px">
            <el-descriptions-item label="当前状态">
              <el-tag :type="push.info?.enabled ? 'success' : 'info'" effect="plain" size="small">
                {{ push.info?.enabled ? '已启用' : '未配置' }}
              </el-tag>
            </el-descriptions-item>
            <el-descriptions-item label="环境">
              {{ push.info?.envLabel || '—' }}
            </el-descriptions-item>
            <el-descriptions-item label="Bundle ID">
              <code class="mono">{{ push.info?.topic || '—' }}</code>
            </el-descriptions-item>
            <el-descriptions-item label="私钥">
              {{ push.info?.hasKey ? '已配置（内容不回显）' : '未配置' }}
            </el-descriptions-item>
          </el-descriptions>

          <el-descriptions border :column="4" style="margin-bottom:14px">
            <el-descriptions-item label="已登记设备">{{ push.stats?.devices ?? 0 }}</el-descriptions-item>
            <el-descriptions-item label="在线设备">{{ push.stats?.activeDevices ?? 0 }}</el-descriptions-item>
            <el-descriptions-item label="近 24 小时发出">{{ push.stats?.last24h?.sent ?? 0 }}</el-descriptions-item>
            <el-descriptions-item label="近 24 小时失败">
              <b :style="{ color: (push.stats?.last24h?.fail ?? 0) > 0 ? 'var(--el-color-danger)' : '' }">
                {{ push.stats?.last24h?.fail ?? 0 }}
              </b>
            </el-descriptions-item>
          </el-descriptions>

          <el-form :model="pushForm" label-width="130px" style="max-width:720px">
            <el-form-item label="Key ID">
              <el-input v-model="pushForm.keyId" placeholder="Apple 后台生成的 Key ID，如 A1B2C3D4E5" />
            </el-form-item>
            <el-form-item label="Team ID">
              <el-input v-model="pushForm.teamId" placeholder="开发者账号的 Team ID（10 位）" />
            </el-form-item>
            <el-form-item label="Bundle ID">
              <el-input v-model="pushForm.topic" placeholder="如 com.xxx.xiaozhi，必须与 App 的标识完全一致" />
            </el-form-item>
            <el-form-item label="环境">
              <el-radio-group v-model="pushForm.env">
                <el-radio value="production">生产（App Store / TestFlight 装的包）</el-radio>
                <el-radio value="sandbox">沙盒（Xcode 直连调试）</el-radio>
              </el-radio-group>
              <div class="hint">
                🔴 手机装的包是哪种，这里就要选哪种。选错的表现是"服务端说发出去了、
                手机一条都收不到"—— 而日志里看起来是成功的。
              </div>
            </el-form-item>
            <el-form-item label=".p8 私钥">
              <el-input v-model="pushForm.keyP8" type="textarea" :rows="4"
                placeholder="-----BEGIN PRIVATE KEY-----&#10;（把文件内容整个粘进来）&#10;-----END PRIVATE KEY-----" />
              <div class="hint">
                私钥<b>只写不读</b>：保存之后服务端只回"有没有、第一行长什么样"，
                界面上不会再显示内容。要换就重新粘一份。
              </div>
            </el-form-item>
          </el-form>

          <div class="page-bar">
            <el-button type="primary" :loading="push.busy" @click="savePush">保存并立即生效</el-button>
            <el-button :loading="push.busy" @click="probePush">本地自检（先试再存）</el-button>
            <el-button :disabled="!push.info?.enabled" :loading="push.busy" @click="testPush">发一条测试推送</el-button>
            <el-button :disabled="!push.info?.enabled" @click="clearPush">清空配置</el-button>
            <el-button @click="loadPush">刷新</el-button>
          </div>

          <el-alert v-if="push.probeText" :title="push.probeText" :type="push.probeOk ? 'success' : 'error'"
            show-icon :closable="false" style="margin:12px 0" />

          <div class="sec-title">最近投递</div>
          <el-table :data="push.logs" border stripe>
            <el-table-column label="时间" width="160">
              <template #default="{ row }">{{ fmtTime(row.created_at) }}</template>
            </el-table-column>
            <el-table-column label="接收人" width="130">
              <template #default="{ row }">{{ row.user }}</template>
            </el-table-column>
            <el-table-column label="标题" min-width="180">
              <template #default="{ row }">{{ row.title }}</template>
            </el-table-column>
            <el-table-column label="结果" width="90">
              <template #default="{ row }">
                <el-tag :type="row.ok ? 'success' : 'danger'" effect="plain" size="small">
                  {{ row.ok ? '成功' : '失败' }}
                </el-tag>
              </template>
            </el-table-column>
            <el-table-column label="说明" min-width="220">
              <template #default="{ row }">{{ row.reason || row.status || '—' }}</template>
            </el-table-column>
          </el-table>
          <el-empty v-if="!push.logs.length" description="还没有投递记录" />
        </div>

        <div v-else-if="tab === 'health'">
          <el-card shadow="never">
            <template #header>
              <div class="card-hdr">
                <span>数据体检</span>
                <el-button size="small" :loading="orphanScan.loading" @click="loadOrphanScan"
                           style="margin-left:auto">重新体检</el-button>
              </div>
            </template>

            <el-alert type="info" :closable="false" style="margin-bottom:14px">
              <template #title>
                这个库<b>没有外键约束</b>，靠应用层维护一致性。历史上可能残留一些
                「指向已删除对象的行」—— 它们不会自己消失，也不会报错，
                只会让好友树出现空壳账号、让某些计数永远不对。
                这里体检所有已知的关联。
              </template>
            </el-alert>

            <!-- 体检结论 -->
            <el-alert v-if="orphanScan.loaded && orphanScan.summary?.healthy"
                      type="success" :closable="false" show-icon style="margin-bottom:14px">
              <template #title>
                未发现可清理的孤儿数据，{{ orphanScan.summary.checked }} 项关联全部正常。
              </template>
            </el-alert>
            <el-alert v-else-if="orphanScan.loaded"
                      :type="orphanScan.summary?.purgeable ? 'warning' : 'info'"
                      :closable="false" show-icon style="margin-bottom:14px">
              <template #title>
                发现 <b>{{ orphanScan.summary?.purgeable || 0 }}</b> 行可清理的孤儿数据
                <span v-if="orphanScan.summary?.kept">
                  ；另有 <b>{{ orphanScan.summary.kept }}</b> 行属于产品刻意保留的历史数据，不建议清理。
                </span>
              </template>
            </el-alert>

            <div class="page-bar">
              <el-button type="danger" plain
                         :disabled="!orphanScanPurgeableCount"
                         @click="openOrphanPurge">
                清理孤儿数据（{{ orphanScanPurgeableCount }} 行）
              </el-button>
              <span class="hint">
                清理前会自动导出备份到 <code>purge-backup/</code>；数量变化时会要求重新确认。
              </span>
            </div>

            <div class="analysis-h">体检结果</div>
            <el-table :data="orphanRows" border stripe size="small">
              <el-table-column prop="label" label="关联关系" min-width="200" show-overflow-tooltip />
              <el-table-column label="孤儿行数" width="110" align="center">
                <template #default="{ row }">
                  <b v-if="row.count > 0" :style="{ color: row.purgeable ? '#E6A23C' : '#909399' }">
                    {{ row.count }}
                  </b>
                  <span v-else style="color:#67C23A">0</span>
                </template>
              </el-table-column>
              <el-table-column label="可否清理" width="120" align="center">
                <template #default="{ row }">
                  <el-tag v-if="row.purgeable" type="warning" size="small" effect="plain">可清理</el-tag>
                  <el-tag v-else type="info" size="small" effect="plain">保留</el-tag>
                </template>
              </el-table-column>
              <el-table-column label="说明" min-width="320">
                <template #default="{ row }">
                  <span v-if="row.purgeable" style="color:#606266">{{ row.impact }}</span>
                  <span v-else style="color:#C0C4CC">{{ stripMd(row.why) }}</span>
                </template>
              </el-table-column>
              <template #empty><div class="empty-tip">正在体检…</div></template>
            </el-table>

            <!-- 保留类为什么不能清：单独一块强调，避免有人只看数字就点清理 -->
            <template v-if="orphanKeptRows.length">
              <div class="analysis-h" style="margin-top:18px">以下为什么建议不要清理</div>
              <el-alert v-for="r in orphanKeptRows" :key="r.key" type="info"
                        :closable="false" show-icon style="margin-bottom:8px">
                <template #title>
                  <b>{{ r.label }}</b>（{{ r.count }} 行）—— {{ stripMd(r.why) }}
                </template>
              </el-alert>
            </template>
          </el-card>
        </div>

        <div v-else-if="tab === 'settings'">
          <el-card style="margin-bottom:16px">
            <template #header>公司与好友模式（对全服务器生效，客户端登录页/扫描结果即时可见）</template>
            <el-form label-width="100px" style="max-width:640px">
              <el-form-item label="公司名称">
                <el-input v-model="compSetting.name" maxlength="20" show-word-limit
                  placeholder="如：盛京 —— 客户端显示为「盛京小智」，留空则只显示「小智 IM」" />
              </el-form-item>
              <el-form-item label="好友模式">
                <el-radio-group v-model="compSetting.mode">
                  <el-radio value="normal">普通好友模式</el-radio>
                  <el-radio value="work">工作模式</el-radio>
                </el-radio-group>
              </el-form-item>
              <el-form-item label="进价显示">
                <div>
                  <el-switch v-model="compSetting.showPurchasePrice"
                    active-text="商档查询显示进货价" inactive-text="不显示" />
                  <div class="hint" style="margin-top:4px">
                    开了之后，员工手机「商档查询」会显示<b>进货价</b>（进价是敏感数据，默认不给看）。
                    保存后在线手机<b>立即生效</b>，无需重装。
                  </div>
                </div>
              </el-form-item>
              <el-form-item label=" ">
                <el-alert :closable="false" :type="compSetting.mode === 'work' ? 'warning' : 'info'"
                  style="margin-bottom:12px">
                  <template #title>
                    <span v-if="compSetting.mode === 'work'">
                      工作模式：关闭自助注册与好友互加，员工由管理员在「组织机构」按工号录入（工号即账号、初始密码=工号），
                      录入后同事自动互为好友，搜索只能找到同组织的人。日常使用请配合组织机构功能。
                    </span>
                    <span v-else>
                      普通好友模式：任何人可自助注册，自由搜索、互加好友。适合个人/小团队自用。
                    </span>
                  </template>
                </el-alert>
                <el-button type="primary" :loading="compBusy" @click="saveCompSetting">保存设置</el-button>
              </el-form-item>
            </el-form>
          </el-card>

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
                  <el-descriptions-item label="文件存储">
                    <template v-if="!fdEdit">
                      <span style="word-break:break-all">{{ info.files_dir }}</span>
                      <el-tag v-if="info.files_dir_custom" type="warning" size="small" style="margin-left:6px">自定义</el-tag>
                      <el-button size="small" text type="primary" style="margin-left:6px" @click="fdStart">改</el-button>
                    </template>
                    <template v-else>
                      <div style="display:flex;gap:6px;width:100%">
                        <el-input v-model="fdValue" size="small" placeholder="留空 = 恢复默认（数据目录/files）" />
                        <el-button size="small" type="primary" :loading="fdBusy" @click="fdSave">保存</el-button>
                        <el-button size="small" @click="fdEdit = false">取消</el-button>
                      </div>
                      <div style="font-size:11px;color:#909399;margin-top:4px;line-height:1.5">
                        保存后需重启服务端生效；重启时会自动把旧目录里的文件搬到新目录（跨盘也能搬）。留空保存 = 恢复默认（文件自动搬回）。
                      </div>
                    </template>
                  </el-descriptions-item>
                  <el-descriptions-item label="磁盘占用">{{ fmtBytes(info.files_disk_bytes) }}</el-descriptions-item>
                  <el-descriptions-item label="单文件上限">{{ info.max_file_mb }} MB</el-descriptions-item>
                  <el-descriptions-item label="Node 版本">{{ info.node }}</el-descriptions-item>
                  <el-descriptions-item label="服务端版本">{{ info.version || '—' }}</el-descriptions-item>
                </el-descriptions>
              </el-card>
            </el-col>
          </el-row>

          <el-card style="margin-top:16px">
            <template #header>
              <div class="card-hdr">
                <span>音视频中继配置（跨网通话用）</span>
                <div>
                  <el-tag v-if="turn.sources && turn.sources.includes('cloudflare')" type="success" size="small">Cloudflare 已启用</el-tag>
                  <el-tag v-else-if="turn.ready" type="warning" size="small">仅自建中继</el-tag>
                  <el-tag v-else type="danger" size="small">未配置中继</el-tag>
                  <el-button size="small" style="margin-left:8px" @click="loadTurn">刷新</el-button>
                </div>
              </div>
            </template>

            <el-alert v-if="!turn.sources || !turn.sources.includes('cloudflare')" type="info" :closable="false" style="margin-bottom:14px">
              <template #title>
                没有配置中继时，<b>手机 4G/5G 打内网必定不通</b>（对称 NAT 打不了洞）。
                推荐下方向导填入 Cloudflare TURN —— <b>不需要信用卡、不需要端口映射</b>，全程免费。
                申请步骤见「系统帮助 → 五之二」。
              </template>
            </el-alert>

            <el-steps :active="turnStep" finish-status="success" align-center style="margin:6px 0 18px">
              <el-step title="填入凭据" description="从 Cloudflare 控制台复制" />
              <el-step title="校验并保存" description="服务端实测签发接口" />
              <el-step title="持久化生效" description="重建容器写入环境变量" />
            </el-steps>

            <div v-show="turnStep === 0">
              <el-form :model="turnForm" label-width="120px" style="max-width:620px">
                <el-form-item label="Turn 令牌 ID">
                  <el-input v-model="turnForm.key_id" placeholder="32 位十六进制字符" clearable />
                </el-form-item>
                <el-form-item label="API 令牌">
                  <el-input v-model="turnForm.api_token" type="password" show-password
                            placeholder="64 位十六进制，Cloudflare 只显示一次" clearable />
                  <div class="hint" style="margin-top:4px">
                    两个值都在 Cloudflare 控制台「媒体 → Realtime → TURN 服务器」创建后显示。
                  </div>
                </el-form-item>
                <el-form-item>
                  <el-button type="primary" :disabled="!turnForm.key_id || !turnForm.api_token" @click="verifyTurn">
                    校验并保存
                  </el-button>
                  <span v-if="turn.cloudflareEnabled" class="hint" style="margin-left:10px">
                    当前已配置：{{ turn.cloudflareKeyIdMasked }}
                  </span>
                </el-form-item>
              </el-form>
            </div>

            <div v-show="turnStep === 1">
              <el-result v-if="turnOk" icon="success" title="凭据有效，已保存并立即生效">
                <template #sub-title>
                  <p>服务端已实测通过 Cloudflare 签发接口，新配置<b>现在就已经在用了</b>。</p>
                  <p>配置文件：<code class="mono">{{ turnSaved.envPath }}</code></p>
                  <p v-if="turnSaved.backup">原文件已备份为 <code class="mono">{{ turnSaved.backup }}</code></p>
                </template>
              </el-result>
              <el-result v-else icon="error" title="校验未通过">
                <template #sub-title>
                  <p style="color:var(--el-color-danger)">{{ turnErr }}</p>
                  <p class="hint">请回上一步确认两个值复制完整、没有多余空格。<b>校验不通过时不会写入任何配置</b>，请放心重试。</p>
                </template>
              </el-result>
            </div>

            <div v-show="turnStep === 2">
              <el-alert v-if="turnSaved.needRecreate" type="warning" :closable="false" style="margin-bottom:12px">
                <template #title>
                  <b>最后一步：建议重建一次容器</b>（不是必须，但推荐）。
                  原因是环境变量在容器<b>创建时</b>烘入 —— 现在配置已经热加载生效了，
                  但不重建的话，<b>下次容器重启会退回旧的空值</b>。
                </template>
              </el-alert>
              <p>在 NAS 的终端里执行这条命令（已按你的目录生成）：</p>
              <div class="mono cmd-box">{{ turnSaved.command }}</div>
              <p class="hint">执行完点「刷新」，确认标签仍为「Cloudflare 已启用」即可。</p>
              <el-button type="primary" @click="loadTurn">刷新状态</el-button>
              <el-button @click="turnStep = 0">重新填写</el-button>
              <el-divider />
              <el-popconfirm title="确定移除 Cloudflare 中继配置？会退回 STUN + 自建中继。" @confirm="removeTurn">
                <template #reference>
                  <el-button type="danger" plain size="small">移除 Cloudflare 配置</el-button>
                </template>
              </el-popconfirm>
            </div>
          </el-card>

          <!-- 远程协助 · 默认控制码 -->
          <el-card style="margin-top:16px">
            <template #header>
              <div class="card-hdr">
                <span>远程协助 · 默认控制码（管理员远程维护用）</span>
                <el-button size="small" @click="loadRdc">刷新</el-button>
              </div>
            </template>

            <el-alert type="info" :closable="false" style="margin-bottom:14px">
              <template #title>
                管理员在客户端输入这把码，就能连上<b>被维护账号</b>那台机器，员工自己不必跑去点「生成访问码」。
                它<b>就是一枚普通访问码</b> —— 同样只存哈希、同样有 <b>10 秒撤销窗口</b>、同样受撞码限流；
                「默认」只表示<b>由管理台统一维护</b>，权限并不更大。
              </template>
            </el-alert>

            <el-form label-width="120px" style="max-width:680px">
              <el-form-item label="被维护的账号">
                <el-select v-model="rdcForm.hostId" filterable placeholder="选这台机器归谁（被控端）" style="width:360px">
                  <el-option v-for="u in userOptions" :key="u.id"
                    :label="`${u.username}（${u.nickname || '—'}）`" :value="u.id" />
                </el-select>
                <div class="hint">选的是<b>被控那台机器</b>的归属账号，不是管理员自己。</div>
              </el-form-item>
              <el-form-item label="备注">
                <el-input v-model="rdcForm.label" maxlength="60" placeholder="如：前台收银机 / 库房盘点机" style="width:360px" />
              </el-form-item>
              <el-form-item label="有效期">
                <el-radio-group v-model="rdcForm.ttlMinutes">
                  <el-radio :value="null">长期有效</el-radio>
                  <el-radio :value="1440">24 小时</el-radio>
                  <el-radio :value="43200">30 天</el-radio>
                </el-radio-group>
              </el-form-item>
              <el-form-item label=" ">
                <el-button type="primary" :loading="rdcBusy" @click="genRdc">
                  {{ rdc.code ? '换一把（旧码立刻失效）' : '生成默认控制码' }}
                </el-button>
                <el-button v-if="rdc.code" type="danger" plain :loading="rdcBusy" @click="clearRdc">吊销</el-button>
              </el-form-item>
            </el-form>

            <el-alert v-if="rdcNewCode" type="success" :closable="false" style="margin-bottom:14px">
              <template #title>
                <div>新控制码 —— <b>只显示这一次</b>，之后连管理台也查不到，请当场复制给管理员：</div>
                <div class="mono" style="font-size:22px;letter-spacing:4px;margin-top:6px">{{ rdcNewCode }}</div>
              </template>
            </el-alert>

            <el-descriptions v-if="rdc.code" :column="2" border size="small">
              <el-descriptions-item label="被维护账号">{{ rdc.code.hostName || rdc.code.hostId }}</el-descriptions-item>
              <el-descriptions-item label="备注">{{ rdc.code.label || '—' }}</el-descriptions-item>
              <el-descriptions-item label="状态">
                <el-tag v-if="rdc.code.revoked" type="danger" size="small">已吊销</el-tag>
                <el-tag v-else type="success" size="small">有效</el-tag>
              </el-descriptions-item>
              <el-descriptions-item label="有效期">{{ rdc.code.expiresAt ? fmtTime(rdc.code.expiresAt) : '长期' }}</el-descriptions-item>
              <el-descriptions-item label="已使用次数">{{ rdc.code.useCount }}</el-descriptions-item>
              <el-descriptions-item label="最近使用">{{ rdc.code.lastUsedAt ? fmtTime(rdc.code.lastUsedAt) : '—' }}</el-descriptions-item>
            </el-descriptions>
            <div v-else class="hint">还没设置默认控制码。</div>
          </el-card>
        </div>
      </el-main>
    </el-container>

        <!-- 批量清理确认（消息 / 文件 / 磁盘残留 共用；三步安全模型的第 2 步） -->
        <el-dialog v-model="orphanDlg" width="620px" title="清理孤儿数据">
          <el-alert type="warning" :closable="false" style="margin-bottom:14px">
            <template #title>
              <b>此操作会直接删除数据库里的行，不可恢复</b>（但会先自动导出备份到
              <code>purge-backup/</code>，万一删错了可以从那里捞回来）。
            </template>
          </el-alert>

          <div class="purge-box">
            <div class="purge-row">
              <span>将要删除</span>
              <b class="purge-num">{{ orphanDlgCount }}</b>
            </div>
            <div class="purge-row">
              <span>涉及关联</span>
              <b>{{ orphanDlgKeys.length }} 项</b>
            </div>
          </div>

          <el-table :data="orphanDlgItems" size="small" border style="margin:12px 0">
            <el-table-column prop="label" label="关联关系" min-width="180" show-overflow-tooltip />
            <el-table-column prop="count" label="行数" width="80" align="center" />
            <template #empty><div class="empty-tip">没有可清理的关联</div></template>
          </el-table>

          <el-alert type="error" :closable="false" style="margin:12px 0">
            <template #title>
              「消息→发送者」「审批单→提交人」「考勤/补卡」这些<b>不在清理范围内</b>
              —— 它们是产品刻意保留的历史数据（离职员工的消息、考勤、审批留痕），
              服务端也会拒绝清理这些类型。
            </template>
          </el-alert>

          <template v-if="orphanDlgConfirmed">
            <el-alert type="info" :closable="false" style="margin:12px 0">
              <template #title>已确认。点「确认清理」执行。</template>
            </el-alert>
          </template>
          <div v-else style="margin:12px 0">
            <div style="margin-bottom:6px;font-size:13px;color:#606266">
              请先勾选上面的确认框（防止手滑点掉）。
            </div>
            <el-checkbox v-model="orphanDlgAck">我已确认这些是废弃数据</el-checkbox>
          </div>

          <template #footer>
            <el-button @click="orphanDlg = false">取消</el-button>
            <el-button type="danger" :loading="orphanDlgBusy"
                       :disabled="!orphanDlgAck" @click="doOrphanPurge">确认清理</el-button>
          </template>
        </el-dialog>

        <el-dialog v-model="purgeDlg" width="640px" :title="purgeKind === 'messages' ? '批量清理消息' : (purgeKind === 'orphan' ? '清理磁盘残留文件' : '批量清理文件')">
          <div v-if="!purgePreview" style="padding:24px;text-align:center;color:#909399">统计中…</div>
          <div v-else>
            <el-alert type="warning" :closable="false" style="margin-bottom:14px">
              <template #title>
                <b>此操作不可恢复。</b>
                <span v-if="purgeKind === 'messages'">删除消息记录；其中不再被任何消息引用的文件会连磁盘文件一并删除。</span>
                <span v-else-if="purgeKind === 'orphan'">只删除磁盘上、数据库里没有记录的文件，不涉及任何消息。</span>
                <span v-else>文件会被删除，引用它的消息内容替换成「[文件已被管理员删除]」（与单条删除保持一致）。</span>
              </template>
            </el-alert>

            <div class="purge-box">
              <div class="purge-row"><span>命中条数</span><b class="purge-num">{{ purgePreview.count }}</b></div>
              <div v-if="purgePreview.bytes !== undefined" class="purge-row"><span>占用空间</span><b>{{ fmtBytes(purgePreview.bytes) }}</b></div>
              <div v-if="purgePreview.oldest" class="purge-row">
                <span>时间跨度</span><b>{{ fmtTime(purgePreview.oldest) }} ~ {{ fmtTime(purgePreview.newest) }}</b>
              </div>
              <div v-for="(s, i) in purgeScopeLines" :key="i" class="purge-row">
                <span>清理条件</span><b>{{ s }}</b>
              </div>
            </div>

            <el-alert v-if="purgePreview.tooMany" type="error" :closable="false" style="margin:12px 0">
              <template #title>
                超过单次上限 {{ purgePreview.limit }} 条，请收窄条件（比如缩短时间范围）后分批清理 —— 这是防止一条写宽的条件把整个库删掉。
              </template>
            </el-alert>
            <el-alert v-else-if="purgePreview.count === 0" type="info" :closable="false" style="margin:12px 0">
              <template #title>当前条件下没有数据，无需清理。</template>
            </el-alert>
            <div v-else style="margin:12px 0">
              <div style="margin-bottom:6px">
                为避免误删，请手工输入要清理的条数 <code class="mono">{{ purgePreview.count }}</code>：
              </div>
              <el-input v-model="purgeInput" placeholder="输入上面的数字" style="width:220px" />
              <div class="hint" style="margin-top:8px">
                服务端会重新统计一遍：若期间条数有变化（有人正在发消息）会拒绝执行并让你重新确认，而不是多删。
                执行前会自动导出一份 JSON 备份到服务器的 <code class="mono">purge-backup/</code>。
              </div>
            </div>
          </div>
          <template #footer>
            <el-button @click="purgeDlg = false">取消</el-button>
            <el-button type="danger" :loading="purgeBusy"
              :disabled="!purgePreview || purgePreview.count === 0 || purgePreview.tooMany"
              @click="doPurge">确认清理</el-button>
          </template>
        </el-dialog>

    <!-- 用户编辑向导：2 步（基本信息 / 密码） -->
    <el-dialog v-model="userDlg" :title="userForm.id ? '编辑用户' : '新建用户'" width="480px" @close="userStep=0">
      <el-steps :active="userStep" finish-status="success" simple style="margin-bottom:18px">
        <el-step title="基本信息" />
        <el-step title="密码" />
      </el-steps>
      <div v-show="userStep === 0">
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
        </el-form>
        <el-alert v-if="compSetting.mode === 'work' && !userForm.id" type="info" :closable="false">
          <template #title>
            工作模式：保存后该账号会<b>自动加入组织</b>（工号 = 账号、自动互为好友）。
            需要指定部门 / 岗位，请到「组织机构」录入或批量导入。
          </template>
        </el-alert>
      </div>
      <div v-show="userStep === 1">
        <el-form :model="userForm" label-width="80px">
          <el-form-item :label="userForm.id ? '重置密码' : '密码'">
            <el-input v-model="userForm.password" type="password" show-password
                      :placeholder="userForm.id ? '留空表示不修改' : '至少 6 位'" />
            <div class="hint" style="margin-top:4px">{{ userForm.id ? '编辑时留空表示不修改' : '密码至少 6 位，建议字母+数字组合' }}</div>
          </el-form-item>
        </el-form>
      </div>
      <template #footer>
        <el-button v-if="userStep > 0" @click="userStep--">上一步</el-button>
        <el-button v-if="userStep < 1" type="primary" @click="userStep++">下一步</el-button>
        <el-button v-if="userStep === 1" type="primary" :loading="userDlgBusy" @click="saveUser">保存</el-button>
        <el-button v-if="userStep === 0" @click="userDlg = false">取消</el-button>
      </template>
    </el-dialog>

    <!-- 群组编辑向导：2 步（基本信息 / 成员） -->
    <el-dialog v-model="groupDlg" :title="groupForm.id ? '编辑群组' : '新建群组'" width="560px" @close="groupStep=0">
      <el-steps :active="groupStep" finish-status="success" simple style="margin-bottom:18px">
        <el-step title="基本信息" />
        <el-step title="成员" />
      </el-steps>
      <div v-show="groupStep === 0">
        <el-form :model="groupForm" label-width="90px">
          <el-form-item label="群名">
            <el-input v-model="groupForm.name" placeholder="群组名称" />
          </el-form-item>
          <el-form-item label="群主">
            <el-select v-model="groupForm.owner_id" filterable placeholder="选择群主" style="width:100%">
              <el-option v-for="u in userOptions" :key="u.id" :label="`${u.username} (${u.nickname || ''})`" :value="u.id" />
            </el-select>
          </el-form-item>
        </el-form>
      </div>
      <div v-show="groupStep === 1">
        <el-form :model="groupForm" label-width="90px">
          <el-form-item label="成员">
            <el-select v-model="groupForm.member_ids" multiple filterable collapse-tags collapse-tags-tooltip
                       placeholder="选择成员（可多选）" style="width:100%">
              <el-option v-for="u in userOptions" :key="u.id" :label="`${u.username} (${u.nickname || ''})`" :value="u.id" />
            </el-select>
            <div class="hint" style="margin-top:6px">
              * 创建时群主自动加入成员列表；编辑时改动成员会同步会话成员。
            </div>
          </el-form-item>
        </el-form>
      </div>
      <template #footer>
        <el-button v-if="groupStep > 0" @click="groupStep--">上一步</el-button>
        <el-button v-if="groupStep < 1" type="primary" @click="groupStep++">下一步</el-button>
        <el-button v-if="groupStep === 1" type="primary" :loading="groupDlgBusy" @click="saveGroup">保存</el-button>
        <el-button v-if="groupStep === 0" @click="groupDlg = false">取消</el-button>
      </template>
    </el-dialog>

    <!-- 机器人向导：新建 2 步（名称 / 可选加入会话）；编辑 = 只改名 -->
    <el-dialog v-model="botDlg" :title="botForm.id ? '编辑机器人' : '新建机器人'" width="520px" @close="botStep=0">
      <el-steps :active="botStep" finish-status="success" simple style="margin-bottom:18px">
        <el-step title="名称" />
        <el-step v-if="!botForm.id" title="加入会话（可选）" />
      </el-steps>
      <div v-show="botStep === 0">
        <el-alert type="info" :closable="false" style="margin-bottom:14px">
          <template #title>
            <template v-if="botForm.id">改名立即生效，已发的消息、令牌、推送地址都不受影响；机器人账号（bot_xxx）创建后不可改。</template>
            <template v-else>机器人是「系统的发言人」：它不能登录、不能冒充真人，只能靠 Webhook / API 令牌替外部系统说话。给它起个一看就懂的名字，如「库存预警」「泰格日报」。</template>
          </template>
        </el-alert>
        <el-form :model="botForm" label-width="100px">
          <el-form-item label="名称">
            <el-input v-model="botForm.name" placeholder="如：工厂助手、库存预警" maxlength="32" show-word-limit />
          </el-form-item>
        </el-form>
      </div>
      <div v-show="botStep === 1">
        <el-alert type="info" :closable="false" style="margin-bottom:14px">
          <template #title>
            这一步决定机器人「站在哪个群里说话」。也可以先跳过，之后在列表里点「加入会话」，或建推送地址时自动把它拉进目标会话。
          </template>
        </el-alert>
        <el-form :model="botForm" label-width="100px">
          <el-form-item label="加入会话">
            <el-select v-model="botForm.conversationId" filterable clearable placeholder="可稍后再加（选填）" style="width:100%">
              <el-option v-for="c in intMeta.conversations" :key="c.id"
                         :label="`${c.type === 'group' ? '群' : '单聊'}｜${c.title || ('#' + c.id)}（${c.members}人）`"
                         :value="c.id" />
            </el-select>
          </el-form-item>
          <p class="hint" style="margin:0 0 0 100px">机器人创建后无法登录，只能通过 Webhook / API 令牌发言。</p>
        </el-form>
      </div>
      <template #footer>
        <el-button v-if="botStep > 0" @click="botStep--">上一步</el-button>
        <el-button v-if="botStep < 1 && !botForm.id" type="primary" @click="botStep++">下一步</el-button>
        <el-button v-if="botStep === 1 || botForm.id" type="primary" :loading="busy" @click="saveBot">{{ botForm.id ? '保存' : '创建' }}</el-button>
        <el-button v-if="botStep === 0" @click="botDlg = false">取消</el-button>
      </template>
    </el-dialog>

    <!-- 机器人加入会话向导：1 步 -->
    <el-dialog v-model="botConvDlg" :title="`把「${botConvForm.name}」加入会话`" width="520px" @close="botConvStep=0">
      <el-steps :active="botConvStep" finish-status="success" simple style="margin-bottom:18px">
        <el-step title="选择会话" />
      </el-steps>
      <div v-show="botConvStep === 0">
        <el-select v-model="botConvForm.conversationId" filterable placeholder="选择会话" style="width:100%">
          <el-option v-for="c in intMeta.conversations" :key="c.id"
                     :label="`${c.type === 'group' ? '群' : '单聊'}｜${c.title || ('#' + c.id)}（${c.members}人）`"
                     :value="c.id" />
        </el-select>
      </div>
      <template #footer>
        <el-button @click="botConvDlg = false">取消</el-button>
        <el-button type="primary" :loading="busy" @click="saveBotConv">加入</el-button>
      </template>
    </el-dialog>

    <!-- 令牌发放向导：3 步（基本信息 / 权限 / 完成） -->
    <el-dialog v-model="tokenDlg" title="发放 API 令牌" width="600px" @close="tokenStep=0">
      <el-steps :active="tokenStep" finish-status="success" simple style="margin-bottom:18px">
        <el-step title="基本信息" />
        <el-step title="权限" />
        <el-step title="完成" />
      </el-steps>
      <div v-show="tokenStep === 0">
        <el-alert type="info" :closable="false" style="margin-bottom:14px">
          <template #title>
            API 令牌给「程序」用：对方拿着它就能以你选的身份调开放接口。先想清楚给谁用、以谁的身份行事 —— 一般选一个<b>机器人</b>，而不是真人。
          </template>
        </el-alert>
        <el-form :model="tokenForm" label-width="100px">
          <el-form-item label="用途">
            <el-input v-model="tokenForm.name" placeholder="如：工厂V2、门店报表脚本" maxlength="64" />
          </el-form-item>
          <el-form-item label="身份">
            <el-select v-model="tokenForm.userId" filterable placeholder="以谁的身份行事" style="width:100%">
              <el-option v-for="u in identityOptions" :key="u.id"
                         :label="`${u.is_bot ? '🤖 ' : ''}${u.nickname || u.username}（${u.username}）`" :value="u.id" />
            </el-select>
          </el-form-item>
        </el-form>
      </div>
      <div v-show="tokenStep === 1">
        <el-alert type="info" :closable="false" style="margin-bottom:14px">
          <template #title>
            权限按<b>最小够用</b>勾：只发消息就只勾 message:send。令牌泄露时，权限越小损失越小；有效期同理，长期任务才选「永不过期」。
          </template>
        </el-alert>
        <el-form :model="tokenForm" label-width="100px">
          <el-form-item label="权限">
            <el-checkbox-group v-model="tokenForm.scopes">
              <el-checkbox v-for="s in intMeta.scopes" :key="s.name" :value="s.name" style="display:block;margin:2px 0">
                <code class="mono">{{ s.name }}</code> — {{ s.desc }}
              </el-checkbox>
            </el-checkbox-group>
          </el-form-item>
          <el-form-item label="有效期">
            <el-input-number v-model="tokenForm.days" :min="0" :max="3650" />
            <span class="hint" style="margin-left:8px">天（0 = 永不过期）</span>
          </el-form-item>
        </el-form>
      </div>
      <div v-show="tokenStep === 2" v-if="newToken">
        <el-result icon="success" title="令牌已生成">
          <template #sub-title>
            <div style="text-align:left;margin-top:6px">
              <p><b>只显示这一次</b>，请立刻复制保存：</p>
              <p><code class="mono" style="word-break:break-all">{{ newToken }}</code></p>
              <el-button size="small" type="primary" @click="copy(newToken)">复制令牌</el-button>
            </div>
          </template>
        </el-result>
      </div>
      <template #footer>
        <el-button v-if="tokenStep > 0 && tokenStep < 2" @click="tokenStep--">上一步</el-button>
        <el-button v-if="tokenStep === 0" type="primary" @click="tokenStep++">下一步</el-button>
        <el-button v-if="tokenStep === 1" type="primary" :loading="busy" @click="saveToken">生成令牌</el-button>
        <el-button v-if="tokenStep === 2" type="primary" @click="tokenDlg = false">完成</el-button>
        <el-button v-if="tokenStep === 0" @click="tokenDlg = false">取消</el-button>
      </template>
    </el-dialog>

    <!-- 签名客户端：发放凭据（2 步 + 只显示一次的 secret） -->
    <el-dialog v-model="clientDlg" title="发放签名凭据" width="640px" @close="clientStep=0">
      <el-steps :active="clientStep" finish-status="success" simple style="margin-bottom:18px">
        <el-step title="基本信息" />
        <el-step title="权限" />
        <el-step title="完成" />
      </el-steps>
      <div v-show="clientStep === 0">
        <el-alert type="info" :closable="false" style="margin-bottom:14px">
          <template #title>
            签名客户端和 API 令牌的区别：令牌是<b>能直接抄走的长期密码</b>，签名是每次请求现算、
            带±5 分钟时间窗和一次性随机数 —— 对接方技术能力强、或推送走公网时优先用这种。
          </template>
        </el-alert>
        <el-form :model="clientForm" label-width="100px">
          <el-form-item label="用途">
            <el-input v-model="clientForm.name" placeholder="如：门店盘点回传、工厂V2 告警" maxlength="64" />
          </el-form-item>
          <el-form-item label="身份">
            <el-select v-model="clientForm.userId" filterable placeholder="以谁的身份行事" style="width:100%">
              <el-option v-for="u in identityOptions" :key="u.id"
                         :label="`${u.is_bot ? '🤖 ' : ''}${u.nickname || u.username}（${u.username}）`" :value="u.id" />
            </el-select>
          </el-form-item>
        </el-form>
      </div>
      <div v-show="clientStep === 1">
        <el-alert type="info" :closable="false" style="margin-bottom:14px">
          <template #title>
            权限按<b>最小够用</b>勾。app_secret 下一页只显示一次，关掉就找不回（库里只有密文），对方要先准备好保存的地方再点「生成凭据」。
          </template>
        </el-alert>
        <el-form :model="clientForm" label-width="100px">
          <el-form-item label="权限">
            <el-checkbox-group v-model="clientForm.scopes">
              <el-checkbox v-for="s in intMeta.scopes" :key="s.name" :value="s.name" style="display:block;margin:2px 0">
                <code class="mono">{{ s.name }}</code> — {{ s.desc }}
              </el-checkbox>
            </el-checkbox-group>
          </el-form-item>
        </el-form>
      </div>
      <div v-show="clientStep === 2" v-if="newClient">
        <el-result icon="success" title="凭据已生成">
          <template #sub-title>
            <div style="text-align:left;margin-top:6px">
              <p><b>app_secret 只显示这一次</b>，关掉就再也找不回来（库里只存密文），请立刻复制保存：</p>
              <p>app_id：<code class="mono" style="word-break:break-all">{{ newClient.appId }}</code></p>
              <p>app_secret：<code class="mono" style="word-break:break-all">{{ newClient.secret }}</code></p>
              <el-button size="small" type="primary" @click="copy(`app_id: ${newClient.appId}\napp_secret: ${newClient.secret}`)">复制这一对</el-button>
            </div>
          </template>
        </el-result>
      </div>
      <template #footer>
        <el-button v-if="clientStep === 1" @click="clientStep--">上一步</el-button>
        <el-button v-if="clientStep === 0" type="primary" @click="clientStep++">下一步</el-button>
        <el-button v-if="clientStep === 1" type="primary" :loading="busy" @click="saveClient">生成凭据</el-button>
        <el-button v-if="clientStep === 2" type="primary" @click="clientDlg = false">完成</el-button>
        <el-button v-if="clientStep === 0" @click="clientDlg = false">取消</el-button>
      </template>
    </el-dialog>

    <!-- 签名客户端：轮换后的新密钥（同样只显示一次） -->
    <el-dialog v-model="rotateDlg" title="新的 app_secret" width="560px">
      <el-alert type="warning" :closable="false" style="margin-bottom:12px">
        <template #title>
          旧密钥还有 <b>24 小时</b>宽限期，之后自动失效 —— 照这个时间给对接方改配置。
        </template>
      </el-alert>
      <p>app_id：<code class="mono">{{ rotatedSecret.appId }}</code></p>
      <p>app_secret：<code class="mono" style="word-break:break-all">{{ rotatedSecret.secret }}</code></p>
      <template #footer>
        <el-button @click="rotateDlg = false">关闭</el-button>
        <el-button type="primary" @click="copy(rotatedSecret.secret)">复制</el-button>
      </template>
    </el-dialog>

    <!-- 入站推送向导：新建 2 步（用途 / 目标）；编辑 = 改名/换机器人/换会话/开关签名 -->
    <el-dialog v-model="incomingDlg" :title="incomingForm.id ? '编辑推送地址' : '新建推送地址'" width="560px" @close="incomingStep=0">
      <el-steps :active="incomingStep" finish-status="success" simple style="margin-bottom:18px">
        <el-step title="用途" />
        <el-step title="目标" />
      </el-steps>
      <div v-show="incomingStep === 0">
        <el-alert type="info" :closable="false" style="margin-bottom:14px">
          <template #title>
            <template v-if="incomingForm.id">编辑只改「谁发言、推到哪」，<b>推送地址（token）不变</b>，对接方什么都不用改。</template>
            <template v-else>「用途」写清楚是谁在推（如：库存预警、销售日报、泰格 POS），以后列表里靠它认；机器人是这条推送的「发言身份」，群里看到的消息来自它。</template>
          </template>
        </el-alert>
        <el-form :model="incomingForm" label-width="100px">
          <el-form-item label="用途">
            <el-input v-model="incomingForm.name" placeholder="如：库存预警、销售日报" maxlength="64" />
          </el-form-item>
          <el-form-item label="机器人">
            <el-select v-model="incomingForm.botId" filterable placeholder="以哪个机器人身份发言" style="width:100%">
              <el-option v-for="b in bots" :key="b.id" :label="`${b.nickname}（${b.username}）`" :value="b.id" />
            </el-select>
          </el-form-item>
        </el-form>
      </div>
      <div v-show="incomingStep === 1">
        <el-alert type="info" :closable="false" style="margin-bottom:14px">
          <template #title>
            <template v-if="incomingForm.id">换目标会话时，机器人会被自动拉进新会话；关掉签名校验会让「外泄的地址谁都能推」，一般保持开启前的状态不动。</template>
            <template v-else>签名校验是可选保险：开启后对方每次请求都要算 HMAC 签名 —— 但绝大多数第三方系统只会自家的签名，开了它们就推不进来，<b>默认关</b>，安全性靠「地址即凭证 + 随时停用」兜底。</template>
          </template>
        </el-alert>
        <el-form :model="incomingForm" label-width="100px">
          <el-form-item label="推到会话">
            <el-select v-model="incomingForm.conversationId" filterable placeholder="选择群或单聊" style="width:100%">
              <el-option v-for="c in intMeta.conversations" :key="c.id"
                         :label="`${c.type === 'group' ? '群' : '单聊'}｜${c.title || ('#' + c.id)}（${c.members}人）`"
                         :value="c.id" />
            </el-select>
          </el-form-item>
          <el-form-item label="签名校验">
            <el-switch v-model="incomingForm.signed" />
            <span class="hint" style="margin-left:10px">开启后请求必须带 HMAC-SHA256 签名，地址外泄也无法被冒用</span>
          </el-form-item>
        </el-form>
      </div>
      <template #footer>
        <el-button v-if="incomingStep > 0" @click="incomingStep--">上一步</el-button>
        <el-button v-if="incomingStep < 1" type="primary" @click="incomingStep++">下一步</el-button>
        <el-button v-if="incomingStep === 1" type="primary" :loading="busy" @click="saveIncoming">{{ incomingForm.id ? '保存' : '创建' }}</el-button>
        <el-button v-if="incomingStep === 0" @click="incomingDlg = false">取消</el-button>
      </template>
    </el-dialog>

    <!-- 出站事件订阅向导：新建 3 步（基本信息 / 事件+范围 / 完成）；编辑 = 前 2 步 -->
    <el-dialog v-model="outgoingDlg" :title="outgoingForm.id ? '编辑事件订阅' : '新建事件订阅'" width="600px" @close="outgoingStep=0; outgoingSecret=''">
      <el-steps :active="outgoingStep" finish-status="success" simple style="margin-bottom:18px">
        <el-step title="基本信息" />
        <el-step title="事件" />
        <el-step v-if="!outgoingForm.id" title="完成" />
      </el-steps>
      <div v-show="outgoingStep === 0">
        <el-alert type="info" :closable="false" style="margin-bottom:14px">
          <template #title>
            <template v-if="outgoingForm.id">改地址/改用途立即生效，签名密钥不变（要换密钥在列表里点「换密钥」）。</template>
            <template v-else>「事件订阅」是反方向的对接：群里有新消息、有人被 @、成员变动时，IM 主动把事件 POST 到你填的地址（带 HMAC 签名防伪造）。适合做同步、做机器人指令。</template>
          </template>
        </el-alert>
        <el-form :model="outgoingForm" label-width="100px">
          <el-form-item label="用途">
            <el-input v-model="outgoingForm.name" placeholder="如：工厂V2 回调" maxlength="64" />
          </el-form-item>
          <el-form-item label="回调地址">
            <el-input v-model="outgoingForm.url" placeholder="https://你的系统/api/xiaozhi/hook" />
          </el-form-item>
        </el-form>
      </div>
      <div v-show="outgoingStep === 1">
        <el-alert type="info" :closable="false" style="margin-bottom:14px">
          <template #title>
            只勾你用得上的事件 —— 全订阅意味着群里每条消息都会打到你的系统，量大时容易把对方接口压垮。限定范围同理。
          </template>
        </el-alert>
        <el-form :model="outgoingForm" label-width="100px">
          <el-form-item label="订阅事件">
            <el-checkbox-group v-model="outgoingForm.events">
              <el-checkbox v-for="e in intMeta.events" :key="e.name" :value="e.name" style="display:block;margin:2px 0">
                <code class="mono">{{ e.name }}</code> — {{ e.desc }}
              </el-checkbox>
            </el-checkbox-group>
            <span class="hint">一个都不勾 = 订阅全部事件</span>
          </el-form-item>
          <el-form-item label="监听范围">
            <el-select v-model="outgoingForm.conversationId" filterable clearable placeholder="全部会话" style="width:100%">
              <el-option v-for="c in intMeta.conversations" :key="c.id"
                         :label="`${c.type === 'group' ? '群' : '单聊'}｜${c.title || ('#' + c.id)}（${c.members}人）`"
                         :value="c.id" />
            </el-select>
          </el-form-item>
        </el-form>
      </div>
      <div v-show="outgoingStep === 2 && !outgoingForm.id" v-if="outgoingSecret">
        <el-result icon="success" title="订阅已创建">
          <template #sub-title>
            <div style="text-align:left;margin-top:6px">
              <p>请求头会带 <code class="mono">X-Xiaozhi-Signature: sha256=&lt;HMAC(body, secret)&gt;</code>，用下方密钥验签：</p>
              <p><b>签名密钥</b>：<code class="mono" style="word-break:break-all">{{ outgoingSecret }}</code></p>
              <el-button size="small" type="primary" @click="copy(outgoingSecret)">复制密钥</el-button>
              <p class="hint" style="margin-top:8px">密钥只在创建时显示一次，请立刻保存；后续可在列表里点「换密钥」重新生成。</p>
            </div>
          </template>
        </el-result>
      </div>
      <template #footer>
        <el-button v-if="outgoingStep > 0" @click="outgoingStep--">上一步</el-button>
        <el-button v-if="outgoingStep < 1" type="primary" @click="outgoingStep++">下一步</el-button>
        <el-button v-if="outgoingStep === 1" type="primary" :loading="busy" @click="saveOutgoing">{{ outgoingForm.id ? '保存' : '创建' }}</el-button>
        <el-button v-if="outgoingStep === 2" type="primary" @click="outgoingDlg = false">完成</el-button>
        <el-button v-if="outgoingStep === 0" @click="outgoingDlg = false">取消</el-button>
      </template>
    </el-dialog>

    <!-- 公钥接入向导：3 步（用途 → 粘贴公钥 → 完成） -->
    <el-dialog v-model="pubkeyDlg" :title="pubkeyStep === 2 ? '公钥已添加' : '添加公钥'" width="640px" @close="closePubkeyDialog">
      <el-steps :active="pubkeyStep" finish-status="success" simple style="margin-bottom:18px">
        <el-step title="用途" />
        <el-step title="粘贴公钥" />
        <el-step title="完成" />
      </el-steps>
      <div v-show="pubkeyStep === 0">
        <el-alert type="info" :closable="false" style="margin-bottom:14px">
          <template #title>
            公钥接入是最安全的一档：对方用<b>私钥</b>签名请求，私钥永远不离开对方机器；你这里只存公钥，泄露了也只影响这一个对接点。先生成密钥对，再回来贴公钥。
          </template>
        </el-alert>
        <el-form label-width="80px">
          <el-form-item label="用途名">
            <el-input v-model="pubkeyForm.name" placeholder="如：工厂V2 库存预警" maxlength="64" show-word-limit />
            <div class="hint" style="margin-top:4px">给你自己看的标识，不会出现在调用里</div>
          </el-form-item>
        </el-form>
      </div>
      <div v-show="pubkeyStep === 1">
        <el-alert type="info" :closable="false" style="margin-bottom:14px">
          <template #title>
            贴<b>公钥</b>（BEGIN PUBLIC KEY），不是私钥 —— 私钥贴进来等于把大门钥匙挂到门口。
          </template>
        </el-alert>
        <el-form label-width="100px">
          <el-form-item label="公钥">
            <el-input v-model="pubkeyForm.publicKey" type="textarea" :rows="10"
                      placeholder="-----BEGIN PUBLIC KEY-----&#10;...&#10;-----END PUBLIC KEY-----" />
            <div class="hint" style="margin-top:4px">支持 RSA / 椭圆曲线 P-256（PEM 格式）</div>
          </el-form-item>
        </el-form>
      </div>
      <div v-show="pubkeyStep === 2" v-if="pubkeyCreated">
        <el-result icon="success" title="公钥已成功添加">
          <template #sub-title>
            <div style="text-align:left;margin-top:6px">
              <p>用途：<b>{{ pubkeyCreated.name }}</b></p>
              <p>公钥 ID：<code class="mono">{{ pubkeyCreated.key_id }}</code>（调用时用作 URL 路径）</p>
              <p>算法：<code class="mono">{{ pubkeyCreated.algorithm }}</code></p>
              <p>指纹：<code class="mono">{{ pubkeyCreated.fingerprint }}</code></p>
            </div>
          </template>
        </el-result>
      </div>
      <template #footer>
        <el-button v-if="pubkeyStep > 0 && pubkeyStep < 2" @click="pubkeyStep--">上一步</el-button>
        <el-button v-if="pubkeyStep === 0" type="primary" @click="savePubkey">下一步</el-button>
        <el-button v-if="pubkeyStep === 1" type="primary" :loading="busy" @click="savePubkey">提交</el-button>
        <el-button v-if="pubkeyStep === 2" type="primary" @click="closePubkeyDialog">完成</el-button>
        <el-button v-if="pubkeyStep === 0" @click="closePubkeyDialog">取消</el-button>
      </template>
    </el-dialog>

    <!-- 公钥验签测试 -->
    <el-dialog v-model="pubkeyTestDlg" :title="`验签测试 — ${pubkeyTestForm.name}`" width="640px">
      <el-alert type="info" :closable="false" style="margin-bottom:12px">
        <template #title>
          把你用<b>私钥签过的 body 原文</b>和<b>base64 编码的签名</b>粘到下面，IM 立即用你提交的公钥验签。
          算法默认 <code class="mono">{{ pubkeyTestForm.algorithm }}</code>。
        </template>
      </el-alert>
      <el-form label-width="80px">
        <el-form-item label="body">
          <el-input v-model="pubkeyTestForm.body" type="textarea" :rows="6" placeholder="原文" />
        </el-form-item>
        <el-form-item label="signature">
          <el-input v-model="pubkeyTestForm.signature" placeholder="base64 字符串" />
        </el-form-item>
      </el-form>
      <el-alert v-if="pubkeyTestForm.result" :type="pubkeyTestForm.result.ok ? 'success' : 'error'" :closable="false">
        <template #title>
          {{ pubkeyTestForm.result.ok ? '✅ 验签通过' : '❌ ' + (pubkeyTestForm.result.error || '验签失败') }}
        </template>
      </el-alert>
      <template #footer>
        <el-button @click="pubkeyTestDlg = false">关闭</el-button>
        <el-button type="primary" :loading="busy" @click="runPubkeyTest">验签</el-button>
      </template>
    </el-dialog>

    <!-- 泰格 POS 日报对接向导：3 步（选会话 / 开通 / 对接说明） -->
    <el-dialog v-model="tigerDlg" title="泰格 POS 日报对接" width="680px" @close="tigerStep=0">
      <el-steps :active="tigerStep" finish-status="success" simple style="margin-bottom:18px">
        <el-step title="推到哪" />
        <el-step title="一键开通" />
        <el-step title="对接说明" />
      </el-steps>

      <!-- 第 1 步：选目标会话 -->
      <div v-show="tigerStep === 0">
        <el-alert type="warning" :closable="false" style="margin-bottom:14px">
          <template #title>
            日报推到<b>群</b>里。选之前先确认：目标群里<b>有真人</b>（只有机器人自己 = 天天推、天天没人看）。
            不确定就先去「群组」页看一眼成员。
          </template>
        </el-alert>
        <el-alert v-if="tigerExisting" type="info" :closable="false" style="margin-bottom:14px">
          <template #title>
            检测到已有对接：{{ tigerExisting.url }}（当前推到「{{ tigerExisting.conversation }}」）。
            直接改下面的会话再点「开通」即可改指向（地址不变）；或
            <el-button size="small" text type="primary" @click="tigerEditExisting">去列表编辑/停用</el-button>
          </template>
        </el-alert>
        <el-form label-width="110px">
          <el-form-item label="推到会话">
            <el-select v-model="tigerForm.conversationId" filterable placeholder="选择日报要进的群" style="width:100%">
              <el-option v-for="c in intMeta.conversations" :key="c.id"
                         :label="`${c.type === 'group' ? '群' : '单聊'}｜${c.title || ('#' + c.id)}（${c.members}人）`"
                         :value="c.id" />
            </el-select>
          </el-form-item>
          <el-form-item label="会建什么">
            <div class="hint" style="line-height:1.9">
              ① 机器人「泰格日报」（已存在就复用，不会重复建）<br />
              ② 推送地址「{{ TIGER_HOOK_NAME }}」（同名已存在则改指向，地址不变）<br />
              ③ 机器人自动进你选的群
            </div>
          </el-form-item>
        </el-form>
      </div>

      <!-- 第 2 步：开通结果 + 地址 -->
      <div v-show="tigerStep === 1">
        <el-result icon="success" :title="tigerResult?.reused ? '对接已更新' : '对接已开通'">
          <template #sub-title>
            <div style="text-align:left;margin-top:6px">
              <p>机器人「{{ tigerResult?.botName }}」已在群里就位。下面这个地址就是<b>tiger-bridge（POS 机上的采集程序）</b>要推送的目标：</p>
              <p><code class="mono" style="word-break:break-all">{{ tigerResult?.url }}</code>
                <el-button size="small" type="primary" text @click="copy(tigerResult?.url)">复制</el-button></p>
              <p>
                <el-button size="small" @click="tigerTestPush">推一张样例日报看看</el-button>
                <span class="hint" style="margin-left:8px">收到 = 链路通了，剩下的只是把 tiger-bridge 指到这个地址</span>
              </p>
            </div>
          </template>
        </el-result>
      </div>

      <!-- 第 3 步：对接说明 -->
      <div v-show="tigerStep === 2">
        <el-alert type="info" :closable="false" style="margin-bottom:12px">
          <template #title>
            tiger-bridge 已跑在 POS 机上（Node 只读取数）。下面是它对接这套地址时的<b>配置方法与必踩坑</b>，改配置后要重启采集程序生效。
          </template>
        </el-alert>
        <el-descriptions :column="1" border size="small" style="margin-bottom:12px">
          <el-descriptions-item label="推送目标">第 2 步复制的地址（POST，JSON）</el-descriptions-item>
          <el-descriptions-item label="取数口径">只读官方视图 pos_v_income_day / v_realtime_stock；价格用 uf_get_itemprice；绝不直写泰格业务表</el-descriptions-item>
          <el-descriptions-item label="对账">tiger-bridge 自带熔断：与自己合计不一致时 exit 2 且不推（宁可不报，不报错的错数）</el-descriptions-item>
          <el-descriptions-item label="日报内容">蓝卡片：销售额 / 客数 / 客单价 + 与官方日结的对账结论</el-descriptions-item>
        </el-descriptions>
        <el-collapse>
          <el-collapse-item title="报文样例（tiger-bridge 推的就是这种形状）">
            <pre class="mono" style="margin:0;padding:10px;background:var(--el-fill-color-light);border-radius:6px;overflow:auto">{
  "title": "门店日报 · 09-17",
  "text": "销售额 ¥40,123.45 · 客数 356 笔 · 客单价 ¥112.76\n毛利率 22.4%（口径：净销售额-成本，成本=out_qty×进价）",
  "color": "blue",
  "fields": [
    {"label": "销售额", "value": "¥40,123.45", "short": true},
    {"label": "客数", "value": "356", "short": true},
    {"label": "客单价", "value": "¥112.76", "short": true},
    {"label": "毛利率", "value": "22.4%", "short": true}
  ],
  "footer": "tiger-bridge · 泰格 POS 数据对接"
}</pre>
            <div class="hint" style="margin-top:6px">
              🔴 title / text / footer / fields[].value <b>必须是字符串</b> —— 传对象会得到
              200 成功 + 群里一条 <code class="mono">[object Object]</code>（假成功）。
              推完必须回读消息确认内容，别只看状态码。
            </div>
          </el-collapse-item>
          <el-collapse-item title="四条必踩坑（tiger-bridge 侧）">
            <ol style="margin:0;padding-left:18px;line-height:2">
              <li>地址前缀是 <code class="mono">/api/hooks/incoming/&lt;token&gt;</code> —— 漏 <code class="mono">/api</code> 会 404。</li>
              <li>签名校验保持<b>关</b>：tiger-bridge 不会算 IM 的 HMAC，开了必 401。</li>
              <li>日期参数传<b>本地时间字符串</b>（<code class="mono">2026-09-17 00:00:00</code>），绝不能传 JS Date —— UTC 转换会静默丢掉下午 4 点后的营业额。</li>
              <li>库存看 <code class="mono">v_realtime_stock</code>，别直接查 <code class="mono">wh_stock</code>（那是永不动的账面数）。</li>
            </ol>
          </el-collapse-item>
        </el-collapse>
        <p class="hint" style="margin-top:10px">
          以后要换群 / 换机器人 / 停用：去「入站推送」列表点「{{ TIGER_HOOK_NAME }}」的「编辑」—— 地址不变，对接方零改动。
        </p>
      </div>

      <template #footer>
        <el-button v-if="tigerStep > 0" @click="tigerStep--">上一步</el-button>
        <el-button v-if="tigerStep === 0" type="primary" :loading="tigerBusy" @click="runTigerSetup">
          {{ tigerExisting ? '改指向并开通' : '一键开通' }}
        </el-button>
        <el-button v-if="tigerStep === 1" type="primary" @click="tigerStep = 2">下一步：对接说明</el-button>
        <el-button v-if="tigerStep === 2" type="primary" @click="tigerDlg = false">完成</el-button>
        <el-button v-if="tigerStep === 0" @click="tigerDlg = false">取消</el-button>
      </template>
    </el-dialog>
  </el-container>
</template>

<script setup>
import { ref, reactive, computed, onMounted, watch, h } from 'vue';
import { ElMessage, ElMessageBox, ElPagination } from 'element-plus';
// 侧栏分类标题的图标。照工厂管理系统 V2 的做法：**只有一级分类标题带图标，
// 二级叶项纯文字** —— 叶项加图标会让 19 行的小图标互相打架，反而更难扫读。
import { Odometer, User, Calendar, Connection, Goods, Setting } from '@element-plus/icons-vue';
import api from './api';

const token = ref(localStorage.getItem('xz_token') || '');
// 品牌名：只依赖 pub（bootstrap 的公开字段，登录前就能拿到）。
// ⚠️ 这里不能引用 compSetting —— 它在文件后面才声明，而下面的 watch 是 immediate，
// setup 阶段就会求值，会踩 TDZ 直接白屏。登录成功后由 loadAll 把公司名回写进 pub。
const pub = ref({});
const brand = computed(() => (pub.value.companyName ? pub.value.companyName + '小智' : '小智 IM'));
const form = ref({ username: '', password: '' });
const loading = ref(false);
const err = ref('');
// 首次运行向导：这台服务器还没人给管理台设过密码时，先显示设置页而不是登录页。
// 判定由服务端做（server/src/setup.js）—— 界面不自己猜，只照办。
const needSetup = ref(false);
const setupForm = ref({ username: 'admin', password: '', confirm: '' });
// 与安装程序 (init-env.js) 和服务端 (setup.js) 用同一套字符集：
// 这串密码要写进 data\.env，再被 cmd 的 for /f 读出来，空格/引号/=/# 都会出事。
const PW_RE = /^[A-Za-z0-9._@!*+?-]{6,64}$/;
const tab = ref('dashboard');
const stats = ref({});
const info = ref({});

/* ====== 侧栏菜单：分类折叠（对齐工厂管理系统 V2 的菜单逻辑）======
   原来 19 个菜单项平铺，实测总高约 1170px，比一般笔记本可视区还高；
   而 .aside 是 flex column、菜单区没有 overflow，超出部分**既看不见也滚不到**
   —— 底部那几项（系统设置/授权管理/系统帮助）等于不存在。
   现在拆成「1 个平铺首页 + 5 个分类折叠」，配 unique-opened 保证同时只展开一组，
   侧栏常态只有 6 行；菜单区再补一层滚动兜底，屏幕再矮也点得到。

   ⚠️ 两个 Element Plus 的坑（都踩过）：
   ① `default-openeds` 只在 el-menu 初始化时读一次，之后改它**不会**展开分组；
      所以 tab 变化后要手动调菜单实例的 `open()` 把父分组撑开 —— 否则从仪表盘
      点「授权管理 →」跳过去，高亮对了、分组却是收着的，看起来就像"没反应"。
   ② `:default-active` 是响应式的（el-menu 内部 watch 了它），高亮会自己跟；
      只有"展开"需要手动补。别为了展开给 el-menu 加 :key 重挂，那会丢动画。 */
const menuRef = ref(null);
// 每个 tab 归属哪个分类。首页（dashboard）是平铺项，不属于任何分类。
const MENU_SUB_OF = {
  users: 'g-org', groups: 'g-org', friends: 'g-org', orgs: 'g-org',
  attendance: 'g-office', files: 'g-office', messages: 'g-office',
  integrations: 'g-link', upstreams: 'g-link', clientconfig: 'g-link', push: 'g-link',
  master: 'g-biz', deduct: 'g-biz', modules: 'g-biz', training: 'g-biz',
  settings: 'g-sys', license: 'g-sys', help: 'g-sys', deploywizard: 'g-sys',
};
// 首屏不进任何分组：默认全收起，侧栏一眼看完。要看什么再展开。
const openedGroups = ref([]);
function syncMenuGroup(v) {
  const g = MENU_SUB_OF[v];
  if (g && typeof menuRef.value?.open === 'function') {
    try { menuRef.value.open(g); } catch (e) { /* 菜单还没挂载，忽略 */ }
  }
}
watch(tab, syncMenuGroup);

/* ====== 仪表盘指标分组（v0.15.0 重做）======
   原来这里是 13 个一模一样的「大绿数字 + 灰标签」平铺四行 —— 数字之间没有关系，
   也没有参照，管理员既看不出"这一块是管什么的"，也判断不出"今天到底有没有人用"。
   现在按用途分成几组，每组一个图标 + 一种配色；带 today 的指标在总数下面显示今日增量；
   带 tab 的指标整块可点，直达对应页面。 */
const metricGroups = computed(() => {
  const s = stats.value;
  const work = compSetting.value.mode === 'work';
  const groups = [
    {
      key: 'people', title: '人员', glyph: '人', tone: 'blue',
      tab: 'users', link: '用户管理',
      items: [
        // 每组的主指标可点，直达该页面；细分类型（文字/图片/语音）没有独立页面，就不给点击
        { key: 'users', label: '用户总数', today: 'usersToday', tab: 'users' },
        { key: 'activeUsers7d', label: '近 7 天活跃', hint: '实际发过消息的人' },
        { key: 'groups', label: '群组', tab: 'groups' },
        { key: 'friendships', label: '好友关系' },
      ],
    },
    {
      key: 'msg', title: '消息', glyph: '讯', tone: 'green',
      tab: 'messages', link: '消息管理',
      items: [
        { key: 'messages', label: '消息总数', today: 'msgsToday', tab: 'messages' },
        { key: 'text', label: '文字' },
        { key: 'images', label: '图片' },
        { key: 'audios', label: '语音' },
        { key: 'cards', label: '卡片' },
        { key: 'recalled', label: '已撤回', dim: true },
      ],
    },
    {
      key: 'file', title: '文件', glyph: '件', tone: 'amber',
      tab: 'files', link: '文件管理',
      items: [
        { key: 'files', label: '文件数', today: 'filesToday', tab: 'files' },
        // 磁盘占用来自 /admin/info 的 files_disk_bytes（实际盘上占用，与库里记录可能不一致）
        { key: '_disk', label: '磁盘占用', raw: fmtBytes(info.value.files_disk_bytes) },
      ],
    },
    {
      key: 'integration', title: '集成对接', glyph: '联', tone: 'purple',
      tab: 'integrations', link: '集成对接',
      items: [
        { key: 'bots', label: '机器人', tab: 'integrations' },
        { key: 'hooks_in', label: '入站推送' },
        { key: 'hooks_out', label: '事件订阅' },
        { key: 'pubkeys', label: '公钥接入' },
        { key: 'tokens', label: '接入令牌' },
        { key: 'deliveries_failed', label: '投递失败', warn: true },
      ],
    },
  ];
  // 工作模式下「组织与考勤」放最前面：这类服务器上它才是管理员每天要看的东西
  if (work) {
    groups.unshift({
      key: 'org', title: '组织与考勤', glyph: '勤', tone: 'cyan',
      tab: 'orgs', link: '组织机构',
      items: [
        { key: 'orgs', label: '组织', tab: 'orgs' },
        { key: 'depts', label: '部门' },
        { key: 'orgMembers', label: '组织人数' },
        { key: 'attShifts', label: '班次', tab: 'attendance' },
        { key: 'attGroups', label: '考勤组', tab: 'attendance' },
        { key: 'attLocations', label: '打卡点位', tab: 'attendance' },
        // 待审批是"每天都有活要干"，属正常状态，不标红（标红的是真异常）；
        // 它靠顶部提醒条提示，这里保持安静，否则满屏都是红的。
        { key: 'attPending', label: '待审批申请', tab: 'attendance' },
      ],
    });
  }
  return groups;
});

/* 该报警的数字自己跳出来（没异常就不占地方）。
   投递失败是最典型的"不显示就等于没有"：外部系统没收到通知，界面上一片绿。 */
// ---------------------------------------------------------------- 授权管理
/**
 * 授权状态（买断 / 年费订阅 / 45 天试用）。
 *
 * 为什么抽成全局状态而不是塞进某个页面：
 *   1) 侧栏和仪表盘都要显示剩余天数，得有一处权威数据
 *   2) 授权到期时所有业务接口都 403，需要统一识别并把人带到授权页
 *
 * ⚠ 定义位置必须在 dashAlerts 之前：computed 里引用了 licenseState，
 *   而 computed 有可能在 setup 期就被求值，声明顺序反了会 TDZ 白屏。
 */
const licenseState = ref(null);
const lic = reactive({ token: '', loading: false, activating: false });

const licTagType = computed(() => {
  const s = licenseState.value;
  if (!s) return 'info';
  if (!s.ok) return 'danger';
  if (s.mode === 'trial') return (s.daysLeft !== null && s.daysLeft <= 7) ? 'warning' : 'info';
  return 'success';
});

const licHeadline = computed(() => {
  const s = licenseState.value;
  if (!s) return '读取中…';
  if (!s.ok) {
    if (s.reason === 'trial_expired') return '试用已结束';
    if (s.reason === 'expired') return '授权已到期';
    if (s.reason === 'clock_back') return '系统时间异常，已暂停';
    if (s.reason === 'bad_token') return '授权码无效';
    return '授权不可用';
  }
  if (s.mode === 'master') return '主密钥授权';
  if (s.mode === 'device') return s.perpetual ? '已激活 · 永久买断' : '已激活 · 年费订阅';
  return '试用中（共 ' + s.trialDays + ' 天）';
});

const licModeText = computed(() => {
  const s = licenseState.value;
  if (!s) return '-';
  if (s.mode === 'trial') return '试用（' + s.trialDays + ' 天全功能）';
  if (s.mode === 'master') return '主密钥（通用授权，不限机器）';
  if (s.mode === 'device') return s.perpetual ? '买断授权（绑定本机，永久有效）' : '订阅授权（绑定本机，到期停止）';
  return '未激活';
});

function licTime(ms) {
  if (!ms) return '-';
  const d = new Date(ms);
  const p = (n) => String(n).padStart(2, '0');
  return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate())
    + ' ' + p(d.getHours()) + ':' + p(d.getMinutes());
}

async function loadLicense() {
  lic.loading = true;
  try {
    const { data } = await api.get('/license');
    licenseState.value = data;
  } catch (e) {
    // 这条接口免鉴权、也不受门禁影响，走到这里基本是网络或服务端本身的问题
    ElMessage.error('读取授权状态失败：' + (e.response?.data?.error || e.message));
  } finally {
    lic.loading = false;
  }
}

async function doActivate() {
  const t = lic.token.trim();
  if (!t) return ElMessage.warning('请先粘贴授权码');
  lic.activating = true;
  try {
    const { data } = await api.post('/license/activate', { token: t });
    licenseState.value = data.state;
    lic.token = '';
    ElMessage.success('激活成功，已立即生效');
  } catch (e) {
    const d = e.response?.data || {};
    ElMessage.error('激活失败：' + (d.error || e.message));
    // 机器码不匹配时后端会回显本机机器码，顺手把最新状态刷新出来
    if (d.machineCode) loadLicense();
  } finally {
    lic.activating = false;
  }
}

async function doDeactivate() {
  try {
    await ElMessageBox.confirm(
      '解绑后本机立即回到受限状态（试用期起点不会重置，不会因此重新获得 45 天）。确定解绑？',
      '解绑本机授权', { type: 'warning' });
  } catch { return; }
  try {
    const { data } = await api.post('/license/deactivate');
    licenseState.value = data.state;
    ElMessage.success('已解绑');
  } catch (e) {
    ElMessage.error('解绑失败：' + (e.response?.data?.error || e.message));
  }
}

function copyMc() {
  const mc = licenseState.value?.machineCode;
  if (!mc) return;
  if (navigator.clipboard?.writeText) {
    navigator.clipboard.writeText(mc)
      .then(() => ElMessage.success('机器码已复制：' + mc))
      .catch(() => ElMessage.warning('复制失败，请手动选中复制'));
  } else {
    ElMessage.warning('当前浏览器不支持自动复制，请手动选中复制');
  }
}

// 业务接口被门禁拦下时（api.js 收到 403 LICENSE_REQUIRED 会派发）：
// 把人带到授权页并同步最新状态。这是「怎么突然什么都点不动了」的唯一解释入口。
window.addEventListener('xz-license-blocked', (ev) => {
  if (ev.detail?.license) licenseState.value = ev.detail.license;
  if (tab.value !== 'license') {
    tab.value = 'license';
    ElMessage.warning(ev.detail?.error || '授权不可用，已跳转到授权管理');
  }
});

const dashAlerts = computed(() => {
  const s = stats.value;
  const list = [];
  if ((s.deliveries_failed || 0) > 0) {
    list.push({
      key: 'deliveries', type: 'error',
      title: `有 ${s.deliveries_failed} 条事件投递失败`,
      desc: '外部系统没有收到通知（对方服务不可用、地址填错或被网络拦截）。失败的事件不会自动补发，'
        + '需要的可以到「集成对接 → 投递日志」里查看原因并重发。',
      tab: 'integrations', action: '去看投递日志',
    });
  }
  if (compSetting.value.mode === 'work' && (s.attPending || 0) > 0) {
    list.push({
      key: 'att', type: 'warning',
      title: `有 ${s.attPending} 张考勤申请待审批`,
      desc: '请假 / 补卡 / 外出 / 加班申请还等着处理。补卡审批通过后会自动补写当天的打卡记录，'
        + '不批的话那天就会一直算缺卡。',
      tab: 'attendance', action: '去审批',
    });
  }
  // 授权不可用是「整站不可用」级别的问题，仪表盘必须置顶说明。
  // 不这样的话，管理员看到的只是各页面零散的「加载失败」，看不出根因在授权。
  if (licenseState.value && !licenseState.value.ok) {
    list.unshift({
      key: 'license', type: 'error',
      title: licenseState.value.message || '授权不可用',
      desc: '业务接口现在会返回 403：员工登录不进来、消息发不出去。在「授权管理」里填写授权码即可立即恢复（不用重启）。',
      tab: 'license', action: '去激活',
    });
  }
  return list;
});

// 系统说明默认收起：它是"读一次就够"的内容，不该占仪表盘首屏
const docOpen = ref(false);

/* ====== 上手向导 ======
   每一步都用服务器真实状态判断，纯前端计算、不新增接口。
   依据：settings（公司名/好友模式）+ stats（用户数/组织数/组织人数/消息数）+ info（TURN）。 */
const setupOpen = ref(true);
const setupSteps = computed(() => {
  const work = compSetting.value.mode === 'work';
  const hasOrg = (stats.value.orgs || 0) > 0;
  const orgMembers = stats.value.orgMembers || 0;
  const hasOtherUser = (stats.value.users || 0) > 1; // 除 admin 外还有人
  const msgs = stats.value.messages || 0;
  // 中继是否可用看 /admin/turn 的 ready（= 至少配了一种中继来源）。
  // 注意别用 /admin/info（没有这个字段），也别用客户端 ICE 接口的 turnConfigured —— 两个接口字段不同名
  const turnReady = !!turn.value?.ready;

  const steps = [{
    key: 'company',
    done: !!compSetting.value.name,
    title: '给服务器起个名字（公司名）',
    desc: compSetting.value.name
      ? `客户端登录页与局域网扫描结果都会显示「${compSetting.value.name}小智」`
      : '填上公司简称（如「盛京」），客户端登录页就显示「盛京小智」—— 员工装完 App 一眼知道连的是自家服务器',
    actionText: '去设置',
    tab: 'settings',
    primary: true,
  }];

  if (work) {
    steps.push({
      key: 'org',
      done: hasOrg,
      title: '创建组织机构',
      desc: hasOrg
        ? '组织已建好，随时可以录员工'
        : '工作模式下人员由组织统一管理：先建一个组织（一个服务器一个组织）',
      actionText: hasOrg ? '去看看' : '去创建',
      tab: 'orgs',
      primary: !hasOrg,
    });
    steps.push({
      key: 'members',
      done: orgMembers > 0,
      title: '把员工录进来',
      desc: orgMembers > 0
        ? `组织里已有 ${orgMembers} 名员工（工号即登录账号，初始密码 = 工号）`
        : '一个个加，或按「工号 姓名 部门 岗位」四列从 Excel 复制过来批量导入；录入后同事自动互为好友',
      actionText: '去录入',
      tab: 'orgs',
      primary: orgMembers === 0,
    });
    // 考勤随工作模式自动启用（默认 08:00-17:00 含休息 12:00-13:00，一天 4 次卡 / 周一至周五），所以这一步"默认就是完成的"。
    // 放进向导的目的不是催办，而是让管理员**知道有这个功能**、知道去哪儿按自己厂里的
    // 作息去调 —— 否则很容易出现"系统有考勤，但所有人都在按 9 点标准被算迟到"。
    steps.push({
      key: 'attendance',
      done: orgMembers > 0 && stats.value.attendanceEnabled !== false,
      title: '考勤打卡（已随工作模式启用）',
      desc: stats.value.attendanceEnabled === false
        ? '考勤当前被停用，员工端看不到打卡入口'
        : '员工端已有「考勤打卡」：默认 08:00-17:00（休息 12:00-13:00，一天 4 次卡）、周一至周五。'
          + '厂里作息不同（夜班、两班倒、周六上班）就去配班次与考勤组；不配也能用',
      actionText: '去查看',
      tab: 'attendance',
      primary: false,
    });
  } else {
    steps.push({
      key: 'users',
      done: hasOtherUser,
      title: '添加用户',
      desc: hasOtherUser
        ? '除管理员外已经有其他人的账号了'
        : '给同事开户，也可以让同事在客户端自己注册。人多、要按部门统一管，就到「系统设置」切工作模式',
      actionText: hasOtherUser ? '去管理' : '去添加',
      tab: 'users',
      primary: !hasOtherUser,
    });
  }

  // 已经建过组织、但当前是普通模式：最容易被卡住的一种状态 ——
  // 组织明明在页面上，录员工却被服务端 400 拒掉。与其让人自己琢磨，
  // 不如向导直接把话说明白。
  if (!work && hasOrg) {
    steps.push({
      key: 'mode-back',
      done: false,
      title: '组织已存在，但当前是普通模式',
      desc: '服务器上已经建过组织机构。要用它按工号录员工，请到「系统设置」把好友模式切回工作模式',
      actionText: '去切换',
      tab: 'settings',
      primary: true,
    });
  }

  steps.push({
    key: 'turn',
    done: turnReady,
    title: '配置音视频中继（外网通话用）',
    desc: turnReady
      ? '已配置：手机 4G/5G 与内网之间也能通话'
      : '不配的话只有同一个 Wi-Fi 内能通，手机流量呼入连不上。推荐 Cloudflare TURN：免费、不需要端口映射，填两个值即可',
    actionText: turnReady ? '查看' : '去配置',
    tab: 'settings',
  });

  steps.push({
    key: 'client',
    done: msgs > 0,
    title: '装客户端，发通第一条消息',
    desc: msgs > 0
      ? '客户端已经用起来了'
      : 'Windows 装 exe、安卓装 APK。首次启动会自动扫描局域网找服务器，也可以在「服务器设置」里手填内网地址',
    actionText: '看安装说明',
    tab: 'help',
  });

  return steps;
});
const setupDoneCount = computed(() => setupSteps.value.filter((s) => s.done).length);
const setupDone = computed(() => setupDoneCount.value === setupSteps.value.length);
const setupPercent = computed(() => Math.round((setupDoneCount.value / setupSteps.value.length) * 100));

// 上手向导：所有步骤完成后默认折叠（龙哥 2026-10 需求）。
// 已完成 → 折叠；未完成 → 展开。首屏已是完成态也直接折叠；
// 用户手动展开后仍不被后续数据刷新强行收起（用 setupAutoCollapsed 守住）。
//
// 🔴 不能在 setup 期就 watch(setupDone)（加不加 immediate 都不行）：
//    setupDone → setupDoneCount → setupSteps 这条链路会读 compSetting
//    （本文件第 8926 行才声明）和 turn（第 9044 行才声明）。而 watch 在
//    **创建时**就会先求值一次源、immediate 更是当场执行回调 —— 两者都会在
//    这些 ref 初始化前求值 setupSteps，撞上 TDZ（Cannot access 'El' before
//    initialization）直接白屏。与上面 brand 注释里"不能引用 compSetting"同源。
//    所以把"建 watch + 首屏判定"整体推迟到 onMounted：那时 setup 已跑完、
//    所有 ref 都已初始化，安全。初值仍必须是 false —— 若为 setupDone.value，
//    则完成态下 `!setupAutoCollapsed` 恒为 false，永远折叠不了。
const setupAutoCollapsed = ref(false);
onMounted(() => {
  const collapseIfDone = () => {
    if (setupDone.value && !setupAutoCollapsed.value) {
      setupOpen.value = false;
      setupAutoCollapsed.value = true;
    }
  };
  collapseIfDone();                     // 首屏已是完成态：直接折叠
  watch(setupDone, collapseIfDone);     // 之后在页面上做完最后一步 → 自动折叠
});

/**
 * 首次运行：设置管理台密码。
 * 成功即拿服务端返回的 token 直接进管理台 —— 刚设完密码再让人输一遍没有意义。
 */
async function doSetup() {
  err.value = '';
  const pw = setupForm.value.password;
  // 本地先挡一道：字符集不对、长度不对，不必往返一趟才知道
  if (!PW_RE.test(pw)) { err.value = '密码 6~64 位，只能用字母、数字和 . _ - @ ! * + ?'; return; }
  if (pw !== setupForm.value.confirm) { err.value = '两次输入的密码不一致'; return; }
  loading.value = true;
  try {
    const { data } = await api.post('/setup/init', { password: pw });
    if (data && data.token) {
      token.value = data.token;
      localStorage.setItem('xz_token', data.token);
      loadAll();
    } else {
      err.value = '设置失败';
    }
  } catch (e) {
    err.value = e.response?.data?.error || '设置失败';
    // 409 = 另一个窗口刚设过了 → 切回登录页，别让人对着一个再也交不上去的表单干瞪眼
    if (e.response?.status === 409) needSetup.value = false;
  } finally {
    loading.value = false;
  }
}

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

/**
 * 通用列表分页器（全站统一约定，见 SPEC-消息与文件管理.md §6.1）。
 *
 * 服务端列表接口统一返回 `{items,total,page,pageSize}`。抽成一个可复用件，
 * 避免每个页面各写一套 —— 之前每个接口各写死一个 LIMIT，数据一多就静默截断。
 *
 * ⚠️ 筛选条件变化时**必须回到第 1 页**：不回到第 1 页的话，用户在第 5 页改条件
 * 会查到空结果，然后以为"没数据"。
 */
function usePager(loader, opts = {}) {
  const p = reactive({
    items: [], total: 0, page: 1, pageSize: opts.pageSize || 50, loading: false,
  });
  let seq = 0;
  async function load() {
    const my = ++seq;              // 防竞态：连续改条件时只认最后一次的结果
    p.loading = true;
    try {
      const r = await loader({ page: p.page, pageSize: p.pageSize });
      if (my !== seq) return;
      p.items = r.items || [];
      p.total = r.total || 0;
      // 删到当前页空了自动回退到最后一页：否则用户对着空表以为数据没了
      const lastPage = Math.max(1, Math.ceil(p.total / p.pageSize));
      if (!p.items.length && p.total > 0 && p.page > lastPage) {
        p.page = lastPage;         // watch(page) 会重新拉
        return;
      }
    } catch (e) {
      if (my === seq) ElMessage.error('加载失败：' + (e.response?.data?.error || e.message));
    } finally {
      if (my === seq) p.loading = false;
    }
  }
  watch(() => p.page, load);
  watch(() => p.pageSize, () => { if (p.page !== 1) p.page = 1; else load(); });
  return {
    p,
    load,
    /** 回到第 1 页并刷新（筛选条件变化后调它） */
    reset() { if (p.page !== 1) { p.page = 1; } else { load(); } },
  };
}

/**
 * 通用分页条。所有列表页共用一套交互，避免每页各写一遍。
 * ⚠️ 不监听 @current-change 手动 reload —— 直接把 current-page 绑到 pager.p.page，
 * usePager 内部 watch(page) 会触发加载，避免"改页码"和"手动请求"两条路径打架。
 */
const PagerBar = {
  name: 'PagerBar',
  props: { pager: { type: Object, required: true } },
  setup(props) {
    return () => h('div', { class: 'pager-bar' }, [
      h(ElPagination, {
        currentPage: props.pager.p.page,
        pageSize: props.pager.p.pageSize,
        total: props.pager.p.total,
        pageSizes: [20, 50, 100, 200],
        layout: 'total, sizes, prev, pager, next, jumper',
        background: true,
        'onUpdate:currentPage': (v) => { props.pager.p.page = v; },
        'onUpdate:pageSize': (v) => { props.pager.p.pageSize = v; },
      }),
    ]);
  },
};

/** 时间范围快捷选项 → 查询参数。`all` 用显式 allTime 表达，不靠"不传"（不传=最近 30 天） */
function rangeToQuery(range, custom) {
  if (range === 'all') return { allTime: '1' };
  if (range === 'custom') {
    const [a, b] = custom || [];
    if (!a || !b) return {};
    return { from: String(new Date(a).getTime()), to: String(new Date(b).getTime()) };
  }
  if (range === 'today') {
    const d = new Date(); d.setHours(0, 0, 0, 0);
    return { from: String(d.getTime()) };
  }
  const days = Number(String(range).replace('d', '')) || 30;
  return { from: String(Date.now() - days * 86400000) };
}
function rangeLabel(range) {
  return { today: '今天', '7d': '最近 7 天', '30d': '最近 30 天', '90d': '最近 90 天', all: '全部时间', custom: '自定义' }[range] || range;
}

async function loadAll() {
  // 授权状态优先取（免鉴权、不受门禁影响）：仪表盘提醒与顶栏标签都靠它。
  // 不 await：它失败不该拖住正常数据的加载。
  loadLicense();
  try {
    // 列表数据不再在登录时一次性全量拉（分页后没必要），切到对应页签再按需加载。
    // 但选择器要用的「全部用户」必须早点拿到，否则建群/考勤组会少人。
    const [s, inf, st] = await Promise.all([
      api.get('/admin/stats'),
      api.get('/admin/info'),
      api.get('/admin/settings'),
    ]);
    stats.value = s.data;
    info.value = inf.data;
    // 公司名与好友模式：上手向导、仪表盘卡片、侧栏都要用，登录后就取好，
    // 不要等切到「系统设置」页才加载（否则向导第一步永远是未完成）
    compSetting.value = {
      name: st.data.companyName || '',
      mode: st.data.friendMode || 'normal',
      showPurchasePrice: !!st.data.masterShowPurchasePrice,
    };
    // 品牌名单一数据源在 pub，登录后把最新公司名回写过去
    pub.value = { ...pub.value, companyName: st.data.companyName || '' };
    await loadUserOptions();
    loadTurn();
  } catch (e) {
    ElMessage.error('加载失败：' + (e.response?.data?.error || e.message));
  }
}

// 切换 tab 时按需加载
async function loadTab() {
  if (tab.value === 'dashboard') {
    // 向导的三个判断依据（统计 / 公司名与模式 / 中继状态）都要重新拉：
    // 否则刚在系统设置里配好中继、切回仪表盘，向导还显示"未完成"
    const [st, sc] = await Promise.all([api.get('/admin/stats'), api.get('/admin/settings')]);
    stats.value = st.data;
    compSetting.value = {
      name: sc.data.companyName || '',
      mode: sc.data.friendMode || 'normal',
      showPurchasePrice: !!sc.data.masterShowPurchasePrice,
    };
    await loadTurn();
  } else if (tab.value === 'users') await userPager.reset();
  else if (tab.value === 'groups') await groupPager.reset();
  else if (tab.value === 'friends') await loadFriends();
  else if (tab.value === 'orgs') await loadOrgs();
  else if (tab.value === 'attendance') await loadAttendance();
  else if (tab.value === 'files') await loadFiles();
  else if (tab.value === 'messages') await loadMessages();
  else if (tab.value === 'integrations') await loadIntegrations();
  else if (tab.value === 'clientconfig') { await loadCc(); await loadCcApplied(); }
  else if (tab.value === 'modules') { await loadMm(); await loadAppCatalog(); await loadUserOptions(); }
  else if (tab.value === 'upstreams') await loadUs();
  else if (tab.value === 'master') await loadMaster();
  else if (tab.value === 'training') { await loadTrCourses(); await loadTrSheets(); await loadTrFiles(); }
  else if (tab.value === 'license') await loadLicense();
  // 数据体检：切进来就体检一次（只读，随手做一次不心疼）
  else if (tab.value === 'health') await loadOrphanScan();
  // 默认控制码要选账号 → 顺手把用户选项也拉上，避免下拉是空的
  else if (tab.value === 'settings') { await loadInfo(); await loadCompSetting(); await loadRdc(); await loadUserOptions(); }
  else if (tab.value === 'deduct') await reloadDeduct();
  else if (tab.value === 'push') await loadPush();
  else if (tab.value === 'deploywizard') await dwEnter();
}

/* ====== 部署向导（换云服务器一键部署） ======
 * 服务端：/api/admin/deploy/*（server/src/routes/deploy_wizard.js）。
 * 四步：① VPS 一键部署 frps+TURN（SSH 自动，日志实时回显）② frpc 隧道切换
 * ③ turn.env 追加 + 重启生效 ④ 客户端地址候选（跳既有页面手工发布）。
 * 密码不回显明文（服务端只回掩码），留空 = 沿用已保存的。
 */
const dw = reactive({
  active: 0,
  shape: 'vps', // vps = 云服务器隧道；direct = 本地公网直连（不走隧道）
  vps: { host: '', port: 22, user: 'root', password: '' },
  fnos: { host: '', port: 22, user: '', password: '' },
  ports: { server: 3602, frp: 7000, turn: 3478 },
  platform: '',
  // 本地公网直连：服务器自身的地址（带类型）
  direct: { lan: '', ipv4: '', ipv6: '' },
  hasVpsPw: false, hasFnosPw: false,
  task: { state: 'idle', steps: [], logs: [] },
  polling: null, waitBack: null,
  health: [],
  ice: null,
  busy: '',
});

// 本地公网直连：把填好的地址（带类型）写入客户端配置中心
const dwDirectBusy = ref(false);
async function dwWriteAddresses() {
  const list = [];
  if (dw.direct.lan.trim()) list.push({ url: dw.direct.lan.trim().replace(/\/+$/, ''), type: 'lan' });
  if (dw.direct.ipv4.trim()) list.push({ url: dw.direct.ipv4.trim().replace(/\/+$/, ''), type: 'ipv4' });
  if (dw.direct.ipv6.trim()) list.push({ url: dw.direct.ipv6.trim().replace(/\/+$/, ''), type: 'ipv6' });
  if (!list.length) { ElMessage.warning('至少填一个地址'); return; }
  dwDirectBusy.value = true;
  try {
    const { data } = await api.post('/admin/client-config', {
      payload: { serverAddresses: list },
      note: '部署向导-本地公网直连',
    });
    ElMessage.success(`已写入客户端地址候选（v${data.version}）`);
  } catch (e) {
    ElMessage.error('写入失败：' + (e.response?.data?.error || e.message));
  } finally {
    dwDirectBusy.value = false;
  }
}
const dwIsWin = computed(() => dw.platform === 'win32');

async function dwEnter() {
  await dwLoadCreds();
  dwHealth();
  // 页面刷新后若有任务在跑（服务端内存任务），恢复轮询
  try {
    const r = await api.get('/admin/deploy/status');
    dw.task = r.data;
    if (r.data && r.data.state === 'running') dwStartPoll();
  } catch { /* ignore */ }
}

async function dwLoadCreds() {
  try {
    const r = await api.get('/admin/deploy/creds');
    dw.platform = r.data.platform || '';
    if (r.data.ports) dw.ports = { ...dw.ports, ...r.data.ports };
    if (r.data.vps) {
      Object.assign(dw.vps, { host: r.data.vps.host, port: r.data.vps.port, user: r.data.vps.user, password: '' });
      dw.hasVpsPw = !!r.data.vps.hasPassword;
    }
    if (r.data.fnos) {
      Object.assign(dw.fnos, { host: r.data.fnos.host, port: r.data.fnos.port, user: r.data.fnos.user, password: '' });
      dw.hasFnosPw = !!r.data.fnos.hasPassword;
    }
  } catch { /* 未保存过就保持空白 */ }
}

async function dwSave(which) {
  dw.busy = 'save-' + which;
  try {
    const body = which === 'vps' ? { vps: dw.vps } : { fnos: dw.fnos };
    body.ports = dw.ports; // 端口随凭据一起存（谁先保存都带上当前值）
    await api.post('/admin/deploy/creds', body);
    ElMessage.success('已保存');
    await dwLoadCreds();
  } catch (e) { ElMessage.error(e.response?.data?.error || e.message); }
  finally { dw.busy = ''; }
}

async function dwTest(which) {
  dw.busy = 'test-' + which;
  try {
    const r = await api.post('/admin/deploy/test', { which });
    ElMessage.success(`连接成功（${r.data.ms}ms）`);
  } catch (e) { ElMessage.error(e.response?.data?.error || e.message); }
  finally { dw.busy = ''; }
}

async function dwStart(kind) {
  try {
    await api.post('/admin/deploy/' + kind);
    dwStartPoll();
  } catch (e) { ElMessage.error(e.response?.data?.error || e.message); }
}

function dwStartPoll() {
  dwStopPoll();
  dw.polling = setInterval(async () => {
    try {
      const r = await api.get('/admin/deploy/status');
      dw.task = r.data;
      if (r.data.state !== 'running') {
        dwStopPoll();
        dwHealth();
        if (r.data.state === 'done') {
          if (r.data.kind === 'vps') { dw.active = Math.max(dw.active, 1); ElMessage.success('服务器部署完成，进入下一步'); }
          else if (r.data.kind === 'tunnel') { dw.active = Math.max(dw.active, 2); ElMessage.success('隧道接入完成'); }
        } else if (r.data.state === 'error') {
          ElMessage.error('任务失败：' + (r.data.error || '未知'));
        }
      }
    } catch { /* 轮询失败忽略下一轮再试 */ }
  }, 1500);
}
function dwStopPoll() { if (dw.polling) { clearInterval(dw.polling); dw.polling = null; } }

async function dwTurn() {
  dw.busy = 'turn';
  try {
    await api.post('/admin/deploy/turn');
    if (dwIsWin.value) {
      // Win 服务端没有守护进程，重启 = 用户手动；服务端已在响应里说明
      ElMessage.info('中继配置已写入。请用「停止服务端.cmd」+「后台启动服务端.vbs」重启服务端后，回本页点「刷新健康检查」确认。');
      dw.ice = (await api.get('/admin/deploy/verify-ice').catch(() => null))?.data || null;
      return;
    }
    ElMessage.success('中继配置已写入，正在重启服务端（约 10~20 秒）...');
    // 重启会让本进程失联 —— 请求失败是预期行为，忽略
    await api.post('/admin/deploy/restart-self').catch(() => {});
    // 轮询等服务端回来（最多 90 秒）
    let back = false;
    for (let i = 0; i < 45; i++) {
      await new Promise((r) => setTimeout(r, 2000));
      try { await api.get('/admin/deploy/creds'); back = true; break; } catch { /* 还没起来 */ }
    }
    if (!back) { ElMessage.error('服务端 90 秒未恢复，请稍后手动刷新页面检查'); dw.busy = ''; return; }
    const r = await api.get('/admin/deploy/verify-ice');
    dw.ice = r.data;
    if (r.data.hasVps) { dw.active = Math.max(dw.active, 3); ElMessage.success('双 TURN 中继下发验证通过'); }
    else ElMessage.warning('服务端已恢复，但 iceServers 里未见 VPS 中继 —— 检查 turn.env');
  } catch (e) { ElMessage.error(e.response?.data?.error || e.message); }
  finally { dw.busy = ''; }
}

async function dwHealth() {
  try {
    const r = await api.get('/admin/deploy/health');
    dw.health = r.data.items;
  } catch { /* ignore */ }
}

/* ====== 消息推送（APNs） ======
 * 服务端接口早就齐了（server/src/routes/push.js 的 admin 路由），
 * 缺的一直是**管理台这一页** —— 于是只能改配置文件、改完还得重启才知道对不对。
 * 这一页把"配 → 自检 → 发一条真的"三步连起来：
 * 自检能证明私钥能签名，**只有真发一条**才能证明 Apple 认这对凭据。
 */
const pushForm = reactive({ keyId: '', teamId: '', topic: '', keyP8: '', env: 'production' });
const push = ref({ info: {}, stats: {}, logs: [], busy: false, probeText: '', probeOk: false });

async function loadPush() {
  try {
    const { data } = await api.get('/admin/push', { params: { limit: 50 } });
    push.value.info = data.info || {};
    push.value.stats = data.stats || {};
    push.value.logs = data.logs || [];
    // 已配好的字段回填，但**私钥不回填**（服务端只给"有没有"，内容不回来）
    if (data.info) {
      pushForm.topic = data.info.topic || pushForm.topic;
      pushForm.env = data.info.env || pushForm.env;
    }
  } catch (e) {
    ElMessage.error('读取推送状态失败：' + (e.response?.data?.error || e.message));
  }
}

async function probePush() {
  push.value.busy = true;
  try {
    // 带上还没保存的凭据去试：服务端只在内存里试签一次就还原，**不落盘**
    const { data } = await api.post('/admin/push/probe', {
      keyId: pushForm.keyId || undefined,
      teamId: pushForm.teamId || undefined,
      topic: pushForm.topic || undefined,
      keyP8: pushForm.keyP8 || undefined,
      env: pushForm.env,
    });
    push.value.probeOk = !!data.ok;
    push.value.probeText = data.ok
      ? `自检通过：私钥能签名（${data.detail || data.env || ''}）`
      : `自检没通过：${data.error || data.reason || '未知原因'}`;
  } catch (e) {
    push.value.probeOk = false;
    push.value.probeText = '自检失败：' + (e.response?.data?.error || e.message);
  } finally { push.value.busy = false; }
}

async function savePush() {
  push.value.busy = true;
  try {
    const { data } = await api.post('/admin/push/config', {
      keyId: pushForm.keyId, teamId: pushForm.teamId,
      topic: pushForm.topic, keyP8: pushForm.keyP8, env: pushForm.env,
    });
    push.value.info = data.info || {};
    pushForm.keyP8 = ''; // 存完就把私钥从界面上抹掉：没必要让它留在内存里
    ElMessage.success('已保存并立即生效（不用重启）');
    await loadPush();
  } catch (e) {
    ElMessage.error('保存失败：' + (e.response?.data?.error || e.message));
  } finally { push.value.busy = false; }
}

async function testPush() {
  push.value.busy = true;
  try {
    const { data } = await api.post('/admin/push/test', {});
    if (data.ok) ElMessage.success('已发出，看手机上有没有收到');
    else ElMessage.warning('没发出去：' + ((data.lastLog && data.lastLog.reason) || '看下面的投递记录'));
    await loadPush();
  } catch (e) {
    // 400 是最常见的：那台手机上还没有登记过的 iOS 令牌 —— 是人能补的事，直说
    ElMessage.error(e.response?.data?.error || ('发测试推送失败：' + e.message));
  } finally { push.value.busy = false; }
}

async function clearPush() {
  try {
    await ElMessageBox.confirm(
      '清空之后所有手机都收不到推送了（要重新配一遍四样东西）。',
      '清空推送配置', { type: 'warning' });
  } catch { return; }
  try {
    await api.post('/admin/push/clear');
    ElMessage.success('已清空');
    await loadPush();
  } catch (e) { ElMessage.error('清空失败：' + (e.response?.data?.error || e.message)); }
}

/* ====== 库房减货（对账） ======
 * 手机上的减货单提交后点「上传管理台」落到这里。
 * 两个视图回答的是两个不同的问题，缺一个都不算"能对账"：
 *   按商品对账 = 这个品一共减了多少、分几次减的（跨单据累加）；
 *   减货单     = 谁、哪台设备、什么时候减了一单（追责与排查用）。
 */
const deductTab = ref('reconcile');
const deductRange = ref(null);
const deduct = ref({
  rec: [], recPage: 1, recTotal: 0,
  sheets: [], sheetsPage: 1, sheetsTotal: 0,
  overall: {}, q: '', loading: false,
  dlg: false, detail: [], cur: '',
});

const deductRangeLabel = computed(() => {
  const r = deductRange.value;
  if (!r || r.length !== 2) return '全部时间';
  const d = (v) => new Date(Number(v)).toLocaleDateString('zh-CN');
  return `${d(r[0])} 至 ${d(r[1])}`;
});

/** 时间范围与关键字 → 查询参数（两个视图共用）。 */
function deductParams() {
  const p = {};
  const r = deductRange.value;
  // 结束日给到当天 23:59:59.999 —— 日期选择器给的是当天 0 点，
  // 不补的话"减货当天"那一整天的数据会被排除在外，而用户以为选了就是包含。
  if (r && r.length === 2) { p.from = r[0]; p.to = Number(r[1]) + 86399999; }
  if (deduct.value.q && deduct.value.q.trim()) p.q = deduct.value.q.trim();
  return p;
}

async function loadDeductRec(page = 1) {
  deduct.value.loading = true;
  try {
    const { data } = await api.get('/deduct/reconcile', {
      params: { ...deductParams(), page, pageSize: 100 },
    });
    deduct.value.rec = data.items || [];
    deduct.value.recTotal = data.total || 0;
    deduct.value.recPage = page;
    // 总览挂在**对账**接口上：它是按当前筛选算的，
    // 用减货单列表的合计会漏掉"筛选范围内只出现在一张单里的品"。
    deduct.value.overall = data.overall || {};
  } catch (e) {
    ElMessage.error('减货对账加载失败：' + (e.response?.data?.error || e.message));
  } finally { deduct.value.loading = false; }
}

async function loadDeductSheets(page = 1) {
  deduct.value.loading = true;
  try {
    const { data } = await api.get('/deduct/sheets', {
      params: { ...deductParams(), page, pageSize: 50 },
    });
    deduct.value.sheets = data.items || [];
    deduct.value.sheetsTotal = data.total || 0;
    deduct.value.sheetsPage = page;
  } catch (e) {
    ElMessage.error('减货单列表加载失败：' + (e.response?.data?.error || e.message));
  } finally { deduct.value.loading = false; }
}

function reloadDeduct() {
  return Promise.all([loadDeductRec(1), loadDeductSheets(1)]);
}

async function openDeductSheet(no) {
  deduct.value.cur = no;
  try {
    const { data } = await api.get(`/deduct/sheet/${encodeURIComponent(no)}`);
    deduct.value.detail = data.rows || [];
    deduct.value.dlg = true;
  } catch (e) {
    ElMessage.error('读取减货单失败：' + (e.response?.data?.error || e.message));
  }
}

/* ====== 用户管理：服务端分页 + 服务端搜索 ====== */

// 搜索必须放服务端：分页和前端过滤天然矛盾 —— 前端只拿到当页 50 条，
// 在当页里 filter 搜不到第 51 个人，而且不报错（属最难查的一类问题）。
const userSearch = ref('');
const userPager = usePager(async ({ page, pageSize }) => {
  const p = new URLSearchParams({ page: String(page), pageSize: String(pageSize) });
  if (userSearch.value.trim()) p.set('q', userSearch.value.trim());
  return (await api.get('/admin/users?' + p.toString())).data;
});
let userSearchTimer = null;
watch(userSearch, () => {
  clearTimeout(userSearchTimer);
  userSearchTimer = setTimeout(() => userPager.reset(), 300);
});

/**
 * 全部用户的轻量列表（**不分页**）。
 *
 * 管理台有 4 处选择器要"全部用户"：身份下拉、建群选成员、考勤组指定到人、
 * 模块表单的人员字段。用户列表一分页，这几处会**集体静默少人** ——
 * 所以它们必须走这个独立接口，不能复用用户页的分页数据。
 */
const userOptions = ref([]);
async function loadUserOptions() { userOptions.value = (await api.get('/admin/users/options')).data; }

/* ====== 群组 / 好友 ====== */
const groupPager = usePager(async ({ page, pageSize }) =>
  (await api.get(`/admin/groups?page=${page}&pageSize=${pageSize}`)).data);
const friendTree = ref([]);
const friendTotal = ref(0);
const friendLoading = ref(false);
/* 搜索：命中"用户名"保留整组；只命中某个好友/状态则只留命中的好友行 */
const friendQ = ref('');
const friendTreeFiltered = computed(() => {
  const q = friendQ.value.trim().toLowerCase();
  if (!q) return friendTree.value;
  return friendTree.value
    .map((u) => {
      if ((u.label || '').toLowerCase().includes(q)) return u;
      const kids = (u.children || []).filter((c) =>
        (c.label || '').toLowerCase().includes(q) ||
        ((c.row?.status || '')).toLowerCase().includes(q));
      return kids.length ? { ...u, children: kids } : null;
    })
    .filter(Boolean);
});
/* 过滤后的树是全新节点，default-expanded-keys 对它们生效 —— 搜索时全部展开，方便直接看到命中行 */
const friendSearchExpanded = computed(() =>
  friendQ.value.trim() ? friendTreeFiltered.value.map((u) => u.key) : []);

async function loadGroups() { return groupPager.reset(); }
async function loadFriends() {
  friendLoading.value = true;
  try {
    const { data } = await api.get('/admin/friendships/tree');
    friendTree.value = (data.tree || []).map((u) => ({
      key: 'u-' + u.userId,
      label: u.userName,
      isUser: true,
      children: (u.friends || []).map((f) => ({
        key: 'f-' + f.id,
        label: f.friend_name,
        isUser: false,
        row: f,
      })),
    }));
    friendTotal.value = data.total || 0;
  } catch (e) {
    ElMessage.error(e.response?.data?.error || '加载好友关系失败');
  } finally {
    friendLoading.value = false;
  }
}

/* ====== 文件管理 ====== */

const fileTab = ref('all');
const fileRange = ref('30d');
const fileCustom = ref(null);
const fileOwnerId = ref(null);
const fileMime = ref('');
const fileQ = ref('');
const fileStorage = ref(null);
const fileOrphans = ref({ dbOnly: [], diskOnly: [], counts: {}, truncated: false });

const filePager = usePager(async ({ page, pageSize }) => {
  const p = new URLSearchParams({ page: String(page), pageSize: String(pageSize) });
  for (const [k, v] of Object.entries(rangeToQuery(fileRange.value, fileCustom.value))) p.set(k, v);
  if (fileOwnerId.value) p.set('ownerId', String(fileOwnerId.value));
  if (fileMime.value) p.set('mime', fileMime.value);
  if (fileQ.value.trim()) p.set('q', fileQ.value.trim());
  return (await api.get('/admin/files?' + p.toString())).data;
});

async function loadFiles() {
  await Promise.all([
    filePager.reset(),
    api.get('/admin/files/storage').then((r) => { fileStorage.value = r.data; }).catch(() => {}),
    loadOrphans(),
  ]);
}

async function loadOrphans() {
  try { fileOrphans.value = (await api.get('/admin/files/orphans')).data; }
  catch (e) { ElMessage.error('孤儿巡检失败：' + (e.response?.data?.error || e.message)); }
}

/* ====== 数据体检（孤儿巡检，2026-10-03 新增） ======
 *
 * ⚠️ 命名刻意和上面那个「文件孤儿巡检」区分开：
 *   loadOrphans       → 文件维度的（断链文件 / 磁盘残留），2026-09-27 就有
 *   loadOrphanScan    → 本页的「数据体检」（全库关联的孤儿行）
 *   两个功能概念相近但对象不同，混用一个名字迟早会叫错接口。
 */

// 服务端 why/impact 里带了 ** 强调标记，这里渲染成纯文本（表格里不需要 markdown）
function stripMd(s) {
  return String(s || '').replace(/\*\*/g, '').replace(/\n/g, ' ');
}

const orphanScan = ref({ loaded: false, loading: false, items: [], summary: null, errors: [] });
// 只展示"有问题"的关联 —— 全 healthy 时那 21 行 0 纯属噪音
const orphanRows = computed(() =>
  (orphanScan.value.items || []).filter((i) => i.count > 0 || i.error)
);
const orphanKeptRows = computed(() =>
  (orphanScan.value.items || []).filter((i) => i.count > 0 && !i.purgeable)
);
const orphanScanPurgeable = computed(() =>
  (orphanScan.value.items || []).filter((i) => i.purgeable && i.count > 0)
);
// 模板里用的"可清理总行数"
const orphanScanPurgeableCount = computed(() =>
  orphanScanPurgeable.value.reduce((s, i) => s + i.count, 0)
);

async function loadOrphanScan() {
  orphanScan.value.loading = true;
  try {
    orphanScan.value = { ...orphanScan.value, ...(await api.get('/admin/orphans/scan')).data, loaded: true, loading: false };
    const errs = orphanScan.value.errors || [];
    if (errs.length) {
      // 单条关联查不了（老库缺某张表）不该被静默吞掉 —— 那会让"体检通过"变成假象
      ElMessage.warning(`有 ${errs.length} 项关联无法体检：${errs[0].error}`);
    }
  } catch (e) {
    orphanScan.value.loading = false;
    ElMessage.error('数据体检失败：' + (e.response?.data?.error || e.message));
  }
}

const orphanDlg = ref(false);
const orphanDlgBusy = ref(false);
const orphanDlgAck = ref(false);
const orphanDlgItems = ref([]);
const orphanDlgCount = computed(() => orphanDlgItems.value.reduce((s, i) => s + i.count, 0));
const orphanDlgKeys = computed(() => orphanDlgItems.value.map((i) => i.key));
const orphanDlgConfirmed = computed(() => orphanDlgAck.value);

function openOrphanPurge() {
  if (!orphanScanPurgeable.value.length) return;
  // 打开时重扫一次：弹窗里展示的行数必须是**当下**的，不能是进页面时那份快照
  loadOrphanScan().then(() => {
    orphanDlgItems.value = orphanScanPurgeable.value.map((i) => ({ key: i.key, label: i.label, count: i.count }));
    orphanDlgAck.value = false;
    orphanDlg.value = true;
  });
}

async function doOrphanPurge() {
  const keys = orphanDlgKeys.value;
  const count = orphanDlgCount.value;
  if (!keys.length) return;
  orphanDlgBusy.value = true;
  try {
    const r = (await api.post('/admin/orphans/purge', { keys, confirm: count })).data;
    // 有单条失败时 ok 会是 false，deleted 仍可信 —— 要如实告诉管理员"部分失败"
    if (r.errors?.length) {
      ElMessage.warning(`已清理 ${r.deleted} 行，但有 ${r.errors.length} 项出错：${r.errors[0].error}`);
    } else {
      ElMessage.success(`已清理 ${r.deleted} 行孤儿数据` + (r.backup?.name ? `，备份 ${r.backup.name}` : ''));
    }
    orphanDlg.value = false;
    await loadOrphanScan();
  } catch (e) {
    // 409 = 数量变了。这是预期内的并发保护，要提示"重新体检"而不是当成报错
    if (e.response?.status === 409) {
      ElMessage.warning('数据已变化，请重新体检后再确认');
      orphanDlg.value = false;
      await loadOrphanScan();
    } else {
      ElMessage.error('清理失败：' + (e.response?.data?.error || e.message));
    }
  } finally {
    orphanDlgBusy.value = false;
  }
}

function resetFileFilter() {
  fileRange.value = '30d';
  fileCustom.value = null;
  fileOwnerId.value = null;
  fileMime.value = '';
  fileQ.value = '';
  filePager.reset();
}

/* ====== 消息管理 ====== */

const msgRange = ref('30d');
const msgCustom = ref(null);
const msgSenderId = ref(null);
const msgConvId = ref(null);
const msgKind = ref('');
const msgQ = ref('');
const msgMentioned = ref(false);
const msgConvs = ref([]);
// 用于「空状态」判断：不限时间还查不到，说明真的没有数据
const msgNoTimeLimit = computed(() => msgRange.value === 'all');

function msgQueryParams(page, pageSize) {
  const p = new URLSearchParams();
  if (page) p.set('page', String(page));
  if (pageSize) p.set('pageSize', String(pageSize));
  for (const [k, v] of Object.entries(rangeToQuery(msgRange.value, msgCustom.value))) p.set(k, v);
  if (msgSenderId.value) p.set('senderId', String(msgSenderId.value));
  if (msgConvId.value) p.set('conversationId', String(msgConvId.value));
  if (msgKind.value) p.set('kind', msgKind.value);
  if (msgQ.value.trim()) p.set('q', msgQ.value.trim());
  if (msgMentioned.value) p.set('mentioned', '1');
  return p;
}

const msgPager = usePager(async ({ page, pageSize }) =>
  (await api.get('/admin/messages?' + msgQueryParams(page, pageSize).toString())).data);

async function loadMessages() {
  if (!msgConvs.value.length) {
    // 会话下拉需要「全部会话」（原来那个列表群/单聊各 LIMIT 100，第 101 个群选不到）
    try { msgConvs.value = (await api.get('/admin/conversations/options')).data; } catch { /* 下拉拿不到不阻断列表 */ }
  }
  await msgPager.reset();
}

function resetMsgFilter() {
  msgRange.value = '30d';
  msgCustom.value = null;
  msgSenderId.value = null;
  msgConvId.value = null;
  msgKind.value = '';
  msgQ.value = '';
  msgMentioned.value = false;
  msgPager.reset();
}

/** 把当前筛选条件整理成给用户看的摘要（批量清理弹窗必须列清楚删的是什么） */
const msgFilterSummary = computed(() => {
  const out = [`时间：${rangeLabel(msgRange.value)}`];
  if (msgSenderId.value) {
    const u = userOptions.value.find((x) => x.id === msgSenderId.value);
    out.push(`发送者：${u ? (u.nickname || u.username) : '#' + msgSenderId.value}`);
  }
  if (msgConvId.value) {
    const c = msgConvs.value.find((x) => x.id === msgConvId.value);
    out.push(`会话：${c ? c.name : '#' + msgConvId.value}`);
  }
  if (msgKind.value) out.push(`类型：${kindLabel(msgKind.value)}`);
  if (msgMentioned.value) out.push('仅 @提及');
  if (msgQ.value.trim()) out.push(`关键词：${msgQ.value.trim()}`);
  return out;
});
const fileFilterSummary = computed(() => {
  const out = [`时间：${rangeLabel(fileRange.value)}`];
  if (fileOwnerId.value) {
    const u = userOptions.value.find((x) => x.id === fileOwnerId.value);
    out.push(`上传者：${u ? (u.nickname || u.username) : '#' + fileOwnerId.value}`);
  }
  if (fileMime.value) out.push(`类型：${fileMime.value}`);
  if (fileQ.value.trim()) out.push(`文件名：${fileQ.value.trim()}`);
  return out;
});

/* ====== 批量清理（三步安全模型：算条数 → 手输确认 → 服务端重算比对） ====== */

const purgeDlg = ref(false);
const purgeKind = ref('messages');           // messages | files | orphan
const purgePreview = ref(null);
const purgeInput = ref('');
const purgeBusy = ref(false);
const purgeBackup = ref('');
const purgeBackupErr = ref('');

async function openPurge(kind) {
  purgeKind.value = kind;
  purgePreview.value = null;
  purgeInput.value = '';
  purgeBackup.value = '';
  purgeBackupErr.value = '';
  purgeDlg.value = true;
  try {
    if (kind === 'messages') {
      purgePreview.value = (await api.get('/admin/messages/purge-preview?' + msgQueryParams().toString())).data;
    } else if (kind === 'files') {
      purgePreview.value = (await api.get('/admin/files/purge-preview?' + filePurgeParams().toString())).data;
    } else {
      purgePreview.value = (await api.get('/admin/files/purge-preview?orphanOnly=1')).data;
    }
  } catch (e) {
    ElMessage.error('统计失败：' + (e.response?.data?.error || e.message));
    purgeDlg.value = false;
  }
}

function filePurgeParams() {
  const p = new URLSearchParams();
  for (const [k, v] of Object.entries(rangeToQuery(fileRange.value, fileCustom.value))) p.set(k, v);
  if (fileOwnerId.value) p.set('ownerId', String(fileOwnerId.value));
  if (fileMime.value) p.set('mime', fileMime.value);
  if (fileQ.value.trim()) p.set('q', fileQ.value.trim());
  return p;
}

async function doPurge() {
  const pv = purgePreview.value;
  if (!pv) return;
  if (Number(purgeInput.value) !== pv.count) {
    ElMessage.error(`请输入与统计一致的条数：${pv.count}`);
    return;
  }
  purgeBusy.value = true;
  try {
    let r;
    if (purgeKind.value === 'messages') {
      const q = msgQueryParams();
      q.set('confirm', String(pv.count));
      r = await api.post('/admin/messages/purge', Object.fromEntries(q));
    } else if (purgeKind.value === 'files') {
      const q = filePurgeParams();
      q.set('confirm', String(pv.count));
      r = await api.post('/admin/files/purge', Object.fromEntries(q));
    } else {
      r = await api.post('/admin/files/purge', { orphanOnly: '1', confirm: String(pv.count) });
    }
    purgeBackup.value = r.data.backup || '';
    purgeBackupErr.value = r.data.backupError || '';
    ElMessage.success(`已清理 ${r.data.deleted} 条`);
    purgeDlg.value = false;
    if (purgeKind.value === 'files' || purgeKind.value === 'orphan') { await loadFiles(); }
    else await msgPager.load();
  } catch (e) {
    const st = e.response?.status;
    ElMessage.error(st === 409 ? (e.response.data?.error || '数量已变化，请重新确认') : ('清理失败：' + (e.response?.data?.error || e.message)));
    // 409 说明数据变了，刷新统计让用户看到新的条数再决定
    if (st === 409) openPurge(purgeKind.value);
  } finally { purgeBusy.value = false; }
}

/** 清理弹窗里列出"到底删的是什么条件"，一个都不能少 —— 用户据此判断有没有点错 */
const purgeScopeLines = computed(() => {
  if (purgeKind.value === 'orphan') return ['磁盘上未被数据库记录的残留文件'];
  return purgeKind.value === 'messages' ? msgFilterSummary.value : fileFilterSummary.value;
});

function kindLabel(k) {
  return { text: '文字', image: '图片', file: '文件', audio: '语音', emoji: '表情', card: '卡片' }[k] || k;
}

function kindTag(k) {
  return { text: 'success', image: 'warning', audio: 'danger', file: 'info', card: 'primary' }[k] || 'info';
}
async function loadInfo() { info.value = (await api.get('/admin/info')).data; }

/* ---- 文件存储目录自定义（写 paths.env，重启生效，启动自动搬文件） ---- */
const fdEdit = ref(false);
const fdValue = ref('');
const fdBusy = ref(false);
function fdStart() {
  fdValue.value = info.value.files_dir_custom ? info.value.files_dir : '';
  fdEdit.value = true;
}
async function fdSave() {
  fdBusy.value = true;
  try {
    const r = await api.post('/admin/files-dir', { dir: fdValue.value.trim() });
    ElMessage.success(r.data.message || '已保存，重启服务端后生效');
    fdEdit.value = false;
    await loadInfo();
  } catch (e) {
    ElMessage.error(e.response?.data?.error || e.message || '保存失败');
  } finally {
    fdBusy.value = false;
  }
}

// ====== 客户端配置中心（v0.8.0 第一期） ======
const cc = ref({ current: { version: 0, payload: {} }, history: [] });
const ccApplied = ref({ latest: 0, devices: [] });
const ccDiffDlg = ref(false);
const ccDiff = ref([]);
const ccNote = ref('');
const ccBusy = ref(false);
// 表单模型：从线上 payload 展开成好编辑的形状
const ccForm = ref({
  addrs: [],           // [{ type, url }]  type ∈ lan/ipv4/ipv6/other
  features: [],        // [{ key, on }]
  minVersion: '',
  upgradeUrl: '',      // 通用升级说明页（浏览器打开）
  pkgAndroid: '',      // 安卓直装包地址（APK）
  pkgWindows: '',      // Windows 直装包地址（exe）
  pkgIos: '',          // iOS 链接（App Store 等）
  announcements: [],   // [{ text, level }]
  maintOn: false,
  maintText: '',
});

// 安装包上传：隐藏 file input + 当前正在传的平台
const pkgFileEl = ref(null);
const pkgUploading = ref(false);
const pkgUploadingPlatform = ref('');

async function onPkgFile(e) {
  const file = e.target.files?.[0];
  e.target.value = '';
  if (!file) return;
  const platform = pkgUploadingPlatform.value;
  pkgUploading.value = true;
  try {
    const fd = new FormData();
    fd.append('file', file);
    const { data } = await api.post('/files/upload-package', fd);
    if (platform === 'android') ccForm.value.pkgAndroid = data.url;
    else if (platform === 'windows') ccForm.value.pkgWindows = data.url;
    else if (platform === 'ios') ccForm.value.pkgIos = data.url;
    ElMessage.success(`已上传到 ${data.url}`);
  } catch (err) { trErr(err, '上传安装包失败'); }
  finally { pkgUploading.value = false; pkgUploadingPlatform.value = ''; }
}

function pkgPick(platform) {
  pkgUploadingPlatform.value = platform;
  pkgFileEl.value?.click();
}

function payloadToForm(p) {
  const rawAddrs = p.serverAddresses || [];
  const addrs = rawAddrs.map((a) => (typeof a === 'string'
    ? { type: 'other', url: a }
    : { type: a.type || 'other', url: a.url || '' }));
  return {
    addrs,
    features: Object.entries(p.features || {}).map(([key, on]) => ({ key, on: !!on })),
    minVersion: p.minClientVersion || '',
    upgradeUrl: p.upgradeUrl || '',
    pkgAndroid: (p.upgradePackages && p.upgradePackages.android) || '',
    pkgWindows: (p.upgradePackages && p.upgradePackages.windows) || '',
    pkgIos: (p.upgradePackages && p.upgradePackages.ios) || '',
    announcements: (p.announcements || []).map((a) => ({ text: a.text, level: a.level || 'info' })),
    maintOn: !!p.maintenance,
    maintText: p.maintenance?.text || '',
  };
}

function formToPayload() {
  const p = {
    // 地址：ipv4/ipv6 保持 {url,type} 对象（老客户端不识别会丢弃，但这两类本就需要新客户端）；
    // 其余类型（lan/wan/other）回退成字符串，保证老客户端仍能识别。
    serverAddresses: ccForm.value.addrs
      .map((a) => ({ type: a.type || 'other', url: String(a.url || '').trim().replace(/\/+$/, '') }))
      .filter((a) => a.url)
      .map((a) => (a.type === 'ipv4' || a.type === 'ipv6') ? { url: a.url, type: a.type } : a.url),
    features: {},
    announcements: ccForm.value.announcements.filter((a) => a.text.trim()).map((a) => ({ text: a.text.trim(), level: a.level })),
  };
  for (const f of ccForm.value.features) {
    const k = f.key.trim();
    if (k) p.features[k] = !!f.on;
  }
  if (ccForm.value.minVersion.trim()) p.minClientVersion = ccForm.value.minVersion.trim();
  // 按平台安装包 + 通用升级页
  const pkgs = {};
  if (ccForm.value.pkgAndroid.trim()) pkgs.android = ccForm.value.pkgAndroid.trim();
  if (ccForm.value.pkgWindows.trim()) pkgs.windows = ccForm.value.pkgWindows.trim();
  if (ccForm.value.pkgIos.trim()) pkgs.ios = ccForm.value.pkgIos.trim();
  if (Object.keys(pkgs).length) p.upgradePackages = pkgs;
  if (ccForm.value.upgradeUrl.trim()) p.upgradeUrl = ccForm.value.upgradeUrl.trim();
  if (ccForm.value.maintOn && ccForm.value.maintText.trim()) p.maintenance = { text: ccForm.value.maintText.trim(), until: null };
  return p;
}

const brief = (v) => {
  const s = JSON.stringify(v) ?? '—';
  return s.length > 120 ? s.slice(0, 120) + '…' : s;
};

async function loadCc() {
  const { data } = await api.get('/admin/client-config');
  cc.value = data;
  ccForm.value = payloadToForm(data.current.payload || {});
}

async function loadCcApplied() {
  ccApplied.value = (await api.get('/admin/client-config/applied')).data;
}

function openCcDiff() {
  const next = formToPayload();
  const cur = cc.value.current.payload || {};
  const keys = new Set([...Object.keys(next), ...Object.keys(cur)]);
  ccDiff.value = [];
  for (const k of keys) {
    if (JSON.stringify(next[k] ?? null) !== JSON.stringify(cur[k] ?? null)) {
      ccDiff.value.push({ key: k, old: brief(cur[k] ?? null), neu: brief(next[k] ?? null) });
    }
  }
  ccNote.value = '';
  ccDiffDlg.value = true;
}

async function publishCc() {
  ccBusy.value = true;
  try {
    const { data } = await api.post('/admin/client-config', { payload: formToPayload(), note: ccNote.value });
    ElMessage.success(`已发布 v${data.version}`);
    ccDiffDlg.value = false;
    await loadCc();
  } catch (e) {
    ElMessage.error('发布失败：' + (e.response?.data?.error || e.message));
  } finally {
    ccBusy.value = false;
  }
}

async function rollbackCc(v) {
  try {
    await ElMessageBox.confirm(`用 v${v} 的内容发布一个新版本？历史记录不会改动。`, '回滚确认', { type: 'warning' });
  } catch { return; }
  try {
    const { data } = await api.post('/admin/client-config/rollback', { version: v });
    ElMessage.success(`已回滚：发布为 v${data.version}`);
    await loadCc();
  } catch (e) {
    ElMessage.error('回滚失败：' + (e.response?.data?.error || e.message));
  }
}

// ====== 动态模块（v0.9.0 第二期） ======
// 设计取向：管理台**不**做"自由 JSON 编辑"，只提供结构化表单。
// 因为服务端 schema 校验是硬约束（未知组件/写死颜色/非 hooks 路径一律拒绝），
// 让管理员手写 JSON 等于把校验错误留到点保存时才暴露，体验很差。
const mm = ref({
  modules: [],
  capability: {
    components: [], colors: [], fieldTypes: [], actions: [],
    navPages: [], icons: [], chartKinds: [], maxDepth: 4, maxComponents: 150,
  },
});
const mmSel = ref('');        // 当前编辑中的 moduleId（'' = 新建）
const mmBusy = ref(false);
const mmJsonDlg = ref(false);
const mmSubsDlg = ref(false);
const mmSubs = ref([]);
const mmForm = ref(newModuleForm());

const mmActionTypes = [
  { value: 'api', label: '调用接口 /api/hooks/*' },
  { value: 'navigate', label: '跳内置页面' },
  { value: 'copy', label: '复制文本' },
  { value: 'openUrl', label: '打开网页（https）' },
];

/** 空的新模块：给一个能立刻保存的最小合法结构 */
function newModuleForm() {
  return {
    moduleId: '',
    title: '',
    icon: 'dashboard',
    sort: 0,
    minClientVersion: '',
    enabled: true,
    roles: [],
    userIds: [],
    body: [blankComp('text')],
  };
}

function blankComp(type) {
  switch (type) {
    case 'text': return { component: 'text', text: '', size: 15, color: 'defaultColor', align: 'left' };
    case 'divider': return { component: 'divider' };
    case 'card': return { component: 'card', title: '', subtitle: '', accent: 'primary', children: [] };
    case 'list':
      return { component: 'list', dataPath: 'data.items', itemTemplate: { title: '', subtitle: '', trailing: '' } };
    case 'table': return { component: 'table', dataPath: 'data.rows', columns: [{ key: '', label: '', width: undefined }] };
    case 'form': return { component: 'form', fields: [{ key: '', label: '', type: 'text', required: false, options: [] }] };
    case 'action': return { component: 'action', label: '', color: 'primary', onTap: { action: 'api', path: '/api/hooks/', method: 'GET' } };
    case 'chart': return { component: 'chart', dataPath: 'data.rows', xKey: 'x', yKey: 'y', kind: 'bar' };
    default: return { component: type };
  }
}

const COMP_LABEL = {
  text: '文字', divider: '分隔线', card: '卡片', list: '列表',
  table: '表格', form: '表单', action: '按钮', chart: '图表',
};
const compLabel = (k) => COMP_LABEL[k] || k;

function visibleLabel(m) {
  const r = m.visibleTo?.roles || [];
  const u = m.visibleTo?.userIds || [];
  if (!r.length && !u.length) return '所有人可见';
  const parts = [];
  if (r.length) parts.push('角色 ' + r.join('/'));
  if (u.length) parts.push(`${u.length} 个指定用户`);
  return parts.join(' + ');
}

async function loadMm() {
  const { data } = await api.get('/admin/modules');
  mm.value = data;
}

function selectModule(m) {
  mmSel.value = m.moduleId;
  mmForm.value = {
    moduleId: m.moduleId,
    title: m.title,
    icon: m.icon || 'dashboard',
    sort: m.sort || 0,
    minClientVersion: m.minClientVersion || '',
    enabled: !!m.enabled,
    roles: [...(m.visibleTo?.roles || [])],
    userIds: [...(m.visibleTo?.userIds || [])],
    // 深拷贝：编辑中直接改 form，只有点保存才发出去（避免误改未保存就"生效"的错觉）
    body: JSON.parse(JSON.stringify(m.body || [])),
  };
}

function newModule() {
  mmSel.value = '';
  mmForm.value = newModuleForm();
}

function addComp(type) {
  mmForm.value.body.push(blankComp(type));
}

function moveComp(i, d) {
  const a = mmForm.value.body;
  const j = i + d;
  if (j < 0 || j >= a.length) return;
  [a[i], a[j]] = [a[j], a[i]];
}

/** 卡内组件：只开放"不嵌套"的类型，避免管理台里做出 4 层嵌套后自己都看不明白 */
function addChild(card) {
  if (!card.children) card.children = [];
  card.children.push(blankComp('text'));
}

/** 把表单模型转成要提交的 schema（与 appmodules.js 的 validate 对齐） */
function mmPayload() {
  const f = mmForm.value;
  const out = {
    moduleId: f.moduleId.trim(),
    title: f.title.trim(),
    icon: f.icon,
    sort: Number(f.sort) || 0,
    enabled: !!f.enabled,
    minClientVersion: f.minClientVersion.trim() || null,
    visibleTo: { roles: [...f.roles], userIds: [...f.userIds] },
    body: JSON.parse(JSON.stringify(f.body)),
  };
  return out;
}

const mmJson = computed(() => JSON.stringify(mmPayload(), null, 2));

async function saveModule() {
  const f = mmForm.value;
  if (!f.moduleId.trim()) return ElMessage.warning('请填写模块 ID');
  if (!f.title.trim()) return ElMessage.warning('请填写标题');
  mmBusy.value = true;
  try {
    const { data } = await api.post('/admin/modules', mmPayload());
    ElMessage.success(`已保存「${data.module.title}」，客户端下拉刷新即可看到`);
    mmSel.value = data.module.moduleId;
    await loadMm();
    const fresh = mm.value.modules.find((x) => x.moduleId === data.module.moduleId);
    if (fresh) selectModule(fresh);
  } catch (e) {
    // 服务端校验失败会把原因写清楚（哪个组件、哪个字段），直接展示给管理员
    ElMessage.error({ message: '保存失败：' + (e.response?.data?.error || e.message), duration: 6000 });
  } finally {
    mmBusy.value = false;
  }
}

async function deleteModule(id) {
  try {
    await ElMessageBox.confirm(
      `删除模块「${id}」？客户端下次刷新后入口就消失。提交记录会保留在数据库里。`,
      '删除确认', { type: 'warning' });
  } catch { return; }
  try {
    await api.delete(`/admin/modules/${id}`);
    ElMessage.success('已删除');
    if (mmSel.value === id) newModule();
    await loadMm();
  } catch (e) {
    ElMessage.error('删除失败：' + (e.response?.data?.error || e.message));
  }
}

async function openSubs(id) {
  try {
    const { data } = await api.get(`/admin/modules/${id}/submissions`);
    mmSubs.value = data.items || [];
    mmSubsDlg.value = true;
  } catch (e) {
    ElMessage.error('读取提交记录失败：' + (e.response?.data?.error || e.message));
  }
}

function applyTemplate(t) {
  const m = JSON.parse(JSON.stringify(t.module));
  mmSel.value = '';
  mmForm.value = {
    moduleId: m.moduleId,
    title: m.title,
    icon: m.icon || 'dashboard',
    sort: m.sort || 0,
    minClientVersion: m.minClientVersion || '',
    enabled: m.enabled !== false,
    roles: m.visibleTo?.roles || [],
    userIds: m.visibleTo?.userIds || [],
    body: m.body || [],
  };
  ElMessage.info(`已载入模板「${t.name}」，确认内容后点保存`);
}

// ====== 上游接口（动态模块第三期：让列表 / 表格 / 图表真能取到数） ======
// 这一页要解决的是"**点进来看**"而不是"推到群里刷屏"：地址登记一次，
// 员工的动态模块按需拉数。所以界面上必须让人①一眼看到客户端该填哪条路径
// ②一键试跑看到真实返回形状 —— 否则管理员只能靠猜字段名去拼表格列。
const us = ref({
  list: [],
  capability: { methods: [], defaultTimeout: 10000, minTimeout: 1000, maxTimeout: 30000 },
  pathPrefix: '/api/hooks/up/',
});
const usDlg = ref(false);
const usBusy = ref(false);
const usSel = ref('');          // 正在编辑的接口名（'' = 新建）
const usProbing = ref(0);
const usTestDlg = ref(false);
const usTestName = ref('');
const usTestSub = ref('');
const usTestBusy = ref(false);
const usTestOut = ref('');
const usTestErr = ref('');
const usTestMeta = ref('');
const usEditingHasAuth = ref(false);   // 编辑的这条是否已存凭据 → 决定 placeholder 与"清空"勾选框

function usNewForm() {
  return {
    name: '', label: '', baseUrl: '', authHeader: '', clearAuth: false,
    timeoutMs: 10000, allowRoles: [], enabled: true,
  };
}
const usForm = ref(usNewForm());

async function loadUs() {
  try {
    const { data } = await api.get('/admin/upstreams');
    us.value = {
      list: data.upstreams || [],
      capability: data.capability || us.value.capability,
      pathPrefix: data.capability?.pathPrefix || '/api/hooks/up/',
    };
  } catch (e) {
    ElMessage.error('读取上游接口失败：' + (e.response?.data?.error || e.message));
  }
}

function openUsDialog(row) {
  if (row) {
    usSel.value = row.name;
    usEditingHasAuth.value = !!row.hasAuth;
    usForm.value = {
      name: row.name,
      label: row.label || '',
      baseUrl: row.baseUrl || '',
      // 刻意留空：服务端不回显凭据明文，空 = 不改。填了才覆盖。
      authHeader: '',
      clearAuth: false,
      timeoutMs: row.timeoutMs || us.value.capability.defaultTimeout,
      allowRoles: [...(row.allowRoles || [])],
      enabled: !!row.enabled,
    };
  } else {
    usSel.value = '';
    usEditingHasAuth.value = false;
    usForm.value = usNewForm();
  }
  usDlg.value = true;
}

async function saveUs() {
  const f = usForm.value;
  if (!f.name.trim()) return ElMessage.warning('请填接口名');
  if (!f.baseUrl.trim()) return ElMessage.warning('请填上游地址');

  const body = {
    name: f.name.trim().toLowerCase(),
    label: f.label,
    baseUrl: f.baseUrl.trim(),
    timeoutMs: f.timeoutMs,
    allowRoles: f.allowRoles,
    enabled: f.enabled,
  };
  // 凭据三态：勾了清空 > 填了新的 > 没动。
  // **没动时不下发这个字段**，服务端才会保持原值（这是"不回显明文"能成立的前提）。
  if (f.clearAuth) body.authHeader = '';
  else if (f.authHeader.trim()) body.authHeader = f.authHeader.trim();

  usBusy.value = true;
  try {
    await api.post('/admin/upstreams', body);
    ElMessage.success(f.enabled ? '已保存' : '已保存（当前为停用状态，客户端取不到数）');
    usDlg.value = false;
    await loadUs();
  } catch (e) {
    ElMessage.error('保存失败：' + (e.response?.data?.error || e.message));
  } finally { usBusy.value = false; }
}

async function toggleUs(row) {
  try {
    // 只提交 enabled —— 服务端支持部分更新，不会因为"没带地址"而失败
    await api.post('/admin/upstreams', { name: row.name, enabled: !row.enabled });
    await loadUs();
  } catch (e) {
    ElMessage.error('操作失败：' + (e.response?.data?.error || e.message));
  }
}

async function delUs(row) {
  try {
    await ElMessageBox.confirm(
      `删除上游「${row.name}」后，用到它的动态模块会立刻取不到数（客户端会看到"没有登记"）。确定删除？`,
      '删除确认', { type: 'warning' });
  } catch { return; }
  try {
    await api.delete(`/admin/upstreams/${row.id}`);
    ElMessage.success('已删除');
    await loadUs();
  } catch (e) {
    ElMessage.error('删除失败：' + (e.response?.data?.error || e.message));
  }
}

async function probeUs(row) {
  usProbing.value = row.id;
  try {
    const { data } = await api.post(`/admin/upstreams/${row.id}/probe`);
    if (data.reachable) ElMessage.success(`通得了：HTTP ${data.status}，${data.ms}ms`);
    else ElMessage.warning(`连不上：${data.error}（地址写错了？还是服务端到不了这个网段？）`);
  } catch (e) {
    ElMessage.error('探活失败：' + (e.response?.data?.error || e.message));
  } finally { usProbing.value = 0; }
}

function openUsTest(row) {
  usTestName.value = row.name;
  usTestSub.value = '';
  usTestOut.value = '';
  usTestErr.value = '';
  usTestMeta.value = '';
  usTestDlg.value = true;
}

async function runUsTest() {
  const row = us.value.list.find((x) => x.name === usTestName.value);
  if (!row) return;
  usTestBusy.value = true;
  usTestErr.value = '';
  usTestOut.value = '';
  usTestMeta.value = '';
  try {
    const { data } = await api.post(`/admin/upstreams/${row.id}/test`,
      { subPath: usTestSub.value.trim() });
    // ⚠️ 显示**整包**，不是只显示 data 里的内容。
    // 只显示内层的话，管理员照着看到的字段名去填 dataPath 会少个 data. 前缀，
    // 到客户端就取不到值 —— 而他在管理台里看到的每一样都是对的，无从怀疑。
    usTestMeta.value = `HTTP ${data.status} · ${data.ms}ms · ${data.url}`;
    usTestOut.value = JSON.stringify(data, null, 2);
  } catch (e) {
    // 502 也走这里：把服务端那句"没有登记 / 已停用 / 超时 / 连不上"原样给人看，
    // 排障时才能一眼知道该改哪儿
    usTestErr.value = e.response?.data?.error || e.message;
  } finally { usTestBusy.value = false; }
}

/* ====== 商品档案（商档）======
   盘点的底表：手机扫出来的每一行靠它显示成人看得懂的名字，差异表靠它算金额。
   这份底表原先进不了服务端（只能从泰格上游拉），所以 /api/master 把它收进来：
   管理台导入一次，手机拉同一份。

   ⚠️ 它**不是差异的基准**：门店系统里没有可用的库存账面（泰格库的库存表全是空的），
   拿账面比会得到"差异集 = 全部商品"。实际口径是三遍平行互比（复盘比初盘、
   抽盘比复盘），`account_qty` 只作参考列。

   🔴 分块写 + commit 的两步语义必须在界面上说清楚：
   12 万行要传 60 多块，传到一半网断了 —— 这时候旧档案必须是**完好的**，
   否则店里会拿着一份缺一半的底表去盘，而界面上什么都看不出来。
   所以写块只管 UPSERT，全部传完才调 commit 换掉旧数据。
   中断时那句提示要明说"旧数据不受影响"，不然管理员会因为怕丢数据而不敢重导。 */
const master = ref({ total: 0, updated_at: 0, list: [], page: 1, pageSize: 20 });
const masterImport = ref({ running: false, done: 0, total: 0, rejected: 0 });
const masterFileEl = ref(null);

async function loadMaster() {
  try {
    const { data } = await api.get('/master/count');
    master.value.total = data.total || 0;
    master.value.updated_at = data.updated_at || 0;
    await loadMasterPage(1);
  } catch (e) {
    ElMessage.error('读取商品档案失败：' + (e.response?.data?.error || e.message));
  }
}

async function loadMasterPage(page) {
  try {
    const { data } = await api.get(`/master/?page=${page}&pageSize=${master.value.pageSize}`);
    master.value.list = data.items || [];
    master.value.page = page;
  } catch (e) {
    ElMessage.error('读取商品档案失败：' + (e.response?.data?.error || e.message));
  }
}

/** 门店导出的 txt/csv 多是 GBK：先按 GBK 解，替换字符多就退回 UTF-8。 */
function readFileText(file) {
  return new Promise((resolve, reject) => {
    const fr = new FileReader();
    fr.onerror = () => reject(new Error('文件读取失败'));
    fr.onload = () => {
      const buf = fr.result;
      let s = '';
      try { s = new TextDecoder('gbk').decode(buf); } catch { s = ''; }
      const bad = (s.match(/\uFFFD/g) || []).length;
      if (!s || bad > Math.max(3, s.length * 0.001)) s = new TextDecoder('utf-8').decode(buf);
      resolve(s);
    };
    fr.readAsArrayBuffer(file);
  });
}

/**
 * 按分隔符切一行 CSV，**认得引号包裹**。
 *
 * 🔴 不能直接 `line.split(',')`（2026-09-27 被测试当场抓出来）：
 *    Excel 导出的价格常常是带千分位的 `"¥1,280.00"`，**字段内部的逗号会被
 *    当成分隔符**，于是这一行从价格开始整列错位 —— 进价吃掉了售价、
 *    售价吃掉了库存，错得还挺整齐，界面上完全看不出来。
 *    CSV 的规矩是：字段被双引号包起来时，内部的逗号属于内容；
 *    字段内部的双引号写成两个（`""`）表示一个字面引号。
 */
function splitCsvLine(line, delim) {
  const out = [];
  let cur = '';
  let inQuotes = false;
  for (let i = 0; i < line.length; i++) {
    const ch = line[i];
    if (inQuotes) {
      if (ch === '"') {
        if (line[i + 1] === '"') { cur += '"'; i++; }   // "" → 一个引号
        else inQuotes = false;
      } else {
        cur += ch;
      }
    } else if (ch === '"') {
      inQuotes = true;
    } else if (ch === delim) {
      out.push(cur); cur = '';
    } else {
      cur += ch;
    }
  }
  out.push(cur);
  return out.map((c) => c.trim());
}

/**
 * 解析成龙哥定的**标准商档列**（2026-09-26 定七列，2026-10-06 加会员价/特价，
 *    2026-10-10 加供应商）：
 *     { barcode 条码, name 名称, spec 规格, unit 单位,
 *       purchase_price 进价, unit_price 售价,
 *       member_price 会员价, special_price 特价, account_qty 库存, supplier 供应商 }
 *
 * 🔴 为什么必须齐着这些列读（2026-09-26 的血泪）：早先这个解析器只读
 *    {barcode, name, account_qty} 三列，**其余列一律丢弃**。于是门店按
 *    「条码/名称/规格/单位/进价/售价/库存」导进来的表，落到库里只剩三个字段 ——
 *    线上 12.6 万行商档「规格」和「单位」都是 0%，不是档案里没有，
 *    是**根本没读进来**。而它不报错、不警告，导入照样显示成功。
 *    少读字段比读错字段更难发现，因为一切看起来都正常。
 *
 * ⚠️ 列是**龙哥 2026-09-27 加了「单位」、2026-10-06 加了「会员价/特价」、
 *    2026-10-10 加了「供应商」**之后的样子：
 *     条码 | 名称 | 规格 | 单位 | 进价 | 售价 | 会员价 | 特价 | 库存 | 供应商
 *    「单位」不是可有可无的附带信息：补货那套「非称重按最小单位、
 *    称重按公斤」的判据就是它，缺了就只能一律按最小单位走。
 *    会员价/特价/供应商**允许没有**：老档案不带这几列照样导，落库就是 NULL。
 *
 * 认两种形状：带表头（按列名找）/ 不带表头（序号,条码,名字,数量）。
 * 🔴 序号列的判定要**严格**：门店编码常常就是 1001、1002 这种四位数，
 *    宽松判定会把"第一列是编码"误认成序号，于是整表的条码列错位一格 ——
 *    导入完看着"有 12 万行"，实际条码全是门店编码，盘点时一个都对不上。
 */
function parseMasterCsv(text) {
  const lines = String(text || '').replace(/^\uFEFF/, '').split(/\r?\n/).filter((l) => l.trim());
  if (!lines.length) return [];
  const probe = lines[0];
  const delim = probe.includes('\t') ? '\t' : (probe.includes(',') ? ',' : (probe.includes(';') ? ';' : '\t'));
  const cells = lines.map((l) => splitCsvLine(l, delim));

  const head = cells[0].map((c) => c.toLowerCase());

  // 已经分配出去的列下标。**这一步是给「单位」留的**：
  //   `unit` 和 `unit_price` 是前缀关系，用裸 includes 匹配时
  //   `unit` 会命中 `unit_price` 那一列 —— 英文表头下单位就会串到售价上。
  //   所以按"先具体、后宽泛"的顺序取，并把取过的列排掉。
  const taken = new Set();
  const find = (keys) => {
    // 先全等（表头就叫"单位"/"售价"），再包含（"基本单位"/"零售价"）
    for (const k of keys) {
      const i = head.findIndex((h, j) => h === k && !taken.has(j));
      if (i >= 0) { taken.add(i); return i; }
    }
    for (const k of keys) {
      const i = head.findIndex((h, j) => h.includes(k) && !taken.has(j));
      if (i >= 0) { taken.add(i); return i; }
    }
    return -1;
  };

  // 🔴 '商品条码' 必须排在 '条码' 之前：两者用 includes 匹配，都能命中
  //    「商品条码」这一列，先命中谁就用谁 —— 结果没差别，但顺序固定了，
  //    后来看代码的人不用猜。
  const hb = find(['商品条码', '条码', 'barcode', '商品编码', '国际条码']);
  let start = 0;
  let idx;
  let noHeadNine = false;   // 无表头且识别为标准九列（嗅探在 money 定义之后做）
  let priceSwapped = false; // 嗅探判定"售价在前"已自动对调（return 前挂到 out 上）
  if (hb >= 0) {
    start = 1;
    idx = {
      barcode: hb,
      name: find(['商品名称', '商品名字', '品名', '名称', 'name']),
      spec: find(['规格', '型号', 'spec']),
      // ⚠️ 价格必须排在「单位」前面取（见上面 taken 那段），
      //    否则 unit 会把 unit_price 抢走，售价变成空、单位变成价格。
      unit_price: find(['售价', '零售价', '单价', 'price', 'unit_price']),
      purchase_price: find(['进价', '成本价', '采购价', 'purchase']),
      // 会员价/特价（2026-10-06）：找不到就 -1，行里落 null —— 老档案不带这两列照样导。
      // ⚠️ '会员价' 必须在 '售价' 之后取没关系（表头全等优先），
      //    但 '特价' 要防把「特价一」「今日特价」之外的列误吞，保持全等+包含两级即可。
      member_price: find(['会员价', '会员价格', 'member_price']),
      special_price: find(['特价', '促销价', 'special_price']),
      unit: find(['单位', '基本单位', '计价单位', 'unit']),
      account_qty: find(['库存', '账面', '数量', 'qty']),
      supplier: find(['供应商', '供货商', 'supplier', '厂商']),
    };
  } else {
    // 没有表头。按**列数**分流，列数不对宁可少读不错位：
    //  ① 标准九列（龙哥 2026-10-06 定版）：
    //     条码,商品名,规格,单位,进价,售价,会员价,特价,库存数（参考）
    //     —— ERP/POS 直接导出来的原始文件往往没有表头行。
    //  ② 老的简四列：序号,条码,名字,数量（第一列严格等于行号才认序号列，
    //     🔴 判定必须严格：门店编码常是 1001 这种四位数，宽松判定会把
    //     "第一列是编码"误认成序号，整表条码错位一格）。
    const sample = cells.slice(0, Math.min(cells.length, 5));
    const hasSerial = cells.length >= 2 && sample.every((c, i) => c[0] === String(i + 1));
    if (!hasSerial && sample.every((c) => c.length === 9)) {
      idx = {
        barcode: 0, name: 1, spec: 2, unit: 3,
        // 按龙哥定的顺序：进价第 5、售价第 6。
        // ⚠️ 若文件实际是"售价在前"，下面（money 定义之后）会嗅探自动对调。
        purchase_price: 4, unit_price: 5,
        member_price: 6, special_price: 7, account_qty: 8,
      };
      noHeadNine = true;
    } else if (!hasSerial && sample.every((c) => c.length === 10)) {
      // 九列 + 供应商（可选列，位置在库存之后）。同样支持"售价在前"嗅探。
      idx = {
        barcode: 0, name: 1, spec: 2, unit: 3,
        purchase_price: 4, unit_price: 5,
        member_price: 6, special_price: 7, account_qty: 8,
        supplier: 9,
      };
      noHeadNine = true;
    } else {
      idx = hasSerial
        ? { barcode: 1, name: 2, account_qty: 3 }
        : { barcode: 0, name: 1, account_qty: 2 };
    }
  }

  // 价格/数量都可能带着 ¥、空格、千分位逗号（"1,280.00"），
  // 只保数字、小数点、负号 —— 账面数出现负数是正常的（盘的货比账多）。
  const money = (v) => {
    const s = String(v ?? '').replace(/[^0-9.\-]/g, '');
    if (s === '' || s === '-') return null;
    const n = Number(s);
    return Number.isFinite(n) ? n : null;
  };

  // 🔴 价格列嗅探（只对无表头九列做）：定版顺序是「进价，售价」，但门店
  //    ERP/POS 导出的原始文件常是**售价在前**（本店 12.6 万行第 5 列几乎
  //    全大于第 6 列 —— 零售价高于进价是常识）。取前 200 行数据统计：
  //    ≥80% 的行第 5 列 > 第 6 列就判定为"售价在前"，自动对调进价/售价
  //    两列，并在导入提示里黄字说明（不黑箱，看得见、能否决）。
  if (noHeadNine) {
    let gt = 0, cnt = 0;
    for (let i = 1; i < Math.min(cells.length, 201); i++) {
      const a = money(cells[i][4]), b = money(cells[i][5]);
      if (a === null || b === null || a === b) continue;
      cnt++;
      if (a > b) gt++;
    }
    if (cnt >= 20 && gt / cnt >= 0.8) {
      const t = idx.purchase_price;
      idx.purchase_price = idx.unit_price;
      idx.unit_price = t;
      priceSwapped = true;
    }
  }

  const out = [];
  // 🔴 列数和表头不一致 = 这一行**整列错位**了（分隔符猜错、或字段里有
  //    没加引号的逗号）。错位最坏的地方是"看着挺整齐"：进价吃售价、
  //    售价吃库存，界面上一点异常都没有。所以数出来，让导入前那一栏能警告。
  let colMismatch = 0;
  for (let i = start; i < cells.length; i++) {
    const c = cells[i];
    if (hb >= 0 && c.length !== head.length) colMismatch++;
    const barcode = (c[idx.barcode] || '').trim();
    if (!barcode) continue;
    out.push({
      barcode,
      name: idx.name >= 0 ? (c[idx.name] || '') : '',
      spec: idx.spec >= 0 ? (c[idx.spec] || '') : '',
      unit: idx.unit >= 0 ? (c[idx.unit] || '') : '',
      purchase_price: idx.purchase_price >= 0 ? money(c[idx.purchase_price]) : null,
      unit_price: idx.unit_price >= 0 ? money(c[idx.unit_price]) : null,
      member_price: idx.member_price >= 0 ? money(c[idx.member_price]) : null,
      special_price: idx.special_price >= 0 ? money(c[idx.special_price]) : null,
      account_qty: idx.account_qty >= 0 ? money(c[idx.account_qty]) : null,
      supplier: idx.supplier >= 0 ? (c[idx.supplier] || '').trim() : '',
    });
  }
  // 挂在数组上带出去（改返回结构会动到所有调用点，没必要）
  out.colMismatch = colMismatch;
  out.noHeadPriceSwapped = priceSwapped;
  return out;
}

function pickMasterFile() { masterFileEl.value?.click(); }

async function onMasterFile(e) {
  const file = e.target.files?.[0];
  e.target.value = '';            // 清掉，否则再选同一个文件不触发 change
  if (!file) return;
  let rows;
  try {
    rows = parseMasterCsv(await readFileText(file));
  } catch (err) {
    ElMessage.error('读文件失败：' + err.message);
    return;
  }
  if (!rows.length) {
    ElMessage.error('没解析出任何行。至少要能找到「条码」这一列。');
    return;
  }

  // 🔴 导入前把**每列读到几行**摆出来 —— 这是防"少读字段"的最后一道护栏。
  //    2026-09-26 线上 12.6 万行商档「规格」「单位」全是 0%，根因就是解析器
  //    只读了三列、**静默丢弃其余**。它不报错、不警告，导入显示成功，
  //    直到三个月后要拿单位判定补货口径才发现。
  //    现在这一栏摆在这儿：哪一列读了 0 行，导入前一眼就能看见。
  const stat = (k) => rows.filter((r) => {
    const v = r[k];
    return v !== null && v !== undefined && v !== '';
  }).length;
  const fields = [
    ['条码', 'barcode'], ['名称', 'name'], ['规格', 'spec'], ['单位', 'unit'],
    ['进价', 'purchase_price'], ['售价', 'unit_price'],
    ['会员价', 'member_price'], ['特价', 'special_price'],
    ['库存', 'account_qty'], ['供应商', 'supplier'],
  ];
  // 会员价/特价/供应商允许整列缺失（老档案不带），不进 missing 警告。
  const optionalFields = new Set(['member_price', 'special_price', 'supplier']);
  const missing = fields
    .filter(([label, k]) => stat(k) === 0 && !optionalFields.has(k))
    .map(([label]) => label);
  const statLine = fields.map(([label, k]) => `${label} <b>${stat(k)}</b>`).join(' / ');
  const warnHtml = missing.length
    ? `<div style="margin-top:8px;color:#e6a23c">⚠️ 这几列<b>一行都没读到</b>：${missing.join('、')}`
      + ` —— 文件里没有这一列，或列名不认识（认的是：`
      + `条码 / 名称 / 规格 / 单位 / 进价 / 售价 / 会员价 / 特价 / 库存）。<br>`
      + `缺了也能导，但下游要用的地方会一直显示"—"（比如补货按单位判称重口径）。</div>`
    : '';
  // 列数不齐 = 整行错位（进价吃售价、售价吃库存）。这种错"看着很整齐"，
  // 界面上完全看不出异常，所以必须在这里明说。
  const mis = rows.colMismatch || 0;
  const misHtml = mis
    ? `<div style="margin-top:8px;color:#f56c6c">🔴 有 <b>${mis}</b> 行的列数和表头对不上 `
      + `—— 这些行<b>整列错位</b>了：多半是字段里有逗号却没加引号`
      + `（价格带千分位很常见，如 ¥1,280.00 必须写成 "¥1,280.00"）。<br>`
      + `建议先在 Excel 里另存为 CSV 再导，别直接从表格复制。</div>`
    : '';
  // 无表头九列的价格列对调说明（自动嗅探的结果要摆出来，不黑箱）
  const swapHtml = rows.noHeadPriceSwapped
    ? `<div style="margin-top:8px;color:#e6a23c">⚠️ 此文件<b>没有表头</b>，按标准九列识别；`
      + `但检测到第 5 列普遍大于第 6 列 —— 已按 <b>售价在前、进价在后</b> 自动对调。`
      + `若反了请给文件加表头再导。</div>`
    : '';

  try {
    await ElMessageBox.confirm(
      `<div>从「${file.name}」解析到 <b>${rows.length}</b> 行，`
      + `导入完成后将替换现有的 ${master.value.total} 行商品档案。</div>`
      + `<div style="margin-top:6px">${statLine}</div>${warnHtml}${misHtml}${swapHtml}`,
      '导入商品档案',
      { type: 'warning', confirmButtonText: '开始导入', cancelButtonText: '取消',
        dangerouslyUseHTMLString: true });
  } catch { return; }

  const batch = 'B' + Date.now();
  masterImport.value = { running: true, done: 0, total: rows.length, rejected: 0 };
  try {
    for (let i = 0; i < rows.length; i += 2000) {
      const { data } = await api.post('/master/upload', { batch, rows: rows.slice(i, i + 2000) });
      masterImport.value.done += data.accepted || 0;
      masterImport.value.rejected += data.rejected_total || 0;
      await new Promise((r) => setTimeout(r, 0));   // 让出主线程，进度条才动得了
    }
    await api.post('/master/commit', { batch });
    ElMessage.success(`导入完成：${masterImport.value.done} 行`
      + (masterImport.value.rejected ? `（跳过 ${masterImport.value.rejected} 行不合法条码）` : ''));
    await loadMaster();
  } catch (err) {
    ElMessage.error('导入中断：' + (err.response?.data?.error || err.message)
      + ' —— 旧档案未受影响，可以重来。');
  } finally {
    masterImport.value.running = false;
  }
}

async function clearMaster() {
  try {
    await ElMessageBox.confirm(
      `将清空全部 ${master.value.total} 行商品档案。清空后手机盘点出来的行会显示成「未知条码」，差异金额也算不出来（差异本身是三遍实盘互比，不受影响）。`,
      '清空商品档案', { type: 'warning', confirmButtonText: '确认清空', cancelButtonText: '取消' });
  } catch { return; }
  try {
    const { data } = await api.delete('/master/');
    ElMessage.success(`已清空 ${data.deleted} 行`);
    await loadMaster();
  } catch (e) {
    ElMessage.error('清空失败：' + (e.response?.data?.error || e.message));
  }
}

/* ====== 培训中心 ====== */
/*
  这一页只回答两个问题：①这门课现在是什么结构 ②谁学了、考了多少。
  视频本体不走这里（200+ 个大文件，浏览器上传会超时且不报错）—— 用
  `server/tools/import_training.js` 扫目录自动建课，这里只维护结构。
  小讲义走「+ 课时」里的上传（file#），大视频走导入器。

  🔴 学员侧那条线在这里看不见：**草稿课（published=0）学员看不到**、
  考试**点开始就消耗机会**、**进度不达标不放行**。这三条判据都在服务端，
  界面只把它们写出来（写出来才不会被当成 bug 反复问）。
*/
const trCategories = ['店长管理', '生鲜陈列', '加工管理', '防损', '前台收银', '杂百运营'];
const trTab = ref('courses');
const tr = ref({
  loading: false, saving: false, uploading: false,
  courses: [],
  files: [], filesLoading: false,
  sheets: [], sheetLoading: false, sheetTotal: 0,
  sheetPage: 1, sheetSize: 50, sheetCourse: null, onlyPassed: false,
  courseDlg: false,
  // wares = 建课当场挂的课件；保存时一并建成「课件」章节下的课时
  courseForm: { id: null, title: '', category: '', intro: '', required: false, published: false, wares: [] },
  wareIdx: -1,
  structDlg: false, structCourse: null, structTitle: '', struct: [],
  lessonDlg: false, lessonChapter: null, lessonEditId: null,
  lessonForm: { title: '', kind: 'video', durationSec: 0, fileId: null, linkUrl: '' },
  examDlg: false, examChapter: null,
  examForm: { title: '', passScore: 60, attemptLimit: 1, minProgress: 100, questions: [] },
});
const trFileEl = ref(null);
const trWareEl = ref(null);

/** 「新建课程」里点某一行的「上传」：记住行号再触发那个隐藏 file input */
function pickTrWare(idx) {
  tr.value.wareIdx = idx;
  trWareEl.value?.click();
}

/** 同上，那一行的「预览」：填了外链就跳，没填就提示先看有没有传文件 */
function openWare(w) {
  const u = String(w.linkUrl || '').trim();
  if (!u) {
    ElMessage.info(w.fileId
      ? '这一节传了文件（file#' + w.fileId + '），保存后去「课程结构」里改'
      : '这一节还没有课件地址');
    return;
  }
  window.open(u, '_blank', 'noopener');
}

/** 课件上传：落到 tr.courseForm.wares[wareIdx] 上 —— 🔴 必须改成"落到指定行"，
 *    原来那版写死进 lessonForm，两边同时开着就会互相串。 */
async function onTrWareFile(e) {
  const file = e.target.files?.[0];
  e.target.value = '';
  const idx = tr.value.wareIdx;
  if (!file || idx < 0) return;
  tr.value.uploading = true;
  try {
    const fd = new FormData();
    fd.append('file', file);
    const { data } = await api.post('/files/upload', fd);
    const w = tr.value.courseForm.wares[idx];
    if (!w) return;
    w.fileId = data.id;
    if (!String(w.title || '').trim()) {
      w.title = String(data.name || '').replace(/\.[^.]+$/, '');
    }
    ElMessage.success(`已上传：${data.name}`);
  } catch (err) { trErr(err, '上传失败'); }
  finally { tr.value.uploading = false; tr.value.wareIdx = -1; }
}

function trErr(e, what) {
  ElMessage.error(what + '：' + (e.response?.data?.error || e.message));
}
const trLabel = (i) => String.fromCharCode(65 + i);
function trTypeName(t) {
  return t === 'multi' ? '多选' : (t === 'judge' ? '判断' : '单选');
}

async function loadTrCourses() {
  tr.value.loading = true;
  try {
    const { data } = await api.get('/training/admin/courses');
    tr.value.courses = data.items || [];
  } catch (e) { trErr(e, '读取课程失败'); }
  finally { tr.value.loading = false; }
}

/**
 * 成绩列表。
 * 🔴 **不传 from/to**：服务端只有在显式传时间时才按时间过滤，
 *    这样去年的成绩也查得到。前端千万别"顺手"带上 30 天参数 ——
 *    那会让历史成绩静默消失（列表短了，界面上看不出来）。
 */
async function loadTrSheets() {
  tr.value.sheetLoading = true;
  try {
    const p = new URLSearchParams({
      page: String(tr.value.sheetPage), pageSize: String(tr.value.sheetSize),
    });
    if (tr.value.sheetCourse) p.set('courseId', String(tr.value.sheetCourse));
    if (tr.value.onlyPassed) p.set('passed', '1');
    const { data } = await api.get('/training/admin/sheets?' + p.toString());
    tr.value.sheets = data.items || [];
    tr.value.sheetTotal = data.total || 0;
  } catch (e) { trErr(e, '读取成绩失败'); }
  finally { tr.value.sheetLoading = false; }
}

// ---- 课程 ----
function openTrCourse(row) {
  // 🔴 改课程时 wares 留空：课件已经落在「课程结构」的课时上了，
  //    这里再塞回去会跟结构里的课时打架（存一次就多出一节重复的课）。
  tr.value.courseForm = {
    id: row ? row.id : null,
    title: row ? row.title : '',
    category: row ? (row.category || '') : '',
    intro: row ? (row.intro || '') : '',
    required: row ? !!row.required : false,
    published: row ? !!row.published : false,
    wares: [],
  };
  tr.value.wareIdx = -1;
  tr.value.courseDlg = true;
}

async function saveTrCourse() {
  const f = tr.value.courseForm;
  if (!f.title.trim()) { ElMessage.warning('请填课程名称'); return; }

  // 只把"填了东西"的课件带过去。名字没填但挂了课件的，用文件名补上，
  // 否则后台会静默跳过这一节（服务端对空标题直接 continue），管理员看到的是"少了几节"。
  const wares = (f.wares || [])
    .map((w, i) => ({
      ...w,
      title: String(w.title || '').trim() || `课件${i + 1}`,
      sort: i,
    }))
    .filter((w) => w.linkUrl || w.fileId);

  tr.value.saving = true;
  try {
    if (f.id) {
      await api.patch(`/training/admin/courses/${f.id}`, f);
      ElMessage.success('已保存');
    } else {
      await api.post('/training/admin/courses', {
        title: f.title, intro: f.intro, category: f.category,
        required: f.required, published: f.published,
        // 一个课件 = 一节课时，全归在「课件」这一章下；想要多章分组，
        // 建完再到「课程结构」里加章节。
        sections: wares.length ? [{ title: '课件', sort: 0, lessons: wares }] : null,
      });
      ElMessage.success(wares.length
        ? '课程已建，' + wares.length + ' 节课件也挂上了（记得点「发布」）'
        : '课程已建（默认是草稿，课件之后可以在「课程结构」里补）');
    }
    tr.value.courseDlg = false;
    await loadTrCourses();
  } catch (e) { trErr(e, '保存失败'); }
  finally { tr.value.saving = false; }
}

async function toggleTrPublish(row) {
  try {
    await api.patch(`/training/admin/courses/${row.id}`, { published: !row.published });
    ElMessage.success(row.published ? '已下线（学员侧不再显示，老成绩还留着）' : '已发布');
    await loadTrCourses();
  } catch (e) { trErr(e, '操作失败'); }
}

async function delTrCourse(row) {
  try {
    await ElMessageBox.confirm(
      `删除「${row.title}」会连同 ${row.chapter_count} 个章节、${row.lesson_count} 个课时、`
      + `${row.exam_count} 场考试以及全部历史成绩一起删掉，不能恢复。\n\n`
      + '如果只是不想让人看到，用「下线」更好 —— 成绩还留着。',
      '删除课程', { type: 'warning', confirmButtonText: '确认删除', cancelButtonText: '取消' });
  } catch { return; }
  try {
    await api.delete(`/training/admin/courses/${row.id}`);
    ElMessage.success('已删除');
    await loadTrCourses();
  } catch (e) { trErr(e, '删除失败'); }
}

// ---- 课程结构（章节 / 课时 / 考试）----
async function openTrStruct(row, keepOpen) {
  tr.value.structCourse = row;
  tr.value.structTitle = `课程结构：${row.title}（#${row.id}）`;
  if (!keepOpen) tr.value.structDlg = true;
  await reloadTrStruct();
}

async function reloadTrStruct() {
  const c = tr.value.structCourse;
  if (!c) return;
  try {
    const { data } = await api.get(`/training/admin/courses/${c.id}`);
    tr.value.struct = data.chapters || [];
  } catch (e) { trErr(e, '读取课程结构失败'); }
}

async function addTrChapter() {
  const c = tr.value.structCourse;
  if (!c) return;
  let title;
  try {
    ({ value: title } = await ElMessageBox.prompt('章节名称（如：第一章 陈列基础）', '添加章节',
      { inputPattern: /\S/, inputErrorMessage: '名称不能为空' }));
  } catch { return; }
  try {
    await api.post('/training/admin/chapters', { courseId: c.id, title, sort: tr.value.struct.length });
    await reloadTrStruct();
    ElMessage.success('章节已加');
  } catch (e) { trErr(e, '添加章节失败'); }
}

async function delTrChapter(ch) {
  try {
    await ElMessageBox.confirm(
      `删除「${ch.title}」会把它下面的课时、考试和历史成绩一起删掉，不能恢复。`,
      '删除章节', { type: 'warning' });
  } catch { return; }
  try {
    await api.delete(`/training/admin/chapters/${ch.id}`);
    await reloadTrStruct();
    ElMessage.success('已删除');
  } catch (e) { trErr(e, '删除失败'); }
}

function addTrLesson(ch) {
  tr.value.lessonChapter = ch;
  tr.value.lessonEditId = null;
  tr.value.lessonForm = { title: '', kind: 'video', durationSec: 0, fileId: null, linkUrl: '' };
  tr.value.lessonDlg = true;
}

/**
 * 改课时。
 *
 * 🔴 字段名两边不一样，别读错：管理端「课程结构」走的是 `GET /admin/courses/:id`
 *    里的 `SELECT *`，下发的是**下划线**（file_id / link_url / duration_sec）；
 *    学员侧接口 `lessonWithProgress` 才转成驼峰（fileId / linkUrl）。
 *    这里连着 ?? 两种写法一起读，省得以后改接口又白屏一次。
 */
function editTrLesson(ch, row) {
  tr.value.lessonChapter = ch;
  tr.value.lessonEditId = row.id;
  tr.value.lessonForm = {
    title: row.title || '',
    kind: row.kind === 'doc' ? 'doc' : 'video',
    durationSec: row.duration_sec ?? row.durationSec ?? 0,
    fileId: row.file_id ?? row.fileId ?? null,
    linkUrl: row.link_url ?? row.linkUrl ?? '',
  };
  tr.value.lessonDlg = true;
}

async function saveTrLesson() {
  const f = tr.value.lessonForm;
  if (!f.title.trim()) { ElMessage.warning('请填课时名称'); return; }
  tr.value.saving = true;
  try {
    if (tr.value.lessonEditId) {
      await api.patch(`/training/admin/lessons/${tr.value.lessonEditId}`, f);
      tr.value.lessonDlg = false;
      await reloadTrStruct();
      // 🔴 改课件**不会**动学员的历史进度（进度挂在 lesson.id 上，没重建），
      //    但要明说，否则管理员会以为"又重建了一次、记录清了"。
      ElMessage.success('课时已更新，学员已看过的记录不受影响');
    } else {
      await api.post('/training/admin/lessons', {
        chapterId: tr.value.lessonChapter.id,
        title: f.title,
        kind: f.kind,
        durationSec: f.durationSec,
        fileId: f.fileId,
        linkUrl: f.linkUrl,
        sort: (tr.value.lessonChapter.lessons || []).length,
      });
      tr.value.lessonDlg = false;
      await reloadTrStruct();
      ElMessage.success('课时已加');
    }
  } catch (e) { trErr(e, '保存课时失败'); }
  finally { tr.value.saving = false; }
}

async function delTrLesson(row) {
  try {
    await api.delete(`/training/admin/lessons/${row.id}`);
    await reloadTrStruct();
    ElMessage.success('已删除');
  } catch (e) { trErr(e, '删除失败'); }
}

/** 小文件（讲义 PDF 之类）直接传；返回 files.id 挂到课时上 */
async function onTrFile(e) {
  const file = e.target.files?.[0];
  e.target.value = '';
  if (!file) return;
  tr.value.uploading = true;
  try {
    const fd = new FormData();
    fd.append('file', file);
    const { data } = await api.post('/files/upload', fd);
    tr.value.lessonForm.fileId = data.id;
    // 名称还没填就用文件名兜一下，省一次手打（扩展名去掉）
    if (!tr.value.lessonForm.title.trim()) {
      tr.value.lessonForm.title = String(data.name || '').replace(/\.[^.]+$/, '');
    }
    ElMessage.success(`已上传：${data.name}（file#${data.id}）`);
  }   catch (err) { trErr(err, '上传失败'); }
  finally { tr.value.uploading = false; }
}

/** 培训文件：列出被课程/课时引用过的文件（独立于通用文件管理） */
async function loadTrFiles() {
  tr.value.filesLoading = true;
  try {
    const { data } = await api.get('/training/admin/files');
    tr.value.files = data.files || [];
  } catch (e) { trErr(e, '读取培训文件失败'); }
  finally { tr.value.filesLoading = false; }
}

function trFileOpen(row) {
  window.open('/files/' + row.path, '_blank', 'noopener');
}

async function delTrFile(row) {
  try {
    await ElMessageBox.confirm(`删除培训文件「${row.name}」？`, '警告', { type: 'warning' });
  } catch { return; }
  try {
    await api.delete(`/training/admin/files/${row.id}`);
    ElMessage.success('已删除');
    await loadTrFiles();
  } catch (e) { trErr(e, '删除失败'); }
}

// ---- 考试 ----
function addTrQuestion() {
  tr.value.examForm.questions.push({
    type: 'single',
    stem: '',
    score: 10,
    options: [{ content: '', correct: false }, { content: '', correct: false }],
  });
}

function addTrExam(ch) {
  tr.value.examChapter = ch;
  tr.value.examForm = {
    title: `${ch.title} 测验`, passScore: 60, attemptLimit: 1, minProgress: 100, questions: [],
  };
  addTrQuestion();
  tr.value.examDlg = true;
}

/**
 * 建考试。题目和考试**一次提交**建好 —— 分开建会出现"没有题的考试"：
 * 学员点进去拿不到题，直接判 0 分，而界面上什么都看不出来。
 * 所以在提交前把三道硬校验做掉（有题干 / 至少两个选项 / 标了正确答案）。
 */
async function saveTrExam() {
  const f = tr.value.examForm;
  if (!f.title.trim()) { ElMessage.warning('请填考试名称'); return; }
  const qs = f.questions.filter((q) => String(q.stem || '').trim());
  if (!qs.length) { ElMessage.warning('至少要有一道填了题干的题'); return; }
  for (let i = 0; i < qs.length; i++) {
    const opts = qs[i].options.filter((o) => String(o.content || '').trim());
    if (opts.length < 2) { ElMessage.warning(`第 ${i + 1} 题至少要有两个选项`); return; }
    if (!opts.some((o) => o.correct)) { ElMessage.warning(`第 ${i + 1} 题还没标正确答案`); return; }
    if (qs[i].type === 'single' && opts.filter((o) => o.correct).length > 1) {
      ElMessage.warning(`第 ${i + 1} 题是单选，只能标一个正确答案（要多个请改成多选）`);
      return;
    }
  }
  tr.value.saving = true;
  try {
    await api.post('/training/admin/exams', {
      chapterId: tr.value.examChapter.id,
      title: f.title,
      passScore: f.passScore,
      attemptLimit: f.attemptLimit,
      minProgress: f.minProgress,
      questions: qs.map((q, i) => ({
        type: q.type,
        stem: q.stem,
        score: q.score,
        sort: i,
        options: q.options.filter((o) => String(o.content || '').trim()),
      })),
    });
    tr.value.examDlg = false;
    await reloadTrStruct();
    ElMessage.success('考试已建 —— 学员要先把本章看完才放行');
  } catch (e) { trErr(e, '建考试失败'); }
  finally { tr.value.saving = false; }
}

async function delTrExam(e) {
  try {
    await ElMessageBox.confirm(
      `删除考试「${e.title}」会连它的题目和所有人的历史成绩一起删掉，不能恢复。`,
      '删除考试', { type: 'warning' });
  } catch { return; }
  try {
    await api.delete(`/training/admin/exams/${e.id}`);
    await reloadTrStruct();
    ElMessage.success('已删除');
  } catch (err) { trErr(err, '删除失败'); }
}


// 监听 tab 切换
watch(tab, loadTab);
// 浏览器标签页标题也跟着公司名走，多开几个后台时不容易认错
watch(brand, (v) => { document.title = v + ' 管理后台'; }, { immediate: true });

/* ====== Users ====== */
// 用户页的搜索与分页已上移到「用户管理」区块（服务端搜索 + 服务端分页）。
// 原来这里是前端过滤 filteredUsers，分页后只会在当页 50 条里搜 —— 必须去掉。
const userDlg = ref(false);
const userDlgBusy = ref(false);
const userForm = ref({ id: null, username: '', nickname: '', role: 'user', password: '' });
const userStep = ref(0);
function openUserDialog(row) {
  if (row) {
    userForm.value = { id: row.id, username: row.username, nickname: row.nickname || '', role: row.role, password: '' };
  } else {
    userForm.value = { id: null, username: '', nickname: '', role: 'user', password: '' };
  }
  userStep.value = 0;
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
const groupStep = ref(0);
async function openGroupDialog(row) {
  await loadUserOptions();   // 选择器要「全部用户」：分页接口只回一页，会静默少人
  if (row) {
    // 编辑时：留空成员选择 = 不动成员；用户主动勾选 = 全量替换（增/删都会自动跳过群主）
    groupForm.value = { id: row.id, name: row.name, owner_id: row.owner_id, member_ids: [] };
  } else {
    groupForm.value = { id: null, name: '', owner_id: null, member_ids: [] };
  }
  groupStep.value = 0;
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

/* ====== 集成对接 ====== */
const intTab = ref('bots');
const intMeta = ref({ scopes: [], events: [], conversations: [], maxAttempts: 4 });
const bots = ref([]);
const tokens = ref([]);
const incoming = ref([]);
const outgoing = ref([]);
const deliveries = ref([]);
const delOk = ref('');
const busy = ref(false);
const newToken = ref('');

const botDlg = ref(false);
const botForm = ref({ name: '', conversationId: null });
const botConvDlg = ref(false);
const botConvForm = ref({ id: null, name: '', conversationId: null });
const tokenDlg = ref(false);
const tokenForm = ref({ name: '', userId: null, scopes: [], days: 0 });
const clients = ref([]);
const clientDlg = ref(false);
const clientForm = ref({ name: '', userId: null, scopes: [] });
const newClient = ref(null);
const rotateDlg = ref(false);
const rotatedSecret = ref({ appId: '', secret: '' });
const incomingDlg = ref(false);
const incomingForm = ref({ name: '', botId: null, conversationId: null, signed: false });
const outgoingDlg = ref(false);
const outgoingForm = ref({ name: '', url: '', events: [], conversationId: null });
const pubkeys = ref([]);
const pubkeyDlg = ref(false);
const pubkeyForm = ref({ name: '', publicKey: '' });
const pubkeyStep = ref(0);                  // 0=用途 1=粘贴公钥 2=创建成功
const pubkeyCreated = ref(null);            // 创建后回显 key_id / fingerprint
const pubkeyTestDlg = ref(false);
const pubkeyTestForm = ref({ id: null, name: '', algorithm: '', body: '', signature: '', result: '' });
const botStep = ref(0);
const botConvStep = ref(0);
const tokenStep = ref(0);
const clientStep = ref(0);
const incomingStep = ref(0);
const outgoingStep = ref(0);

/* ====== 泰格 POS 日报对接向导（2026-10-11 #313）====== */
// 把「建机器人 + 建入站推送 + 教对接方怎么配」压成一个三步向导。
// 机器人/推送地址都按名字找，找到就复用 —— 向导重复打开不会建出一堆重复的。
const TIGER_BOT_NAME = '泰格日报';
const TIGER_HOOK_NAME = '泰格POS日报';
const tigerDlg = ref(false);
const tigerStep = ref(0);            // 0=选会话 1=开通中/结果 2=对接说明
const tigerBusy = ref(false);
const tigerForm = ref({ conversationId: null });
const tigerResult = ref(null);       // { botName, url, hookId, reused }
const tigerExisting = ref(null);     // 已存在的同名入站推送（进了向导先提示，避免重复建）

/** 身份下拉：机器人排前面（对接一般以机器人身份发言），再接真人用户 */
const identityOptions = computed(() => [
  ...bots.value.map((b) => ({ id: b.id, username: b.username, nickname: b.nickname, is_bot: true })),
  ...userOptions.value.filter((u) => !u.is_bot).map((u) => ({ ...u, is_bot: false })),
]);

// 集成页内的子标签切换（放在 intTab 定义之后，避免 const 暂时性死区）
watch(intTab, loadIntTab);

function fullUrl(p) { return location.origin + p; }

async function copy(t) {
  try {
    await navigator.clipboard.writeText(t);
    ElMessage.success('已复制');
  } catch {
    ElMessage.warning('浏览器拒绝了剪贴板权限，请手动选中复制');
  }
}

async function loadMeta() { intMeta.value = (await api.get('/admin/integrations/meta')).data; }
async function loadBots() { bots.value = (await api.get('/admin/integrations/bots')).data; }
async function loadTokens() { tokens.value = (await api.get('/admin/integrations/tokens')).data; }
async function loadIncoming() { incoming.value = (await api.get('/admin/integrations/incoming')).data; }
async function loadOutgoing() { outgoing.value = (await api.get('/admin/integrations/outgoing')).data; }
async function loadDeliveries() {
  const p = new URLSearchParams({ limit: '200' });
  if (delOk.value !== '') p.set('ok', delOk.value);
  deliveries.value = (await api.get('/admin/integrations/deliveries?' + p.toString())).data;
}

async function loadIntegrations() {
  try {
    await Promise.all([loadMeta(), loadBots(), loadTokens(), loadClients(),
      loadIncoming(), loadOutgoing(), loadDeliveries(), loadPubkeys()]);
  } catch (e) {
    ElMessage.error('加载集成配置失败：' + (e.response?.data?.error || e.message));
  }
}

/** 切子标签时按需刷新（新建前需要最新的机器人与会话列表） */
async function loadIntTab() {
  try {
    if (intTab.value === 'bots') await loadBots();
    else if (intTab.value === 'tokens') await loadTokens();
    else if (intTab.value === 'clients') await loadClients();
    else if (intTab.value === 'incoming') { await Promise.all([loadMeta(), loadBots()]); await loadIncoming(); }
    else if (intTab.value === 'outgoing') { await loadMeta(); await loadOutgoing(); }
    else if (intTab.value === 'deliveries') await loadDeliveries();
    else if (intTab.value === 'pubkeys') await loadPubkeys();
  } catch (e) {
    ElMessage.error(e.response?.data?.error || e.message);
  }
}

async function loadPubkeys() { pubkeys.value = (await api.get('/admin/integrations/publickeys')).data; }
async function loadClients() { clients.value = (await api.get('/admin/integrations/clients')).data; }

function openBotDialog(row = null) {
  // 传 row = 编辑模式（改名）；不传 = 新建
  botForm.value = row
    ? { id: row.id, name: row.nickname || '', conversationId: null }
    : { name: '', conversationId: null };
  botStep.value = 0;
  botDlg.value = true;
}
async function saveBot() {
  const f = botForm.value;
  if (!f.name.trim()) return ElMessage.warning('请填机器人名称');
  busy.value = true;
  try {
    if (f.id) {
      await api.patch(`/admin/integrations/bots/${f.id}`, { name: f.name });
      ElMessage.success('已保存');
      botDlg.value = false;
      await Promise.all([loadBots(), loadIncoming(), loadMeta()]);
    } else {
      await api.post('/admin/integrations/bots', f);
      ElMessage.success('机器人已创建');
      botDlg.value = false;
      await Promise.all([loadBots(), loadMeta()]);
    }
  } catch (e) {
    ElMessage.error(e.response?.data?.error || (f.id ? '保存失败' : '创建失败'));
  } finally { busy.value = false; }
}
function openBotConvDialog(row) {
  botConvForm.value = { id: row.id, name: row.nickname || row.username, conversationId: null };
  botConvDlg.value = true;
}
async function saveBotConv() {
  if (!botConvForm.value.conversationId) return ElMessage.warning('请选择会话');
  busy.value = true;
  try {
    await api.post(`/admin/integrations/bots/${botConvForm.value.id}/conversations`,
      { conversationId: botConvForm.value.conversationId });
    ElMessage.success('已加入会话');
    botConvDlg.value = false;
    await loadMeta();
  } catch (e) {
    ElMessage.error(e.response?.data?.error || '操作失败');
  } finally { busy.value = false; }
}
async function delBot(row) {
  try {
    await ElMessageBox.confirm(
      `删除机器人「${row.nickname}」会同时清掉它的令牌和推送地址，且无法恢复。继续？`,
      '确认删除', { type: 'warning' });
  } catch { return; }
  try {
    await api.delete(`/admin/integrations/bots/${row.id}`);
    ElMessage.success('已删除');
    await loadIntegrations();
  } catch (e) { ElMessage.error(e.response?.data?.error || '删除失败'); }
}

function openTokenDialog() {
  newToken.value = '';
  tokenForm.value = { name: '', userId: bots.value[0]?.id || null, scopes: ['message:send'], days: 0 };
  tokenDlg.value = true;
}
async function saveToken() {
  const f = tokenForm.value;
  if (!f.name.trim()) return ElMessage.warning('请填用途');
  if (!f.userId) return ElMessage.warning('请选择身份');
  if (!f.scopes.length) return ElMessage.warning('至少勾一个权限');
  busy.value = true;
  try {
    const { data } = await api.post('/admin/integrations/tokens', {
      name: f.name,
      userId: f.userId,
      scopes: f.scopes,
      expiresAt: f.days > 0 ? Date.now() + f.days * 86400000 : 0,
    });
    newToken.value = data.token;
    tokenStep.value = 2;
    await loadTokens();
  } catch (e) {
    ElMessage.error(e.response?.data?.error || '生成失败');
  } finally { busy.value = false; }
}
async function toggleToken(row) {
  try {
    await api.post(`/admin/integrations/tokens/${row.id}/revoke`, { revoked: !row.revoked });
    ElMessage.success(row.revoked ? '已恢复' : '已吊销');
    await loadTokens();
  } catch (e) { ElMessage.error(e.response?.data?.error || '操作失败'); }
}
async function delToken(row) {
  try { await ElMessageBox.confirm(`删除令牌「${row.name}」？使用它的程序会立刻失效。`, '确认删除', { type: 'warning' }); }
  catch { return; }
  try {
    await api.delete(`/admin/integrations/tokens/${row.id}`);
    ElMessage.success('已删除');
    await loadTokens();
  } catch (e) { ElMessage.error(e.response?.data?.error || '删除失败'); }
}

/* ====== 签名客户端（app_id / app_secret） ====== */

/** 给对接方照抄的签名示例。写死在前端而不是从服务端取，避免"文档和实际校验不是同一份"。 */
const signSample = `待签串 = [
  "POST",
  "/api/open/conversations/12/messages",
  "",                 // query（没有就空串，但不能少这一行）
  "1758000000",       // X-Timestamp，unix **秒**
  "8f3c1a2b...",      // X-Nonce，每次随机
  "e3b0c442..."       // sha256_hex(原始请求体字节)
].join("\\n")

X-Sign = hex(HMAC_SHA256(app_secret, 待签串))

curl -X POST 'http://<服务端地址>/api/open/conversations/12/messages' \\
  -H 'Content-Type: application/json' \\
  -H "X-App-Id:     $APP_ID" \\
  -H "X-Timestamp:  $(date +%s)" \\
  -H "X-Nonce:      $(openssl rand -hex 12)" \\
  -H "X-Sign:       $SIGN" \\
  -d '{"text":"来自门店系统的告警"}'`;

function openClientDialog() {
  newClient.value = null;
  clientForm.value = { name: '', userId: bots.value[0]?.id || null, scopes: ['message:send'] };
  clientDlg.value = true;
}
async function saveClient() {
  const f = clientForm.value;
  if (!f.name.trim()) return ElMessage.warning('请填用途');
  if (!f.userId) return ElMessage.warning('请选择身份');
  if (!f.scopes.length) return ElMessage.warning('至少勾一个权限');
  busy.value = true;
  try {
    const { data } = await api.post('/admin/integrations/clients', {
      name: f.name, userId: f.userId, scopes: f.scopes,
    });
    newClient.value = { appId: data.client.appId, secret: data.secret };
    clientStep.value = 2;
    await loadClients();
  } catch (e) {
    ElMessage.error(e.response?.data?.error || '生成失败');
  } finally { busy.value = false; }
}
async function toggleClient(row) {
  try {
    await api.post(`/admin/integrations/clients/${row.id}/enable`, { enabled: !row.enabled });
    ElMessage.success(row.enabled ? '已停用' : '已启用');
    await loadClients();
  } catch (e) { ElMessage.error(e.response?.data?.error || '操作失败'); }
}
async function rotateClient(row) {
  try { await ElMessageBox.confirm(
    `轮换「${row.name}」的密钥？旧密钥还有 24 小时可用，新密钥只显示这一次。`, '确认轮换', { type: 'warning' }); }
  catch { return; }
  try {
    const { data } = await api.post(`/admin/integrations/clients/${row.id}/rotate`, {});
    rotatedSecret.value = { appId: data.client.appId, secret: data.secret };
    rotateDlg.value = true;
    await loadClients();
  } catch (e) { ElMessage.error(e.response?.data?.error || '轮换失败'); }
}
async function delClient(row) {
  try { await ElMessageBox.confirm(`删除凭据「${row.name}」？用它的程序会立刻失效。`, '确认删除', { type: 'warning' }); }
  catch { return; }
  try {
    await api.delete(`/admin/integrations/clients/${row.id}`);
    ElMessage.success('已删除');
    await loadClients();
  } catch (e) { ElMessage.error(e.response?.data?.error || '删除失败'); }
}

function openIncomingDialog(row = null) {
  // 传 row = 编辑模式：改名称 / 换机器人 / 换目标会话 / 开关签名。地址(token)不变。
  incomingForm.value = row
    ? { id: row.id, name: row.name, botId: row.bot_id,
        conversationId: row.conversation_id, signed: !!row.signed }
    : { name: '', botId: bots.value[0]?.id || null,
        conversationId: intMeta.value.conversations[0]?.id || null, signed: false };
  incomingStep.value = 0;
  incomingDlg.value = true;
}
async function saveIncoming() {
  const f = incomingForm.value;
  if (!f.name.trim()) return ElMessage.warning('请填用途');
  if (!f.botId) return ElMessage.warning('请选择机器人');
  if (!f.conversationId) return ElMessage.warning('请选择目标会话');
  busy.value = true;
  try {
    if (f.id) {
      await api.patch(`/admin/integrations/incoming/${f.id}`, {
        name: f.name, botId: f.botId, conversationId: f.conversationId, signed: !!f.signed,
      });
      ElMessage.success('已保存（推送地址不变，对接方无需改动）');
      incomingDlg.value = false;
      await loadIncoming();
    } else {
      await api.post('/admin/integrations/incoming', f);
      ElMessage.success('推送地址已创建');
      incomingDlg.value = false;
      await loadIncoming();
    }
  } catch (e) {
    ElMessage.error(e.response?.data?.error || (f.id ? '保存失败' : '创建失败'));
  } finally { busy.value = false; }
}
async function toggleIncoming(row) {
  try {
    await api.post(`/admin/integrations/incoming/${row.id}/revoke`, { revoked: !row.revoked });
    ElMessage.success(row.revoked ? '已启用' : '已停用');
    await loadIncoming();
  } catch (e) { ElMessage.error(e.response?.data?.error || '操作失败'); }
}
async function delIncoming(row) {
  try { await ElMessageBox.confirm(`删除推送地址「${row.name}」？对方的推送会立刻失败。`, '确认删除', { type: 'warning' }); }
  catch { return; }
  try {
    await api.delete(`/admin/integrations/incoming/${row.id}`);
    ElMessage.success('已删除');
    await loadIncoming();
  } catch (e) { ElMessage.error(e.response?.data?.error || '删除失败'); }
}
/** 试推一张示例卡片：既验证链路，也能顺便看到客户端卡片长什么样 */
async function testIncoming(row) {
  try {
    await api.post(`/admin/integrations/incoming/${row.id}/send`, {
      kind: 'card',
      content: {
        title: '测试推送',
        text: '这是一条来自管理后台的测试卡片。收到它说明推送地址已经配好了。',
        color: 'green',
        fields: [
          { label: '用途', value: row.name, short: true },
          { label: '目标会话', value: row.conversation_title || ('#' + row.conversation_id), short: true },
        ],
        footer: '小智 IM · 集成对接',
      },
    });
    ElMessage.success('已推送，去群里看看');
    await loadIncoming();
  } catch (e) { ElMessage.error(e.response?.data?.error || '推送失败'); }
}

/* ====== 泰格 POS 日报对接向导 ====== */

/** 打开向导。同名钩子已存在时先亮出来，避免重复建一套 */
async function openTigerDialog() {
  tigerStep.value = 0;
  tigerResult.value = null;
  tigerExisting.value = null;
  tigerForm.value = { conversationId: intMeta.value.conversations[0]?.id || null };
  await loadIncoming();
  const hit = incoming.value.find((x) => x.name === TIGER_HOOK_NAME && !x.revoked);
  tigerExisting.value = hit
    ? { id: hit.id, url: fullUrl(hit.path), conversation: hit.conversation_title || ('#' + hit.conversation_id) }
    : null;
  tigerDlg.value = true;
}

/** 一键开通：机器人按名字复用，没有才建；入站推送同 理（改指向时地址不变） */
async function runTigerSetup() {
  if (!tigerForm.value.conversationId) return ElMessage.warning('请选择日报推到哪个会话');
  tigerBusy.value = true;
  try {
    await loadBots();
    let bot = bots.value.find((b) => b.nickname === TIGER_BOT_NAME);
    const reused = !!bot;
    if (!bot) bot = (await api.post('/admin/integrations/bots', { name: TIGER_BOT_NAME })).data;
    await loadIncoming();
    let hook = incoming.value.find((x) => x.name === TIGER_HOOK_NAME);
    if (hook) {
      const { data } = await api.patch(`/admin/integrations/incoming/${hook.id}`, {
        botId: bot.id, conversationId: tigerForm.value.conversationId,
      });
      hook = data;
    } else {
      hook = (await api.post('/admin/integrations/incoming', {
        name: TIGER_HOOK_NAME, botId: bot.id,
        conversationId: tigerForm.value.conversationId, signed: false,
      })).data;
    }
    tigerResult.value = { botName: bot.nickname, reused, hookId: hook.id, url: fullUrl(hook.path) };
    tigerStep.value = 1;
    await Promise.all([loadBots(), loadIncoming(), loadMeta()]);
  } catch (e) {
    ElMessage.error(e.response?.data?.error || '开通失败');
  } finally { tigerBusy.value = false; }
}

/** 推一张日报样例卡片，验证整条链路 */
async function tigerTestPush() {
  if (!tigerResult.value) return;
  try {
    await api.post(`/admin/integrations/incoming/${tigerResult.value.hookId}/send`, {
      kind: 'card',
      content: {
        title: '泰格 POS 日报（样例）',
        text: '销售额 ¥12,345.67 · 客数 123 笔 · 客单价 ¥100.37\n\n对账：与泰格官方日结口径一致 ✅',
        color: 'blue',
        fields: [
          { label: '销售额', value: '¥12,345.67', short: true },
          { label: '客数', value: '123', short: true },
        ],
        footer: 'tiger-bridge · 泰格 POS 数据对接',
      },
    });
    ElMessage.success('样例已推送，去群里看');
  } catch (e) { ElMessage.error(e.response?.data?.error || '推送失败'); }
}

/** 已有对接 → 跳「入站推送」标签去编辑（改会话/换机器人/停用都在那里） */
function tigerEditExisting() {
  tigerDlg.value = false;
  intTab.value = 'incoming';
}

function openOutgoingDialog(row = null) {
  // 传 row = 编辑模式（PATCH /outgoing 已有后端，这次把入口补上）
  outgoingForm.value = row
    ? { id: row.id, name: row.name, url: row.url,
        events: row.events === '*' ? [] : String(row.events).split(',').filter(Boolean),
        conversationId: row.conversation_id || null }
    : { name: '', url: '', events: [], conversationId: null };
  outgoingStep.value = 0;
  outgoingSecret.value = '';
  outgoingDlg.value = true;
}
async function saveOutgoing() {
  const f = outgoingForm.value;
  if (!f.name.trim()) return ElMessage.warning('请填用途');
  if (!/^https?:\/\/.+/i.test(f.url.trim())) return ElMessage.warning('回调地址要以 http:// 或 https:// 开头');
  busy.value = true;
  try {
    if (f.id) {
      await api.patch(`/admin/integrations/outgoing/${f.id}`, {
        name: f.name, url: f.url, events: f.events, conversationId: f.conversationId,
      });
      ElMessage.success('已保存');
      outgoingDlg.value = false;
      await loadOutgoing();
    } else {
      const { data } = await api.post('/admin/integrations/outgoing', f);
      outgoingSecret.value = data.secret;
      outgoingStep.value = 2;
      ElMessage.success('订阅已创建');
      await loadOutgoing();
    }
  } catch (e) {
    ElMessage.error(e.response?.data?.error || (f.id ? '保存失败' : '创建失败'));
  } finally { busy.value = false; }
}
async function toggleOutgoing(row, v) {
  try {
    await api.patch(`/admin/integrations/outgoing/${row.id}`, { active: v });
    ElMessage.success(v ? '已启用' : '已停用');
    await loadOutgoing();
  } catch (e) { ElMessage.error(e.response?.data?.error || '操作失败'); }
}
async function testOutgoing(row) {
  try {
    await api.post(`/admin/integrations/outgoing/${row.id}/test`);
    ElMessage.success('测试事件已发出，去「投递日志」看结果');
    setTimeout(loadDeliveries, 800);
  } catch (e) { ElMessage.error(e.response?.data?.error || '发送失败'); }
}
async function rotateOutgoing(row) {
  try { await ElMessageBox.confirm('换密钥后对方必须同步更新，否则验签会失败。继续？', '确认换密钥', { type: 'warning' }); }
  catch { return; }
  try {
    const { data } = await api.patch(`/admin/integrations/outgoing/${row.id}`, { rotateSecret: true });
    ElMessage.success(`新密钥：${data.secret}`);
    await loadOutgoing();
  } catch (e) { ElMessage.error(e.response?.data?.error || '操作失败'); }
}
async function delOutgoing(row) {
  try { await ElMessageBox.confirm(`删除订阅「${row.name}」？投递日志会一并清理。`, '确认删除', { type: 'warning' }); }
  catch { return; }
  try {
    await api.delete(`/admin/integrations/outgoing/${row.id}`);
    ElMessage.success('已删除');
    await loadIntegrations();
  } catch (e) { ElMessage.error(e.response?.data?.error || '删除失败'); }
}
async function retryDelivery(row) {
  try {
    await api.post(`/admin/integrations/deliveries/${row.id}/retry`);
    ElMessage.success('已重新投递');
    setTimeout(loadDeliveries, 900);
  } catch (e) { ElMessage.error(e.response?.data?.error || '重发失败'); }
}

/* ====== 公钥接入 ====== */
function openPubkeyDialog() {
  pubkeyForm.value = { name: '', publicKey: '' };
  pubkeyStep.value = 0;
  pubkeyCreated.value = null;
  pubkeyDlg.value = true;
}
async function savePubkey() {
  const f = pubkeyForm.value;
  if (pubkeyStep.value === 0) {
    if (!f.name.trim()) return ElMessage.warning('请填用途名');
    pubkeyStep.value = 1;
    return;
  }
  if (pubkeyStep.value === 1) {
    if (!f.publicKey.includes('BEGIN')) return ElMessage.warning('请粘贴 PEM 格式的公钥（含 BEGIN/END 标记）');
    busy.value = true;
    try {
      const { data } = await api.post('/admin/integrations/publickeys', { name: f.name.trim(), publicKey: f.publicKey });
      pubkeyCreated.value = data;
      pubkeyStep.value = 2;
      await loadPubkeys();
    } catch (e) { ElMessage.error(e.response?.data?.error || '提交失败'); }
    finally { busy.value = false; }
  }
}
function closePubkeyDialog() { pubkeyDlg.value = false; }
async function delPubkey(row) {
  try { await ElMessageBox.confirm(`删除公钥「${row.name}」（${row.key_id}）？使用它的对接点会立即失效。`, '确认删除', { type: 'warning' }); }
  catch { return; }
  try {
    await api.delete(`/admin/integrations/publickeys/${row.id}`);
    ElMessage.success('已删除');
    await loadPubkeys();
  } catch (e) { ElMessage.error(e.response?.data?.error || '删除失败'); }
}
async function togglePubkey(row) {
  try {
    await api.post(`/admin/integrations/publickeys/${row.id}/revoke`, { revoked: !row.revoked });
    ElMessage.success(row.revoked ? '已启用' : '已停用');
    await loadPubkeys();
  } catch (e) { ElMessage.error(e.response?.data?.error || '操作失败'); }
}
function openPubkeyTestDialog(row) {
  pubkeyTestForm.value = { id: row.id, name: row.name, algorithm: row.algorithm, body: '', signature: '', result: '' };
  pubkeyTestDlg.value = true;
}
async function runPubkeyTest() {
  const f = pubkeyTestForm.value;
  if (!f.body || !f.signature) return ElMessage.warning('请填 body 和 signature');
  try {
    const { data } = await api.post(`/admin/integrations/publickeys/${f.id}/test`,
      { body: f.body, signature: f.signature, algorithm: f.algorithm });
    f.result = data;
    if (data.ok) ElMessage.success('验签通过');
    else ElMessage.warning('验签失败：' + (data.error || ''));
  } catch (e) {
    f.result = { ok: false, error: e.response?.data?.error || e.message };
    ElMessage.error('请求失败');
  }
}

/* ====== Settings ====== */
// ---- 组织机构（部门 / 岗位 / 员工 + 批量导入） ----
const orgData = ref({ org: null, members: [], depts: [], positions: [] });
const orgBusy = ref(false);
const orgNewName = ref('');
const orgDlg = ref(false);
const orgEmp = ref({ no: '', name: '', deptId: null, positionId: null });
const orgWorkMode = ref(false);
const orgTab = ref('members');

const deptDlg = ref(false);
const deptForm = ref({ id: null, name: '', parentId: null, sort: 0 });
const posDlg = ref(false);
const posForm = ref({ id: null, name: '', deptId: null, sort: 0 });
const memberDlg = ref(false);
const memberForm = ref({ id: null, username: '', nickname: '', deptId: null, positionId: null });

const orgImportDlg = ref(false);
const importText = ref('');
const importResultDlg = ref(false);
const importResult = ref(null);

function deptName(id) {
  return orgData.value.depts?.find((d) => d.id === id)?.name || '';
}

// 解析粘贴的表格文本（Excel 复制 = TSV；也兼容逗号/CSV），列：工号 姓名 部门 岗位
const importRows = computed(() => {
  const lines = (importText.value || '').split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
  const rows = [];
  for (const line of lines) {
    const cols = line.split(/\t|,(?=(?:[^"]*"[^"]*")*[^"]*$)/).map((c) => c.replace(/^"|"$/g, '').trim());
    if (!cols[0]) continue;
    // 首列表头行跳过
    if (/工号|employee/i.test(cols[0])) continue;
    rows.push({
      employeeNo: cols[0] || '',
      nickname: cols[1] || '',
      dept: cols[2] || '',
      position: cols[3] || '',
      _bad: /^[A-Za-z0-9_]{3,20}$/.test(cols[0] || '') ? '' : '工号需 3-20 位字母/数字/下划线',
    });
  }
  return rows;
});

function onImportFile(ev) {
  const f = ev.target?.files?.[0];
  if (!f) return;
  const reader = new FileReader();
  reader.onload = () => { importText.value = String(reader.result || ''); };
  reader.readAsText(f, 'utf-8');
}

async function loadOrgs() {
  try {
    // /orgs/my 带 admin token 走 admin 分支（返回服务器唯一的组织 + 部门/岗位全集）；
    // 顺带读一次好友模式，用来把"普通模式下操作会被 400"提前告诉管理员
    const [my, st] = await Promise.all([api.get('/orgs/my'), api.get('/admin/settings')]);
    orgData.value = { depts: [], positions: [], ...my.data };
    orgWorkMode.value = (st.data.friendMode || 'normal') === 'work';
  } catch (e) {
    ElMessage.error(e.response?.data?.error || '加载组织机构失败');
  }
}
async function createOrg() {
  const name = orgNewName.value.trim();
  if (name.length < 2) return ElMessage.warning('组织名至少 2 个字');
  orgBusy.value = true;
  try {
    await api.post('/orgs', { name });
    ElMessage.success('组织已创建，可以录入员工了');
    orgNewName.value = '';
    await loadOrgs();
  } catch (e) {
    ElMessage.error(e.response?.data?.error || '创建失败');
  } finally {
    orgBusy.value = false;
  }
}
async function addMember() {
  const no = orgEmp.value.no.trim();
  if (!/^[A-Za-z0-9_]{3,20}$/.test(no)) return ElMessage.warning('工号 3-20 位，仅限字母、数字、下划线');
  orgBusy.value = true;
  try {
    const { data } = await api.post(`/orgs/${orgData.value.org.id}/members`, {
      employeeNo: no,
      nickname: orgEmp.value.name.trim(),
      deptId: orgEmp.value.deptId || null,
      positionId: orgEmp.value.positionId || null,
    });
    // 撞上「老账号」（普通模式时期自己注册、还没进组织）时会走收编：
    // 只改归属、不动密码，提示必须跟新建账号区分开，否则管理员会以为
    // 员工密码被重置成工号了
    if (data.adopted) {
      ElMessage.success(`账号 ${data.user.username} 已纳入组织（沿用原密码，未清零），并已和同事互为好友`);
    } else {
      ElMessage.success(`已录入 ${data.user.username}，初始密码 = 工号，请通知员工登录后修改`);
    }
    orgEmp.value = { no: '', name: '', deptId: null, positionId: null };
    orgDlg.value = false;
    await loadOrgs();
  } catch (e) {
    ElMessage.error(e.response?.data?.error || '录入失败');
  } finally {
    orgBusy.value = false;
  }
}
async function removeMember(row) {
  try {
    await ElMessageBox.confirm(
      `移除员工 ${row.username}？其账号将退出组织并解除组织内好友关系（账号本身保留、可重新录入）。`,
      '移除确认', { type: 'warning' });
  } catch {
    return; // 用户点了取消
  }
  try {
    await api.delete(`/orgs/${orgData.value.org.id}/members/${row.id}`);
    ElMessage.success('已移除');
    await loadOrgs();
  } catch (e) {
    ElMessage.error(e.response?.data?.error || '移除失败');
  }
}

// ---- 部门 ----
function openDeptDlg(row) {
  deptForm.value = row
    ? { id: row.id, name: row.name, parentId: row.parent_id || null, sort: row.sort }
    : { id: null, name: '', parentId: null, sort: 0 };
  deptDlg.value = true;
}
async function saveDept() {
  const f = deptForm.value;
  if (!f.name.trim()) return ElMessage.warning('部门名称必填');
  orgBusy.value = true;
  try {
    if (f.id) await api.put(`/orgs/depts/${f.id}`, { name: f.name.trim(), parentId: f.parentId, sort: f.sort });
    else await api.post('/orgs/depts', { name: f.name.trim(), parentId: f.parentId, sort: f.sort });
    ElMessage.success('已保存');
    deptDlg.value = false;
    await loadOrgs();
  } catch (e) {
    ElMessage.error(e.response?.data?.error || '保存失败');
  } finally {
    orgBusy.value = false;
  }
}
async function removeDept(row) {
  try {
    await ElMessageBox.confirm(`删除部门「${row.name}」？（部门下有员工或子部门时无法删除）`, '删除确认', { type: 'warning' });
  } catch { return; }
  try {
    await api.delete(`/orgs/depts/${row.id}`);
    ElMessage.success('已删除');
    await loadOrgs();
  } catch (e) {
    ElMessage.error(e.response?.data?.error || '删除失败');
  }
}

// ---- 岗位 ----
function openPosDlg(row) {
  posForm.value = row
    ? { id: row.id, name: row.name, deptId: row.dept_id || null, sort: row.sort }
    : { id: null, name: '', deptId: null, sort: 0 };
  posDlg.value = true;
}
async function savePos() {
  const f = posForm.value;
  if (!f.name.trim()) return ElMessage.warning('岗位名称必填');
  orgBusy.value = true;
  try {
    if (f.id) await api.put(`/orgs/positions/${f.id}`, { name: f.name.trim(), deptId: f.deptId, sort: f.sort });
    else await api.post('/orgs/positions', { name: f.name.trim(), deptId: f.deptId, sort: f.sort });
    ElMessage.success('已保存');
    posDlg.value = false;
    await loadOrgs();
  } catch (e) {
    ElMessage.error(e.response?.data?.error || '保存失败');
  } finally {
    orgBusy.value = false;
  }
}
async function removePos(row) {
  try {
    await ElMessageBox.confirm(`删除岗位「${row.name}」？（岗位下有员工时无法删除）`, '删除确认', { type: 'warning' });
  } catch { return; }
  try {
    await api.delete(`/orgs/positions/${row.id}`);
    ElMessage.success('已删除');
    await loadOrgs();
  } catch (e) {
    ElMessage.error(e.response?.data?.error || '删除失败');
  }
}

// ---- 编辑员工 ----
function openMemberDlg(row) {
  memberForm.value = { id: row.id, username: row.username, nickname: row.nickname || '', deptId: row.dept_id || null, positionId: row.position_id || null };
  memberDlg.value = true;
}
async function saveMember() {
  const f = memberForm.value;
  orgBusy.value = true;
  try {
    await api.put(`/orgs/${orgData.value.org.id}/members/${f.id}`, {
      nickname: f.nickname,
      deptId: f.deptId,
      positionId: f.positionId,
    });
    ElMessage.success('已保存');
    memberDlg.value = false;
    await loadOrgs();
  } catch (e) {
    ElMessage.error(e.response?.data?.error || '保存失败');
  } finally {
    orgBusy.value = false;
  }
}

// ---- 批量导入 ----
async function doImport() {
  const rows = importRows.value.map(({ employeeNo, nickname, dept, position }) => ({ employeeNo, nickname, dept, position }));
  if (!rows.length) return;
  orgBusy.value = true;
  try {
    const { data } = await api.post(`/orgs/${orgData.value.org.id}/members/import`, { rows });
    importResult.value = data;
    orgImportDlg.value = false;
    importText.value = '';
    importResultDlg.value = true;
    await loadOrgs();
  } catch (e) {
    ElMessage.error(e.response?.data?.error || '导入失败');
  } finally {
    orgBusy.value = false;
  }
}

const pwd = ref({ old: '', neu: '', neu2: '' });
const pwdBusy = ref(false);

// ---- 公司与好友模式 ----
// showPurchasePrice：「商档查询显示进货价」开关（2026-10-06）。默认关 ——
// 进价是敏感数据，员工手机上默认不给看；老板要给谁看，在这里开。
const compSetting = ref({ name: '', mode: 'normal', showPurchasePrice: false });
const compBusy = ref(false);
async function loadCompSetting() {
  try {
    const { data } = await api.get('/admin/settings');
    compSetting.value = {
      name: data.companyName || '',
      mode: data.friendMode || 'normal',
      showPurchasePrice: !!data.masterShowPurchasePrice,
    };
  } catch (e) {
    ElMessage.error(e.response?.data?.error || '读取设置失败');
  }
}
async function saveCompSetting() {
  const name = compSetting.value.name.trim();
  if (/[<>"'\\]/.test(name)) return ElMessage.warning('公司名称不能包含 < > " \' \\ 字符');
  compBusy.value = true;
  try {
    await api.put('/admin/settings', {
      companyName: name,
      friendMode: compSetting.value.mode,
      masterShowPurchasePrice: !!compSetting.value.showPurchasePrice,
    });
    pub.value = { ...pub.value, companyName: name }; // 侧栏/标签页品牌即时更新
    ElMessage.success('设置已保存，客户端即时生效（在线推送 / 下次拉取）');
    await loadCompSetting();
  } catch (e) {
    ElMessage.error(e.response?.data?.error || '保存失败');
  } finally {
    compBusy.value = false;
  }
}
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

/* ====== Settings: 远程协助 · 默认控制码 ======
 *
 * 为什么要有它：员工自己生成的访问码是**他个人**的钥匙。管理员要维护门店/
 * 前台那台常开的机器时，不可能每次都让人家跑过去点一次「生成访问码」。
 * 所以由管理台统一保管一把 —— 「默认」二字只表示**由管理台统一维护**，
 * 它**就是一枚普通访问码**：同样只存哈希、同样有 10 秒撤销窗口、同样撞码限流，
 * 权限一点都不更大。
 *
 * ⚠️ 明文只在生成的那一秒回一次，之后连管理台也查不到（库里只有哈希），
 *    所以界面必须当场提示复制；要换只能"吊销重发"。
 */
const rdc = ref({ code: null });              // 元信息，永不含明文
const rdcForm = ref({ hostId: null, label: '', ttlMinutes: null });
const rdcBusy = ref(false);
const rdcNewCode = ref('');                   // 刚生成的明文，仅这一次可见

async function loadRdc() {
  try {
    const { data } = await api.get('/admin/remote/default-code');
    rdc.value = data || { code: null };
    if (rdc.value.code) {
      rdcForm.value.hostId = rdc.value.code.hostId;
      rdcForm.value.label = rdc.value.code.label || '';
    }
  } catch (e) {
    ElMessage.error(e.response?.data?.error || '读取默认控制码失败');
  }
}

async function genRdc() {
  if (!rdcForm.value.hostId) return ElMessage.warning('请先选择「被维护的账号」');
  rdcBusy.value = true;
  try {
    const { data } = await api.post('/admin/remote/default-code', {
      hostId: rdcForm.value.hostId,
      label: rdcForm.value.label,
      ttlMinutes: rdcForm.value.ttlMinutes,
    });
    rdcNewCode.value = data.code || '';
    await loadRdc();
    ElMessage.success('已生成，请当场复制保存（之后查不到）');
  } catch (e) {
    ElMessage.error(e.response?.data?.error || '生成失败');
  } finally {
    rdcBusy.value = false;
  }
}

async function clearRdc() {
  try {
    await ElMessageBox.confirm(
      '吊销后这把码立刻失效，已拿到它的人将无法再连接。确定吊销？',
      '吊销默认控制码', { type: 'warning' });
  } catch { return; }
  rdcBusy.value = true;
  try {
    await api.delete('/admin/remote/default-code');
    rdcNewCode.value = '';
    await loadRdc();
    ElMessage.success('已吊销');
  } catch (e) {
    ElMessage.error(e.response?.data?.error || '吊销失败');
  } finally {
    rdcBusy.value = false;
  }
}

/* ====== Settings: TURN 配置向导 ====== */
const turn = ref({});
const turnStep = ref(0);
const turnForm = ref({ key_id: '', api_token: '' });
const turnOk = ref(false);
const turnErr = ref('');
const turnSaved = ref({});

async function loadTurn() {
  try {
    turn.value = (await api.get('/admin/turn')).data;
    // 已配好且来源里有 cloudflare 时，直接落到第三步（方便看命令/移除）
    if (turn.value.cloudflareEnabled) turnStep.value = 2;
  } catch (e) {
    ElMessage.error(e.response?.data?.error || '读取中继状态失败');
  }
}

async function verifyTurn() {
  turnOk.value = false;
  turnErr.value = '';
  try {
    // 先纯探测，不写盘 —— 把「凭据是否可用」和「写配置」两步分开，出错好定位
    const probe = (await api.post('/admin/turn/verify', turnForm.value)).data;
    if (!probe.ok) {
      turnErr.value = probe.error || '校验失败';
      turnStep.value = 1;
      return;
    }
    const r = (await api.post('/admin/turn', turnForm.value)).data;
    turnSaved.value = r;
    turnOk.value = true;
    turnStep.value = 1;
    turnForm.value = { key_id: '', api_token: '' };
    await loadTurn();
  } catch (e) {
    turnErr.value = e.response?.data?.error || e.message || '保存失败';
    turnStep.value = 1;
  }
}

async function removeTurn() {
  try {
    const r = (await api.delete('/admin/turn')).data;
    turnSaved.value = r;
    turnStep.value = 2;
    await loadTurn();
    ElMessage.success('已移除，请按下方命令重建容器');
  } catch (e) {
    ElMessage.error(e.response?.data?.error || '移除失败');
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

// ====== 应用中心总览（内置应用 + 自定义模块） ======
// 内置应用（考勤/申请/通讯录）随客户端发布，管理员只能"看"、不能改 ——
// 能改的只有它们依赖的业务状态。所以这里展示的是"现在为什么可见/不可见"，
// 而不是一堆开关（开关只会配出"入口在、点进去报错"的状态）。
const appCatalog = ref({ builtin: [], dynamic: [], context: {} });
const appWhy = ref({});
async function loadAppCatalog() {
  try {
    const { data } = await api.get('/admin/apps');
    appCatalog.value = data;
    const whys = await Promise.all((data.builtin || []).map((a) =>
      api.get('/admin/apps/why?id=' + a.id).then((r) => r.data).catch(() => null)));
    const map = {};
    for (const w of whys) if (w) map[w.id] = w;
    appWhy.value = map;
    await loadWorkbenchView();
  } catch (e) {
    ElMessage.error(e.response?.data?.error || '加载应用清单失败');
  }
}

// ====== 工作台版式：分组 + 公告（v0.22.0） ======
// 这两样管的是"整块工作台长什么样"，不属于任何一个应用，所以单独一块。
// 和上面的应用总览共用 /admin/apps 一次请求拿到的 groups / notices。
const wb = reactive({
  groups: [], notices: [], textMax: 60, contentMax: 2000, maxDownload: 3, labelMax: 8,
  newKey: '', newLabel: '', newSort: 100,
  newNotice: '', newNoticeSort: 100, newNoticeContent: '',
  newNoticeBg: null, newNoticeBgUrl: '',
  busy: false,
});

// 公告背景图：上传后回填到草稿；wbBgTarget 区分"新建草稿"还是"改某条已有公告"
const wbBgTarget = ref(null);
const wbBgEl = ref(null);
const wbPreviewStyle = computed(() => wb.newNoticeBgUrl
  ? { backgroundImage: `url(${wb.newNoticeBgUrl})`, backgroundSize: 'cover', backgroundPosition: 'center' }
  : {});

/** 表单都放空，免得下次打开抽屉留着上一次的输入 */
function resetWorkbenchDraft() {
  wb.newKey = ''; wb.newLabel = ''; wb.newSort = 100;
  wb.newNotice = ''; wb.newNoticeSort = 100; wb.newNoticeContent = '';
  wb.newNoticeBg = null; wb.newNoticeBgUrl = '';
}

async function loadWorkbenchView() {
  // ⚠️ 分组和公告都**当场向各自的接口要**，不要从 appCatalog 那份快照里读。
  //
  // 2026-09-27 实测踩到的坑：发布公告后列表**永远是空的**（No Data），
  // 得整页刷新才看得见。原因就是这里原来写的是
  //     wb.notices = appCatalog.value.notices || [];
  // 而 appCatalog 是**上一次 loadAppCatalog() 留下的旧快照** ——
  // addNotice() 发布成功后只调了这个函数，没人去重新拉 /admin/apps，
  // 于是刚发的那条根本不在 wb.notices 里。改名 / 调序 / 停用 / 删除
  // 之后也一样显示的是改之前的状态。
  // 顺带修掉：wb.maxDownload 原来从没被赋过值，一直写死 3。
  const [g, n] = await Promise.allSettled([
    api.get('/admin/apps/groups'),
    api.get('/admin/apps/notices'),
  ]);
  if (g.status === 'fulfilled') {
    wb.groups = g.value.data.groups || wb.groups;
    wb.labelMax = g.value.data.labelMax || 8;
  } else {
    wb.groups = appCatalog.value.groups || wb.groups;   // 接口挂了退回快照
  }
  if (n.status === 'fulfilled') {
    wb.notices = n.value.data.notices || [];
    wb.textMax = n.value.data.textMax || 60;
    wb.contentMax = n.value.data.contentMax || 2000;
    wb.maxDownload = n.value.data.maxDownload || 3;
  } else {
    wb.notices = appCatalog.value.notices || [];
  }
}

const wbToast = (data, fallback) => ElMessage.success((data && data.message) || fallback);

/* ---------- 分组 ---------- */

async function addGroup() {
  if (!wb.newKey.trim() || !wb.newLabel.trim()) {
    ElMessage.warning('组名和 key 都要填'); return;
  }
  wb.busy = true;
  try {
    const { data } = await api.post('/admin/apps/groups', {
      key: wb.newKey.trim(), label: wb.newLabel.trim(), sort: wb.newSort,
    });
    wbToast(data, '已新增分组');
    await Promise.all([loadWorkbenchView(), loadAppCatalog()]);
  } catch (e) {
    ElMessage.error(e.response?.data?.error || '新增分组失败');
  } finally {
    wb.busy = false;
    resetWorkbenchDraft();
  }
}

/** 改一个组（改名 / 调序 / 收放）。inline 表格里直接改，不用点保存 */
async function wbSaveGroup(row, patch) {
  try {
    const { data } = await api.patch('/admin/apps/groups/' + row.key, patch);
    wbToast(data, '已保存');
    await Promise.all([loadWorkbenchView(), loadAppCatalog()]);
  } catch (e) {
    ElMessage.error(e.response?.data?.error || '保存失败');
    loadWorkbenchView();
  }
}

async function wbDelGroup(row) {
  try {
    const { data } = await api.delete('/admin/apps/groups/' + row.key);
    wbToast(data, '已删除');
    await Promise.all([loadWorkbenchView(), loadAppCatalog()]);
  } catch (e) {
    ElMessage.error(e.response?.data?.error || '删除失败');
  }
}

/** 总览表里直接把某个应用挪到别的组（下拉选一次就生效） */
async function appMoveGroup(row, key) {
  if (!key) return;
  try {
    await api.patch('/admin/apps/' + row.id, { group: key });
    ElMessage.success(`已把「${row.effective.title}」挪到「${groupLabelOf(key)}」，客户端下次进工作台生效`);
    await Promise.all([loadWorkbenchView(), loadAppCatalog()]);
  } catch (e) {
    ElMessage.error(e.response?.data?.error || '挪分组失败');
    loadAppCatalog();
  }
}

function groupLabelOf(key) {
  const g = (wb.groups || []).find((x) => x.key === key);
  return g ? g.label : key;
}

/* ---------- 公告 ---------- */

async function addNotice() {
  const text = (wb.newNotice || '').trim();
  if (!text) { ElMessage.warning('公告标题不能为空'); return; }
  wb.busy = true;
  try {
    const { data } = await api.post('/admin/apps/notices', {
      text, content: wb.newNoticeContent || '', sort: wb.newNoticeSort, bgFileId: wb.newNoticeBg || undefined,
    });
    wbToast(data, '已发布');
    await loadWorkbenchView();
  } catch (e) {
    ElMessage.error(e.response?.data?.error || '发布失败');
  } finally {
    wb.busy = false;
    wb.newNotice = '';
    wb.newNoticeContent = '';
  }
}

/** 公告背景图上传：wbBgTarget 决定填到"草稿"还是"某条已有公告" */
async function onWbBg(e) {
  const file = e.target.files?.[0];
  e.target.value = '';
  const target = wbBgTarget.value;
  wbBgTarget.value = null;
  if (!file) return;
  try {
    const fd = new FormData();
    fd.append('file', file);
    const { data } = await api.post('/files/upload', fd);
    if (target === 'new') {
      wb.newNoticeBg = data.id;
      wb.newNoticeBgUrl = data.url;
    } else if (target && target.row) {
      const row = target.row;
      row.bgFileId = data.id;
      row.bgUrl = data.url;
      await wbSaveNotice(row, { bgFileId: data.id });
    }
    ElMessage.success('背景图已上传');
  } catch (err) {
    ElMessage.error(err.response?.data?.error || '上传失败');
  }
}

function clearWbBg() {
  wb.newNoticeBg = null;
  wb.newNoticeBgUrl = '';
}

async function clearWbRowBg(row) {
  row.bgFileId = 0;
  row.bgUrl = '';
  await wbSaveNotice(row, { bgFileId: null });
}

async function wbSaveNotice(row, patch) {
  try {
    const { data } = await api.patch('/admin/apps/notices/' + row.id, patch);
    wbToast(data, '已保存');
    await loadWorkbenchView();
  } catch (e) {
    ElMessage.error(e.response?.data?.error || '保存失败');
    loadWorkbenchView();
  }
}

async function delNotice(row) {
  try {
    const { data } = await api.delete('/admin/apps/notices/' + row.id);
    wbToast(data, '已删除');
    await loadWorkbenchView();
  } catch (e) {
    ElMessage.error(e.response?.data?.error || '删除失败');
  }
}

/** 只清已停用的，生效中的不动 */
async function purgeNotices() {
  try {
    const { data } = await api.post('/admin/apps/notices/purge');
    wbToast(data, '已清理');
    await loadWorkbenchView();
  } catch (e) {
    ElMessage.error(e.response?.data?.error || '清理失败');
  }
}

// ====== 应用管理抽屉（v0.21.0） ======
//
// 四块：基本信息（改名/图标/排序）、功能设置（参数）、数据（概览/明细/导出）、停用与清理。
//
// ⚠️ 一个刻意的取舍：基本信息是"整份表单提交"，参数与停用是"改一下立刻保存"。
//    因为表单里的名称/图标/排序是一个整体（改完点保存才生效，能反悔），
//    而开关类的参数如果也要"改完再点保存"，管理员会漏点 —— 他以为已经生效了。
const appAdm = reactive({
  open: false, loading: false, error: '', id: '', title: '', tab: 'basic',
  data: null, saving: false,
  form: { title: '', icon: '', sort: null, group: '', color: '' },
  src: '', q: '', range: null, allTime: true, page: 1, pageSize: 50,
  rows: [], cols: [], total: 0, rowsLoading: false, srcTimeFiltered: true,
  purgeSrc: '', purgePrev: null, purgeConfirm: 0, purgeBusy: false,
});

const NEED_LABEL = {
  workMode: '需开启工作模式', attendance: '需开启考勤', orgMember: '需录进组织名册',
};
/** 出厂条件（need）翻成人话 —— 管理台要能回答"为什么员工看不到" */
function needText(need) {
  if (!need || !Object.keys(need).length) return '无（对所有人生效）';
  const t = [];
  if (need.workMode) t.push(NEED_LABEL.workMode);
  if (need.attendance) t.push(NEED_LABEL.attendance);
  if (need.orgMember) t.push(NEED_LABEL.orgMember);
  if (need.role === 'employee') t.push('员工专属（管理员看不到）');
  if (need.adminOnly) t.push('管理员专属（员工看不到）');
  return t.join(' · ') || '无';
}

function admFormOf(d) {
  const ov = d.app.override || {};
  return {
    title: ov.title || '', icon: ov.icon || '', sort: ov.sort ?? null,
    group: ov.group || '', color: ov.color || '',
  };
}

/**
 * 图标底色的预设色块 —— 和 apps.js 里 BUILTIN_APPS 的出厂色对齐，
 * 管理员不用猜 "#" 后面该填什么。
 */
const WB_COLORS = [
  '#2B6FE0', '#12A594', '#475569', '#0E7490', '#F0821E', '#C0392B',
  '#A9761A', '#1F7A3D', '#2E8BC0', '#C2185B', '#8250DF',
];

/** 只刷数据、不重置界面状态（保存完、清理完要留在原处，不能把抽屉弹回第一页） */
async function refreshAppAdmin() {
  const { data } = await api.get('/admin/apps/' + appAdm.id);
  appAdm.data = data;
  appAdm.title = `${data.app.factory.title} · 应用管理`;
  appAdm.form = admFormOf(data);
  return data;
}

/**
 * 打开某个应用的「应用管理」抽屉。
 * @param label 行内当前显示名 —— 标题在**打开瞬间**就用它设好。曾经只在加载成功
 *              后才更新标题，结果加载失败时抽屉顶着上一个应用的名字（截图里
 *              「补货 · 应用管理」实际点的是库房减货），排查的人先被带进沟里。
 */
async function openAppAdmin(id, label) {
  Object.assign(appAdm, {
    open: true, loading: true, error: '', id, tab: 'basic', data: null,
    title: `${label || id} · 应用管理`,
    rows: [], cols: [], total: 0, q: '', range: null, allTime: true, page: 1,
    purgePrev: null, purgeConfirm: 0,
  });
  try {
    const data = await refreshAppAdmin();
    appAdm.src = (data.data.sources[0] || {}).key || '';
    appAdm.purgeSrc = (data.data.purgeables[0] || {}).key || '';
    if (appAdm.src) await loadAppRows();
  } catch (e) {
    appAdm.error = e.response?.data?.error || '加载应用信息失败';
  } finally {
    appAdm.loading = false;
  }
}

async function saveAppAdm() {
  appAdm.saving = true;
  try {
    // 留空 = 清回出厂（服务端把 '' 与 null 都当"不覆盖"）。
    // 表单里预填的是**当前覆盖值**，所以保存 = "让覆盖正好等于这些值"，
    // 没碰过的项本来就是空的，不会被这次保存莫名其妙改掉。
    const { data } = await api.patch('/admin/apps/' + appAdm.id, {
      title: appAdm.form.title || '',
      icon: appAdm.form.icon || '',
      group: appAdm.form.group || '',
      color: appAdm.form.color || '',
      sort: appAdm.form.sort === null || appAdm.form.sort === undefined ? null : Number(appAdm.form.sort),
    });
    ElMessage.success(data.message || '已保存');
    await Promise.all([refreshAppAdmin(), loadAppCatalog()]);
  } catch (e) {
    ElMessage.error(e.response?.data?.error || '保存失败');
  } finally {
    appAdm.saving = false;
  }
}

/**
 * 总览页直接调序（龙哥 2026-09-26：不想为挪个顺序进抽屉填数字）。
 * 做法：按当前生效排序找到相邻行，两行**交换排序号**，各 PATCH 一次。
 * 两个 sort 相等时（历史数据撞号）交换不生效，退一步把后面那行
 * 挪一个位 —— 不追求完美布局，管理员随后还能再点。
 */
async function appMove(row, dir) {
  const list = [...(appCatalog.value.builtin || [])].sort(
    (a, b) => (a.effective.sort - b.effective.sort) || a.id.localeCompare(b.id));
  const i = list.findIndex((x) => x.id === row.id);
  const j = i + dir;
  if (i < 0 || j < 0 || j >= list.length) return;
  const a = list[i], b = list[j];
  let sa = a.effective.sort, sb = b.effective.sort;
  if (sa === sb) sb = sb + (dir === -1 ? 1 : -1);
  try {
    await Promise.all([
      api.patch('/admin/apps/' + a.id, { sort: sb }),
      api.patch('/admin/apps/' + b.id, { sort: sa }),
    ]);
    ElMessage.success('已调整顺序，客户端下次进工作台生效');
    await loadAppCatalog();
  } catch (e) {
    ElMessage.error(e.response?.data?.error || '调整顺序失败');
  }
}

async function resetAppAdm() {  try {
    await ElMessageBox.confirm('恢复出厂设置：名称、图标、排序、参数、停用状态全部回到出厂。确定吗？',
      '恢复出厂', { type: 'warning', confirmButtonText: '恢复', cancelButtonText: '取消' });
  } catch { return; }
  try {
    const { data } = await api.delete('/admin/apps/' + appAdm.id);
    ElMessage.success(data.message || '已恢复出厂设置');
    await Promise.all([refreshAppAdmin(), loadAppCatalog()]);
  } catch (e) {
    ElMessage.error(e.response?.data?.error || '恢复失败');
  }
}

/** 单个参数即时保存。送出厂默认值 = 还原（服务端会把这个键删掉，不留"假覆盖"） */
async function setAppParam(key, value) {
  try {
    const { data } = await api.patch('/admin/apps/' + appAdm.id, { params: { [key]: value } });
    appAdm.data.app = data.app;
    ElMessage.success('已保存');
    await loadAppCatalog();
  } catch (e) {
    ElMessage.error(e.response?.data?.error || '参数保存失败');
  }
}

async function toggleAppDisabled(v) {
  if (v) {
    const label = appAdm.data?.app?.effective?.title || appAdm.id;
    try {
      await ElMessageBox.confirm(
        `停用「${label}」后：客户端不再显示这个入口，它的后端接口一律回 403（不再只是藏图标）。`
        + '已经产生的数据不受影响，随时可以在同一个开关上恢复。确定停用吗？',
        '停用应用', { type: 'warning', confirmButtonText: '停用', cancelButtonText: '取消' });
    } catch { return; }
  }
  try {
    const { data } = await api.patch('/admin/apps/' + appAdm.id, { disabled: !!v });
    ElMessage.success(data.message || '已更新');
    await Promise.all([refreshAppAdmin(), loadAppCatalog()]);
  } catch (e) {
    ElMessage.error(e.response?.data?.error || '操作失败');
  }
}

/** 时间窗（明细与清理共用同一套口径，避免两个 tab 各筛一套） */
function admWindow() {
  const p = {};
  if (appAdm.allTime) { p.allTime = 1; return p; }
  if (appAdm.range && appAdm.range.length === 2) {
    p.from = new Date(`${appAdm.range[0]}T00:00:00`).getTime();
    p.to = new Date(`${appAdm.range[1]}T23:59:59`).getTime();
  }
  return p;
}

async function loadAppRows() {
  if (!appAdm.src) return;
  appAdm.rowsLoading = true;
  try {
    const { data } = await api.get(`/admin/apps/${appAdm.id}/data`, {
      params: { source: appAdm.src, page: appAdm.page, pageSize: appAdm.pageSize, q: appAdm.q || undefined, ...admWindow() },
    });
    appAdm.rows = data.items || [];
    appAdm.total = data.total || 0;
    appAdm.cols = data.columns || [];
    appAdm.srcTimeFiltered = data.timeFiltered !== false;
  } catch (e) {
    ElMessage.error(e.response?.data?.error || '加载明细失败');
  } finally {
    appAdm.rowsLoading = false;
  }
}

async function exportAppRows() {
  try {
    const res = await api.get(`/admin/apps/${appAdm.id}/export`, {
      params: { source: appAdm.src, q: appAdm.q || undefined, ...admWindow() },
      responseType: 'blob',
    });
    const url = URL.createObjectURL(res.data);
    const a = document.createElement('a');
    a.href = url;
    a.download = `${appAdm.id}-${appAdm.src}-${new Date().toISOString().slice(0, 10)}.csv`;
    document.body.appendChild(a);
    a.click();
    a.remove();
    URL.revokeObjectURL(url);
    ElMessage.success('已导出（Excel 直接双击打开，中文不乱码）');
  } catch (e) {
    ElMessage.error('导出失败：' + (e.response?.data?.error || e.message || '未知错误'));
  }
}

async function appPurgePreview() {
  appAdm.purgeBusy = true;
  appAdm.purgePrev = null;
  appAdm.purgeConfirm = 0;
  try {
    const { data } = await api.post(`/admin/apps/${appAdm.id}/purge`,
      { source: appAdm.purgeSrc, dryRun: true, ...admWindow() });
    appAdm.purgePrev = data;
  } catch (e) {
    ElMessage.error(e.response?.data?.error || '预览失败');
  } finally {
    appAdm.purgeBusy = false;
  }
}

async function appPurgeRun() {
  const expect = appAdm.purgePrev?.count;
  if (!expect) return;
  appAdm.purgeBusy = true;
  try {
    const { data } = await api.post(`/admin/apps/${appAdm.id}/purge`,
      { source: appAdm.purgeSrc, dryRun: false, expectCount: expect, ...admWindow() });
    appAdm.purgePrev = null;
    appAdm.purgeConfirm = 0;
    ElMessage.success(data.message || '已清理');
    // 备份没落盘必须单独说 —— 删成功但没备份，是"以为能捞回来其实不能"
    if (data.backupError) ElMessage.warning('注意：备份没能落盘 —— ' + data.backupError);
    if (data.backupTruncated) ElMessage.warning(`备份只含前 ${data.backupTotal} 行中的一部分（见响应 backupTruncated）`);
    await refreshAppAdmin();
    if (appAdm.src) await loadAppRows();
  } catch (e) {
    const d = e.response?.data;
    ElMessage.error(d?.error || '清理失败');
    // 条数变了就作废预览：让管理员重新看一遍现在的命中范围，而不是照着旧数字再点一次
    if (d?.code === 'count_changed') appAdm.purgePrev = null;
  } finally {
    appAdm.purgeBusy = false;
  }
}

// ====== 考勤管理（工作模式下随工作模式一起启用） ======
//
// 服务端把口径全部算好（谁迟到、迟到几分钟、那天算不算请假），管理台只负责展示与
// 配置。所以这里没有任何"前端算考勤"的逻辑 —— 一旦前端算，管理台和客户端就会
// 各算一套，两边数字对不上时没人说得清哪个对。
const attTab = ref('today');
const attBusy = ref(false);
const attDay = ref('');
const attRange = ref([]);
const attDeptId = ref(null);
const attWeekLabels = [
  { v: 1, t: '周一' }, { v: 2, t: '周二' }, { v: 3, t: '周三' }, { v: 4, t: '周四' },
  { v: 5, t: '周五' }, { v: 6, t: '周六' }, { v: 0, t: '周日' },
];
const attConfig = ref({
  enabled: true,
  // 与服务端 attDefaultShift 的默认值保持一致（08:00-12:00 / 13:00-17:00，一天 4 次卡）
  defaultShift: { workStart: '08:00', restStart: '12:00', restEnd: '13:00', workEnd: '17:00', restMinutes: 60, flexMinutes: 0, lateGrace: 0, earlyGrace: 0 },
  workdays: [1, 2, 3, 4, 5],
  // 定位精度阈值（米）：与服务端 attFenceAccuracyMax 默认值一致
  fenceAccuracyMax: 200,
  serverTime: 0,
  timezone: '',
});
const attOverview = ref({ stats: {}, items: [] });
const attReport = ref({ users: [], totals: {} });
const attShifts = ref([]);
const attGroups = ref([]);
const attRequests = ref([]);
const attReqCounts = ref({});
const attReqStatus = ref('pending');
const attReqKind = ref('');
const attShiftDlg = ref(false);
const attShiftForm = ref({});
const attGroupDlg = ref(false);
const attGroupForm = ref({});
const attLocations = ref([]);
const attLocDlg = ref(false);
const attLocForm = ref({ id: null, name: '', lat: '', lng: '', radius: 100 });
const attRecDlg = ref(false);
const attRecForm = ref({});
const attDetailDlg = ref(false);
const attDetail = ref({ day: '', nickname: '', items: [] });

// ── 智能薪酬（复刻钉钉的"考勤算工资"）──
const salMonth = ref('');
const salBusy = ref(false);
const salConfig = ref({
  lateTiers: [{ upTo: 30, amount: 20 }, { upTo: 60, amount: 50 }],
  latePerMinute: 2,
  missingCardDeduct: 50,
  absentDayDeductPct: 100,
  leaveDeductPct: 100,
  fullAttendanceBonus: 100,
  dayDivisor: 21.75,
  overtimePerHour: 0,
  customized: false,
});
const salBases = ref([]);
const salReport = ref({ items: [], totalNet: 0, config: {} });

// 看板卡片：口径与服务端判定一致（迟到含"迟到+早退"，早退同理）
const attOvCards = computed(() => [
  { k: 'total', label: '应打卡' }, { k: 'present', label: '已打卡' },
  { k: 'normal', label: '正常' }, { k: 'late', label: '迟到' },
  { k: 'early', label: '早退' }, { k: 'missing', label: '缺卡' },
  { k: 'absent', label: '缺勤' }, { k: 'leave', label: '请假' },
]);
// 报表卡片：4 次卡的班次下"缺卡(次)"会因为一天 4 张卡而虚高，
// 所以把"漏打卡(张)"和总计"在岗(小时)"摆出来 —— 管理者真正要看的是工时
const attRepCards = computed(() => [
  { k: 'people', label: '人数' }, { k: 'workdays', label: '应出勤(人日)' },
  { k: 'present', label: '出勤(人日)' }, { k: 'late', label: '迟到(次)' },
  { k: 'early', label: '早退(次)' }, { k: 'missingPunches', label: '漏打卡(张)' },
  { k: 'absent', label: '缺勤(天)' },
  { k: 'workedMinutes', label: '在岗(小时)', fmt: 'hours' },
]);
// 合计卡片的取值：分钟转小时走 fmt，其余原样
function attCardVal(totals, c) {
  if (!totals) return '—';
  if (c.fmt === 'hours') return (Math.round((Number(totals[c.k]) || 0) / 6) / 10) + 'h';
  return totals[c.k] ?? 0;
}

function attDayStr(d) {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}
function attToday() { return attDayStr(new Date()); }
function attFmtTs(ts) {
  if (!ts) return '—';
  const d = new Date(ts);
  return `${attDayStr(d)} ${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`;
}
function attWeekName(w) {
  return ['周日', '周一', '周二', '周三', '周四', '周五', '周六'][w] || '';
}
// 在岗时长：管理台是横向密集表格，"8h / 7.5h" 比"8 小时 0 分"省地方
function attHours(min) {
  const m = Number(min) || 0;
  if (m <= 0) return '—';
  return (Math.round(m / 6) / 10) + 'h';
}
// 一天打了几张卡："3/4"。2 次卡的班次自然是 "2/2"，同一个写法能兼容
function attPunchCount(row) {
  const exp = Number(row?.expectedPunches) || 0;
  if (!exp) return '—';
  return `${Number(row?.donePunches) || 0}/${exp}`;
}
// 单张卡的小标签样式：缺卡=红、迟到/早退=黄、请假豁免=灰、已打=绿
function attPunchTagType(p) {
  if (p?.exempt) return 'info';
  if (p?.status === 'missing') return 'danger';
  if (p?.status === 'late' || p?.status === 'early') return 'warning';
  if (p?.done) return 'success';
  return 'info';
}
function attPunchText(p) {
  if (!p) return '—';
  if (p.exempt) return '免';
  if (!p.done) return p.due ? '缺' : '待';
  return p.time || '—';
}
function attStatusType(s) {
  return {
    normal: 'success', pending: 'primary', late: 'warning', early: 'warning',
    late_early: 'warning', missing: 'danger', absent: 'danger', leave: 'info',
    outing: 'info', rest: 'info', future: 'info',
  }[s] || 'info';
}
function attLocLabel(m) {
  return { off: '不校验', optional: '有就记录', required: '必须提供（围栏）' }[m] || '不校验';
}
function attLocStatusLabel(s) {
  return { ok: '围栏内', outside: '超出围栏', weak_gps: '精度过低', mock: '模拟定位', no_fix: '无定位' }[s] || '—';
}
function attLocName(id) {
  return attLocations.value.find((l) => l.id === id)?.name || ('#' + id);
}
function attSourceLabel(s) {
  return { app: '客户端打卡', admin: '管理员补录', makeup: '补卡审批' }[s] || s;
}

async function loadAttConfig() {
  try {
    const { data } = await api.get('/admin/attendance/config');
    attConfig.value = {
      enabled: data.enabled !== false,
      defaultShift: data.defaultShift || attConfig.value.defaultShift,
      workdays: Array.isArray(data.workdays) ? data.workdays : [1, 2, 3, 4, 5],
      // 定位精度阈值：老服务端还没这个字段时按默认 200 兜底
      fenceAccuracyMax: Number(data.fenceAccuracyMax) || 200,
      serverTime: data.serverTime,
      timezone: data.timezone,
    };
    return true;
  } catch (e) {
    // 没建组织时后端返回 404 —— 这是"还没到能配考勤的阶段"，不是错误
    if (e.response?.status === 404) return false;
    ElMessage.error(e.response?.data?.error || '加载考勤设置失败');
    return false;
  }
}

async function loadAttOverview() {
  try {
    attOverview.value = (await api.get('/admin/attendance/overview?day=' + attDay.value)).data;
  } catch (e) {
    ElMessage.error(e.response?.data?.error || '加载打卡看板失败');
  }
}
async function loadAttReport() {
  if (!attRange.value || attRange.value.length !== 2) return;
  try {
    const p = new URLSearchParams({ from: attRange.value[0], to: attRange.value[1] });
    if (attDeptId.value) p.set('deptId', attDeptId.value);
    attReport.value = (await api.get('/admin/attendance/report?' + p.toString())).data;
  } catch (e) {
    ElMessage.error(e.response?.data?.error || '加载统计报表失败');
  }
}
async function loadAttShifts() {
  attShifts.value = (await api.get('/admin/attendance/shifts')).data.items || [];
}
async function loadAttGroups() {
  attGroups.value = (await api.get('/admin/attendance/groups')).data.items || [];
}
async function loadAttRequests() {
  try {
    const p = new URLSearchParams();
    if (attReqStatus.value) p.set('status', attReqStatus.value);
    if (attReqKind.value) p.set('kind', attReqKind.value);
    const { data } = await api.get('/admin/attendance/requests?' + p.toString());
    attRequests.value = data.items || [];
    attReqCounts.value = data.counts || {};
  } catch (e) {
    ElMessage.error(e.response?.data?.error || '加载申请列表失败');
  }
}
async function loadAttTab() {
  if (attTab.value === 'today') await loadAttOverview();
  else if (attTab.value === 'report') await loadAttReport();
  else if (attTab.value === 'shift') { await loadAttShifts(); await loadAttGroups(); await loadAttLocations(); }
  else if (attTab.value === 'locations') await loadAttLocations();
  else if (attTab.value === 'review') await loadAttRequests();
  else if (attTab.value === 'config') await loadAttConfig();
  else if (attTab.value === 'salary') await loadSalary();
}

// ── 智能薪酬 ──
async function loadSalary() {
  if (!salMonth.value) {
    const d = new Date();
    salMonth.value = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`;
  }
  try {
    const [cfg, bases] = await Promise.all([
      api.get('/admin/attendance/salary/config'),
      api.get('/admin/attendance/salary/bases'),
    ]);
    if (cfg.data?.config) {
      // 档位是数组，深拷贝一份再做表单编辑（避免直接改到展示数据）
      salConfig.value = { ...cfg.data.config, lateTiers: (cfg.data.config.lateTiers || []).map((t) => ({ ...t })) };
    }
    salBases.value = bases.data?.items || [];
    await loadSalReport();
  } catch (e) {
    ElMessage.error(e.response?.data?.error || '加载智能薪酬失败');
  }
}
async function loadSalReport() {
  try {
    salReport.value = (await api.get('/admin/attendance/salary/report?month=' + salMonth.value)).data;
  } catch (e) {
    ElMessage.error(e.response?.data?.error || '加载薪酬报表失败');
  }
}
async function saveSalConfig() {
  salBusy.value = true;
  try {
    const { data } = await api.put('/admin/attendance/salary/config', salConfig.value);
    salConfig.value = { ...data.config, lateTiers: (data.config.lateTiers || []).map((t) => ({ ...t })) };
    ElMessage.success('薪酬规则已保存，报表已按新规则重算');
    await loadSalReport();
  } catch (e) {
    ElMessage.error(e.response?.data?.error || '保存失败');
  } finally {
    salBusy.value = false;
  }
}
async function saveSalBases() {
  salBusy.value = true;
  try {
    await api.put('/admin/attendance/salary/bases', {
      items: salBases.value.map((b) => ({ userId: b.userId, monthBase: Number(b.monthBase) || 0 })),
    });
    ElMessage.success('月薪基数已保存');
    await loadSalReport();
  } catch (e) {
    ElMessage.error(e.response?.data?.error || '保存失败');
  } finally {
    salBusy.value = false;
  }
}
/** 报表导出 CSV（Excel 直接打开；金额两位列拆开，方便财务核对） */
function exportSalCsv() {
  const esc = (v) => '"' + String(v ?? '').replaceAll('"', '""') + '"';
  const head = ['工号', '姓名', '月薪基数', '迟到次数', '迟到分钟', '缺卡次数', '早退次数', '旷工天数', '请假天数', '加班分钟', '扣款合计', '奖励合计', '应发', '明细'];
  const lines = [head.map(esc).join(',')];
  for (const it of salReport.value.items || []) {
    lines.push([
      it.username, it.nickname, it.base,
      it.stats?.lateCount ?? 0, it.stats?.lateMinutes ?? 0,
      it.stats?.missingCount ?? 0, it.stats?.earlyCount ?? 0,
      it.stats?.absentDays ?? 0, it.stats?.leaveDays ?? 0,
      it.stats?.overtimeMinutes ?? 0,
      it.deductions, it.bonus, it.net,
      (it.items || []).map((x) => `${x.label} ${x.amount}（${x.note}）`).join('；'),
    ].map(esc).join(','));
  }
  const blob = new Blob(['\uFEFF' + lines.join('\r\n')], { type: 'text/csv;charset=utf-8' });
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = `智能薪酬_${salMonth.value}.csv`;
  a.click();
  URL.revokeObjectURL(a.href);
}
async function loadAttLocations() {
  try {
    attLocations.value = (await api.get('/admin/attendance/locations')).data.items || [];
  } catch (e) {
    ElMessage.error(e.response?.data?.error || '加载打卡点位失败');
  }
}
// 某点位被多少个考勤组引用（用于删除前的提示，避免误删正在用的围栏）
function attGroupRefCount(locId) {
  let n = 0;
  for (const g of attGroups.value) if ((g.locationIds || []).includes(locId)) n++;
  return n;
}
async function loadAttendance() {
  if (!attDay.value) attDay.value = attToday();
  if (!attRange.value || attRange.value.length !== 2) {
    const d = new Date();
    d.setDate(d.getDate() - 29);
    attRange.value = [attDayStr(d), attToday()];
  }
  await loadOrgs();          // 部门/员工列表（报表筛选、考勤组选人要用）
  await loadAttConfig();     // 服务器时间、开关、默认班次
  await loadAttLocations();  // 打卡点位（考勤组弹窗勾选用）
  await loadAttTab();
}
async function saveAttConfig() {
  attBusy.value = true;
  try {
    const shift = { ...attConfig.value.defaultShift };
    if (shift.restStart) shift.restMinutes = attRestSpan(shift);
    const { data } = await api.put('/admin/attendance/config', {
      enabled: attConfig.value.enabled,
      defaultShift: shift,
      workdays: attConfig.value.workdays,
      fenceAccuracyMax: attConfig.value.fenceAccuracyMax,
    });
    const n = Number(data.defaultShift?.punchesPerDay) || 2;
    ElMessage.success(`考勤设置已保存（默认班次一天 ${n} 次卡）`);
    attConfig.value = {
      ...attConfig.value,
      enabled: data.enabled,
      defaultShift: data.defaultShift,
      workdays: data.workdays,
      fenceAccuracyMax: Number(data.fenceAccuracyMax) || attConfig.value.fenceAccuracyMax,
    };
    await loadAttOverview();
    await loadAttShifts();
  } catch (e) {
    ElMessage.error(e.response?.data?.error || '保存失败');
  } finally {
    attBusy.value = false;
  }
}

// ---- 班次 ----
function openShiftDlg(row) {
  // 新增班次默认带上 12:00-13:00 的休息时段＝一天 4 次卡（龙哥这边的常见作息）；
  // 不想要的把两个框清空即可，会退回 2 次卡
  attShiftForm.value = row
    ? { ...row }
    : { id: null, name: '', workStart: '09:00', workEnd: '18:00', restStart: '12:00', restEnd: '13:00',
        restMinutes: 60, flexMinutes: 0, lateGrace: 0, earlyGrace: 0 };
  attShiftDlg.value = true;
}
async function saveShift() {
  attBusy.value = true;
  try {
    const b = { ...attShiftForm.value };
    if (b.restStart) b.restMinutes = attRestSpan(b);
    if (b.id) await api.put(`/admin/attendance/shifts/${b.id}`, b);
    else await api.post('/admin/attendance/shifts', b);
    ElMessage.success('班次已保存');
    attShiftDlg.value = false;
    await loadAttShifts();
  } catch (e) {
    ElMessage.error(e.response?.data?.error || '保存失败');
  } finally {
    attBusy.value = false;
  }
}
// 休息时段跨多少分钟。填了时段后 restMinutes 只作展示，但让它跟时段一致，
// 免得后台数据里留着一个"休息 60 分"、时段却是 12:00-13:30 的自相矛盾数字
function attRestSpan(f) {
  const toMin = (t) => Number(String(t).slice(0, 2)) * 60 + Number(String(t).slice(3, 5));
  const a = toMin(f.restStart), b = toMin(f.restEnd);
  return Number.isFinite(a) && Number.isFinite(b) && b > a ? b - a : 0;
}
async function removeShift(row) {
  try {
    await ElMessageBox.confirm(`确认删除班次「${row.name}」？`, '删除确认', { type: 'warning' });
  } catch { return; }
  try {
    await api.delete(`/admin/attendance/shifts/${row.id}`);
    ElMessage.success('已删除');
    await loadAttShifts();
  } catch (e) {
    ElMessage.error(e.response?.data?.error || '删除失败');
  }
}

// ---- 考勤组 ----
function openGroupDlg(row) {
  attGroupForm.value = row
    ? { id: row.id, name: row.name, shiftId: row.shiftId || null, locationMode: row.locationMode || 'off',
        deptIds: [...(row.deptIds || [])], memberIds: [...(row.memberIds || [])],
        locationIds: [...(row.locationIds || [])] }
    : { id: null, name: '', shiftId: null, locationMode: 'off', deptIds: [], memberIds: [], locationIds: [] };
  attGroupDlg.value = true;
}
async function saveAttGroup() {
  attBusy.value = true;
  try {
    const b = attGroupForm.value;
    if (b.id) await api.put(`/admin/attendance/groups/${b.id}`, b);
    else await api.post('/admin/attendance/groups', b);
    ElMessage.success('考勤组已保存');
    attGroupDlg.value = false;
    await loadAttGroups();
  } catch (e) {
    ElMessage.error(e.response?.data?.error || '保存失败');
  } finally {
    attBusy.value = false;
  }
}
async function removeGroup(row) {
  try {
    await ElMessageBox.confirm(`确认删除考勤组「${row.name}」？组内人员将回到组织默认班次。`, '删除确认', { type: 'warning' });
  } catch { return; }
  try {
    await api.delete(`/admin/attendance/groups/${row.id}`);
    ElMessage.success('已删除');
    await loadAttGroups();
  } catch (e) {
    ElMessage.error(e.response?.data?.error || '删除失败');
  }
}

// ---- 打卡点位 ----
function openLocDlg(row) {
  attLocForm.value = row
    ? { id: row.id, name: row.name, lat: String(row.lat), lng: String(row.lng), radius: row.radius || 100 }
    : { id: null, name: '', lat: '', lng: '', radius: 100 };
  attLocDlg.value = true;
}
async function saveLoc() {
  const f = attLocForm.value;
  const lat = Number(f.lat), lng = Number(f.lng);
  if (!String(f.name || '').trim()) { ElMessage.warning('请填写点位名称'); return; }
  if (!Number.isFinite(lat) || !Number.isFinite(lng) || lat < -90 || lat > 90 || lng < -180 || lng > 180) {
    ElMessage.warning('经纬度不合法：纬度 -90~90，经度 -180~180');
    return;
  }
  attBusy.value = true;
  try {
    const b = { name: f.name, lat, lng, radius: f.radius || 100 };
    if (f.id) await api.put(`/admin/attendance/locations/${f.id}`, b);
    else await api.post('/admin/attendance/locations', b);
    ElMessage.success('打卡点位已保存');
    attLocDlg.value = false;
    await loadAttLocations();
  } catch (e) {
    ElMessage.error(e.response?.data?.error || '保存失败');
  } finally {
    attBusy.value = false;
  }
}
async function removeLoc(row) {
  const n = attGroupRefCount(row.id);
  const tip = n > 0
    ? `有 ${n} 个考勤组正在使用该点位，删除后这些组将失去该围栏（若组没有其他点位，将退回"只校验有定位"）。`
    : '该点位未被任何考勤组引用。';
  try {
    await ElMessageBox.confirm(`确认删除打卡点位「${row.name}」？${tip}`, '删除确认', { type: 'warning' });
  } catch { return; }
  try {
    await api.delete(`/admin/attendance/locations/${row.id}`);
    ElMessage.success('已删除');
    await loadAttLocations();
    if (attGroups.value.length) await loadAttGroups(); // 引用数变了，同步刷新
  } catch (e) {
    ElMessage.error(e.response?.data?.error || '删除失败');
  }
}

// ---- 审批 ----
async function reviewAtt(row, approve) {
  let note = '';
  if (approve) {
    try {
      await ElMessageBox.confirm(`通过「${row.nickname}」的${row.kindLabel}申请（${row.desc}）？`, '审批确认', { type: 'info' });
    } catch { return; }
  } else {
    try {
      const r = await ElMessageBox.prompt('请填写驳回原因（会展示给申请人）', '驳回申请', {
        inputPlaceholder: '如：与排班冲突 / 请补充说明',
        inputValidator: (v) => (v && v.trim() ? true : '驳回需要填写原因'),
      });
      note = r.value;
    } catch { return; }
  }
  try {
    await api.post(`/admin/attendance/requests/${row.id}/review`, { approve, note });
    ElMessage.success(approve ? '已通过' : '已驳回');
    await loadAttRequests();
    if (attTab.value === 'review') { /* 留在本页 */ }
  } catch (e) {
    ElMessage.error(e.response?.data?.error || '审批失败');
  }
}

// ---- 补卡 / 明细 ----
function openAttRecordDlg(row) {
  // 默认选中"缺的那张卡"：管理员点「补卡」十有八九就是为了补缺失的卡，
  // 让他再挑一次是多余动作。4 次卡下缺哪张都能直接点名。
  const ps = row.punches || [];
  const options = ps.length ? ps : [
    { key: 'in1', type: 'in', slot: 1, label: '上班卡', expectTime: '' },
    { key: 'out1', type: 'out', slot: 1, label: '下班卡', expectTime: '' },
  ];
  const pick = ps.find((p) => !p.done && !p.exempt) || options[0];
  attRecForm.value = {
    userId: row.userId, nickname: row.nickname, employeeNo: row.employeeNo,
    day: attDay.value,
    key: pick.key, type: pick.type, slot: pick.slot,
    time: pick.expectTime || '',
    options,
  };
  attRecDlg.value = true;
}
// 换卡：类型/段位/默认时刻一起跟着换，避免"选了收工那张、时间还留着 08:00"
function onAttRecPick(key) {
  const p = (attRecForm.value.options || []).find((x) => x.key === key);
  if (!p) return;
  attRecForm.value.type = p.type;
  attRecForm.value.slot = p.slot;
  attRecForm.value.time = p.expectTime || '';
}
async function saveAttRecord() {
  attBusy.value = true;
  try {
    // 只发服务端认识的字段（options 是给弹窗渲染用的，发过去纯属噪音）
    const f = attRecForm.value;
    await api.post('/admin/attendance/records', {
      userId: f.userId, day: f.day, type: f.type, slot: f.slot, time: f.time,
    });
    ElMessage.success('打卡记录已写入');
    attRecDlg.value = false;
    await loadAttOverview();
  } catch (e) {
    ElMessage.error(e.response?.data?.error || '写入失败');
  } finally {
    attBusy.value = false;
  }
}
async function openAttDetail(row) {
  try {
    const { data } = await api.get(`/admin/attendance/records?day=${attDay.value}&userId=${row.userId}`);
    attDetail.value = { day: attDay.value, nickname: row.nickname, items: data.items || [] };
    attDetailDlg.value = true;
  } catch (e) {
    ElMessage.error(e.response?.data?.error || '加载明细失败');
  }
}
async function deleteAttRecord(row) {
  try {
    await ElMessageBox.confirm(`删除这张「${row.punchLabel || (row.type === 'in' ? '上班卡' : '下班卡')}」（${row.time}）？删除后当天的判定会跟着变。`, '删除确认', { type: 'warning' });
  } catch { return; }
  try {
    await api.delete(`/admin/attendance/records/${row.id}`);
    ElMessage.success('已删除');
    attDetail.value.items = attDetail.value.items.filter((x) => x.id !== row.id);
    await loadAttOverview();
  } catch (e) {
    ElMessage.error(e.response?.data?.error || '删除失败');
  }
}

/* ---- 系统帮助页：可搜索问答（套工厂V2「搜索问题→解决问题」模式） ---- */
const helpSearch = ref('');
const helpFaq = [
  { q: '集成对接向导建错了能改吗？怎么改？',
    tags: '集成 对接 向导 修改 编辑 改 机器人 推送地址 入站 出站 订阅 改名',
    a: `<p><b>都能改</b>，不用删了重建（重建会让对接方重新配置）：</p>
      <ul>
        <li><b>机器人</b>：集成对接 → 机器人 → 「改名」。账号（bot_xxx）不可改，其余立即生效。</li>
        <li><b>入站推送</b>：集成对接 → 入站推送 → 「编辑」。可改用途名、换机器人、换目标会话、开关签名校验 —— <b>推送地址不变</b>，对接方零改动。换机器人时它会自动被拉进新会话。</li>
        <li><b>事件订阅</b>：集成对接 → 事件订阅 → 「编辑」。可改用途、回调地址、订阅事件、监听范围；签名密钥不变（换密钥单独点「换密钥」，旧密钥有 24 小时宽限）。</li>
        <li><b>令牌 / 签名凭据</b>：权限和有效期建好后不可改，但可以随时吊销 / 停用 / 重新发一对。</li>
      </ul>
      <p>每一步向导页面上也有说明文字，第一次接可以先读完再点下一步。</p>` },
  { q: '泰格 POS 日报怎么对接到群里？',
    tags: '泰格 POS 日报 对接 tiger-bridge 销售报表 推送',
    a: `<p>集成对接页顶部点 <b>「泰格 POS 日报对接」</b>，三步走完：</p>
      <ol>
        <li><b>推到哪</b>：选日报要进的群（先确认群里有真人 —— 只有机器人自己等于天天推没人看）。</li>
        <li><b>一键开通</b>：自动建好机器人「泰格日报」和推送地址「泰格POS日报」（同名已存在就复用 / 改指向，地址不变），机器人自动进群。可当场点「推一张样例日报」验证链路。</li>
        <li><b>对接说明</b>：向导给出 tiger-bridge（POS 机上的采集程序）的配置要点和必踩坑 —— 地址带 /api 前缀、签名保持关、日期传本地字符串、库存看 v_realtime_stock。</li>
      </ol>
      <p>以后要换群 / 换机器人 / 停用：入站推送列表里点「泰格POS日报」的「编辑」，地址不变，对接方零改动。</p>
      <p>数据口径：tiger-bridge 只读泰格官方视图取数（pos_v_income_day / v_realtime_stock），自带与官方日结的对账熔断，绝不直写泰格业务表。</p>` },
  { q: '推送返回成功，但群里看不到消息',
    tags: '推送 成功 看不到 群 无人 空白 假成功 卡片',
    a: `<p>按命中率排序排查：</p>
      <ol>
        <li><b>群里有没有真人</b>：机器人 + 机器人 = 天天"成功"没人看。去「群组」页实看成员。</li>
        <li><b>推的会话是不是想要的那个</b>：入站推送列表里 name 是你起的名字，<b>「目标会话」列才是真实去向</b>，不一致时以它为准（列表可「编辑」换会话，地址不变）。</li>
        <li><b>是不是"假成功"</b>：HTTP 200 ≠ 内容对。title/text/fields 值必须是<b>字符串</b>，传对象会得到 200 + 群里一条 [object Object]。用列表里的「试推」对比正常卡片长什么样。</li>
        <li><b>手机上登录的账号在不在群里</b>：账号常有重名，"群里有潘坚强"和"你在的号能看到"是两件事。</li>
      </ol>` },
  { q: '入站推送的「签名校验」要不要开？',
    tags: '签名 校验 HMAC 入站 webhook 401 推不进来',
    a: `<p><b>默认关</b>。开了之后对方每次请求都要按 IM 的规则算 HMAC-SHA256 签名 ——
      而绝大多数第三方系统（钉钉风格的告警器、监控工具、泰格 tiger-bridge 等）只会签<b>自家协议</b>的签名，
      开了它们就全部 401 推不进来。</p>
      <p>不开签名也安全：地址本身就是凭证（长随机 token），在列表里随时「停用 / 删除」即可立即失效。
      对接方技术能力强、或要跨公网长期推的，用「签名客户端」（app_id/app_secret）或「公钥接入」那两档更合适。</p>
      <p>已经开了想关：入站推送「编辑」里关掉开关即可，地址不变。</p>` },
  { q: '外网呼入时，被叫端「来电界面根本不弹」，挂断后才显示未接',
    tags: '来电 电话 通话 界面 未接 弹窗 不弹',
    a: `<p>已在 v0.6.1 修复，根因有两个，缺一都修不好：</p>
      <ul>
        <li>长连接断线后<b>放弃重连</b>（旧版重试 12 次就彻底不管了），且没有心跳，假死连接识别不出来 → 来电帧收不到。现在改为无限重连 + 20 秒应用层心跳 + 服务端 30 秒协议层探测。</li>
        <li>服务端一发现被叫掉线就<b>立刻拆话</b>，重连回来也补不了。现在有 20 秒宽限期，期内重连会补推来电界面。</li>
      </ul>
      <p>若仍出现：确认手机上的客户端版本 ≥ v0.6.1。</p>` },
  { q: '双方都在外网时通话完全打不通，或只有声音没有画面',
    tags: '通话 外网 中继 TURN 打不通 没画面 只有声音 P2P',
    a: `<p>说明 P2P 和中继都没成功，基本都是<b>中继没配上</b>。按顺序检查：</p>
      <ol>
        <li>本页「系统设置」是否显示已下发 TURN；没配就先配 Cloudflare TURN（不需要端口映射，最省事）。</li>
        <li>用<b>手机 4G/5G</b> 实测（同 Wi-Fi 下测不出来）。</li>
        <li>自建 coturn 方案还要确认公网端口真的能进 —— 在家里的网络上测公网 IP:3478 是测不准的。</li>
      </ol>` },
  { q: '忘记管理员密码了',
    tags: '管理员 密码 忘记 找回 重置 登录 登录不了',
    a: `<p><b>先看能不能自己查回来</b>：Windows 版双击安装目录里的
      <code class="mono">查看管理员密码.cmd</code>，它会读出当前密码
      （首次运行向导里设的密码也会同步写进那份配置）。</p>
      <p>登录后可在「系统设置」页直接改（无需重启服务）。若已经登不进去、也查不到，
      用环境变量 <code class="mono">ADMIN_USERNAME</code> /
      <code class="mono">ADMIN_PASSWORD</code> 重启服务端做引导；
      用户名不存在时会自动补建这个管理员账号。</p>
      <p><b>全新服务器</b>（还从没设过管理密码）打开管理台会自动进「首次运行」向导，
      当场设一个就行，不用去翻任何配置文件。</p>` },
  { q: '数据怎么备份 / 迁移',
    tags: '备份 迁移 数据 数据库 文件 目录',
    a: `<p>全部数据都在 NAS 的应用目录（<code class="mono">/vol1/@appcenter/xiaozhi-im</code>）下：
      数据库、上传的文件、以及 <code class="mono">docker/.env</code> 配置。
      定期备份 <code class="mono">data/</code> 目录即可，迁机时整个目录搬过去。</p>` },
  { q: '手机装了新版本，但界面还是旧的',
    tags: '更新 升级 版本 安装 安卓 APK 界面旧 没更新',
    a: `<p>安卓在 <code class="mono">versionCode</code> 没增长时会<b>静默跳过</b>覆盖安装，看起来像没更新。
      请确认安装的是交付目录里版本号最高的那个 APK。</p>` },
  { q: '客户端连不上服务器',
    tags: '连不上 连接 服务器 地址 网络 内网 外网 3602',
    a: `<p>先在 App 内「服务器设置」确认地址正确（内网一般是 <code class="mono">http://192.168.1.100:3602</code>）。
      若人在外面，需要走外网访问通道；服务端本身只监听 3602 一个端口。</p>` },
  { q: '员工登录后搜不到同事，也加不了好友',
    tags: '搜不到 同事 好友 工作模式 组织 加不了 空',
    a: `<p>先确认当前是不是<b>工作模式</b>。工作模式下：搜索只返回<b>同组织</b>成员，且不允许主动加好友
      （同事关系由组织决定，不靠申请/同意）。</p>
      <p>如果这个账号还<b>不属于任何组织</b>（普通模式时期自己注册的老账号，或直接在「用户管理」里建的），
      他就会一个人都搜不到，看着像系统坏了。处理办法：</p>
      <ol>
        <li>打开「组织机构 → 员工管理」；</li>
        <li>把他的<b>账号本身当作工号</b>录入（可顺手指定部门和岗位）；</li>
        <li>系统会识别出这是已有账号 → <b>收编进组织、不改密码</b>，并立刻与同事互为好友。</li>
      </ol>
      <p>要一次处理一批人，用「员工管理 → 批量导入」把账号列粘进去即可。</p>` },
  { q: '部门删不掉，提示「该部门下有 N 名员工」，但列表里看不到人',
    tags: '部门 删不掉 删除 员工 残留 名额',
    a: `<p>这是老版本的残留数据：早期「移除员工」只清掉了组织归属，没清部门 / 岗位，
      人被移走了却仍占着部门名额。当前版本已修复（移除时会一并清空）。</p>
      <p>若已有这种残留：把那个人<b>重新录入一次再移除</b>，即可清干净；或者给他重新指定一个部门再撤回。</p>` },
  { q: '员工忘记登录密码了',
    tags: '员工 密码 忘记 重置 登录密码',
    a: `<p>管理员在「用户管理」里找到该账号 → 编辑 → <b>重置密码</b>（不需要旧密码）。
      员工也可以在客户端「个人信息 → 账号 → 修改密码」自己改，但只能改自己的。</p>` },
  { q: '普通模式切成工作模式，原来的人还能用吗',
    tags: '普通模式 工作模式 切换 老账号 还能用 好友',
    a: `<p>能登录，和已有好友也能照常聊天（好友关系保留）。但<b>没进组织的人搜不到新同事</b>，
      因为工作模式下搜索被限定为同组织。把他们收编进组织即可，见「四之二」。</p>` },
  { q: '员工端看不到「考勤打卡」入口',
    tags: '考勤打卡 入口 看不到 工作台 员工 管理员 缺入口',
    a: `<p>考勤入口由服务端按<b>业务状态</b>决定是否下发，三个条件缺一不可：</p>
      <ol>
        <li>好友模式是<b>工作模式</b>（系统设置）；</li>
        <li>已经<b>创建组织</b>（组织机构）；</li>
        <li>该账号<b>是组织员工</b>（有工号）。</li>
      </ol>
      <p><b>先确认这个账号到底是不是"员工"</b>：最容易踩的是<b>账号没录入组织</b>（看「组织机构」里数得到人吗）——
      没入编的账号工作台是空的，看起来跟"功能坏了"一模一样。用「组织机构 → 录入员工」补上即可。</p>
      <p><b>如果这个账号是管理员</b>：管理员本身不参与考勤，看不到「考勤打卡」是<b>正常</b>的 ——
      他看到的是「<b>考勤记录</b>」（今日全员出勤、缺卡、代补卡）。两种角色看到的工作台本来就不同：
      员工 = 考勤打卡 / 我的申请 / 组织通讯录；管理员 = 考勤记录 / 组织通讯录。</p>
      <p>另外确认「考勤管理 → 考勤设置」里的<b>启用考勤</b>没有被关掉。客户端下拉刷新工作台即可。</p>` },
  { q: '打卡时间不对，差了整整几小时',
    tags: '打卡 时间 不对 时区 8小时 UTC 服务器时间 差',
    a: `<p>打卡时刻按<b>服务器时钟</b>记录。先看「考勤管理」页右上角的<b>服务器时间</b>是否正确：</p>
      <ul>
        <li>时间本身就错了 → 服务器（或 NAS）系统时间没同步，开 NTP 对时；</li>
        <li>时间对、但记下来的时刻差 8 小时 → 容器时区是 UTC 而员工看的是北京时间。
          服务端已用显式时区（默认 <code class="mono">Asia/Shanghai</code>）换算，与容器 <code class="mono">TZ</code> 无关；
          若在别的时区部署，设环境变量 <code class="mono">ATT_TIMEZONE</code>（如 <code class="mono">Asia/Urumqi</code>）后重启服务。</li>
      </ul>` },
  { q: '厂里是两班倒 / 周六也上班，怎么配考勤',
    tags: '两班倒 倒班 夜班 周六 周末 上班 排班 考勤组',
    a: `<p>①「考勤管理 → 考勤设置 → 工作日」把<b>周六</b>也勾上（不勾的星期不计应出勤）；
      ②「班次与考勤组 → 新增班次」建白班与夜班（夜班下班时间填 <code class="mono">06:00</code>，系统自动识别为跨天）；
      ③「考勤组」按<b>部门</b>把生产部纳进夜班 —— 之后新员工入职会自动进组，不用每次手工加人。</p>` },
  { q: '客户端怎么更新 / 升级（关于→立即更新、升级说明页）',
    tags: '更新 升级 客户端 版本 关于 立即更新 安装包 APK EXE 升级说明页',
    a: `<p>客户端「关于」里有「立即更新」：管理员在<b>客户端配置</b>页上传了安卓 APK / Windows EXE 安装包后，
      客户端会下载并调起系统安装器完成升级（iOS 跳 App Store / TestFlight 链接）。</p>
      <p>「升级说明页网址」是<b>可选项</b>：在客户端配置页填了之后，客户端「关于」里会多一个打开该网址的入口，
      适合放更新须知 / 帮助文档；<b>留空则客户端不显示该项</b>，不影响「立即更新」下载安装包。</p>
      <p>低于服务端设置的<b>最低客户端版本</b>时，客户端会在「关于」里提示并可直接更新。</p>` },
  { q: '服务器怎么让外网手机直连（不走 frps 隧道）',
    tags: '外网 公网 直连 手机 部署 向导 本地公网 隧道 frps 地址',
    a: `<p>如果服务器自身有<b>公网 IP</b>（或已做端口映射），在<b>部署向导</b>里选「本地公网直连」最省事，
      不用走 frps 隧道。向导会让你填服务器地址候选（可分类型标 <code class="mono">lan / wan / ipv4 / ipv6 / other</code>），
      客户端启动时并发探测这些地址、自动连第一个可达的。</p>
      <p>没有公网 IP 的，选「云服务器隧道」走 frps 内网穿透。两种形态在部署向导第一步即可切换。</p>` },
];
const helpFaqFiltered = computed(() => {
  const q = (helpSearch.value || '').trim().toLowerCase();
  if (!q) return helpFaq;
  return helpFaq.filter((it) => {
    const full = (it.q + ' ' + (it.tags || '') + ' ' + it.a.replace(/<[^>]+>/g, ' ')).toLowerCase();
    if (full.includes(q)) return true;
    // 子序列匹配：中文短语关键字被隔开（如「忘记密码」拆成「忘记管理员密码」）也能命中
    const qt = (it.q + ' ' + (it.tags || '')).toLowerCase();
    let i = 0;
    for (const ch of qt) { if (ch === q[i]) i++; if (i === q.length) return true; }
    return i === q.length;
  });
});

onMounted(async () => {
  bindUnauthorized();
  // 登录前也要能显示「××小智」：bootstrap 免鉴权，只取公开字段
  try {
    pub.value = (await api.get('/client/bootstrap')).data || {};
  } catch { /* 服务器没连上就算了，退回默认名 */ }
  // 没登录才需要问"要不要走向导"；已经登录的人直接从 localStorage 进管理台。
  // 老服务端没有 /setup/status（会 404）→ 安静地退回登录页，不影响使用。
  if (!token.value) {
    try {
      const { data } = await api.get('/setup/status');
      needSetup.value = !!data?.needSetup;
      if (data?.username) setupForm.value.username = data.username;
    } catch { /* 老版本服务端，照常登录 */ }
  }
  if (token.value) loadAll();
});
</script>

<style>
body { margin: 0; font-family: -apple-system, "Microsoft YaHei", sans-serif; }
/* 建课程时挂的课件：一行一个，flex 自适应宽度，窄屏会自己折行。
   不加 flex-wrap 的话，最后一列的「删」按钮会被窗口挤到看不见。 */
.tr-ware { display: flex; flex-wrap: wrap; align-items: center; gap: 6px; margin-bottom: 6px; }
.tr-ware-no { width: 18px; text-align: center; color: #909399; font-size: 12px; flex: none; }
.login-wrap { height: 100vh; display: flex; align-items: center; justify-content: center; background: #f0f2f5; }
.login-card { width: 340px; }
/* 向导那张卡文字多（说明 + 字符集提示 + 两个输入框），340px 里要折四行，太挤 */
.login-card-wide { width: 400px; }
.aside { background: #0F2620; display: flex; flex-direction: column; }
/* min-height:0 是必须的：flex item 默认 min-height:auto，不加这行它宁可撑破也不滚动。
   没有这一层的时候，19 个平铺菜单项在 900px 高的屏幕上，最后 3 项直接人间蒸发。 */
.aside-menu { flex: 1 1 auto; min-height: 0; overflow-y: auto; overflow-x: hidden; }
.aside-menu::-webkit-scrollbar { width: 6px; }
.aside-menu::-webkit-scrollbar-track { background: transparent; }
.aside-menu::-webkit-scrollbar-thumb { background: rgba(255,255,255,.16); border-radius: 3px; }
.aside-menu::-webkit-scrollbar-thumb:hover { background: rgba(255,255,255,.3); }
.logo { flex: none; color: #fff; font-size: 20px; font-weight: 700; text-align: center; padding: 18px 0; }
/* 展开的分类标题：底色比菜单底稍亮一点，一眼能看出"这行是个可展开的分组"而不是页面。 */
.aside .el-sub-menu__title:hover { background-color: #16342C !important; }
.aside .el-menu-item:hover { background-color: #16342C !important; }
/* 二级叶项缩进 14px，跟分类标题的图标对齐出层级感。 */
.aside .el-sub-menu .el-menu-item { padding-left: 40px !important; }
/* 分类标题的文字窄一点，防止「组织与用户」在 200px 侧栏里挤到箭头。 */
.aside .el-sub-menu__title > span { font-size: 13.5px; }
.aside-foot { margin-top: auto; padding: 11px 14px; color: #8a8f99; font-size: 12px;
  display: flex; justify-content: space-between; align-items: center;
  border-top: 1px solid rgba(255,255,255,.08); }
/* 运行状态：小绿点代替干巴巴一行字（与仪表盘的绿色语义一致） */
.aside-status { display: inline-flex; align-items: center; gap: 6px; }
.aside-status .dot { width: 6px; height: 6px; border-radius: 50%; background: #10B981;
  box-shadow: 0 0 0 3px rgba(16,185,129,.15); }
/* 退出登录：默认低调灰、hover 才提示红色。
   原来常亮的 danger 红是深色侧栏上最扎眼的一处，跟"美化"的意图相反。 */
.aside-foot .aside-out { color: #8a8f99; }
.aside-foot .aside-out:hover { color: #f56c6c; background: transparent; }
.hdr { background: #fff; border-bottom: 1px solid #ebeef5; display: flex; align-items: center; justify-content: space-between; font-weight: 600; }
.stat { text-align: center; }
.stat-num { font-size: 28px; font-weight: 700; color: #10B981; }
.stat-label { color: #909399; margin-top: 6px; }

/* ====== 仪表盘：分组指标卡（v0.15.0 重做）====== */
.dash-alert { margin-bottom: 12px; }
.dash-alert-title { font-weight: 600; margin-right: 10px; }
.dash-alert-desc { font-size: 12.5px; line-height: 1.75; margin-top: 2px; }

.dash-groups { margin-top: 18px; display: flex; flex-direction: column; gap: 14px; }
.mgroup-title { display: inline-flex; align-items: center; gap: 9px; font-weight: 600; }
/* 图标用单字色块：不引图标库也有辨识度，且不会因为主题变化糊掉 */
.mgroup-ic {
  width: 24px; height: 24px; border-radius: 6px; color: #fff;
  font-size: 13px; font-weight: 700; line-height: 1;
  display: inline-flex; align-items: center; justify-content: center;
}
.tone-blue   { background: #3B82F6; }
.tone-green  { background: #10B981; }
.tone-amber  { background: #F59E0B; }
.tone-purple { background: #8B5CF6; }
.tone-cyan   { background: #06B6D4; }

.mtiles { display: flex; flex-wrap: wrap; gap: 12px; }
.mtile {
  flex: 1 1 132px; min-width: 132px;
  padding: 12px 14px;
  border: 1px solid var(--el-border-color-lighter);
  border-radius: 10px;
  background: var(--el-fill-color-blank);
  transition: border-color .18s, box-shadow .18s, transform .18s;
}
.mtile.clickable { cursor: pointer; }
.mtile.clickable:hover {
  border-color: var(--el-color-primary-light-5);
  box-shadow: 0 2px 10px rgba(16, 185, 129, .13);
  transform: translateY(-1px);
}
.mtile-k { font-size: 12px; color: var(--el-text-color-secondary); }
.mtile-v { font-size: 24px; font-weight: 700; line-height: 1.35; margin: 2px 0 1px; }
.mtile-d { font-size: 11.5px; color: var(--el-color-success); }
.mtile-d.muted { color: var(--el-text-color-placeholder); }
/* 真异常才变红（如投递失败）。日常正常的数字保持安静，否则满屏都在喊。 */
.mtile-warn { border-color: var(--el-color-danger); background: var(--el-color-danger-light-9); }
.mtile-warn .mtile-v { color: var(--el-color-danger); }
.mtile-dim .mtile-v { color: var(--el-text-color-secondary); }

.dash-doc { margin-top: 18px; }
/* ---- 系统说明：分区卡片 + 双栏 ----
   原来是 5 行 `· xxx` 的平铺 bullet，信息混在一起、没有层次，读起来像附录。
   现在按「定位 → 能力（客户端 / 管理台）→ 从哪里开始 / 注意点」分区，
   图标块直接复用仪表盘的 .mgroup-ic + .tone-*，与上方分组卡是同一套视觉语言。 */
.doc-body { display: flex; flex-direction: column; gap: 14px; }
.doc-lead {
  padding: 11px 14px; border-radius: 8px; font-size: 13px; line-height: 1.85;
  background: #F5FBF8; border: 1px solid #D6EEE4; border-left: 3px solid #10B981;
  color: #3F5148;
}
.doc-lead b { color: #0F2620; }
.doc-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 14px; align-items: start; }
@media (max-width: 900px) { .doc-grid { grid-template-columns: 1fr; } }
.doc-card {
  border: 1px solid var(--el-border-color); border-radius: 8px;
  padding: 12px 14px; background: var(--el-fill-color-blank);
}
.doc-soft { background: #FAFBFC; }
.doc-card-h {
  display: flex; align-items: center; gap: 8px;
  font-size: 13.5px; font-weight: 600; color: #0F2620; margin-bottom: 9px;
}
/* 图标块在 flex 行里不能被压缩成椭圆 */
.doc-card-h .mgroup-ic, .doc-lead .mgroup-ic { flex: none; }
.doc-tag {
  font-weight: 400; font-size: 11px; color: #8a8f99;
  border: 1px solid var(--el-border-color); border-radius: 10px; padding: 1px 8px;
}
/* 条目用自绘小圆点：默认 list-style 的圆点在这些紧凑卡片里偏大、且与行高不齐 */
.doc-card ul { margin: 0; padding: 0; list-style: none; }
.doc-card li {
  position: relative; padding-left: 12px; margin: 6px 0;
  font-size: 12.5px; line-height: 1.8; color: #4B5563;
}
.doc-card li::before {
  content: ''; position: absolute; left: 1px; top: 9px;
  width: 4px; height: 4px; border-radius: 50%; background: #C7D6D0;
}
.doc-card li b { color: #253830; }
.page-bar { display: flex; align-items: center; gap: 12px; margin-bottom: 12px; }
.hint { color: #909399; font-size: 12px; }

/* ====== 列表分页 / 筛选（v0.14.0 全站统一） ====== */
.page-bar.wrap { flex-wrap: wrap; row-gap: 10px; }
.pager-bar { display: flex; justify-content: flex-end; margin-top: 12px; }
/* 空状态：筛选后没数据时给一条"怎么放宽条件"的出路，避免用户以为数据丢了 */
.empty-tip { padding: 18px; color: var(--el-text-color-secondary); }
.empty-tip .el-button { margin-left: 6px; }

/* 文件页顶部统计卡 */
.stat-row { display: flex; gap: 12px; margin-bottom: 14px; flex-wrap: wrap; }
.stat-box {
  flex: 1 1 150px; padding: 12px 14px; border: 1px solid var(--el-border-color);
  border-radius: 8px; background: var(--el-fill-color-blank);
}
.stat-k { font-size: 12px; color: var(--el-text-color-secondary); margin-bottom: 6px; }
.stat-v { font-size: 20px; font-weight: 600; }
.stat-warn { border-color: var(--el-color-warning); }
.stat-warn .stat-v { color: var(--el-color-warning); }

/* 存储占用分析 */
.file-analysis { margin-bottom: 8px; }
.analysis-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; }
.analysis-h { font-size: 13px; font-weight: 600; margin: 6px 0 8px; color: var(--el-text-color-regular); }
@media (max-width: 900px) { .analysis-grid { grid-template-columns: 1fr; } }

/* 批量清理确认弹窗 */
.purge-box { border: 1px solid var(--el-border-color); border-radius: 8px; padding: 10px 14px; }
.purge-row { display: flex; gap: 12px; padding: 4px 0; font-size: 13px; align-items: baseline; }
.purge-row > span { color: var(--el-text-color-secondary); width: 76px; flex: none; }
.purge-num { color: var(--el-color-danger); font-size: 16px; }
/* 考勤：迟到/早退/缺卡的数字用红字标出来，一眼能扫到异常 */
.att-bad { color: #f56c6c; font-weight: 600; }

/* ====== 动态模块编辑器（v0.9.0 第二期） ====== */
.mm-item { padding: 9px 10px; border: 1px solid var(--el-border-color); border-radius: 6px; margin-bottom: 8px; cursor: pointer; }
.mm-item:hover { border-color: var(--el-color-primary); }
.mm-item-on { border-color: var(--el-color-primary); background: var(--el-color-primary-light-9); }
.mm-comp { border: 1px solid var(--el-border-color); border-left: 3px solid var(--el-color-primary); border-radius: 6px; padding: 10px; margin-bottom: 10px; background: #fafcff; }
.mm-comp-hdr { display: flex; align-items: center; justify-content: space-between; margin-bottom: 8px; }
.mm-act { display: flex; gap: 6px; flex-wrap: wrap; }
.mm-field { border: 1px dashed var(--el-border-color); border-radius: 6px; padding: 8px; margin-bottom: 8px; }
.mm-json { max-height: 520px; overflow: auto; background: #f5f7fa; padding: 12px; border-radius: 6px; font-size: 12px; line-height: 1.5; }
.mono { font-family: Consolas, Monaco, "Courier New", monospace; font-size: 12px; background: #f5f7fa; padding: 1px 5px; border-radius: 4px; word-break: break-all; }
/* 向导里的命令块：整块可选中复制，长命令自动换行不撑破卡片 */
.cmd-box { display: block; padding: 10px 12px; margin: 8px 0; border-radius: 6px; background: #f5f7fa; border: 1px solid #e4e7ed; white-space: pre-wrap; word-break: break-all; line-height: 1.7; user-select: all; }
.el-menu { border-right: none !important; }

/* ====== 上手向导 ====== */
.setup { margin-bottom: 16px; }
.setup-bar { margin-bottom: 14px; }
.setup-item {
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 10px 12px;
  border-radius: 8px;
  border: 1px solid var(--el-border-color-lighter);
  margin-bottom: 8px;
}
.setup-item.done {
  background: var(--el-color-success-light-9);
  border-color: var(--el-color-success-light-5);
}
.setup-mark {
  flex: 0 0 24px;
  height: 24px;
  line-height: 24px;
  text-align: center;
  border-radius: 50%;
  font-size: 13px;
  font-weight: 700;
  background: var(--el-fill-color);
  color: var(--el-text-color-secondary);
}
.setup-item.done .setup-mark { background: var(--el-color-success); color: #fff; }
.setup-body { flex: 1; min-width: 0; }
.setup-title { font-size: 14px; font-weight: 600; }
.setup-item.done .setup-title { color: var(--el-color-success-dark-2); }
.setup-desc {
  font-size: 12.5px;
  color: var(--el-text-color-secondary);
  line-height: 1.6;
  margin-top: 2px;
}
.setup-allgood {
  margin-top: 6px;
  font-size: 13px;
  color: var(--el-color-success-dark-2);
}

/* ---- 仪表盘「系统说明」卡头（标题 + 右侧入口按钮）---- */
.card-hdr { display: flex; align-items: center; justify-content: space-between; }

/* ---- 系统帮助页 ---- */
.help { max-width: 980px; }
.faq-q { font-weight: 600; color: #1f2d3d; }
.faq-a { font-size: 13.5px; line-height: 1.75; color: #4b5563; }
.help-sec { margin-bottom: 26px; }
.help-sec:last-child { margin-bottom: 4px; }
.help-sec h3 {
  font-size: 15px; font-weight: 700; color: #0F2620;
  margin: 0 0 10px; padding-left: 9px;
  border-left: 3px solid #10B981; line-height: 1.2;
}
.help-sec p { margin: 6px 0; font-size: 13.5px; line-height: 1.75; color: #4b5563; }
.help-sec ul, .help-sec ol { margin: 6px 0; padding-left: 22px; }
.help-sec li { font-size: 13.5px; line-height: 1.85; color: #4b5563; }
.help-table { width: 100%; border-collapse: collapse; margin: 8px 0 4px; }
.help-table th, .help-table td {
  border: 1px solid #ebeef5; padding: 8px 10px;
  font-size: 13px; line-height: 1.7; text-align: left; vertical-align: top; color: #4b5563;
}
.help-table th { background: #f7faf9; color: #0F2620; font-weight: 600; white-space: nowrap; }
.help-table td code.mono { white-space: nowrap; }
.help-tip {
  background: #f0f9f4; border-left: 3px solid #10B981;
  padding: 8px 12px; border-radius: 0 6px 6px 0;
  font-size: 13px !important; color: #2f6b55 !important;
}
.help-sec .el-collapse-item__content { padding-bottom: 12px; }
.help-sec .el-steps { margin: 10px 0 16px; }
</style>