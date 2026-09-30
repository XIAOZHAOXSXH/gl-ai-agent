/*!
 * GL-AI助手 - bootstrap injected into the stock GL.iNet admin page.
 *
 * Injected by the package post-install script immediately before the SPA
 * bundle, so this runs first. The page itself (menu entry, view, RPC object)
 * is delivered by the normal SDK4 plugin mechanism; this file exists for
 * things that mechanism cannot do:
 *
 *   1. a health marker the page and the support bundle can read back
 *   2. optional enhancements to first-party pages, off by default
 *
 * Hard rules, because this runs inside GL's own admin UI:
 *   - never throw: a failure here must not affect the stock interface
 *   - never block: no synchronous work on the critical path
 *   - no global leakage beyond one namespaced object
 */
(function () {
    'use strict';

    var NS = 'GL_AI_AGENT';
    if (window[NS]) return;

    var api = {
        version: '0.1.0',
        ready: false,
        enabled: true,
        log: function () {
            if (!api.debug) return;
            var a = Array.prototype.slice.call(arguments);
            a.unshift('[GL-AI]');
            console.log.apply(console, a);
        },
    };
    window[NS] = api;

    /** Enhancement switches (default off; settings UI flips them later). */
    var ENHANCE = {
        overviewCard: false,
        headerButton: false,
    };

    function injectStyle(id, css) {
        try {
            if (document.getElementById(id)) return;
            var el = document.createElement('style');
            el.id = id;
            el.type = 'text/css';
            el.appendChild(document.createTextNode(css));
            (document.head || document.documentElement).appendChild(el);
        } catch (e) {
            /* ignore */
        }
    }

    /**
     * A small shortcut into the assistant from the admin header. Reuses the
     * stock header markup and the theme tokens so it looks native in every
     * theme, and does nothing until the header actually exists.
     */
    function addHeaderButton() {
        try {
            var host = document.querySelector('.hd-right');
            if (!host || host.querySelector('.glai-boot-entry')) return;

            injectStyle(
                'glai-boot-style',
                '.glai-boot-entry{display:inline-flex;align-items:center;justify-content:center;' +
                'width:32px;height:32px;border-radius:8px;cursor:pointer;color:var(--icon);' +
                'transition:color .18s,background .18s}' +
                '.glai-boot-entry:hover{color:var(--primary);background:var(--primary-background)}' +
                '.glai-boot-dot{width:16px;height:16px;border-radius:50%;' +
                'background:conic-gradient(from 0deg,var(--primary),var(--secondary),var(--primary))}'
            );

            var btn = document.createElement('a');
            btn.className = 'glai-boot-entry';
            btn.setAttribute('title', 'GL-AI助手');
            btn.setAttribute('aria-label', 'GL-AI助手');
            btn.href = '#/gl-ai';
            btn.innerHTML = '<span class="glai-boot-dot"></span>';
            host.insertBefore(btn, host.firstChild);
            api.log('header entry added');
        } catch (e) {
            /* ignore */
        }
    }

    /** Wait for the SPA shell without polling forever. */
    function whenShellReady(fn) {
        var tries = 0;
        (function poll() {
            if (++tries > 60) return;                 // ~30s then give up quietly
            if (document.querySelector('.hd-right') || document.querySelector('#app > *')) {
                try { fn(); } catch (e) { /* ignore */ }
                return;
            }
            setTimeout(poll, 500);
        })();
    }

    function afterLoginRedirect() {
        if (location.hash.indexOf('login') !== -1) return false;
        return true;
    }

    try {
        whenShellReady(function () {
            if (!api.enabled) return;
            if (!afterLoginRedirect()) return;         // do not touch the login page
            if (ENHANCE.headerButton) addHeaderButton();

            // Re-apply after SPA route changes, which re-render the header.
            window.addEventListener('hashchange', function () {
                if (api.enabled && ENHANCE.headerButton) setTimeout(addHeaderButton, 400);
            });

            api.ready = true;
            api.log('ready');
        });
    } catch (e) {
        api.log('bootstrap failed', e);
    }
})();
