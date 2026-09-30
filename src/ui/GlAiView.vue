<template>
    <div class="gla">
        <!-- ===================== 顶部品牌区 ===================== -->
        <header class="gla-hero">
            <div class="gla-hero-main">
                <div class="gla-orb" :class="{ 'is-busy': busy }">
                    <span class="gla-orb-core"></span>
                    <span class="gla-orb-ring"></span>
                </div>
                <div class="gla-hero-text">
                    <h1>{{ t('title') }}</h1>
                    <p>{{ subtitle }}</p>
                </div>
            </div>
            <div class="gla-hero-side">
                <span class="gla-chip" :class="statusClass">
                    <i class="gla-dot"></i>{{ statusText }}
                </span>
                <button class="gla-ghost" type="button" :title="t('settings')" @click="openSettings">
                    <svg viewBox="0 0 24 24" width="15" height="15" aria-hidden="true">
                        <path d="M12 15.5A3.5 3.5 0 1 0 12 8.5a3.5 3.5 0 0 0 0 7z" fill="none"
                              stroke="currentColor" stroke-width="1.8" />
                        <path d="M19.4 15a1.7 1.7 0 0 0 .3 1.9l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-2.9 1.2 2 2 0 1 1-4 0 1.7 1.7 0 0 0-2.9-1.2l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1A1.7 1.7 0 0 0 3 15a2 2 0 1 1 0-4 1.7 1.7 0 0 0 1.2-2.9l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1A1.7 1.7 0 0 0 10 4.1a2 2 0 1 1 4 0 1.7 1.7 0 0 0 2.9 1.2l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1A1.7 1.7 0 0 0 21 11a2 2 0 1 1 0 4z"
                              fill="none" stroke="currentColor" stroke-width="1.5" />
                    </svg>
                </button>
                <button class="gla-ghost" type="button" @click="reset" :title="t('new_chat')">
                    <svg viewBox="0 0 24 24" width="15" height="15" aria-hidden="true">
                        <path d="M12 5v14M5 12h14" fill="none" stroke="currentColor" stroke-width="2"
                              stroke-linecap="round" />
                    </svg>
                </button>
            </div>
        </header>

        <!-- ===================== 设置面板 ===================== -->
        <transition name="gla-slide">
            <section v-if="showSettings" class="gla-panel">
                <div class="gla-panel-head">
                    <strong>{{ t('settings') }}</strong>
                    <button class="gla-ghost" type="button" @click="showSettings = false">
                        <svg viewBox="0 0 24 24" width="14" height="14">
                            <path d="M18 6L6 18M6 6l12 12" fill="none" stroke="currentColor"
                                  stroke-width="2" stroke-linecap="round" />
                        </svg>
                    </button>
                </div>

                <div class="gla-field">
                    <label>API 地址</label>
                    <input v-model.trim="form.base_url" type="text" spellcheck="false"
                           placeholder="https://api.deepseek.com/v1" />
                </div>
                <div class="gla-field">
                    <label>模型</label>
                    <input v-model.trim="form.model" type="text" spellcheck="false"
                           placeholder="deepseek-chat" />
                </div>
                <div class="gla-field">
                    <label>API Key</label>
                    <input v-model.trim="form.api_key" type="password" spellcheck="false"
                           :placeholder="config.provider.has_api_key ? config.provider.api_key_hint : 'sk-...'" />
                </div>
                <div class="gla-field-row">
                    <div class="gla-field">
                        <label>协议</label>
                        <select v-model="form.protocol">
                            <option value="openai">OpenAI 兼容</option>
                            <option value="anthropic">Anthropic</option>
                            <option value="gemini">Gemini</option>
                        </select>
                    </div>
                    <div class="gla-field">
                        <label>写操作权限</label>
                        <select v-model="form.permission">
                            <option value="readonly">只读</option>
                            <option value="ask">询问（推荐）</option>
                            <option value="auto">自动</option>
                        </select>
                    </div>
                </div>

                <div class="gla-panel-actions">
                    <button class="gla-btn" type="button" :disabled="testing || !configLoaded" @click="testConnection">
                        {{ testing ? '测试中…' : '测试连接' }}
                    </button>
                    <button class="gla-btn is-primary" type="button" :disabled="saving || !configLoaded" @click="saveSettings">
                        {{ saving ? '保存中…' : '保存' }}
                    </button>
                </div>
                <div v-if="testResult" class="gla-note" :class="testResult.ok ? 'is-ok' : 'is-bad'">
                    {{ testResult.text }}
                </div>

                <details class="gla-adv">
                    <summary>{{ t('advanced') }}<span>{{ t('advanced_hint') }}</span></summary>
                    <label class="gla-check">
                        <input v-model="form.verify_tls" type="checkbox" />
                        <span class="gla-check-body">
                            <strong>{{ t('verify_tls') }}</strong>
                            <em>{{ t('verify_tls_hint') }}</em>
                        </span>
                    </label>
                    <label class="gla-check">
                        <input v-model="form.stream" type="checkbox" />
                        <span class="gla-check-body">
                            <strong>{{ t('stream') }}</strong>
                            <em>{{ t('stream_hint') }}</em>
                        </span>
                    </label>
                </details>
            </section>
        </transition>

        <!-- ===================== 对话流 ===================== -->
        <div class="gla-stream" ref="stream">
            <!-- 空状态 -->
            <section v-if="!messages.length" class="gla-empty">
                <div class="gla-empty-title">{{ t('empty_title') }}</div>
                <div class="gla-empty-desc">{{ t('empty_desc') }}</div>
                <div class="gla-suggest">
                    <button v-for="s in suggestions" :key="s" type="button" class="gla-suggest-item"
                            @click="send(s)">
                        {{ s }}
                    </button>
                </div>
            </section>

            <!-- 消息 -->
            <div v-for="(m, i) in messages" :key="i" class="gla-row" :class="'is-' + m.role">
                <div v-if="m.role === 'assistant'" class="gla-avatar">
                    <span class="gla-avatar-core"></span>
                </div>

                <div class="gla-body">
                    <!-- 工具步骤时间线 -->
                    <div v-if="m.steps && m.steps.length" class="gla-steps">
                        <div v-for="(s, si) in m.steps" :key="si" class="gla-step" :class="'is-' + s.state">
                            <span class="gla-step-rail"></span>
                            <span class="gla-step-icon">
                                <svg v-if="s.state === 'done'" viewBox="0 0 24 24" width="12" height="12">
                                    <path d="M20 6L9 17l-5-5" fill="none" stroke="currentColor"
                                          stroke-width="3" stroke-linecap="round" stroke-linejoin="round" />
                                </svg>
                                <svg v-else-if="s.state === 'error'" viewBox="0 0 24 24" width="12" height="12">
                                    <path d="M18 6L6 18M6 6l12 12" fill="none" stroke="currentColor"
                                          stroke-width="3" stroke-linecap="round" />
                                </svg>
                                <span v-else class="gla-step-spin"></span>
                            </span>
                            <span class="gla-step-text">{{ s.label }}</span>
                            <span v-if="s.risk" class="gla-step-risk" :class="'risk-' + s.risk">
                                {{ t('risk_' + s.risk) }}
                            </span>
                        </div>
                    </div>

                    <!-- 变更确认卡 -->
                    <div v-if="m.confirm" class="gla-confirm">
                        <div class="gla-confirm-head">
                            <svg viewBox="0 0 24 24" width="15" height="15">
                                <path d="M12 9v4m0 4h.01M10.3 3.9L1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z"
                                      fill="none" stroke="currentColor" stroke-width="1.8"
                                      stroke-linecap="round" stroke-linejoin="round" />
                            </svg>
                            <strong>{{ m.confirm.tool }}</strong>
                            <span class="gla-step-risk" :class="'risk-' + m.confirm.risk">
                                {{ t('risk_' + m.confirm.risk) }}
                            </span>
                        </div>
                        <p class="gla-confirm-desc">{{ m.confirm.preview }}</p>
                        <ul class="gla-confirm-args">
                            <li v-for="(v, k) in m.confirm.args" :key="k">
                                <span>{{ k }}</span><code>{{ v }}</code>
                            </li>
                        </ul>
                        <div class="gla-confirm-actions">
                            <button class="gla-btn is-primary" type="button" @click="decide(m.confirm, true)">
                                {{ t('confirm_apply') }}
                            </button>
                            <button class="gla-btn" type="button" @click="decide(m.confirm, false)">
                                {{ t('confirm_cancel') }}
                            </button>
                            <span v-if="m.confirm.left > 0" class="gla-confirm-timer">{{ m.confirm.left }}s</span>
                        </div>
                    </div>

                    <!-- 正文 -->
                    <div v-if="m.content || m.streaming" class="gla-bubble">
                        <span class="gla-text">{{ m.content }}</span>
                        <span v-if="m.streaming" class="gla-caret"></span>
                    </div>

                    <!-- 思考指示 -->
                    <div v-if="m.thinking" class="gla-thinking">
                        <span></span><span></span><span></span>
                        <em>{{ t('thinking') }}</em>
                    </div>
                </div>
            </div>
        </div>

        <!-- ===================== 输入区 ===================== -->
        <footer class="gla-composer">
            <div class="gla-box" :class="{ 'is-focus': focused }">
                <textarea ref="input" v-model="draft" rows="1" :placeholder="t('input_placeholder')"
                          @focus="focused = true" @blur="focused = false" @keydown.enter.exact.prevent="send()"
                          @input="autoGrow"></textarea>
                <button class="gla-send" type="button" :class="{ 'is-stop': busy }" :disabled="!busy && !draft.trim()"
                        @click="busy ? stop() : send()" :title="busy ? t('stop') : t('send')">
                    <svg v-if="!busy" viewBox="0 0 24 24" width="17" height="17">
                        <path d="M4 12l16-8-6 8 6 8-16-8z" fill="currentColor" />
                    </svg>
                    <svg v-else viewBox="0 0 24 24" width="15" height="15">
                        <rect x="6" y="6" width="12" height="12" rx="2.5" fill="currentColor" />
                    </svg>
                </button>
            </div>
            <div class="gla-foot">
                <span class="gla-foot-pill">{{ footNote }}</span>
            </div>
        </footer>
    </div>
