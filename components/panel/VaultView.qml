import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "../../core"
import "../../ui"
import ".."

FocusScope {
    id: page

    property var win: null
    property bool unlocked: false
    property bool hasVault: false
    property bool existsKnown: false
    property string masterPassword: ""
    property string requestPassword: ""
    property string searchQuery: ""
    property var entries: []
    property string errorText: ""
    property string statusText: ""
    property bool formOpen: false
    property int editingIndex: -1
    property int generation: 0
    readonly property string scriptPath: Quickshell.env("HOME") + "/oberon/scripts/vault.sh"

    readonly property var filteredEntries: {
        const result = [];
        const query = page.searchQuery.trim().toLowerCase();
        for (let i = 0; i < page.entries.length; i++) {
            const entry = page.entries[i] || {};
            const haystack = [entry.name, entry.user, entry.url].join(" ").toLowerCase();
            if (query === "" || haystack.indexOf(query) >= 0)
                result.push({ "index": i, "entry": entry });
        }
        return result;
    }

    visible: win !== null && win.mode === "panel" && win.page === "vault"
    Layout.fillWidth: true
    implicitWidth: content.implicitWidth
    implicitHeight: content.implicitHeight
    focus: visible

    onVisibleChanged: {
        if (visible) {
            page.existsKnown = false;
            page.errorText = "";
            page.refreshExists();
            Qt.callLater(() => {
                if (page.visible)
                    page.unlocked ? searchField.forceActiveFocus() : masterField.forceActiveFocus();
            });
        } else {
            page.lockVault();
        }
    }

    onActiveFocusChanged: {
        if (page.activeFocus && page.unlocked) {
            page.touch();
        } else if (!page.activeFocus && page.unlocked) {
            Qt.callLater(() => {
                if (page.visible && page.unlocked && !page.activeFocus)
                    page.lockVault();
            });
        }
    }

    Keys.priority: Keys.BeforeItem
    Keys.onPressed: (event) => {
        if (page.unlocked)
            page.touch();
    }

    function touch() {
        if (page.unlocked)
            idleTimer.restart();
    }

    function startVaultProcess(action, input, entriesJson, closeForm) {
        if (vaultProc.running)
            return false;
        vaultProc.requestAction = action;
        vaultProc.requestGeneration = page.generation;
        vaultProc.pendingInput = input === null ? "" : String(input);
        vaultProc.hasInput = input !== null;
        vaultProc.pendingEntriesJson = entriesJson || "";
        vaultProc.closeFormAfterSave = closeForm === true;
        vaultProc.output = "";
        vaultProc.stdinEnabled = vaultProc.hasInput;
        vaultProc.command = ["bash", page.scriptPath, action];
        vaultProc.running = true;
        return true;
    }

    function refreshExists() {
        if (!page.visible || vaultProc.running)
            return;
        page.existsKnown = false;
        page.startVaultProcess("exists", null, "", false);
    }

    function unlockVault() {
        const password = masterField.text;
        if (password === "") {
            page.errorText = "Введите мастер-пароль.";
            masterField.forceActiveFocus();
            return;
        }
        page.requestPassword = password;
        page.errorText = "";
        if (!page.startVaultProcess("unlock", password + "\n", "", false))
            page.requestPassword = "";
    }

    function createVault() {
        const password = masterField.text;
        if (password === "") {
            page.errorText = "Введите мастер-пароль.";
            masterField.forceActiveFocus();
            return;
        }
        page.requestPassword = password;
        page.errorText = "";
        if (!page.startVaultProcess("init", password + "\n", "", false))
            page.requestPassword = "";
    }

    function lockVault() {
        page.generation++;
        if (vaultProc.running)
            vaultProc.running = false;
        vaultProc.pendingInput = "";
        vaultProc.pendingEntriesJson = "";
        vaultProc.output = "";
        page.unlocked = false;
        page.masterPassword = "";
        page.requestPassword = "";
        page.entries = [];
        page.searchQuery = "";
        page.errorText = "";
        page.statusText = "";
        page.formOpen = false;
        page.editingIndex = -1;
        page.clearForm();
        idleTimer.stop();
        masterField.text = "";
    }

    function writeEntries(nextEntries, closeForm) {
        if (!page.unlocked || vaultProc.running)
            return;
        page.touch();
        page.errorText = "";
        page.statusText = "";
        const json = JSON.stringify(nextEntries);
        page.startVaultProcess("save", page.masterPassword + "\n" + json, json, closeForm);
    }

    function openForm(index) {
        page.touch();
        page.errorText = "";
        page.statusText = "";
        page.editingIndex = index;
        page.formOpen = true;
        const entry = index >= 0 ? page.entries[index] : null;
        formName.text = entry ? String(entry.name || "") : "";
        formUser.text = entry ? String(entry.user || "") : "";
        formPass.text = entry ? String(entry.pass || "") : "";
        formUrl.text = entry ? String(entry.url || "") : "";
        formNotes.text = entry ? String(entry.notes || "") : "";
        Qt.callLater(() => formName.forceActiveFocus());
    }

    function clearForm() {
        formName.text = "";
        formUser.text = "";
        formPass.text = "";
        formUrl.text = "";
        formNotes.text = "";
    }

    function closeForm() {
        page.formOpen = false;
        page.editingIndex = -1;
        page.clearForm();
        if (page.unlocked)
            Qt.callLater(() => searchField.forceActiveFocus());
    }

    function saveForm() {
        const name = formName.text.trim();
        if (name === "") {
            page.errorText = "Укажите название записи.";
            formName.forceActiveFocus();
            return;
        }
        const entry = {
            "name": name,
            "user": formUser.text,
            "pass": formPass.text,
            "url": formUrl.text,
            "notes": formNotes.text
        };
        const next = page.entries.slice();
        if (page.editingIndex >= 0 && page.editingIndex < next.length)
            next[page.editingIndex] = entry;
        else
            next.push(entry);
        page.writeEntries(next, true);
    }

    function deleteEntry(index) {
        if (!page.unlocked || index < 0 || index >= page.entries.length)
            return;
        page.touch();
        const next = page.entries.slice();
        next.splice(index, 1);
        page.writeEntries(next, false);
    }

    function copyText(value) {
        if (!page.unlocked)
            return;
        const text = String(value === undefined || value === null ? "" : value);
        if (text === "")
            return;
        page.touch();
        page.errorText = "";
        if (clipProc.running) {
            clipProc.queuedText = text;
            clipProc.hasQueuedText = true;
            return;
        }
        page.startClipboardCopy(text);
    }

    function startClipboardCopy(text) {
        clipProc.pendingText = text;
        clipProc.command = ["wl-copy"];
        clipProc.stdinEnabled = true;
        clipProc.running = true;
    }

    function finishVault(exitCode) {
        const action = vaultProc.requestAction;
        const generation = vaultProc.requestGeneration;
        const output = vaultProc.output.trim();
        const savedJson = vaultProc.pendingEntriesJson;
        const closeFormAfterSave = vaultProc.closeFormAfterSave;
        vaultProc.requestAction = "";
        vaultProc.pendingInput = "";
        vaultProc.pendingEntriesJson = "";
        vaultProc.output = "";

        if (generation !== page.generation || !page.visible) {
            page.requestPassword = "";
            if (page.visible)
                Qt.callLater(() => page.refreshExists());
            return;
        }

        if (action === "exists") {
            page.existsKnown = true;
            page.hasVault = output === "да";
            if (exitCode !== 0)
                page.errorText = "Не удалось проверить хранилище.";
            return;
        }

        if (action === "init") {
            if (exitCode !== 0) {
                page.requestPassword = "";
                page.errorText = "Не удалось создать хранилище.";
                masterField.text = "";
                Qt.callLater(() => page.refreshExists());
                return;
            }
            const password = page.requestPassword;
            page.hasVault = true;
            page.existsKnown = true;
            page.entries = [];
            page.masterPassword = password;
            page.requestPassword = "";
            masterField.text = "";
            page.unlocked = true;
            page.statusText = "Хранилище создано.";
            page.touch();
            Qt.callLater(() => searchField.forceActiveFocus());
            return;
        }

        if (action === "unlock") {
            if (exitCode === 2) {
                page.requestPassword = "";
                masterField.text = "";
                page.errorText = "Неверный мастер-пароль.";
                return;
            }
            if (exitCode !== 0) {
                page.requestPassword = "";
                masterField.text = "";
                page.errorText = "Не удалось открыть хранилище.";
                return;
            }
            try {
                const result = JSON.parse(output || "[]");
                if (!Array.isArray(result))
                    throw new Error("invalid vault data");
                page.entries = result;
            } catch (error) {
                page.requestPassword = "";
                masterField.text = "";
                page.errorText = "Не удалось прочитать хранилище.";
                return;
            }
            page.masterPassword = page.requestPassword;
            page.requestPassword = "";
            masterField.text = "";
            page.unlocked = true;
            page.statusText = "Хранилище открыто.";
            page.touch();
            Qt.callLater(() => searchField.forceActiveFocus());
            return;
        }

        if (action === "save") {
            if (exitCode === 2) {
                page.lockVault();
                page.errorText = "Хранилище изменилось. Разблокируйте его снова.";
                return;
            }
            if (exitCode !== 0) {
                page.errorText = "Не удалось сохранить хранилище.";
                return;
            }
            try {
                page.entries = JSON.parse(savedJson || "[]");
            } catch (error) {
                page.errorText = "Не удалось обновить список записей.";
                return;
            }
            page.errorText = "";
            page.statusText = "Сохранено.";
            page.touch();
            if (closeFormAfterSave)
                page.closeForm();
        }
    }

    function finishClipboard(exitCode) {
        if (exitCode === 0) {
            clipboardTimer.restart();
        } else {
            page.errorText = "Не удалось скопировать в буфер обмена.";
        }
        if (clipProc.hasQueuedText) {
            const next = clipProc.queuedText;
            clipProc.queuedText = "";
            clipProc.hasQueuedText = false;
            Qt.callLater(() => page.startClipboardCopy(next));
        }
    }

    Process {
        id: vaultProc
        property string requestAction: ""
        property int requestGeneration: 0
        property string pendingInput: ""
        property string pendingEntriesJson: ""
        property string output: ""
        property bool hasInput: false
        property bool closeFormAfterSave: false

        stdinEnabled: false
        stdout: SplitParser {
            onRead: line => vaultProc.output += line + "\n"
        }
        onStarted: {
            if (vaultProc.hasInput) {
                const input = vaultProc.pendingInput;
                vaultProc.pendingInput = "";
                vaultProc.hasInput = false;
                vaultProc.write(input);
                vaultProc.stdinEnabled = false;
            }
        }
        onExited: (exitCode) => page.finishVault(exitCode)
    }

    Process {
        id: clipProc
        property string pendingText: ""
        property string queuedText: ""
        property bool hasQueuedText: false

        stdinEnabled: false
        onStarted: {
            const text = clipProc.pendingText;
            clipProc.pendingText = "";
            clipProc.write(text);
            clipProc.stdinEnabled = false;
        }
        onExited: (exitCode) => page.finishClipboard(exitCode)
        onRunningChanged: if (!clipProc.running && clipProc.pendingText !== "") {
            clipProc.pendingText = "";
            clipProc.queuedText = "";
            clipProc.hasQueuedText = false;
        }
    }

    Timer {
        id: idleTimer
        interval: 15 * 60 * 1000
        onTriggered: page.lockVault()
    }

    Timer {
        id: clipboardTimer
        interval: 30 * 1000
        onTriggered: Quickshell.execDetached(["wl-copy", "--clear"])
    }

    HoverHandler {
        enabled: page.unlocked
        onPointChanged: page.touch()
    }

    ColumnLayout {
        id: content
        width: page.width
        spacing: Theme.pageSpacing

        Card {
            Layout.fillWidth: true
            visible: !page.unlocked
            title: page.hasVault ? "Разблокировка" : "Новое хранилище"

            LText {
                Layout.fillWidth: true
                text: page.hasVault
                    ? "Введите мастер-пароль, чтобы открыть хранилище."
                    : "Задайте мастер-пароль для нового зашифрованного хранилища."
                role: "bodySmall"
                color: Theme.subtext
                wrapMode: Text.WordWrap
            }

            TextField {
                id: masterField
                Layout.fillWidth: true
                label: "Мастер-пароль"
                placeholder: "Введите пароль"
                password: true
                enabled: !vaultProc.running
                onAccepted: page.hasVault ? page.unlockVault() : page.createVault()
                onTextEdited: page.errorText = ""
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.dp(8)

                Button {
                    text: "Открыть"
                    icon: "lock_open"
                    variant: "filled"
                    disabled: !page.existsKnown || !page.hasVault || vaultProc.running
                    onClicked: page.unlockVault()
                }

                Button {
                    visible: page.existsKnown && !page.hasVault
                    text: "Создать хранилище"
                    icon: "add"
                    variant: "tonal"
                    disabled: vaultProc.running
                    onClicked: page.createVault()
                }
            }

            LText {
                Layout.fillWidth: true
                visible: !page.existsKnown && !page.errorText
                text: "Проверяю хранилище…"
                role: "bodySmall"
                color: Theme.subtext
            }

            LText {
                Layout.fillWidth: true
                visible: page.errorText !== ""
                text: page.errorText
                role: "bodySmall"
                color: Theme.error
                wrapMode: Text.WordWrap
            }
        }

        ColumnLayout {
            visible: page.unlocked
            Layout.fillWidth: true
            spacing: Theme.pageSpacing

            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.dp(6)

                TextField {
                    id: searchField
                    Layout.fillWidth: true
                    variant: "search"
                    icon: "search"
                    placeholder: "Поиск записей"
                    text: page.searchQuery
                    enabled: !vaultProc.running
                    onTextEdited: {
                        page.searchQuery = text;
                        page.touch();
                    }
                }

                Button {
                    text: "Добавить запись"
                    icon: "add"
                    variant: "tonal"
                    disabled: vaultProc.running
                    onClicked: page.openForm(-1)
                }

                IconButton {
                    icon: "lock"
                    tooltip: "Заблокировать"
                    disabled: vaultProc.running
                    onClicked: page.lockVault()
                }
            }

            Card {
                Layout.fillWidth: true
                visible: page.formOpen
                title: page.editingIndex >= 0 ? "Редактировать запись" : "Новая запись"

                TextField {
                    id: formName
                    Layout.fillWidth: true
                    label: "Название"
                    placeholder: "Например, Почта"
                    enabled: !vaultProc.running
                    onAccepted: formUser.forceActiveFocus()
                    onTextEdited: page.touch()
                }
                TextField {
                    id: formUser
                    Layout.fillWidth: true
                    label: "Логин"
                    placeholder: "Имя пользователя"
                    enabled: !vaultProc.running
                    onAccepted: formPass.forceActiveFocus()
                    onTextEdited: page.touch()
                }
                TextField {
                    id: formPass
                    Layout.fillWidth: true
                    label: "Пароль"
                    placeholder: "Пароль записи"
                    password: true
                    enabled: !vaultProc.running
                    onAccepted: formUrl.forceActiveFocus()
                    onTextEdited: page.touch()
                }
                TextField {
                    id: formUrl
                    Layout.fillWidth: true
                    label: "Адрес"
                    placeholder: "https://"
                    enabled: !vaultProc.running
                    onAccepted: formNotes.forceActiveFocus()
                    onTextEdited: page.touch()
                }
                TextField {
                    id: formNotes
                    Layout.fillWidth: true
                    label: "Заметки"
                    placeholder: "Дополнительная информация"
                    enabled: !vaultProc.running
                    onAccepted: page.saveForm()
                    onTextEdited: page.touch()
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.dp(8)
                    Button {
                        text: "Сохранить"
                        icon: "save"
                        variant: "filled"
                        disabled: vaultProc.running
                        onClicked: page.saveForm()
                    }
                    Button {
                        text: "Отмена"
                        variant: "text"
                        disabled: vaultProc.running
                        onClicked: page.closeForm()
                    }
                }
            }

            Card {
                Layout.fillWidth: true
                title: "Записи"

                LText {
                    visible: page.entries.length === 0
                    Layout.fillWidth: true
                    text: "Хранилище пока пусто. Добавьте первую запись."
                    role: "bodySmall"
                    color: Theme.subtext
                }
                LText {
                    visible: page.entries.length > 0 && page.filteredEntries.length === 0
                    Layout.fillWidth: true
                    text: "Ничего не найдено."
                    role: "bodySmall"
                    color: Theme.subtext
                }

                Repeater {
                    model: page.filteredEntries
                    delegate: RowLayout {
                        required property var modelData
                        Layout.fillWidth: true
                        spacing: Theme.dp(2)

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0
                            LText {
                                Layout.fillWidth: true
                                text: String(modelData.entry.name || "Без названия")
                                role: "bodyLarge"
                                weight: 500
                                color: Theme.text
                                elide: Text.ElideRight
                            }
                            LText {
                                Layout.fillWidth: true
                                text: String(modelData.entry.user || modelData.entry.url || "Без логина")
                                role: "bodySmall"
                                color: Theme.subtext
                                elide: Text.ElideRight
                            }
                        }

                        IconButton {
                            size: "xs"
                            icon: "key"
                            tooltip: "Копировать пароль"
                            disabled: vaultProc.running
                            onClicked: page.copyText(modelData.entry.pass)
                        }
                        IconButton {
                            size: "xs"
                            icon: "person"
                            tooltip: "Копировать логин"
                            disabled: vaultProc.running
                            onClicked: page.copyText(modelData.entry.user)
                        }
                        IconButton {
                            size: "xs"
                            icon: "edit"
                            tooltip: "Редактировать"
                            disabled: vaultProc.running
                            onClicked: page.openForm(modelData.index)
                        }
                        IconButton {
                            size: "xs"
                            icon: "delete"
                            tooltip: "Удалить"
                            disabled: vaultProc.running
                            onClicked: page.deleteEntry(modelData.index)
                        }
                    }
                }
            }

            LText {
                Layout.fillWidth: true
                visible: page.errorText !== ""
                text: page.errorText
                role: "bodySmall"
                color: Theme.error
                wrapMode: Text.WordWrap
            }
            LText {
                Layout.fillWidth: true
                visible: page.statusText !== ""
                text: page.statusText
                role: "bodySmall"
                color: Theme.success
            }
            LText {
                Layout.fillWidth: true
                text: "Автоблокировка после 15 минут бездействия. Пароль хранится только в памяти открытого хранилища."
                role: "bodySmall"
                color: Theme.subtextDim
                wrapMode: Text.WordWrap
            }
        }
    }
}
