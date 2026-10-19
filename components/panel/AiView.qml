pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "../../core"
import "../../ui"
import "../../ui/IconAliases.js" as IconAliases

// Встроенный ИИ-ассистент Oberon в стиле end-4 (illogical-impulse) + Material 3 Expressive.
// Поддерживает OpenCode (API и CLI), Google Gemini, OpenRouter, OpenAI и локальный Ollama.
ColumnLayout {
    id: root

    property var win: null
    readonly property bool active: win !== null && win.mode === "panel" && win.page === "ai"

    readonly property string homeDir: Quickshell.env("HOME") || "/"
    readonly property string scriptPath: homeDir + "/oberon/scripts/ai-chat.py"
    readonly property string chatsPath: homeDir + "/.local/state/oberon/ai-chats.json"

    // Провайдеры ИИ
    readonly property var providerSpecs: [
        { id: "opencode", label: "OpenCode", icon: "terminal" },
        { id: "gemini", label: "Gemini", icon: "auto_awesome" },
        { id: "openrouter", label: "OpenRouter", icon: "hub" },
        { id: "openai", label: "OpenAI", icon: "psychology" },
        { id: "ollama", label: "Ollama (Локально)", icon: "computer" }
    ]

    property string currentProvider: Prefs.aiProvider !== undefined && String(Prefs.aiProvider) !== ""
        ? String(Prefs.aiProvider) : "opencode"
    property string currentModel: Prefs.aiModel !== undefined && String(Prefs.aiModel) !== ""
        ? String(Prefs.aiModel) : "gemini-4-argon-contributor"
    property real temperature: Prefs.aiTemperature !== undefined ? Number(Prefs.aiTemperature) : 0.7

    // Статус провайдеров из scripts/ai-chat.py status
    property var providersStatus: ({
        opencode: {
            name: "OpenCode",
            has_key: false,
            key_preview: "CLI",
            base_url: "https://opencode.ai/zen/v1/chat/completions",
            models: ["gemini-4-argon-contributor", "claude-sonnet-4-5", "gpt-5.4", "qwen3.7-plus", "deepseek-v3", "opencode-cli"],
            ready: true
        },
        gemini: {
            name: "Google Gemini",
            has_key: false,
            key_preview: "",
            base_url: "https://generativelanguage.googleapis.com/v1beta",
            models: ["gemini-2.5-flash", "gemini-2.5-pro", "gemini-2.0-flash"],
            ready: false
        },
        openrouter: {
            name: "OpenRouter",
            has_key: false,
            key_preview: "",
            base_url: "https://openrouter.ai/api/v1/chat/completions",
            models: ["deepseek/deepseek-chat-v3-0324:free", "google/gemini-2.5-flash", "anthropic/claude-3.7-sonnet", "openai/gpt-4o-mini"],
            ready: false
        },
        openai: {
            name: "OpenAI",
            has_key: false,
            key_preview: "",
            base_url: "https://api.openai.com/v1/chat/completions",
            models: ["gpt-4o-mini", "gpt-4o", "deepseek-chat"],
            ready: false
        },
        ollama: {
            name: "Ollama (Локально)",
            has_key: true,
            key_preview: "",
            base_url: "http://127.0.0.1:11434",
            models: ["llama3.2", "qwen2.5-coder", "deepseek-r1"],
            ready: true
        }
    })
    property bool opencodeCliAvailable: true
    property bool ollamaOnline: false

    // Текущий статус выбранного провайдера
    readonly property var activeProvInfo: root.providersStatus[root.currentProvider] || ({
        name: root.currentProvider,
        has_key: false,
        key_preview: "",
        base_url: "",
        models: [],
        ready: false
    })
    readonly property var availableModels: {
        const list = root.activeProvInfo && Array.isArray(root.activeProvInfo.models)
            ? root.activeProvInfo.models.slice() : [];
        if (root.currentModel !== "" && list.indexOf(root.currentModel) < 0)
            list.unshift(root.currentModel);
        return list;
    }
    readonly property bool currentHasKey: Boolean(root.activeProvInfo && root.activeProvInfo.has_key)
    readonly property bool currentReady: Boolean(
        root.currentHasKey
        || (root.currentProvider === "opencode" && root.opencodeCliAvailable)
        || (root.currentProvider === "ollama" && root.ollamaOnline)
    )

    // Состояния панелей / дроверов
    property bool keyDrawerOpen: false
    property bool historyDrawerOpen: false
    property bool customModelOpen: false

    // Быстрый контекст
    property bool includeSysinfo: true
    property bool attachClipboard: false

    // Сессии чатов и сообщения
    property var sessions: []
    property string activeSessionId: ""
    property var messages: []
    property bool chatsLoaded: false
    property string statusToast: ""
    property string errorBanner: ""

    // Быстрые 1-клик действия в стиле end-4
    readonly property var quickActions: [
        {
            id: "translate_clip",
            label: "Перевести буфер",
            icon: "text_fields",
            needsClipboard: true,
            promptPrefix: "Переведи следующий текст из буфера обмена на русский язык (или на английский, если он уже на русском). Сохрани форматирование и тон:\n\n"
        },
        {
            id: "explain_clip",
            label: "Объяснить код из буфера",
            icon: "code",
            needsClipboard: true,
            promptPrefix: "Подробно и понятно объясни, что делает этот код или команда из буфера обмена, и укажи потенциальные подводные камни:\n\n```\n"
        },
        {
            id: "fix_error",
            label: "Исправить ошибку",
            icon: "build",
            needsClipboard: true,
            promptPrefix: "Проанализируй этот лог ошибки / код из буфера обмена, объясни причину проблемы и предложи готовое исправление:\n\n```\n"
        },
        {
            id: "arch_cmd",
            label: "Команда для Arch",
            icon: "terminal",
            needsClipboard: false,
            prefill: "Подскажи команду терминала в Arch Linux (pacman / paru / systemctl) для: "
        },
        {
            id: "summarize_clip",
            label: "Кратко суть",
            icon: "notes",
            needsClipboard: true,
            promptPrefix: "Выдели главную суть (краткое резюме по пунктам) из следующего текста:\n\n"
        }
    ]

    readonly property var starterCards: [
        {
            title: "Терминал и Arch Linux",
            subtitle: "Подобрать пакеты, systemd-юниты, однострочники bash",
            icon: "terminal",
            prompt: "Покажи самые полезные команды обслуживания Arch Linux (очистка кэша пакетов, осиротевшие пакеты, логи ошибок systemd)."
        },
        {
            title: "Разбор кода и QML / Python",
            subtitle: "Объяснить фрагмент из буфера или найти баг",
            icon: "code",
            prompt: "Напиши пример компактного скрипта на Python 3 для мониторинга ресурсов Linux с выводом в JSON."
        },
        {
            title: "Конфигурация Umbriel",
            subtitle: "Хоткеи, правила окон, размытие и анимации",
            icon: "auto_awesome",
            prompt: "Как устроена современная тайлинговая среда на Wayland с композитором Umbriel и оболочкой Oberon?"
        }
    ]

    visible: root.active
    Layout.fillWidth: true
    Layout.preferredHeight: Theme.dp(560)
    implicitHeight: Theme.dp(560)
    spacing: Theme.dp(8)

    Component.onCompleted: {
        // Регистрируем алиасы иконок в общей таблице SymbolPaths, чтобы
        // иконки провайдеров и кнопок рендерились векторно без предупреждений.
        if (IconAliases.alias) {
            if (!IconAliases.alias["psychology"])
                IconAliases.alias["psychology"] = "orbit";
            if (!IconAliases.alias["add_comment"])
                IconAliases.alias["add_comment"] = "chat";
            if (!IconAliases.alias["attach_file"])
                IconAliases.alias["attach_file"] = "upload_file";
            if (!IconAliases.alias["translate"])
                IconAliases.alias["translate"] = "text_fields";
        }
        root.refreshStatus();
        root.loadChats();
    }

    onActiveChanged: {
        if (root.active) {
            root.refreshStatus();
            if (!root.chatsLoaded)
                root.loadChats();
            Qt.callLater(() => promptField.input.forceActiveFocus());
        }
    }

    Connections {
        target: root.win ? root.win.shell : null
        ignoreUnknownSignals: true
        function onAiPromptRequested(promptText) {
            root.handleExternalPrompt(promptText);
        }
    }

    // ── Вспомогательные функции ──────────────────────────────────────────
    function shq(s) {
        return "'" + String(s).replace(/'/g, "'\\''") + "'";
    }

    function showToast(msg) {
        root.statusToast = String(msg || "");
        toastTimer.restart();
    }

    function copyToClipboard(text, toastLabel) {
        const clean = String(text || "");
        if (clean === "")
            return;
        Quickshell.execDetached(["sh", "-c", "printf '%s' \"$1\" | wl-copy", "sh", clean]);
        root.showToast(toastLabel || "Скопировано в буфер обмена");
    }

    function isShellLang(lang) {
        const l = String(lang || "").toLowerCase().trim();
        return l === "sh" || l === "bash" || l === "zsh" || l === "shell" || l === "fish" || l === "console" || l === "";
    }

    function sendToIslandTerminal(cmdText) {
        const clean = String(cmdText || "").trim();
        if (clean === "")
            return;
        Quickshell.execDetached(["sh", "-c", "printf '%s' \"$1\" | wl-copy", "sh", clean]);
        if (root.win && root.win.shell) {
            root.win.shell.openTerminal("");
            try {
                if (typeof root.win.shell.terminalCommandRequested === "function")
                    root.win.shell.terminalCommandRequested(clean);
            } catch (e) {}
        }
        root.showToast("Команда скопирована и открыт терминал островка");
    }

    function selectProvider(pid) {
        const clean = String(pid || "opencode");
        root.currentProvider = clean;
        const info = root.providersStatus[clean];
        if (info && Array.isArray(info.models) && info.models.length > 0) {
            if (info.models.indexOf(root.currentModel) < 0)
                root.currentModel = String(info.models[0]);
        }
        if (keyDrawerOpen) {
            keyInputField.text = "";
            baseUrlField.text = info && info.base_url ? String(info.base_url) : "";
        }
    }

    function selectModel(mid) {
        const clean = String(mid || "").trim();
        if (clean === "")
            return;
        root.currentModel = clean;
        root.customModelOpen = false;
    }

    function refreshStatus() {
        if (statusProc.running)
            return;
        statusProc.buf = "";
        statusProc.command = ["python3", root.scriptPath, "status"];
        statusProc.running = true;
    }

    function saveApiKey() {
        if (statusProc.running)
            return;
        const keyVal = keyInputField.text.trim();
        const urlVal = baseUrlField.text.trim();
        if (keyVal === "" && root.currentProvider !== "ollama" && urlVal === "") {
            root.errorBanner = "Введите API-ключ перед сохранением.";
            return;
        }
        root.errorBanner = "";
        statusProc.buf = "";
        statusProc.command = ["python3", root.scriptPath, "set-key", root.currentProvider, keyVal, urlVal];
        statusProc.running = true;
        keyInputField.text = "";
        root.keyDrawerOpen = false;
        root.showToast("Ключ для " + (root.activeProvInfo.name || root.currentProvider) + " сохранён");
    }

    function removeApiKey() {
        if (statusProc.running)
            return;
        root.errorBanner = "";
        statusProc.buf = "";
        statusProc.command = ["python3", root.scriptPath, "remove-key", root.currentProvider];
        statusProc.running = true;
        keyInputField.text = "";
        root.showToast("Ключ для " + (root.activeProvInfo.name || root.currentProvider) + " удалён");
    }

    // ── Управление сессиями и историей чатов ─────────────────────────────
    function makeSessionId() {
        return "chat-" + Date.now() + "-" + Math.floor(Math.random() * 1000);
    }

    function sessionTitleFromMessages(msgs) {
        if (!Array.isArray(msgs))
            return "Новый диалог";
        for (let i = 0; i < msgs.length; i++) {
            if (msgs[i] && msgs[i].role === "user" && String(msgs[i].content || "").trim() !== "") {
                const raw = String(msgs[i].content).trim().replace(/\s+/g, " ");
                return raw.length > 44 ? raw.slice(0, 44) + "…" : raw;
            }
        }
        return "Новый диалог";
    }

    function startNewChat() {
        if (askProc.running)
            askProc.running = false;
        const newId = root.makeSessionId();
        root.activeSessionId = newId;
        root.messages = [];
        root.errorBanner = "";
        root.historyDrawerOpen = false;
        Qt.callLater(() => promptField.input.forceActiveFocus());
    }

    function switchSession(sessionId) {
        if (askProc.running)
            return;
        for (let i = 0; i < root.sessions.length; i++) {
            const s = root.sessions[i];
            if (s && s.id === sessionId) {
                root.activeSessionId = s.id;
                root.messages = Array.isArray(s.messages) ? s.messages.slice() : [];
                if (s.provider)
                    root.currentProvider = String(s.provider);
                if (s.model)
                    root.currentModel = String(s.model);
                root.historyDrawerOpen = false;
                root.scrollToBottom();
                return;
            }
        }
    }

    function deleteSession(sessionId) {
        const next = [];
        for (let i = 0; i < root.sessions.length; i++) {
            if (root.sessions[i] && root.sessions[i].id !== sessionId)
                next.push(root.sessions[i]);
        }
        root.sessions = next;
        if (root.activeSessionId === sessionId) {
            if (next.length > 0) {
                root.activeSessionId = next[0].id;
                root.messages = Array.isArray(next[0].messages) ? next[0].messages.slice() : [];
            } else {
                root.activeSessionId = root.makeSessionId();
                root.messages = [];
            }
        }
        root.saveChats();
    }

    function syncActiveSessionToList() {
        if (root.messages.length === 0)
            return;
        if (root.activeSessionId === "")
            root.activeSessionId = root.makeSessionId();
        const entry = {
            id: root.activeSessionId,
            title: root.sessionTitleFromMessages(root.messages),
            updatedAt: Date.now(),
            provider: root.currentProvider,
            model: root.currentModel,
            messages: root.messages.slice()
        };
        const next = [entry];
        for (let i = 0; i < root.sessions.length; i++) {
            const s = root.sessions[i];
            if (s && s.id !== root.activeSessionId && Array.isArray(s.messages) && s.messages.length > 0)
                next.push(s);
            if (next.length >= 25)
                break;
        }
        root.sessions = next;
        root.saveChats();
    }

    function loadChats() {
        loadChatsProc.buf = "";
        loadChatsProc.running = false;
        loadChatsProc.running = true;
    }

    function saveChats() {
        const payload = JSON.stringify({
            activeSessionId: root.activeSessionId,
            provider: root.currentProvider,
            model: root.currentModel,
            includeSysinfo: root.includeSysinfo,
            sessions: root.sessions
        });
        const dir = root.homeDir + "/.local/state/oberon";
        saveChatsProc.command = [
            "sh", "-c",
            "mkdir -p " + root.shq(dir) +
            " && printf '%s' " + root.shq(payload) + " > " + root.shq(root.chatsPath + ".tmp") +
            " && mv -f " + root.shq(root.chatsPath + ".tmp") + " " + root.shq(root.chatsPath)
        ];
        saveChatsProc.running = false;
        saveChatsProc.running = true;
    }

    // ── Отправка запроса к ИИ ────────────────────────────────────────────
    function handleExternalPrompt(promptText) {
        const clean = String(promptText || "").trim();
        if (clean === "")
            return;
        promptField.text = clean;
        Qt.callLater(() => root.submitPrompt());
    }

    function triggerQuickAction(actionObj) {
        if (!actionObj || askProc.running)
            return;
        if (!actionObj.needsClipboard) {
            promptField.text = String(actionObj.prefill || "");
            promptField.input.forceActiveFocus();
            return;
        }
        clipReadProc.mode = "quick";
        clipReadProc.quickPrefix = String(actionObj.promptPrefix || "");
        clipReadProc.quickNeedsFenceClose = String(actionObj.promptPrefix || "").indexOf("```") >= 0;
        clipReadProc.userPrompt = "";
        clipReadProc.buf = "";
        clipReadProc.running = false;
        clipReadProc.running = true;
    }

    function submitPrompt() {
        if (askProc.running)
            return;
        const text = promptField.text.trim();
        if (text === "" && !root.attachClipboard)
            return;
        promptField.text = "";
        root.errorBanner = "";

        if (root.attachClipboard) {
            clipReadProc.mode = "attach";
            clipReadProc.userPrompt = text;
            clipReadProc.buf = "";
            clipReadProc.running = false;
            clipReadProc.running = true;
            return;
        }
        root.dispatchUserMessage(text);
    }

    function retryMessage(msgText) {
        const clean = String(msgText || "").trim();
        if (clean === "" || askProc.running)
            return;
        root.dispatchUserMessage(clean);
    }

    function dispatchUserMessage(fullUserText) {
        const clean = String(fullUserText || "").trim();
        if (clean === "")
            return;
        if (root.activeSessionId === "")
            root.activeSessionId = root.makeSessionId();

        const nextMsgs = root.messages.slice();
        nextMsgs.push({
            role: "user",
            content: clean,
            ts: Date.now(),
            provider: root.currentProvider,
            model: root.currentModel,
            blocks: []
        });
        root.messages = nextMsgs;
        root.syncActiveSessionToList();
        root.scrollToBottom();

        // Подготавливаем историю для скрипта
        const apiMsgs = [];
        const startIdx = Math.max(0, nextMsgs.length - 16);
        for (let i = startIdx; i < nextMsgs.length; i++) {
            const m = nextMsgs[i];
            if (m && (m.role === "user" || m.role === "assistant") && String(m.content || "").trim() !== "") {
                apiMsgs.push({
                    role: m.role,
                    content: String(m.content)
                });
            }
        }

        let activeWinTitle = "";
        if (Umbriel.activeWindow) {
            const appId = String(Umbriel.activeWindow.app_id || "");
            const wTitle = String(Umbriel.activeWindow.title || "");
            activeWinTitle = appId + (wTitle ? " — " + wTitle : "");
        }

        const stdinJson = JSON.stringify({
            messages: apiMsgs,
            include_sysinfo: root.includeSysinfo,
            active_window: activeWinTitle
        });

        askProc.pendingStdin = stdinJson;
        askProc.buf = "";
        askProc.command = [
            "python3",
            root.scriptPath,
            "ask",
            root.currentProvider,
            root.currentModel,
            String(root.temperature)
        ];
        askProc.stdinEnabled = true;
        askProc.running = true;
    }

    function stopGeneration() {
        if (askProc.running) {
            askProc.running = false;
            root.showToast("Генерация остановлена");
        }
    }

    function scrollToBottom() {
        Qt.callLater(() => {
            if (chatList.count > 0)
                chatList.positionViewAtEnd();
        });
    }

    // ── Процессы ─────────────────────────────────────────────────────────
    Timer {
        id: toastTimer
        interval: 2500
        onTriggered: root.statusToast = ""
    }

    Process {
        id: statusProc
        property string buf: ""
        running: false
        stdout: SplitParser {
            splitMarker: ""
            onRead: chunk => statusProc.buf += chunk
        }
        onExited: exitCode => {
            const raw = statusProc.buf.trim();
            statusProc.buf = "";
            if (exitCode !== 0 || raw === "")
                return;
            try {
                const res = JSON.parse(raw);
                if (res && res.ok && res.providers) {
                    root.providersStatus = res.providers;
                    root.opencodeCliAvailable = Boolean(res.opencode_cli_available);
                    root.ollamaOnline = Boolean(res.ollama_online);
                    const curInfo = res.providers[root.currentProvider];
                    if (curInfo && Array.isArray(curInfo.models) && curInfo.models.length > 0) {
                        if (curInfo.models.indexOf(root.currentModel) < 0)
                            root.currentModel = String(curInfo.models[0]);
                    }
                }
            } catch (e) {}
        }
    }

    Process {
        id: askProc
        property string pendingStdin: ""
        property string buf: ""
        running: false
        stdinEnabled: true
        stdout: SplitParser {
            splitMarker: ""
            onRead: chunk => askProc.buf += chunk
        }
        onStarted: {
            if (askProc.pendingStdin !== "") {
                const payload = askProc.pendingStdin;
                askProc.pendingStdin = "";
                askProc.write(payload);
                askProc.stdinEnabled = false;
            }
        }
        onExited: exitCode => {
            const raw = askProc.buf.trim();
            askProc.buf = "";
            if (raw === "") {
                if (exitCode !== 0)
                    root.errorBanner = "Процесс генерации завершился с кодом " + exitCode;
                return;
            }
            try {
                const res = JSON.parse(raw);
                if (!res || !res.ok) {
                    root.errorBanner = String((res && res.error) ? res.error : "Не удалось получить ответ от ИИ.");
                    return;
                }
                const nextMsgs = root.messages.slice();
                nextMsgs.push({
                    role: "assistant",
                    content: String(res.reply || ""),
                    blocks: Array.isArray(res.blocks) ? res.blocks : [],
                    provider: String(res.provider || root.currentProvider),
                    model: String(res.model || root.currentModel),
                    ts: Date.now()
                });
                root.messages = nextMsgs;
                root.syncActiveSessionToList();
                root.scrollToBottom();
            } catch (e) {
                root.errorBanner = "Ошибка чтения ответа ИИ: " + raw.slice(0, 200);
            }
        }
    }

    Process {
        id: clipReadProc
        property string mode: "attach"
        property string quickPrefix: ""
        property bool quickNeedsFenceClose: false
        property string userPrompt: ""
        property string buf: ""
        command: ["wl-paste", "-n"]
        running: false
        stdout: SplitParser {
            splitMarker: ""
            onRead: chunk => clipReadProc.buf += chunk
        }
        onExited: {
            const clipText = clipReadProc.buf.trim();
            clipReadProc.buf = "";
            if (clipText === "") {
                root.errorBanner = "Буфер обмена пуст — скопируйте текст или код и попробуйте снова.";
                return;
            }
            if (clipReadProc.mode === "quick") {
                const suffix = clipReadProc.quickNeedsFenceClose ? "\n```" : "";
                root.dispatchUserMessage(clipReadProc.quickPrefix + clipText + suffix);
            } else {
                const head = clipReadProc.userPrompt !== ""
                    ? clipReadProc.userPrompt + "\n\nСодержимое буфера обмена:\n```\n" + clipText + "\n```"
                    : "Проанализируй содержимое буфера обмена:\n```\n" + clipText + "\n```";
                root.attachClipboard = false;
                root.dispatchUserMessage(head);
            }
        }
    }

    Process {
        id: loadChatsProc
        property string buf: ""
        command: ["sh", "-c", "cat " + root.shq(root.chatsPath) + " 2>/dev/null"]
        running: false
        stdout: SplitParser {
            splitMarker: ""
            onRead: chunk => loadChatsProc.buf += chunk
        }
        onExited: {
            root.chatsLoaded = true;
            const raw = loadChatsProc.buf.trim();
            loadChatsProc.buf = "";
            if (raw === "") {
                root.activeSessionId = root.makeSessionId();
                return;
            }
            try {
                const data = JSON.parse(raw);
                if (data && typeof data === "object") {
                    if (typeof data.provider === "string" && data.provider !== "")
                        root.currentProvider = data.provider;
                    if (typeof data.model === "string" && data.model !== "")
                        root.currentModel = data.model;
                    if (typeof data.includeSysinfo === "boolean")
                        root.includeSysinfo = data.includeSysinfo;
                    if (Array.isArray(data.sessions)) {
                        root.sessions = data.sessions;
                        const targetId = String(data.activeSessionId || "");
                        for (let i = 0; i < data.sessions.length; i++) {
                            const s = data.sessions[i];
                            if (s && (s.id === targetId || i === 0)) {
                                root.activeSessionId = String(s.id || root.makeSessionId());
                                root.messages = Array.isArray(s.messages) ? s.messages : [];
                                if (s.id === targetId)
                                    break;
                            }
                        }
                    }
                }
            } catch (e) {}
            if (root.activeSessionId === "")
                root.activeSessionId = root.makeSessionId();
            root.scrollToBottom();
        }
    }

    Process {
        id: saveChatsProc
        running: false
    }

    // ── 1. ВЕРХНЯЯ ПАНЕЛЬ ПРОВАЙДЕРОВ И УПРАВЛЕНИЯ ──────────────────────
    RowLayout {
        Layout.fillWidth: true
        spacing: Theme.dp(6)

        Flickable {
            Layout.fillWidth: true
            Layout.preferredHeight: Theme.dp(32)
            contentWidth: provRow.implicitWidth
            contentHeight: height
            clip: true
            flickableDirection: Flickable.HorizontalFlick
            boundsBehavior: Flickable.StopAtBounds

            Row {
                id: provRow
                height: parent.height
                spacing: Theme.dp(6)

                Repeater {
                    model: root.providerSpecs
                    delegate: Chip {
                        id: provChip
                        required property var modelData
                        size: "md"
                        kind: "filter"
                        icon: provChip.modelData.icon
                        label: provChip.modelData.label
                        selected: root.currentProvider === provChip.modelData.id
                        onClicked: root.selectProvider(provChip.modelData.id)
                    }
                }
            }
        }

        // Кнопка настройки ключа API
        Chip {
            size: "md"
            kind: "assist"
            icon: "key"
            selected: root.keyDrawerOpen
            customColors: !root.keyDrawerOpen
            backgroundColor: root.currentReady
                ? Theme.alpha(Theme.secondaryContainer, 0.55)
                : Theme.alpha(Theme.errorContainer, 0.75)
            foregroundColor: root.currentReady ? Theme.text : Theme.fgErrorContainer
            iconColor: root.currentReady ? Theme.success : Theme.error
            borderColor: root.currentReady ? Theme.outline : Theme.error
            label: {
                if (root.currentProvider === "ollama")
                    return root.ollamaOnline ? "🔑 Ollama: Онлайн" : "🔑 Ollama: Офлайн";
                if (root.currentHasKey)
                    return "🔑 Ключ: ОК";
                if (root.currentProvider === "opencode" && root.opencodeCliAvailable)
                    return "🔑 Ключ / CLI";
                return "🔑 Ввести ключ";
            }
            onClicked: {
                root.keyDrawerOpen = !root.keyDrawerOpen;
                if (root.keyDrawerOpen) {
                    root.historyDrawerOpen = false;
                    baseUrlField.text = root.activeProvInfo && root.activeProvInfo.base_url
                        ? String(root.activeProvInfo.base_url) : "";
                    Qt.callLater(() => keyInputField.input.forceActiveFocus());
                }
            }
        }

        IconButton {
            size: "xs"
            variant: "tonal"
            icon: "add_comment"
            tooltip: "+ Новый чат"
            onClicked: root.startNewChat()
        }

        IconButton {
            size: "xs"
            variant: root.historyDrawerOpen ? "filled" : "tonal"
            icon: "history"
            tooltip: "История чатов (" + root.sessions.length + ")"
            onClicked: {
                root.historyDrawerOpen = !root.historyDrawerOpen;
                if (root.historyDrawerOpen)
                    root.keyDrawerOpen = false;
            }
        }
    }

    // ── 1b. ПОЛОСА ВЫБОРА МОДЕЛИ АКТИВНОГО ПРОВАЙДЕРА ────────────────────
    RowLayout {
        Layout.fillWidth: true
        spacing: Theme.dp(6)

        LText {
            role: "labelSmall"
            color: Theme.subtext
            text: "Модель:"
        }

        Flickable {
            Layout.fillWidth: true
            Layout.preferredHeight: Theme.dp(28)
            contentWidth: modelsRow.implicitWidth
            contentHeight: height
            clip: true
            flickableDirection: Flickable.HorizontalFlick
            boundsBehavior: Flickable.StopAtBounds

            Row {
                id: modelsRow
                height: parent.height
                spacing: Theme.dp(6)

                Repeater {
                    model: root.availableModels
                    delegate: Chip {
                        id: modChip
                        required property var modelData
                        size: "sm"
                        kind: "filter"
                        label: String(modChip.modelData)
                        selected: root.currentModel === String(modChip.modelData)
                        onClicked: root.selectModel(modChip.modelData)
                    }
                }

                Chip {
                    size: "sm"
                    kind: "assist"
                    icon: "edit"
                    label: "Своя модель…"
                    selected: root.customModelOpen
                    onClicked: {
                        root.customModelOpen = !root.customModelOpen;
                        if (root.customModelOpen) {
                            customModelField.text = root.currentModel;
                            Qt.callLater(() => customModelField.input.forceActiveFocus());
                        }
                    }
                }
            }
        }

        IconButton {
            size: "xs"
            icon: "refresh"
            tooltip: "Обновить статус провайдеров и локальных моделей"
            onClicked: root.refreshStatus()
        }
    }

    // Поле ввода произвольной модели
    RowLayout {
        visible: root.customModelOpen
        Layout.fillWidth: true
        spacing: Theme.dp(6)

        TextField {
            id: customModelField
            Layout.fillWidth: true
            variant: "outlined"
            placeholder: "Введите ID модели (например: claude-sonnet-4-5, deepseek/deepseek-r1)…"
            onAccepted: {
                if (customModelField.text.trim() !== "")
                    root.selectModel(customModelField.text.trim());
            }
            onEscaped: root.customModelOpen = false
        }

        Button {
            size: "s"
            variant: "filled"
            icon: "check"
            text: "Выбрать"
            onClicked: {
                if (customModelField.text.trim() !== "")
                    root.selectModel(customModelField.text.trim());
            }
        }
    }

    // ── 2. ВЫДВИЖНАЯ КАРТОЧКА НАСТРОЙКИ КЛЮЧА API (KEY DRAWER) ──────────
    Card {
        visible: root.keyDrawerOpen
        Layout.fillWidth: true
        title: "🔑 Настройка API — " + (root.activeProvInfo.name || root.currentProvider)
        actionIcon: "close"
        onActionClicked: root.keyDrawerOpen = false

        LText {
            Layout.fillWidth: true
            role: "bodySmall"
            color: Theme.subtext
            wrapMode: Text.WordWrap
            text: {
                if (root.currentProvider === "opencode")
                    return "Укажите API-ключ OpenCode (Zen / Go endpoint) или оставьте пустым для работы через локальный OpenCode CLI (`opencode run`). Ключи хранятся в ~/.local/share/oberon/ai-keys.json (права 0600).";
                if (root.currentProvider === "gemini")
                    return "Укажите ключ Google AI Studio (Gemini API). Ключ сохраняется локально с правами 0600.";
                if (root.currentProvider === "openrouter")
                    return "Укажите ключ OpenRouter (sk-or-v1-...) для доступа к сотням моделей, включая бесплатные.";
                if (root.currentProvider === "ollama")
                    return "Для локального сервера Ollama ключ не требуется — можно указать нестандартный адрес сервера.";
                return "Укажите API-ключ и при необходимости совместимый с OpenAI Base URL.";
            }
        }

        RowLayout {
            visible: root.activeProvInfo && root.activeProvInfo.key_preview !== ""
            Layout.fillWidth: true
            spacing: Theme.dp(6)

            Icon {
                name: "check_circle"
                size: Theme.dp(16)
                color: Theme.success
            }

            LText {
                role: "labelMedium"
                color: Theme.success
                text: "Текущий источник: " + String(root.activeProvInfo.key_preview)
            }
        }

        TextField {
            id: keyInputField
            visible: root.currentProvider !== "ollama"
            Layout.fillWidth: true
            variant: "outlined"
            password: true
            label: "API-ключ (" + (root.activeProvInfo.name || root.currentProvider) + ")"
            placeholder: "Вставьте секретный ключ (sk-..., AIza...)…"
            onAccepted: root.saveApiKey()
            onEscaped: root.keyDrawerOpen = false
        }

        TextField {
            id: baseUrlField
            Layout.fillWidth: true
            variant: "outlined"
            label: "Base URL (необязательно)"
            placeholder: root.activeProvInfo ? String(root.activeProvInfo.base_url || "") : "https://..."
            onAccepted: root.saveApiKey()
            onEscaped: root.keyDrawerOpen = false
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Theme.dp(8)

            Button {
                size: "s"
                variant: "filled"
                icon: "save"
                text: "Сохранить ключ"
                onClicked: root.saveApiKey()
            }

            Button {
                visible: root.currentHasKey && root.currentProvider !== "ollama"
                size: "s"
                variant: "tonal"
                danger: true
                icon: "delete"
                text: "Удалить"
                onClicked: root.removeApiKey()
            }

            Item { Layout.fillWidth: true }

            Button {
                size: "s"
                variant: "text"
                text: "Закрыть"
                onClicked: root.keyDrawerOpen = false
            }
        }
    }

    // ── 2b. ВЫДВИЖНАЯ КАРТОЧКА ИСТОРИИ ЧАТОВ ────────────────────────────
    Card {
        visible: root.historyDrawerOpen
        Layout.fillWidth: true
        title: "История диалогов"
        actionIcon: "close"
        onActionClicked: root.historyDrawerOpen = false

        LText {
            visible: root.sessions.length === 0
            Layout.fillWidth: true
            role: "bodySmall"
            color: Theme.subtext
            text: "Сохранённых диалогов пока нет."
        }

        Repeater {
            model: root.sessions.slice(0, 8)
            delegate: RowLayout {
                id: sessRow
                required property var modelData
                Layout.fillWidth: true
                spacing: Theme.dp(8)

                Chip {
                    Layout.fillWidth: true
                    size: "md"
                    kind: "filter"
                    icon: "chat"
                    selected: String(sessRow.modelData.id) === root.activeSessionId
                    label: String(sessRow.modelData.title || "Диалог") + " · " + String(sessRow.modelData.model || "")
                    onClicked: root.switchSession(sessRow.modelData.id)
                }

                IconButton {
                    size: "xs"
                    icon: "delete"
                    tooltip: "Удалить диалог"
                    onClicked: root.deleteSession(sessRow.modelData.id)
                }
            }
        }
    }

    // ── 3. ПАНЕЛЬ БЫСТРОГО КОНТЕКСТА И 1-КЛИК ПРОМПТОВ (КАК В END-4) ────
    Flickable {
        Layout.fillWidth: true
        Layout.preferredHeight: Theme.dp(28)
        contentWidth: contextChipsRow.implicitWidth
        contentHeight: height
        clip: true
        flickableDirection: Flickable.HorizontalFlick
        boundsBehavior: Flickable.StopAtBounds

        Row {
            id: contextChipsRow
            height: parent.height
            spacing: Theme.dp(6)

            Chip {
                size: "sm"
                kind: "filter"
                icon: "upload_file"
                selected: root.includeSysinfo
                label: "📎 Контекст системы"
                onClicked: {
                    root.includeSysinfo = !root.includeSysinfo;
                    root.saveChats();
                }
            }

            Chip {
                size: "sm"
                kind: "filter"
                icon: "content_paste"
                selected: root.attachClipboard
                label: "📋 Прикрепить буфер обмена"
                onClicked: root.attachClipboard = !root.attachClipboard
            }

            Repeater {
                model: root.quickActions
                delegate: Chip {
                    id: qaChip
                    required property var modelData
                    size: "sm"
                    kind: "suggestion"
                    icon: qaChip.modelData.icon
                    label: qaChip.modelData.label
                    disabled: askProc.running
                    onClicked: root.triggerQuickAction(qaChip.modelData)
                }
            }
        }
    }

    // Баннер ошибки или тост-уведомление
    Rectangle {
        visible: root.errorBanner !== ""
        Layout.fillWidth: true
        implicitHeight: errLayout.implicitHeight + Theme.dp(16)
        radius: Theme.shapeMd
        color: Theme.errorContainer

        RowLayout {
            id: errLayout
            anchors.fill: parent
            anchors.margins: Theme.dp(8)
            spacing: Theme.dp(8)

            Icon {
                name: "error"
                size: Theme.dp(18)
                color: Theme.fgErrorContainer
            }

            LText {
                Layout.fillWidth: true
                role: "bodySmall"
                color: Theme.fgErrorContainer
                wrapMode: Text.WordWrap
                text: root.errorBanner
            }

            Button {
                visible: !root.currentHasKey && root.currentProvider !== "ollama"
                size: "xs"
                variant: "filled"
                icon: "key"
                text: "Ввести ключ"
                onClicked: {
                    root.errorBanner = "";
                    root.keyDrawerOpen = true;
                }
            }

            IconButton {
                size: "xs"
                icon: "close"
                tintOverride: Theme.fgErrorContainer
                onClicked: root.errorBanner = ""
            }
        }
    }

    // ── 4. ОСНОВНАЯ ОБЛАСТЬ СООБЩЕНИЙ ЧАТА ──────────────────────────────
    Rectangle {
        id: chatViewport
        Layout.fillWidth: true
        Layout.fillHeight: true
        radius: Theme.shapeLgInc
        color: Theme.mLow
        clip: true

        // Пустое состояние — приветственная карточка M3 Expressive
        ColumnLayout {
            visible: root.messages.length === 0 && !askProc.running
            anchors.centerIn: parent
            width: Math.min(parent.width - Theme.dp(32), Theme.dp(680))
            spacing: Theme.dp(14)

            Item {
                Layout.alignment: Qt.AlignHCenter
                width: Theme.dp(68)
                height: Theme.dp(68)

                MaterialShape {
                    anchors.fill: parent
                    shape: "softBurst"
                    color: Theme.primaryContainer
                }

                Icon {
                    anchors.centerIn: parent
                    name: "auto_awesome"
                    size: Theme.dp(30)
                    color: Theme.fgPrimaryContainer
                    fill: 1
                }
            }

            LText {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                role: "headlineSmall"
                color: Theme.text
                text: "ИИ-Ассистент Oberon"
            }

            LText {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                role: "bodyMedium"
                color: Theme.subtext
                wrapMode: Text.WordWrap
                text: "Активный провайдер: " + (root.activeProvInfo.name || root.currentProvider) +
                      " · Модель: " + root.currentModel +
                      (root.includeSysinfo ? " · Контекст Arch/Umbriel включён" : "")
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.dp(10)

                Repeater {
                    model: root.starterCards
                    delegate: Rectangle {
                        id: stCard
                        required property var modelData
                        Layout.fillWidth: true
                        Layout.preferredHeight: Theme.dp(96)
                        radius: Theme.shapeLg
                        color: stMouse.containsMouse ? Theme.mHighest : Theme.mHigh

                        Behavior on color {
                            ColorAnimation { duration: Theme.durFastEffects }
                        }

                        ColumnLayout {
                            anchors.fill: parent
                            anchors.margins: Theme.dp(12)
                            spacing: Theme.dp(4)

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Theme.dp(6)

                                Icon {
                                    name: stCard.modelData.icon
                                    size: Theme.dp(18)
                                    color: Theme.primary
                                }

                                LText {
                                    Layout.fillWidth: true
                                    role: "labelLarge"
                                    color: Theme.text
                                    elide: Text.ElideRight
                                    text: stCard.modelData.title
                                }
                            }

                            LText {
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                role: "bodySmall"
                                color: Theme.subtext
                                wrapMode: Text.WordWrap
                                text: stCard.modelData.subtitle
                            }
                        }

                        MouseArea {
                            id: stMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.dispatchUserMessage(stCard.modelData.prompt)
                        }
                    }
                }
            }
        }

        // Список сообщений диалога
        ListView {
            id: chatList
            visible: root.messages.length > 0
            anchors.fill: parent
            anchors.margins: Theme.dp(12)
            spacing: Theme.dp(10)
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            model: root.messages

            delegate: Item {
                id: msgDelegate
                required property var modelData
                required property int index

                readonly property bool isUser: msgDelegate.modelData.role === "user"
                readonly property var codeBlocks: Array.isArray(msgDelegate.modelData.blocks)
                    ? msgDelegate.modelData.blocks : []

                width: chatList.width
                height: bubbleRect.implicitHeight

                Rectangle {
                    id: bubbleRect
                    width: msgDelegate.isUser
                        ? Math.min(parent.width * 0.82, userMsgCol.implicitWidth + Theme.dp(28))
                        : Math.min(parent.width * 0.94, parent.width)
                    anchors.right: msgDelegate.isUser ? parent.right : undefined
                    anchors.left: msgDelegate.isUser ? undefined : parent.left
                    implicitHeight: (msgDelegate.isUser ? userMsgCol.implicitHeight : assistantMsgCol.implicitHeight) + Theme.dp(22)
                    radius: Theme.shapeLgInc
                    bottomRightRadius: msgDelegate.isUser ? Theme.shapeXs : Theme.shapeLgInc
                    bottomLeftRadius: msgDelegate.isUser ? Theme.shapeLgInc : Theme.shapeXs
                    color: msgDelegate.isUser ? Theme.primaryContainer : Theme.mHigh

                    // ── Сообщение пользователя ──────────────────────────
                    ColumnLayout {
                        id: userMsgCol
                        visible: msgDelegate.isUser
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.margins: Theme.dp(11)
                        spacing: Theme.dp(6)

                        TextEdit {
                            Layout.fillWidth: true
                            readOnly: true
                            selectByMouse: true
                            wrapMode: TextEdit.Wrap
                            color: Theme.fgPrimaryContainer
                            selectionColor: Theme.alpha(Theme.fgPrimaryContainer, 0.25)
                            selectedTextColor: Theme.fgPrimaryContainer
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.typeSize("bodyMedium")
                            text: String(msgDelegate.modelData.content || "")
                        }

                        RowLayout {
                            Layout.alignment: Qt.AlignRight
                            spacing: Theme.dp(4)

                            IconButton {
                                size: "xs"
                                icon: "content_copy"
                                tooltip: "Копировать запрос"
                                tintOverride: Theme.fgPrimaryContainer
                                onClicked: root.copyToClipboard(msgDelegate.modelData.content, "Запрос скопирован")
                            }

                            IconButton {
                                size: "xs"
                                icon: "refresh"
                                tooltip: "Повторить запрос"
                                disabled: askProc.running
                                tintOverride: Theme.fgPrimaryContainer
                                onClicked: root.retryMessage(msgDelegate.modelData.content)
                            }
                        }
                    }

                    // ── Сообщение ИИ-ассистента ─────────────────────────
                    ColumnLayout {
                        id: assistantMsgCol
                        visible: !msgDelegate.isUser
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.margins: Theme.dp(12)
                        spacing: Theme.dp(8)

                        // Шапка ответа: провайдер + модель + копирование всего ответа
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Theme.dp(6)

                            Icon {
                                name: "auto_awesome"
                                size: Theme.dp(16)
                                color: Theme.primary
                                fill: 1
                            }

                            LText {
                                role: "labelMedium"
                                color: Theme.primary
                                text: String(msgDelegate.modelData.provider || root.currentProvider).toUpperCase()
                            }

                            LText {
                                Layout.fillWidth: true
                                role: "labelSmall"
                                color: Theme.subtext
                                elide: Text.ElideRight
                                text: "· " + String(msgDelegate.modelData.model || root.currentModel)
                            }

                            Chip {
                                size: "sm"
                                kind: "assist"
                                icon: "content_copy"
                                label: "Копировать ответ"
                                onClicked: root.copyToClipboard(msgDelegate.modelData.content, "Ответ скопирован в буфер")
                            }
                        }

                        // Основной текст ответа
                        TextEdit {
                            Layout.fillWidth: true
                            readOnly: true
                            selectByMouse: true
                            wrapMode: TextEdit.Wrap
                            color: Theme.text
                            selectionColor: Theme.alpha(Theme.primary, 0.3)
                            selectedTextColor: Theme.text
                            font.family: Theme.fontFamily
                            font.pixelSize: Theme.typeSize("bodyMedium")
                            text: String(msgDelegate.modelData.content || "")
                        }

                        // Интерактивные карточки для каждого извлечённого блока кода
                        Repeater {
                            model: msgDelegate.codeBlocks
                            delegate: Rectangle {
                                id: codeCard
                                required property var modelData
                                Layout.fillWidth: true
                                implicitHeight: codeCardCol.implicitHeight + Theme.dp(16)
                                radius: Theme.shapeMd
                                color: Theme.mLowest
                                border.width: 1
                                border.color: Theme.outline

                                ColumnLayout {
                                    id: codeCardCol
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.top: parent.top
                                    anchors.margins: Theme.dp(8)
                                    spacing: Theme.dp(6)

                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: Theme.dp(6)

                                        Rectangle {
                                            radius: Theme.shapeXs
                                            color: Theme.secondaryContainer
                                            implicitWidth: langBadge.implicitWidth + Theme.dp(10)
                                            implicitHeight: Theme.dp(20)

                                            LText {
                                                id: langBadge
                                                anchors.centerIn: parent
                                                role: "labelSmall"
                                                mono: true
                                                color: Theme.fgSecondaryContainer
                                                text: String(codeCard.modelData.lang || "code")
                                            }
                                        }

                                        Item { Layout.fillWidth: true }

                                        Chip {
                                            size: "sm"
                                            kind: "assist"
                                            icon: "content_copy"
                                            label: "Копировать код"
                                            onClicked: root.copyToClipboard(codeCard.modelData.code, "Код скопирован в буфер")
                                        }

                                        Chip {
                                            visible: root.isShellLang(codeCard.modelData.lang)
                                            size: "sm"
                                            kind: "assist"
                                            icon: "play_arrow"
                                            label: "▶ В терминал островка"
                                            onClicked: root.sendToIslandTerminal(codeCard.modelData.code)
                                        }
                                    }

                                    TextEdit {
                                        Layout.fillWidth: true
                                        readOnly: true
                                        selectByMouse: true
                                        wrapMode: TextEdit.Wrap
                                        color: Theme.text
                                        selectionColor: Theme.alpha(Theme.primary, 0.35)
                                        selectedTextColor: Theme.text
                                        font.family: "monospace"
                                        font.pixelSize: Theme.fs(12)
                                        text: String(codeCard.modelData.code || "")
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // Индикатор генерации ответа
        Rectangle {
            visible: askProc.running
            anchors.left: parent.left
            anchors.bottom: parent.bottom
            anchors.margins: Theme.dp(12)
            height: Theme.dp(46)
            width: Math.min(parent.width - Theme.dp(24), thinkingRow.implicitWidth + Theme.dp(24))
            radius: Theme.radiusPill
            color: Theme.alpha(Theme.mHighest, 0.94)
            border.width: 1
            border.color: Theme.outline

            RowLayout {
                id: thinkingRow
                anchors.centerIn: parent
                spacing: Theme.dp(10)

                LoadingIndicator {
                    Layout.preferredWidth: Theme.dp(28)
                    Layout.preferredHeight: Theme.dp(28)
                    running: askProc.running
                }

                LText {
                    role: "labelLarge"
                    color: Theme.text
                    text: "Генерация ответа (" + root.currentModel + ")…"
                }

                Button {
                    size: "xs"
                    variant: "tonal"
                    danger: true
                    icon: "stop"
                    text: "Стоп"
                    onClicked: root.stopGeneration()
                }
            }
        }

        // Всплывающий тост-статус
        Rectangle {
            visible: root.statusToast !== ""
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.margins: Theme.dp(12)
            height: Theme.dp(28)
            width: toastLabel.implicitWidth + Theme.dp(20)
            radius: Theme.radiusPill
            color: Theme.inverseSurface

            LText {
                id: toastLabel
                anchors.centerIn: parent
                role: "labelMedium"
                color: Theme.fgInverseSurface
                text: root.statusToast
            }
        }
    }

    // ── 5. НИЖНЯЯ СТРОКА ВВОДА ПРОМПТА ───────────────────────────────────
    RowLayout {
        Layout.fillWidth: true
        spacing: Theme.dp(8)

        TextField {
            id: promptField
            Layout.fillWidth: true
            variant: "search"
            icon: "auto_awesome"
            placeholder: root.attachClipboard
                ? "Добавьте комментарий к буферу обмена (Enter — отправить)…"
                : "Спросите что угодно или вставьте код (Enter — отправить)…"
            enabled: !askProc.running
            onAccepted: root.submitPrompt()
            onEscaped: {
                if (root.win && root.win.shell)
                    root.win.shell.closeOverlays();
            }
        }

        IconButton {
            size: "m"
            variant: "filled"
            icon: askProc.running ? "stop" : "send"
            tooltip: askProc.running ? "Остановить генерацию" : "Отправить запрос (Enter)"
            onClicked: {
                if (askProc.running)
                    root.stopGeneration();
                else
                    root.submitPrompt();
            }
        }
    }
}