</template>

<script>
export default {
    name: 'GlAiView',
    data() {
        return {
            draft: '',
            focused: false,
            busy: false,
            messages: [],
            reply: null,

            i18n: null,
            config: { provider: {}, agent: {}, configured: false },
            form: {
                protocol: 'openai',
                base_url: '',
                model: '',
                api_key: '',
                permission: 'ask',
                verify_tls: true,
                stream: false,
            },
            showSettings: false,
            testing: false,
            saving: false,
            testResult: null,
            // The form must not be used before the stored config has arrived:
            // its defaults (verify_tls: true) would silently overwrite what the
            // router has saved (verify_tls: false), which is exactly how a
            // working setup turns into "self signed certificate in certificate
            // chain".
            configLoaded: false,

            turnId: null,
            sessionId: null,
            offset: 0,
            pollTimer: null,
            countdownTimer: null,
            activeConfirm: null,

            suggestions: [
                '把 5G 密码改成 abc12345',
                '看看谁在蹭我的网',
                '2.4G 信道换到最不拥挤的',
                '给访客网络限速 5Mbps',
            ],
        };
    },
    computed: {
        subtitle() {
            if (!this.config.configured) return '先在设置里填入你的模型 API';
            return this.config.provider.model || this.t('subtitle');
        },
        statusText() {
            if (this.busy) return this.t('thinking');
            return this.config.configured ? 'GL-AI' : '未配置';
        },
        statusClass() {
            if (this.busy) return 'is-busy';
            return this.config.configured ? 'is-idle' : 'is-warn';
        },
        footNote() {
            if (!this.config.configured) return '尚未配置模型 API · 点右上角齿轮';
            const mode = this.config.agent && this.config.agent.permission;
            if (mode === 'readonly') return '当前为「只读」模式 · 不会修改任何设置';
            if (mode === 'auto') return '当前为「自动」模式 · 危险操作仍会确认';
            return '当前为「询问模式」· 写操作会先给你确认';
        },
    },
    created() {
        this.loadLocale();
        this.loadConfig();
    },
    methods: {
        /**
         * The GL SDK4 front end is a runtime-only Vue build whose $t
         * implementation is not a documented contract. Rather than depend on
         * it, load our own namespace from /www/i18n and fall back to it.
         */
        loadLocale() {
            const lang = (this.$lang || navigator.language || 'en').toLowerCase();
            const candidates = [lang, lang.replace('_', '-'), lang.split('-')[0], 'en'];
            const seen = new Set();
            const urls = [];
            candidates.forEach((l) => {
                if (!l || seen.has(l)) return;
                seen.add(l);
                urls.push('/i18n/gl-sdk4-ui-gl-ai.' + l + '.json');
            });
            const tryNext = (i) => {
                if (i >= urls.length) return;
                fetch(urls[i], { credentials: 'same-origin' })
                    .then((r) => (r.ok ? r.json() : Promise.reject(r.status)))
                    .then((data) => {
                        this.i18n = data;
                    })
                    .catch(() => tryNext(i + 1));
            };
            tryNext(0);
        },
        t(key) {
            const full = 'gl_ai.' + key;
            const fromGlobal = this.$t ? this.$t(full) : full;
            if (fromGlobal && fromGlobal !== full) return fromGlobal;
            const ns = this.i18n && this.i18n.gl_ai;
            if (ns && ns[key]) return ns[key];
            return key;
        },

        // ------------------------------------------------------------------
        // backend
        // ------------------------------------------------------------------
        /**
         * Every call goes through the single stable method `rpc`.
         *
         * The SDK caches an RPC object's method table for the whole life of the
         * nginx worker, so naming methods individually would mean an nginx
         * restart on every upgrade. `rpc` dispatches to freshly loaded code.
         */
        rpc(method, params) {
            return this.$request('call', ['sid', 'gl_ai', 'rpc', { m: method, p: params || {} }])
                .then((res) => {
                    const out = res && res.result !== undefined ? res.result : res;
                    if (out && out.error) {
                        throw new Error(out.error + (out.detail ? ': ' + out.detail : ''));
                    }
                    return out || {};
                });
        },

        loadConfig() {
            this.rpc('get_config')
                .then((cfg) => {
                    this.config = cfg;
                    const p = cfg.provider || {};
                    this.form.protocol = p.protocol || 'openai';
                    this.form.base_url = p.base_url || '';
                    this.form.model = p.model || '';
                    this.form.permission = (cfg.agent && cfg.agent.permission) || 'ask';
                    this.form.verify_tls = p.verify_tls !== false;
                    this.form.stream = p.stream === true;
                    this.configLoaded = true;
                })
                .catch(() => { /* footer tells the user what to do */ });
        },
        openSettings() {
            this.testResult = null;
            this.showSettings = true;
        },
        saveSettings() {
            if (!this.configLoaded) {
                this.testResult = { ok: false, text: '正在读取已保存的配置，请稍候…' };
                return;
            }
            this.saving = true;
            this.testResult = null;
            const patch = {
                provider: {
                    protocol: this.form.protocol,
                    base_url: this.form.base_url,
                    model: this.form.model,
                    verify_tls: this.form.verify_tls,
                    stream: this.form.stream,
                },
                agent: { permission: this.form.permission },
            };
            // an empty key means "keep the stored one", so the masked input can
            // round-trip without the secret ever being echoed back
            if (this.form.api_key) patch.provider.api_key = this.form.api_key;

            this.rpc('set_config', patch)
                .then((cfg) => {
                    this.config = cfg;
                    this.form.api_key = '';
                    this.showSettings = false;
                })
                .catch((e) => {
                    this.testResult = { ok: false, text: String(e.message || e) };
                })
                .then(() => { this.saving = false; });
        },
        testConnection() {
            if (!this.configLoaded) {
                this.testResult = { ok: false, text: '正在读取已保存的配置，请稍候…' };
                return;
            }
            this.testing = true;
            this.testResult = null;
            const patch = {
                protocol: this.form.protocol,
                base_url: this.form.base_url,
                model: this.form.model,
                verify_tls: this.form.verify_tls,
            };
            if (this.form.api_key) patch.api_key = this.form.api_key;

            this.rpc('test_connection', { provider: patch })
                .then((res) => {
                    if (res.ok) {
                        this.testResult = {
                            ok: true,
                            text: '连接成功 · ' + res.latency_ms + ' ms · 模型回复「'
                                + String(res.reply || '').trim() + '」',
                        };
                    } else {
                        this.testResult = { ok: false, text: res.error || '连接失败' };
                    }
                })
                .catch((e) => {
                    this.testResult = { ok: false, text: String(e.message || e) };
                })
                .then(() => { this.testing = false; });
        },

        // ------------------------------------------------------------------
        // conversation
        // ------------------------------------------------------------------
        autoGrow() {
            const el = this.$refs.input;
            if (!el) return;
            el.style.height = 'auto';
            el.style.height = Math.min(el.scrollHeight, 132) + 'px';
        },
        scrollToEnd() {
            this.$nextTick(() => {
                const el = this.$refs.stream;
                if (!el) return;
                const near = el.scrollHeight - el.scrollTop - el.clientHeight < 140;
                if (near || this.busy) el.scrollTop = el.scrollHeight;
            });
        },
        reset() {
            this.stop();
            this.messages = [];
            this.reply = null;
            this.draft = '';
            this.autoGrow();
        },
        stop() {
            this.stopPolling();
            this.stopCountdown();
            this.busy = false;
            this.turnId = null;
            this.activeConfirm = null;
            this.messages.forEach((m) => {
                m.streaming = false;
                m.thinking = false;
                m.confirm = null;
            });
        },
        send(preset) {
            const text = (preset || this.draft).trim();
            if (!text || this.busy) return;

            if (!this.config.configured) {
                this.showSettings = true;
                this.testResult = { ok: false, text: '请先填写 API 地址、模型与 API Key' };
                return;
            }

            this.draft = '';
            this.autoGrow();
            this.messages.push({ role: 'user', content: text });

            this.reply = {
                role: 'assistant',
                content: '',
                steps: [],
                thinking: true,
                streaming: false,
                confirm: null,
            };
            this.messages.push(this.reply);
            this.busy = true;
            this.scrollToEnd();

            this.rpc('chat', { text })
                .then((res) => {
                    this.turnId = res.turn_id;
                    this.sessionId = res.session_id;
                    this.offset = 0;
                    this.startPolling();
                })
                .catch((e) => {
                    if (this.reply) {
                        this.reply.thinking = false;
                        this.reply.content = '启动失败：' + String(e.message || e);
                    }
                    this.busy = false;
                });
        },

        /**
         * Follow the turn's event log.
         *
         * A turn runs in a background timer and appends newline-delimited JSON;
         * we poll with a byte offset so nothing is missed and nothing is
         * re-rendered. Polling only while a turn is live, so an idle page makes
         * no requests at all.
         */
        startPolling() {
            this.stopPolling();
            const tick = () => {
                if (!this.turnId) return;
                this.rpc('poll', { turn_id: this.turnId, offset: this.offset })
                    .then((res) => {
                        this.offset = res.offset;
                        (res.events || []).forEach((ev) => this.applyEvent(ev));
                        if (res.finished) {
                            this.stopPolling();
                            this.finishTurn();
                            return;
                        }
                        // A confirmation is parked server-side or another poll
                        // owns the turn: slow down rather than pile on requests.
                        const delay = (res.awaiting || res.busy || this.activeConfirm) ? 1500 : 220;
                        this.pollTimer = setTimeout(tick, delay);
                    })
                    .catch(() => {
                        // a transient failure should not end the turn
                        this.pollTimer = setTimeout(tick, 1200);
                    });
            };
            this.pollTimer = setTimeout(tick, 120);
        },
        stopPolling() {
            if (this.pollTimer) {
                clearTimeout(this.pollTimer);
                this.pollTimer = null;
            }
        },
        finishTurn() {
            this.busy = false;
            if (this.reply) {
                this.reply.thinking = false;
                this.reply.streaming = false;
                (this.reply.steps || []).forEach((s) => {
                    if (s.state === 'running') s.state = 'done';
                });
            }
            this.stopCountdown();
            this.activeConfirm = null;
            this.scrollToEnd();
        },

        /** Map one backend event onto UI state. */
        applyEvent(ev) {
            const r = this.reply;
            if (!r) return;

            switch (ev.type) {
                case 'text':
                    r.thinking = false;
                    r.streaming = true;
                    r.content += ev.text;
                    break;

                case 'step':
                    r.thinking = true;
                    break;

                case 'tool_start':
                case 'tool_call':
                    r.thinking = false;
                    r.steps.push({
                        label: this.prettyTool(ev.name),
                        state: 'running',
                        risk: ev.risk,
                    });
                    break;

                case 'tool_result': {
                    const step = r.steps[r.steps.length - 1];
                    if (step) {
                        step.state = ev.state === 'done' ? 'done'
                            : ev.state === 'denied' ? 'denied' : 'error';
                        if (ev.summary) step.summary = ev.summary;
                    }
                    break;
                }

                case 'confirm': {
                    // One card per tool invocation, whatever the backend does.
                    //
                    // Overlapping polls can each drive a step, so a single
                    // request can legitimately produce two confirm events for the
                    // same tool call. Keying on the tool plus its arguments makes
                    // the renderer idempotent: a repeat updates the card already
                    // on screen instead of stacking another one, and the
                    // underlying approval ids are treated as the same decision.
                    const key = JSON.stringify([ev.tool, ev.args || {}]);
                    let host = r.confirm;

                    if (!host || host.key !== key) {
                        // if an older card for another call is still open, retire it
                        const last = r.steps[r.steps.length - 1];
                        const label = this.prettyTool(ev.tool);
                        if (!last || last.label !== label || last.state !== 'running') {
                            r.steps.push({ label: label, state: 'running', risk: ev.risk });
                        }
                        host = {
                            key: key,
                            ids: [],
                            tool: label,
                            risk: ev.risk,
                            preview: ev.preview,
                            args: ev.args || {},
                            left: ev.timeout || 45,
                        };
                        r.confirm = host;
                        this.startCountdown();
                    } else {
                        // same change, another poll: refresh only the countdown
                        host.left = Math.max(host.left, 1);
                        host.preview = ev.preview || host.preview;
                    }
                    if (host.ids.indexOf(ev.id) === -1) host.ids.push(ev.id);
                    this.activeConfirm = host;
                    break;
                }

                case 'confirm_timeout':
                    if (r.confirm) r.confirm = null;
                    this.activeConfirm = null;
                    this.stopCountdown();
                    break;

                case 'usage':
                    if (ev.usage && ev.usage.total_tokens) r.tokens = ev.usage.total_tokens;
                    break;

                case 'error':
                    r.thinking = false;
                    r.streaming = false;
                    r.content += (r.content ? '\n\n' : '') + this.errorText(ev);
                    this.stopCountdown();
                    break;

                case 'saved':
                    if (ev.session_id) this.sessionId = ev.session_id;
                    break;
            }
            this.scrollToEnd();
        },

        /** Internal tool ids are meaningless to a router owner. */
        prettyTool(name) {
            const map = {
                router_overview: '读取路由器概况',
                wifi_get_config: '读取 WiFi 配置',
                wifi_scan: '扫描周边网络',
                wifi_channel_info: '检查信道占用',
                list_clients: '读取在线设备',
                get_logs: '读取系统日志',
                get_wan_access: '检查远程访问设置',
                wifi_set_ssid_or_password: '修改 WiFi 名称或密码',
                set_client_blocked: '拉黑或放行设备',
                set_client_limit: '设置设备限速',
                rename_client: '重命名设备',
                add_port_forward: '添加端口转发',
                set_timezone: '修改时区',
                set_wan_access: '修改远程访问设置',
                reboot_router: '重启路由器',
            };
            return map[name] || name;
        },
        errorText(ev) {
            if (ev.message === 'not_configured') {
                return '还没有配置模型 API，点右上角齿轮填一下。';
            }
            return '出错了：' + (ev.detail || ev.message || '未知错误');
        },

        startCountdown() {
            this.stopCountdown();
            this.countdownTimer = setInterval(() => {
                const c = this.activeConfirm;
                if (!c) return this.stopCountdown();
                c.left = Math.max(0, c.left - 1);
                if (c.left === 0) {
                    this.messages.forEach((m) => {
                        if (m.confirm && m.confirm.key === c.key) m.confirm = null;
                    });
                    this.activeConfirm = null;
                    this.stopCountdown();
                }
            }, 1000);
        },
        stopCountdown() {
            if (this.countdownTimer) {
                clearInterval(this.countdownTimer);
                this.countdownTimer = null;
            }
        },

        decide(confirm, allow) {
            this.stopCountdown();
            // A card may cover more than one server-side approval id (see the
            // confirm handler); answer them all so none is left dangling.
            const ids = (confirm.ids && confirm.ids.length) ? confirm.ids.slice() : [confirm.id];
            this.messages.forEach((m) => {
                if (m.confirm === confirm || (m.confirm && m.confirm.key === confirm.key)) {
                    m.confirm = null;
                }
            });
            this.activeConfirm = null;
            ids.forEach((id) => {
                if (!id) return;
                this.rpc('approve', { id: id, allow: allow })
                    .catch(() => { /* the turn times out on its own */ });
            });
        },
    },
    beforeDestroy() {
        this.stop();
    },
};
</script>
<style>
/* ============================================================
   GL-AI助手 — visual layer.
   Colours come exclusively from the GL SDK4 theme tokens so the
   page follows the light / dark / classic themes automatically.
   ============================================================ */
.gla {
    display: flex;
    flex-direction: column;
    height: calc(100vh - 130px);
    min-height: 460px;
    padding: 0 4px;
    color: var(--text-regular);
    font-size: 14px;
    box-sizing: border-box;
}
.gla *,
.gla *::before,
.gla *::after {
    box-sizing: border-box;
}

/* ---------------- hero ---------------- */
.gla-hero {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 16px;
    padding: 6px 4px 16px;
}
.gla-hero-main {
    display: flex;
    align-items: center;
    gap: 14px;
    min-width: 0;
}
.gla-hero-text h1 {
    margin: 0;
    font-size: 19px;
    line-height: 26px;
    font-weight: 600;
    letter-spacing: 0.2px;
    color: var(--text-title);
}
.gla-hero-text p {
    margin: 2px 0 0;
    font-size: 12px;
    line-height: 18px;
    color: var(--text-weak);
}
.gla-hero-side {
    display: flex;
    align-items: center;
    gap: 8px;
    flex: 0 0 auto;
}

/* orb */
.gla-orb {
    position: relative;
    width: 40px;
    height: 40px;
    flex: 0 0 auto;
    display: grid;
    place-items: center;
}
.gla-orb-core {
    width: 22px;
    height: 22px;
    border-radius: 50%;
    background: conic-gradient(from 0deg, var(--primary), var(--secondary), var(--primary));
    box-shadow: 0 0 0 4px var(--primary-background);
}
.gla-orb-ring {
    position: absolute;
    inset: 0;
    border-radius: 50%;
    border: 1px solid var(--primary);
    opacity: 0.28;
}
.gla-orb.is-busy .gla-orb-ring {
    animation: gla-pulse 1.6s ease-out infinite;
}
.gla-orb.is-busy .gla-orb-core {
    animation: gla-spin 2.4s linear infinite;
}

/* status chip */
.gla-chip {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    height: 26px;
    padding: 0 11px;
    border-radius: 999px;
    font-size: 12px;
    background: var(--background-badge);
    color: var(--text-badge);
    white-space: nowrap;
}
.gla-chip .gla-dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: currentColor;
}
.gla-chip.is-idle {
    background: var(--success-background);
    color: var(--success);
}
.gla-chip.is-busy {
    background: var(--primary-background);
    color: var(--primary);
}
.gla-chip.is-busy .gla-dot {
    animation: gla-blink 1.1s ease-in-out infinite;
}

/* ghost icon button */
.gla-ghost {
    width: 30px;
    height: 30px;
    display: grid;
    place-items: center;
    border-radius: 8px;
    border: 1px solid var(--divider);
    background: var(--background-card);
    color: var(--icon);
    cursor: pointer;
    transition: color 0.16s, border-color 0.16s, transform 0.16s;
}
.gla-ghost:hover {
    color: var(--primary);
    border-color: var(--primary);
}
.gla-ghost:active {
    transform: scale(0.94);
}

/* ---------------- stream ---------------- */
.gla-stream {
    flex: 1 1 auto;
    min-height: 0;
    overflow-y: auto;
    overflow-x: hidden;
    padding: 4px 6px 8px;
    scroll-behavior: smooth;
    scrollbar-width: thin;
}
.gla-stream::-webkit-scrollbar {
    width: 6px;
}
.gla-stream::-webkit-scrollbar-thumb {
    background: var(--scrollbar);
    border-radius: 999px;
}

/* empty state */
.gla-empty {
    max-width: 560px;
    margin: 5vh auto 0;
    text-align: center;
    animation: gla-rise 0.36s cubic-bezier(0.22, 1, 0.36, 1) both;
}
.gla-empty-title {
    font-size: 17px;
    font-weight: 600;
    color: var(--text-title);
}
.gla-empty-desc {
    margin-top: 6px;
    font-size: 12.5px;
    line-height: 20px;
    color: var(--text-weak);
}
.gla-suggest {
    margin-top: 18px;
    display: flex;
    flex-wrap: wrap;
    gap: 9px;
    justify-content: center;
}
.gla-suggest-item {
    padding: 8px 14px;
    border-radius: 999px;
    font-size: 12.5px;
    color: var(--text-regular);
    background: var(--background-card);
    border: 1px solid var(--divider);
    cursor: pointer;
    transition: color 0.18s, border-color 0.18s, transform 0.18s, box-shadow 0.18s;
}
.gla-suggest-item:hover {
    color: var(--primary);
    border-color: var(--primary);
    transform: translateY(-1px);
    box-shadow: 0 4px 12px -6px var(--shadow);
}
.gla-suggest-item:active {
    transform: translateY(0) scale(0.985);
}

/* rows */
.gla-row {
    display: flex;
    gap: 10px;
    margin-bottom: 14px;
    animation: gla-rise 0.32s cubic-bezier(0.22, 1, 0.36, 1) both;
}
.gla-row.is-user {
    justify-content: flex-end;
}
.gla-body {
    min-width: 0;
    max-width: min(76%, 660px);
    display: flex;
    flex-direction: column;
    gap: 8px;
}
.gla-row.is-user .gla-body {
    align-items: flex-end;
}

/* avatar */
.gla-avatar {
    flex: 0 0 auto;
    width: 28px;
    height: 28px;
    border-radius: 9px;
    display: grid;
    place-items: center;
    background: var(--primary-background);
    margin-top: 1px;
}
.gla-avatar-core {
    width: 12px;
    height: 12px;
    border-radius: 50%;
    background: conic-gradient(from 40deg, var(--primary), var(--secondary), var(--primary));
}

/* bubbles */
.gla-bubble {
    position: relative;
    padding: 10px 14px;
    border-radius: 12px;
    font-size: 13.5px;
    line-height: 22px;
    white-space: pre-wrap;
    word-break: break-word;
    background: var(--background-card);
    border: 1px solid var(--divider);
    color: var(--text-regular);
}
.gla-row.is-user .gla-bubble {
    background: var(--primary);
    border-color: var(--primary);
    color: #fff;
    border-bottom-right-radius: 4px;
}
.gla-row.is-assistant .gla-bubble {
    border-bottom-left-radius: 4px;
}
.gla-text {
    white-space: pre-wrap;
}
.gla-caret {
    display: inline-block;
    width: 2px;
    height: 14px;
    margin-left: 2px;
    vertical-align: -2px;
    background: var(--primary);
    animation: gla-blink 1s steps(1) infinite;
}

/* thinking */
.gla-thinking {
    display: inline-flex;
    align-items: center;
    gap: 5px;
    padding: 9px 14px;
    border-radius: 12px;
    background: var(--background-card);
    border: 1px solid var(--divider);
}
.gla-thinking span {
    width: 5px;
    height: 5px;
    border-radius: 50%;
    background: var(--primary);
    opacity: 0.45;
    animation: gla-bounce 1.2s ease-in-out infinite;
}
.gla-thinking span:nth-child(2) {
    animation-delay: 0.16s;
}
.gla-thinking span:nth-child(3) {
    animation-delay: 0.32s;
}
.gla-thinking em {
    margin-left: 6px;
    font-style: normal;
    font-size: 12px;
    color: var(--text-weak);
}

/* tool steps timeline */
.gla-steps {
    display: flex;
    flex-direction: column;
}
.gla-step {
    position: relative;
    display: flex;
    align-items: center;
    gap: 9px;
    min-height: 30px;
    padding-left: 2px;
    font-size: 12.5px;
    color: var(--text-weak);
}
.gla-step-rail {
    position: absolute;
    left: 11px;
    top: 0;
    bottom: 0;
    width: 1px;
    background: var(--divider);
}
.gla-step:first-child .gla-step-rail {
    top: 50%;
}
.gla-step:last-child .gla-step-rail {
    bottom: 50%;
}
.gla-step-icon {
    position: relative;
    z-index: 1;
    flex: 0 0 auto;
    width: 20px;
    height: 20px;
    border-radius: 50%;
    display: grid;
    place-items: center;
    background: var(--background-main);
    border: 1px solid var(--divider);
    color: var(--text-weak);
}
.gla-step.is-running .gla-step-icon {
    border-color: var(--primary);
    color: var(--primary);
    background: var(--primary-background);
}
.gla-step.is-done .gla-step-icon {
    border-color: transparent;
    background: var(--success-background);
    color: var(--success);
}
.gla-step.is-error .gla-step-icon {
    border-color: transparent;
    background: var(--error-background);
    color: var(--error);
}
.gla-step.is-running .gla-step-text {
    color: var(--text-regular);
}
.gla-step-spin {
    width: 9px;
    height: 9px;
    border-radius: 50%;
    border: 1.5px solid var(--primary);
    border-top-color: transparent;
    animation: gla-spin 0.7s linear infinite;
}
.gla-step-text {
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
}
.gla-step-risk {
    flex: 0 0 auto;
    padding: 1px 7px;
    border-radius: 999px;
    font-size: 11px;
    line-height: 16px;
    background: var(--background-badge);
    color: var(--text-badge);
}
.gla-step-risk.risk-medium {
    background: var(--warning-background);
    color: var(--warning);
}
.gla-step-risk.risk-high {
    background: var(--error-background);
    color: var(--error);
}
.gla-step-risk.risk-low {
    background: var(--success-background);
    color: var(--success);
}

/* ---------------- composer ---------------- */
.gla-composer {
    flex: 0 0 auto;
    padding: 10px 4px 2px;
    border-top: 1px solid var(--divider);
}
.gla-box {
    display: flex;
    align-items: flex-end;
    gap: 8px;
    padding: 7px 7px 7px 4px;
    border-radius: 14px;
    background: var(--background-card);
    border: 1px solid var(--divider);
    transition: border-color 0.2s, box-shadow 0.2s;
}
.gla-box.is-focus {
    border-color: var(--primary);
    box-shadow: 0 0 0 3px var(--primary-background);
}
.gla-box textarea {
    flex: 1 1 auto;
    min-width: 0;
    max-height: 132px;
    padding: 6px 4px;
    border: 0;
    outline: 0;
    resize: none;
    background: transparent;
    color: var(--text-regular);
    font-family: inherit;
    font-size: 13.5px;
    line-height: 21px;
    overflow-y: auto;
}
.gla-box textarea::placeholder {
    color: var(--text-hint);
}
.gla-send {
    flex: 0 0 auto;
    width: 34px;
    height: 34px;
    display: grid;
    place-items: center;
    border: 0;
    border-radius: 11px;
    cursor: pointer;
    color: #fff;
    background: var(--primary);
    transition: transform 0.18s, background 0.18s, opacity 0.18s;
}
.gla-send:hover:not(:disabled) {
    background: var(--primary-hover);
}
.gla-send:active:not(:disabled) {
    transform: scale(0.92);
}
.gla-send:disabled {
    background: var(--primary-disabled);
    cursor: not-allowed;
}
.gla-send.is-stop {
    background: var(--error);
}
.gla-send.is-stop:hover {
    background: var(--error-hover);
}
.gla-foot {
    display: flex;
    justify-content: center;
    padding: 8px 0 2px;
}
.gla-foot-pill {
    font-size: 11.5px;
    color: var(--text-hint);
}

/* ---------------- keyframes ---------------- */
@keyframes gla-rise {
    from {
        opacity: 0;
        transform: translateY(8px);
    }
    to {
        opacity: 1;
        transform: translateY(0);
    }
}
@keyframes gla-spin {
    to {
        transform: rotate(360deg);
    }
}
@keyframes gla-pulse {
    0% {
        transform: scale(0.9);
        opacity: 0.4;
    }
    70% {
        transform: scale(1.35);
        opacity: 0;
    }
    100% {
        opacity: 0;
    }
}
@keyframes gla-blink {
    0%,
    100% {
        opacity: 1;
    }
    50% {
        opacity: 0.25;
    }
}
@keyframes gla-bounce {
    0%,
    60%,
    100% {
        transform: translateY(0);
        opacity: 0.4;
    }
    30% {
        transform: translateY(-3px);
        opacity: 1;
    }
}

/* ---------------- responsive ---------------- */
@media (max-width: 768px) {
    .gla {
        height: calc(100vh - 150px);
    }
    .gla-body {
        max-width: 88%;
    }
    .gla-hero-text h1 {
        font-size: 17px;
    }
}

/* ---------------- settings panel ---------------- */
.gla-panel {
    flex: 0 0 auto;
    margin-bottom: 12px;
    padding: 14px 16px 16px;
    border-radius: 12px;
    background: var(--background-card);
    border: 1px solid var(--divider);
    box-shadow: 0 6px 24px -14px var(--shadow);
}
.gla-panel-head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-bottom: 12px;
}
.gla-panel-head strong {
    font-size: 14px;
    color: var(--text-title);
}
.gla-field {
    display: flex;
    flex-direction: column;
    gap: 5px;
    margin-bottom: 10px;
    min-width: 0;
}
.gla-field label {
    font-size: 12px;
    color: var(--text-weak);
}
.gla-field input,
.gla-field select {
    height: 34px;
    padding: 0 11px;
    border-radius: 8px;
    border: 1px solid var(--divider);
    background: var(--background-main);
    color: var(--text-regular);
    font-family: inherit;
    font-size: 13px;
    outline: 0;
    transition: border-color 0.16s, box-shadow 0.16s;
}
.gla-field input:focus,
.gla-field select:focus {
    border-color: var(--primary);
    box-shadow: 0 0 0 3px var(--primary-background);
}
.gla-field-row {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 10px;
}
.gla-panel-actions {
    display: flex;
    gap: 8px;
    justify-content: flex-end;
    margin-top: 4px;
}
.gla-btn {
    height: 34px;
    padding: 0 16px;
    border-radius: 8px;
    border: 1px solid var(--divider);
    background: var(--background-card);
    color: var(--text-regular);
    font-family: inherit;
    font-size: 13px;
    cursor: pointer;
    transition: background 0.16s, color 0.16s, border-color 0.16s, transform 0.16s;
}
.gla-btn:hover:not(:disabled) {
    color: var(--primary);
    border-color: var(--primary);
}
.gla-btn:active:not(:disabled) {
    transform: scale(0.97);
}
.gla-btn:disabled {
    opacity: 0.55;
    cursor: not-allowed;
}
.gla-btn.is-primary {
    background: var(--primary);
    border-color: var(--primary);
    color: #fff;
}
.gla-btn.is-primary:hover:not(:disabled) {
    background: var(--primary-hover);
    color: #fff;
}
.gla-note {
    margin-top: 10px;
    padding: 8px 11px;
    border-radius: 8px;
    font-size: 12.5px;
    line-height: 19px;
    word-break: break-word;
}
.gla-note.is-ok {
    background: var(--success-background);
    color: var(--success);
}
.gla-note.is-bad {
    background: var(--error-background);
    color: var(--error);
}
.gla-slide-enter-active,
.gla-slide-leave-active {
    transition: opacity 0.22s ease, transform 0.22s cubic-bezier(0.22, 1, 0.36, 1);
}
.gla-slide-enter,
.gla-slide-leave-to {
    opacity: 0;
    transform: translateY(-8px);
}

/* ---------------- advanced options ---------------- */
.gla-adv {
    margin-top: 12px;
    border-top: 1px solid var(--divider);
    padding-top: 10px;
}
.gla-adv summary {
    display: flex;
    align-items: baseline;
    gap: 8px;
    cursor: pointer;
    font-size: 12.5px;
    color: var(--text-subtitle);
    list-style: none;
    outline: 0;
}
.gla-adv summary::-webkit-details-marker {
    display: none;
}
.gla-adv summary::before {
    content: '▸';
    color: var(--text-weak);
    transition: transform 0.18s;
}
.gla-adv[open] summary::before {
    transform: rotate(90deg);
}
.gla-adv summary span {
    font-size: 11.5px;
    color: var(--text-hint);
}
.gla-check {
    display: flex;
    gap: 9px;
    align-items: flex-start;
    margin-top: 12px;
    cursor: pointer;
}
.gla-check input {
    flex: 0 0 auto;
    width: 15px;
    height: 15px;
    margin-top: 1px;
    accent-color: var(--primary);
}
.gla-check-body {
    display: flex;
    flex-direction: column;
    gap: 2px;
    min-width: 0;
}
.gla-check-body strong {
    font-size: 12.5px;
    font-weight: 500;
    color: var(--text-regular);
}
.gla-check-body em {
    font-style: normal;
    font-size: 11.5px;
    line-height: 17px;
    color: var(--text-weak);
}

/* ---------------- confirm card ---------------- */
.gla-confirm {
    padding: 12px 14px;
    border-radius: 12px;
    background: var(--warning-background);
    border: 1px solid var(--warning);
    animation: gla-rise 0.28s cubic-bezier(0.22, 1, 0.36, 1) both;
}
.gla-confirm-head {
    display: flex;
    align-items: center;
    gap: 8px;
    color: var(--warning);
}
.gla-confirm-head strong {
    font-size: 13.5px;
    color: var(--text-strong);
}
.gla-confirm-desc {
    margin: 8px 0 0;
    font-size: 12.5px;
    line-height: 19px;
    color: var(--text-regular);
}
.gla-confirm-args {
    margin: 8px 0 0;
    padding: 0;
    list-style: none;
    display: flex;
    flex-wrap: wrap;
    gap: 6px;
}
.gla-confirm-args li {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 3px 9px;
    border-radius: 6px;
    background: var(--background-card);
    font-size: 12px;
}
.gla-confirm-args span {
    color: var(--text-weak);
}
.gla-confirm-args code {
    color: var(--text-regular);
    font-family: ui-monospace, Consolas, monospace;
}
.gla-confirm-actions {
    display: flex;
    align-items: center;
    gap: 8px;
    margin-top: 12px;
}
.gla-confirm-timer {
    margin-left: auto;
    font-size: 12px;
    color: var(--text-weak);
    font-variant-numeric: tabular-nums;
}

/* ---------------- responsive ---------------- */
@media (max-width: 768px) {
    .gla {
        height: calc(100vh - 150px);
    }
    .gla-body {
        max-width: 88%;
    }
    .gla-hero-text h1 {
        font-size: 17px;
    }
    .gla-field-row {
        grid-template-columns: 1fr;
    }
}

@media (prefers-reduced-motion: reduce) {
    .gla-orb.is-busy .gla-orb-ring,
    .gla-orb.is-busy .gla-orb-core,
    .gla-thinking span,
    .gla-step-spin,
    .gla-caret,
    .gla-chip.is-busy .gla-dot {
        animation: none !important;
    }
    .gla-row,
    .gla-empty,
    .gla-confirm {
        animation: none !important;
    }
}
</style>
